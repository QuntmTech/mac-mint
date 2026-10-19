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

  func testActivationReactivatesOnlyWhenExplicitlyRequested() async throws {
    let device = DeviceInfo(deviceId: "ABCDEF0123456789", name: "n", model: "m", osVersion: "o", appVersion: "v")
    for (explicit, expected) in [(nil, false), (false, false), (true, true)] as [(Bool?, Bool)] {
      let box = RequestBox()
      let client = client(status: 200, json: meJSON, capture: box)
      if let explicit {
        _ = try await client.activate(device, token: "t", reactivate: explicit)
      } else {
        _ = try await client.activate(device, token: "t")
      }
      let body = try XCTUnwrap(try JSONSerialization.jsonObject(with: XCTUnwrap(box.request?.httpBody)) as? [String: Any])
      XCTAssertEqual(body["reactivate"] as? Bool, expected)
      XCTAssertEqual(body["device_id"] as? String, "ABCDEF0123456789")
    }
    let json = #"{"error":"device_deactivated","message":"This Mac was removed from your account."}"#
    do {
      _ = try await client(status: 409, json: json).activate(device, token: "t")
      XCTFail("expected error")
    } catch let error as AccountAPIError {
      XCTAssertEqual(error.code, "device_deactivated")
      XCTAssertFalse(error.isTransient)
    }
  }

  func testVerificationAndRedemptionNameThisMacForAnAssertion() async throws {
    let box = RequestBox()
    _ = try await client(status: 200, json: meJSON, capture: box).me(token: "t", deviceId: "ABCDEF0123456789")
    XCTAssertEqual(box.request?.url?.path, "/api/macmint/me")
    XCTAssertEqual(box.request?.url?.query, "device_id=ABCDEF0123456789")
    XCTAssertEqual(box.request?.cachePolicy, .reloadIgnoringLocalCacheData)
    _ = try await client(status: 200, json: meJSON, capture: box).me(token: "t")
    XCTAssertNil(box.request?.url?.query)
    _ = try await client(status: 200, json: meJSON, capture: box).redeem(code: "MINT-1", token: "t", deviceId: "ABCDEF0123456789")
    let body = try XCTUnwrap(try JSONSerialization.jsonObject(with: XCTUnwrap(box.request?.httpBody)) as? [String: String])
    XCTAssertEqual(body, ["code": "MINT-1", "device_id": "ABCDEF0123456789"])
  }

  func testTransportFailuresAreClassifiedWithoutMakingCancellationOrTLSOfflineEligible() async {
    let cases: [(Error, String)] = [
      (CancellationError(), "cancelled"), (URLError(.cancelled), "cancelled"),
      (URLError(.serverCertificateUntrusted), "tls"), (URLError(.secureConnectionFailed), "tls"),
      (URLError(.serverCertificateHasUnknownRoot), "tls"), (URLError(.notConnectedToInternet), "network"),
      (URLError(.timedOut), "network"), (NSError(domain: "other", code: 1), "network"),
    ]
    for (thrown, code) in cases {
      let failing = AccountClient(baseURL: base) { _ in throw thrown }
      do {
        _ = try await failing.me(token: "t")
        XCTFail("expected error")
      } catch let error as AccountAPIError {
        XCTAssertEqual(error.code, code, "\(thrown)")
        XCTAssertEqual(error.isNetwork, code == "network")
        XCTAssertEqual(error.isCancellation, code == "cancelled")
        XCTAssertEqual(error.isSecureConnectionFailure, code == "tls")
        XCTAssertEqual(error.isTransient, code == "network")
      } catch {
        XCTFail("unexpected \(error)")
      }
    }
    for status in [404, 408, 425, 429, 500, 502, 503] {
      XCTAssertTrue(AccountClient.apiError(status: status, data: Data()).isTransient, "\(status)")
    }
    for status in [400, 401, 402, 403, 409] {
      XCTAssertFalse(AccountClient.apiError(status: status, data: Data()).isTransient, "\(status)")
    }
  }

  func testAccountSessionNeverCachesAuthorizedResponses() {
    let configuration = AccountClient.sessionConfiguration()
    XCTAssertNil(configuration.urlCache)
    XCTAssertEqual(configuration.requestCachePolicy, .reloadIgnoringLocalCacheData)
    XCTAssertNil(configuration.httpCookieStorage)
    XCTAssertFalse(configuration.httpShouldSetCookies)
    XCTAssertEqual(configuration.timeoutIntervalForResource, AccountClient.resourceTimeout)
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

  func testMalformedExpiryAndContradictoryPlanCannotUnlockOffline() {
    let now = Date()
    for entitlement in [
      Entitlement(plan: "pro", status: "active", active: true, expiresAt: "not a date", maxDevices: 3),
      Entitlement(plan: "pro", status: "active", active: true, expiresAt: "", maxDevices: 3),
      Entitlement(plan: "free", status: "active", active: true, maxDevices: 3),
      Entitlement(plan: "pro", status: "revoked", active: true, maxDevices: 3),
    ] {
      let snapshot = AccountSnapshot(user: AccountUser(id: "u", email: "e"), entitlement: entitlement)
      XCTAssertFalse(AccessPolicy.allowsOffline(CachedAccess(snapshot: snapshot, verifiedAt: now), now: now))
      XCTAssertFalse(entitlement.isLifetime)
    }
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

final class ReleaseCheckerTests: XCTestCase {
  func testVersionOrdering() {
    XCTAssertLessThan(AppVersion("0.9.3"), AppVersion("0.10.0"))
    XCTAssertEqual(AppVersion("1.0"), AppVersion("1.0.0"))
    XCTAssertLessThan(AppVersion("1.2.0-beta"), AppVersion("1.2.1"))
  }

  func testStatusPrefersRequiredOverAvailable() {
    let latest = ReleaseInfo(version: "0.6.0", downloadUrl: "https://x")
    XCTAssertEqual(ReleaseChecker.status(current: "0.6.0", latest: latest, minimum: "0.3.0"), .current)
    XCTAssertEqual(
      ReleaseChecker.status(current: "0.5.0", latest: latest, minimum: "0.3.0"), .available(latest))
    XCTAssertEqual(
      ReleaseChecker.status(current: "0.2.9", latest: latest, minimum: "0.3.0"),
      .required(latest, minimum: "0.3.0"))
  }

  func testCheckDecodesPocketBaseCollections() async throws {
    let checker = ReleaseChecker(baseURL: URL(string: "https://example.test")!) { request in
      let path = request.url!.path
      let body =
        path.contains("app_releases")
        ? #"{"items":[{"version":"0.7.0","build":7,"download_url":"https://dl/MacMint.zip","min_os":"14.0"}]}"#
        : #"{"items":[{"key":"client","value":{"min_version":"0.3.0","offline_grace_days":14}}]}"#
      return (
        Data(body.utf8),
        HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
      )
    }
    let status = try await checker.check(currentVersion: "0.5.0")
    guard case .available(let release) = status else { return XCTFail("expected update, got \(status)") }
    XCTAssertEqual(release.version, "0.7.0")
    XCTAssertEqual(release.downloadUrl, "https://dl/MacMint.zip")
  }
}
