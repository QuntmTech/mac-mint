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
}

@MainActor
private final class TestTokens {
  var value: String?
  var storage: AccountTokenStorage {
    AccountTokenStorage(load: { self.value }, save: { self.value = $0 }, delete: { self.value = nil })
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
  func goOffline() { offline = true }
  func removeDevice() { removed = true }
  func respond(_ request: URLRequest) throws -> (Data, URLResponse) {
    if offline { throw URLError(.notConnectedToInternet) }
    let path = request.url!.path
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
