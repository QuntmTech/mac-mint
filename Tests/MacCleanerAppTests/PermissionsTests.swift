import Foundation
import Photos
import UserNotifications
import XCTest
@testable import MacCleanerApp

@MainActor
final class PermissionsTests: XCTestCase {
  func testPhotoStatusKeepsDeniedRestrictedAndLimitedDistinct() {
    XCTAssertEqual(PhotosPermissionState(.notDetermined), .notRequested)
    XCTAssertEqual(PhotosPermissionState(.authorized), .allowed)
    XCTAssertEqual(PhotosPermissionState(.limited), .limited)
    XCTAssertEqual(PhotosPermissionState(.denied), .denied)
    XCTAssertEqual(PhotosPermissionState(.restricted), .restricted)
    XCTAssertTrue(PhotosPermissionState(.denied).requiresSettings)
    XCTAssertTrue(PhotosPermissionState(.restricted).requiresSettings)
    XCTAssertFalse(PhotosPermissionState(.notDetermined).requiresSettings)
    XCTAssertFalse(PhotosPermissionState(.limited).requiresSettings)
  }

  func testSettingsFailureFallsBackWithoutClaimingPermissionWasGranted() async {
    var opened: [URL] = []
    let service = PermissionsService(readPhotos: { .denied }, readNotifications: { .denied },
      openURL: { opened.append($0); return false })
    await service.refresh()
    service.open(.photos)
    XCTAssertEqual(opened, [PermissionSettingsPane.photos.url,
      URL(fileURLWithPath: "/System/Applications/System Settings.app")])
    XCTAssertEqual(service.photos, .denied)
    XCTAssertTrue(service.settingsError?.contains(PermissionSettingsPane.photos.path) == true)
    XCTAssertEqual(service.notifications, .denied)
  }

  func testSuccessfulSettingsLinkDoesNotOpenFallbackOrChangeStatus() async {
    var opened: [URL] = []
    let service = PermissionsService(readPhotos: { .restricted }, readNotifications: { .notDetermined },
      openURL: { opened.append($0); return true })
    await service.refresh()
    service.open(.fullDiskAccess)
    XCTAssertEqual(opened, [PermissionSettingsPane.fullDiskAccess.url])
    XCTAssertNil(service.settingsError)
    XCTAssertEqual(service.photos, .restricted)
    XCTAssertEqual(service.notifications, .notRequested)
    // App Management has its own written path; opening general Privacy & Security
    // deliberately does not pretend an undocumented pane anchor is supported.
    XCTAssertEqual(PermissionSettingsPane.appManagement.url.query, nil)
    XCTAssertTrue(PermissionSettingsPane.appManagement.path.hasSuffix("App Management"))
  }

  func testLateStatusRefreshCannotReplaceNewerAuthorization() async {
    let fixture = DelayedPermissionFixture()
    let service = PermissionsService(readPhotos: { fixture.photoStatus },
      readNotifications: { await fixture.readStatus() })
    let first = Task { await service.refresh() }
    for _ in 0..<100 {
      if fixture.pending != nil { break }
      await Task.yield()
    }
    XCTAssertNotNil(fixture.pending)
    fixture.photoStatus = .limited
    await service.refresh()
    fixture.pending?.resume(returning: .denied)
    fixture.pending = nil
    await first.value
    XCTAssertEqual(service.photos, .limited)
    XCTAssertEqual(service.notifications, .enabled)
  }

  func testCareRefreshDoesNotRequestNotificationPermission() async {
    let fixture = NotificationFixture()
    let care = CareService(notifications: fixture.client)
    await care.refreshAuthorization()
    XCTAssertEqual(care.notificationPermission, .notRequested)
    XCTAssertEqual(fixture.requests, 0)
    fixture.status = .denied
    await care.refreshAuthorization()
    XCTAssertTrue(care.notificationsDenied)
    await care.requestAuthorization()
    XCTAssertEqual(fixture.requests, 0, "Denied access needs Settings, not another permission request")
    fixture.status = .authorized
    await care.refreshAuthorization()
    XCTAssertFalse(care.notificationsDenied)
    XCTAssertEqual(fixture.requests, 0)
  }

  func testExplicitReminderOptInRequestsOnlyUndeterminedAccess() async {
    let fixture = NotificationFixture()
    let care = CareService(notifications: fixture.client)
    await care.requestAuthorization()
    XCTAssertEqual(fixture.requests, 1)
    XCTAssertEqual(care.notificationPermission, .enabled)
    await care.requestAuthorization()
    XCTAssertEqual(fixture.requests, 1)
  }

  func testDeniedAndFailedRemindersDoNotConsumeTheReminderCooldown() async throws {
    let name = "MacMint-PermissionTests-\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
    defer { defaults.removePersistentDomain(forName: name) }
    defaults.set(true, forKey: CareService.Keys.scanReminders)
    let fixture = NotificationFixture()
    fixture.status = .denied
    let care = CareService(defaults: defaults, notifications: fixture.client)
    let noon = try XCTUnwrap(Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 17, hour: 12)))
    await care.refreshAuthorization()
    care.evaluate(now: noon)
    await Task.yield()
    XCTAssertEqual(fixture.scheduled, 0)
    XCTAssertNil(defaults.object(forKey: CareService.Keys.lastScanReminder))

    fixture.status = .authorized
    fixture.failScheduling = true
    await care.refreshAuthorization()
    care.evaluate(now: noon)
    for _ in 0..<100 {
      if care.notificationError != nil { break }
      await Task.yield()
    }
    XCTAssertEqual(fixture.scheduled, 1)
    XCTAssertNotNil(care.notificationError)
    XCTAssertNil(defaults.object(forKey: CareService.Keys.lastScanReminder))

    fixture.failScheduling = false
    care.evaluate(now: noon)
    care.evaluate(now: noon)
    for _ in 0..<100 {
      if defaults.object(forKey: CareService.Keys.lastScanReminder) != nil { break }
      await Task.yield()
    }
    XCTAssertEqual(fixture.scheduled, 2, "Concurrent evaluations must share one pending notification")
    XCTAssertEqual(defaults.object(forKey: CareService.Keys.lastScanReminder) as? Date, noon)
    XCTAssertNil(care.notificationError)
    care.evaluate(now: noon)
    await Task.yield()
    XCTAssertEqual(fixture.scheduled, 2)
  }
}

@MainActor
private final class DelayedPermissionFixture {
  var photoStatus = PHAuthorizationStatus.denied
  var pending: CheckedContinuation<UNAuthorizationStatus?, Never>?
  private var reads = 0
  func readStatus() async -> UNAuthorizationStatus? {
    reads += 1
    if reads == 1 { return await withCheckedContinuation { pending = $0 } }
    return .authorized
  }
}

@MainActor
private final class NotificationFixture {
  var status = UNAuthorizationStatus.notDetermined
  var requests = 0
  var scheduled = 0
  var failScheduling = false
  var client: CareNotificationClient {
    CareNotificationClient(available: true, status: { self.status }, request: {
      self.requests += 1
      self.status = .authorized
      return true
    }, add: { _ in
      self.scheduled += 1
      if self.failScheduling { throw URLError(.cannotConnectToHost) }
    })
  }
}
