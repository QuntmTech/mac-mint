import Foundation
import MacCleanerCore
import XCTest
@testable import MacCleanerApp

@MainActor
final class AccountLifecycleTests: XCTestCase {
  private let device = DeviceInfo(deviceId: "native-integration-device", name: "Fixture", model: "Fixture",
    osVersion: "test", appVersion: "test")

  func testForegroundVerificationCannotExtendFourteenDayOfflineGrace() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let fixture = AccountFixture(), clock = TestClock()
    let tokens = TestTokens()
    let store = AccountStore(supportDirectory: folder, client: AccountClient(transport: { try await fixture.respond($0) }),
      deviceInfo: device, tokenStorage: tokens.storage, now: { clock.now })
    await store.signIn(email: "fixture@example.invalid", password: "fixture")
    XCTAssertTrue(store.isUnlocked)
    await fixture.goOffline()
    clock.advance(14 * 86_400 - 1)
    await store.refreshAccess()
    XCTAssertEqual(store.phase, .active(offline: true))
    XCTAssertTrue(store.isUnlocked)
    clock.advance(2)
    XCTAssertFalse(store.isUnlocked)
    await store.refreshAccess()
    if case .failed = store.phase {} else { XCTFail("Expired grace must leave the active phase") }
    XCTAssertFalse(store.isUnlocked)
  }

  func testForegroundVerificationDoesNotReactivateRemovedDevice() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let fixture = AccountFixture(), tokens = TestTokens()
    let store = AccountStore(supportDirectory: folder, client: AccountClient(transport: { try await fixture.respond($0) }),
      deviceInfo: device, tokenStorage: tokens.storage)
    await store.signIn(email: "fixture@example.invalid", password: "fixture")
    await fixture.removeDevice()
    await store.refreshAccess()
    XCTAssertFalse(store.isUnlocked)
    let firstCount = await fixture.activations
    XCTAssertEqual(firstCount, 1)
    await store.signIn(email: "fixture@example.invalid", password: "fixture")
    XCTAssertTrue(store.isUnlocked)
    let secondCount = await fixture.activations
    XCTAssertEqual(secondCount, 2)
    await store.signOut()
    XCTAssertFalse(store.isUnlocked)
    XCTAssertNil(tokens.value)
  }

  func testLateVerificationCannotRestoreAccessAfterSignOut() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let fixture = AccountFixture(), tokens = TestTokens()
    let store = AccountStore(supportDirectory: folder, client: AccountClient(transport: { try await fixture.respond($0) }),
      deviceInfo: device, tokenStorage: tokens.storage)
    await store.signIn(email: "fixture@example.invalid", password: "fixture")
    await fixture.holdNextVerification()
    let checking = Task { await store.refreshAccess() }
    for _ in 0..<100 {
      if await fixture.isPaused { break }
      try await Task.sleep(for: .milliseconds(10))
    }
    let paused = await fixture.isPaused
    XCTAssertTrue(paused)
    await store.signOut()
    await fixture.resumeVerification()
    await checking.value
    XCTAssertEqual(store.phase, .signedOut)
    XCTAssertNil(tokens.value)
    XCTAssertFalse(store.isUnlocked)
    XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("account.json").path))
  }

  func testDelayedAuthenticationAndActivationCannotUndoSignOut() async throws {
    for suffix in ["auth-with-password", "/activate"] {
      let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
      defer { try? FileManager.default.removeItem(at: folder) }
      let fixture = AccountFixture(), tokens = TestTokens()
      let store = AccountStore(supportDirectory: folder, client: AccountClient(transport: { try await fixture.respond($0) }),
        deviceInfo: device, tokenStorage: tokens.storage)
      await fixture.hold(suffix)
      let signingIn = Task { await store.signIn(email: "fixture@example.invalid", password: "fixture") }
      try await waitUntilPaused(fixture)
      let signingOut = Task { await store.signOut() }
      // Sign-out clears local access before waiting for an outstanding activation.
      for _ in 0..<100 {
        if store.phase == .signedOut { break }
        try await Task.sleep(for: .milliseconds(10))
      }
      XCTAssertEqual(store.phase, .signedOut)
      XCTAssertFalse(store.isBusy)
      await fixture.resumeVerification()
      await signingIn.value
      await signingOut.value
      XCTAssertEqual(store.phase, .signedOut, suffix)
      XCTAssertNil(tokens.value, suffix)
      XCTAssertFalse(store.isUnlocked, suffix)
    }
  }

  func testSlowRemoteSignOutDoesNotRetainAccessOrEraseANewerSignIn() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let fixture = AccountFixture(), tokens = TestTokens()
    let store = AccountStore(supportDirectory: folder, client: AccountClient(transport: { try await fixture.respond($0) }),
      deviceInfo: device, tokenStorage: tokens.storage)
    await store.signIn(email: "fixture@example.invalid", password: "fixture")
    await fixture.hold("/deactivate")
    let signingOut = Task { await store.signOut() }
    try await waitUntilPaused(fixture)
    XCTAssertEqual(store.phase, .signedOut)
    XCTAssertFalse(store.isUnlocked)
    XCTAssertNil(tokens.value)
    let newSignIn = Task { await store.signIn(email: "fixture@example.invalid", password: "fixture") }
    await fixture.resumeVerification()
    await signingOut.value
    await newSignIn.value
    XCTAssertTrue(store.isUnlocked)
    XCTAssertEqual(tokens.value, "fixture-token")
  }

  func testVerifiedAccessSurvivesCacheWriteFailureAndReportsIt() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    // A file where the support directory should be guarantees failure even as root.
    try Data().write(to: folder)
    let fixture = AccountFixture(), tokens = TestTokens()
    let store = AccountStore(supportDirectory: folder, client: AccountClient(transport: { try await fixture.respond($0) }),
      deviceInfo: device, tokenStorage: tokens.storage)
    await store.signIn(email: "fixture@example.invalid", password: "fixture")
    XCTAssertTrue(store.isUnlocked)
    XCTAssertTrue(store.infoMessage?.contains("offline access could not be saved") == true)
    await fixture.goOffline()
    await store.refreshAccess()
    XCTAssertTrue(store.isUnlocked)
    XCTAssertTrue(store.isOffline)
  }

  func testOfflineCacheIsBoundToTheStoredSession() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let fixture = AccountFixture(), tokens = TestTokens()
    let client = AccountClient(transport: { try await fixture.respond($0) })
    let first = AccountStore(supportDirectory: folder, client: client, deviceInfo: device, tokenStorage: tokens.storage)
    await first.signIn(email: "fixture@example.invalid", password: "fixture")
    await fixture.goOffline()
    let restarted = AccountStore(supportDirectory: folder, client: client, deviceInfo: device, tokenStorage: tokens.storage)
    await restarted.start()
    XCTAssertTrue(restarted.isUnlocked)
    tokens.value = "another-account-token"
    let different = AccountStore(supportDirectory: folder, client: client, deviceInfo: device, tokenStorage: tokens.storage)
    await different.start()
    XCTAssertFalse(different.isUnlocked)
  }

  func testRepeatedSubmitDoesNotLaunchOverlappingAuthentication() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let fixture = AccountFixture(), tokens = TestTokens()
    let store = AccountStore(supportDirectory: folder, client: AccountClient(transport: { try await fixture.respond($0) }),
      deviceInfo: device, tokenStorage: tokens.storage)
    await fixture.hold("auth-with-password")
    let first = Task { await store.signIn(email: "fixture@example.invalid", password: "fixture") }
    try await waitUntilPaused(fixture)
    await store.signIn(email: "fixture@example.invalid", password: "fixture")
    let count = await fixture.authentications
    XCTAssertEqual(count, 1)
    await fixture.resumeVerification()
    await first.value
    XCTAssertTrue(store.isUnlocked)
  }

  private func waitUntilPaused(_ fixture: AccountFixture) async throws {
    for _ in 0..<200 {
      if await fixture.isPaused { return }
      try await Task.sleep(for: .milliseconds(10))
    }
    XCTFail("The intended network boundary was not reached")
  }
}

@MainActor
private final class TestTokens {
  var value: String?
  var storage: AccountTokenStorage {
    AccountTokenStorage(load: { self.value }, save: { self.value = $0; return true }, delete: { self.value = nil })
  }
}

private final class TestClock: @unchecked Sendable {
  private let lock = NSLock()
  private var date = Date()
  var now: Date { lock.lock(); defer { lock.unlock() }; return date }
  func advance(_ interval: TimeInterval) { lock.lock(); defer { lock.unlock() }; date.addTimeInterval(interval) }
}

private actor AccountFixture {
  var offline = false
  var removed = false
  var activations = 0
  var authentications = 0
  private var pauseSuffix: String?
  private var pending: CheckedContinuation<Void, Never>?
  var isPaused: Bool { pending != nil }
  func goOffline() { offline = true }
  func removeDevice() { removed = true }
  func holdNextVerification() { hold("/me") }
  func hold(_ suffix: String) { pauseSuffix = suffix }
  func resumeVerification() { pending?.resume(); pending = nil }
  func respond(_ request: URLRequest) async throws -> (Data, URLResponse) {
    if offline { throw URLError(.notConnectedToInternet) }
    let path = request.url!.path
    if path.hasSuffix("auth-with-password") { authentications += 1 }
    if let suffix = pauseSuffix, path.hasSuffix(suffix) {
      pauseSuffix = nil
      await withCheckedContinuation { pending = $0 }
    }
    var body: [String: Any] = [:]
    if path.hasSuffix("auth-with-password") || path.hasSuffix("auth-refresh") {
      body = ["token": "fixture-token", "record": ["id": "fixture", "email": "fixture@example.invalid", "verified": true]]
    } else if !path.hasSuffix("deactivate") {
      if path.hasSuffix("activate") { activations += 1; removed = false }
      body = ["user": ["id": "fixture", "email": "fixture@example.invalid", "verified": true],
        "entitlement": ["plan": "pro", "status": "active", "active": true, "max_devices": 1],
        "devices": removed ? [] : [["id": "device", "device_id": "native-integration-device", "name": "Fixture",
          "model": "Fixture", "os_version": "test", "app_version": "test", "last_seen": ""]]]
    }
    return (try JSONSerialization.data(withJSONObject: body), HTTPURLResponse(url: request.url!,
      statusCode: 200, httpVersion: nil, headerFields: nil)!)
  }
}
