import XCTest

@testable import MacCleanerCore

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

final class AccountTests: XCTestCase {
  private let base = URL(string: "https://example.test")!

  private func client(status: Int, json: String, capture: RequestBox? = nil) -> AccountClient {
    AccountClient(baseURL: base) { request in
      capture?.set(request)
      let response = HTTPURLResponse(
        url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
      return (Data(json.utf8), response)
    }
  }

  private let meJSON = """
    {"user":{"id":"u1","email":"a@b.co","name":"A","verified":true},
     "entitlement":{"plan":"pro","status":"active","active":true,"expires_at":null,"max_devices":10,"source":"demo"},
     "devices":[{"id":"d1","device_id":"ABCDEF0123456789","name":"Mac","model":"Mac15,3","os_version":"15.0","app_version":"0.3.0","last_seen":"2026-10-16 01:27:16.200Z"}],
     "server_time":"2026-10-16T01:27:16.202Z"}
    """

  func testDecodesSnapshotFromServerPayload() async throws {
    let box = RequestBox()
    let snapshot = try await client(status: 200, json: meJSON, capture: box).me(token: "tok")
    XCTAssertEqual(snapshot.user.email, "a@b.co")
    XCTAssertTrue(snapshot.entitlement.active)
    XCTAssertTrue(snapshot.entitlement.isLifetime)
    XCTAssertEqual(snapshot.entitlement.maxDevices, 10)
    XCTAssertEqual(snapshot.devices.first?.deviceId, "ABCDEF0123456789")
    XCTAssertNotNil(snapshot.devices.first?.lastSeenDate)
    XCTAssertEqual(box.request?.value(forHTTPHeaderField: "Authorization"), "tok")
    XCTAssertEqual(box.request?.url?.path, "/api/macmint/me")
  }

  func testDeviceLimitErrorCarriesDeviceList() async {
    let json = """
      {"error":"device_limit","message":"MacMint is already active on 3 Macs.","limit":3,
       "devices":[{"id":"d1","device_id":"ABCDEF0123456789","name":"Studio","last_seen":""}]}
      """
    do {
      _ = try await client(status: 409, json: json).activate(
        DeviceInfo(deviceId: "X", name: "n", model: "m", osVersion: "o", appVersion: "v"),
        token: "t")
      XCTFail("expected error")
    } catch let error as AccountAPIError {
      XCTAssertEqual(error.code, "device_limit")
      XCTAssertEqual(error.devices.map(\.name), ["Studio"])
      XCTAssertEqual(error.message, "MacMint is already active on 3 Macs.")
    } catch {
      XCTFail("unexpected \(error)")
    }
  }

  func testPocketBaseFieldErrorsBecomeReadableMessages() {
    let json = """
      {"status":400,"message":"Failed to create record.","data":{"email":{"code":"validation_not_unique","message":"Value must be unique."}}}
      """
    let error = AccountClient.apiError(status: 400, data: Data(json.utf8))
    XCTAssertEqual(error.message, "Email: Value must be unique.")
  }

  func testUnauthorizedAndNetworkErrorsAreClassified() async {
    XCTAssertTrue(AccountClient.apiError(status: 401, data: Data("{}".utf8)).isUnauthorized)
    let offline = AccountClient(baseURL: base) { _ in throw URLError(.notConnectedToInternet) }
    do {
      _ = try await offline.me(token: "t")
      XCTFail("expected error")
    } catch let error as AccountAPIError {
      XCTAssertTrue(error.isNetwork)
    } catch {
      XCTFail("unexpected \(error)")
    }
  }

  func testOfflineGraceAllowsRecentActiveAccessOnly() {
    let now = Date()
    let active = Entitlement(plan: "pro", status: "active", active: true, maxDevices: 3)
    let snapshot = AccountSnapshot(user: AccountUser(id: "u", email: "e"), entitlement: active)

    XCTAssertTrue(
      AccessPolicy.allowsOffline(
        CachedAccess(snapshot: snapshot, verifiedAt: now.addingTimeInterval(-3 * 86_400)), now: now))
    XCTAssertFalse(
      AccessPolicy.allowsOffline(
        CachedAccess(snapshot: snapshot, verifiedAt: now.addingTimeInterval(-15 * 86_400)), now: now))
    XCTAssertFalse(AccessPolicy.allowsOffline(nil, now: now))

    let inactive = AccountSnapshot(
      user: AccountUser(id: "u", email: "e"),
      entitlement: Entitlement(plan: "free", status: "active", active: false, maxDevices: 0))
    XCTAssertFalse(
      AccessPolicy.allowsOffline(CachedAccess(snapshot: inactive, verifiedAt: now), now: now))

    let lapsed = AccountSnapshot(
      user: AccountUser(id: "u", email: "e"),
      entitlement: Entitlement(
        plan: "pro", status: "active", active: true, expiresAt: "2020-01-01T00:00:00Z",
        maxDevices: 3))
    XCTAssertFalse(
      AccessPolicy.allowsOffline(CachedAccess(snapshot: lapsed, verifiedAt: now), now: now))
  }

  func testCachedAccessRoundTripsThroughJSON() throws {
    let cached = CachedAccess(
      snapshot: AccountSnapshot(
        user: AccountUser(id: "u", email: "e"),
        entitlement: Entitlement(plan: "pro", status: "active", active: true, maxDevices: 3)),
      verifiedAt: Date(timeIntervalSince1970: 1_800_000_000))
    let data = try JSONEncoder().encode(cached)
    XCTAssertEqual(try JSONDecoder().decode(CachedAccess.self, from: data), cached)
  }
}

final class RequestBox: @unchecked Sendable {
  private let lock = NSLock()
  private var stored: URLRequest?

  func set(_ request: URLRequest) {
    lock.lock()
    stored = request
    lock.unlock()
  }

  var request: URLRequest? {
    lock.lock()
    defer { lock.unlock() }
    return stored
  }
}
