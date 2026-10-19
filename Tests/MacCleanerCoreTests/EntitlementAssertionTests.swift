import XCTest

@testable import MacCleanerCore

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

/// Portable stand-in for Ed25519: a "signature" is a keyed SHA-256 of the message, padded to 64
/// bytes. The real CryptoKit verifier is exercised by the macOS app tests.
private struct FakeVerifier: EntitlementSignatureVerifier {
  var keys: [String: String] = ["test-kid": "fixture-secret"]

  func check(signature: Data, message: Data, keyID: String) -> EntitlementSignatureCheck {
    guard let secret = keys[keyID] else { return .unknownKey }
    return signature == Self.sign(message, secret: secret) ? .valid : .invalid
  }

  static func sign(_ message: Data, secret: String) -> Data {
    let digest = SHA256.hexDigest(data: Data(secret.utf8) + message)
    return Data(digest.utf8.prefix(64))
  }

  static func assertion(_ claims: EntitlementClaims, secret: String = "fixture-secret") throws -> String {
    let message = try JSONEncoder().encode(claims)
    return Base64URL.encode(message) + "." + Base64URL.encode(sign(message, secret: secret))
  }
}

final class EntitlementAssertionTests: XCTestCase {
  private let issued = Date(timeIntervalSince1970: 1_800_000_000)
  private let verifier = FakeVerifier()

  private func claims(
    user: String = "user1", device: String = "ABCDEF0123456789", active: Bool = true,
    kid: String = "test-kid", version: Int = 1, expires: Date? = nil, graceDays: Double = 14
  ) -> EntitlementClaims {
    EntitlementClaims(
      version: version, keyID: kid, userId: user, deviceId: device, active: active,
      expiresAt: expires, issuedAt: issued, offlineUntil: issued.addingTimeInterval(graceDays * 86_400))
  }

  private func verify(_ compact: String, user: String = "user1", device: String = "ABCDEF0123456789")
    -> Result<SignedEntitlement, EntitlementAssertionError>
  {
    Result { try SignedEntitlement.verify(compact, verifier: verifier, userId: user, deviceId: device) }
      .mapError { $0 as? EntitlementAssertionError ?? .malformed }
  }

  func testServerWireFormatDecodesWithIntegerSecondsAndNullExpiry() throws {
    // Byte-for-byte what macmint_entitlement.js signs (canonical, sorted keys).
    let json = #"{"active":true,"device_id":"ABCDEF0123456789","expires_at":null,"issued_at":1800000000,"kid":"test-kid","offline_until":1801209600,"plan":"pro","user_id":"user1","v":1}"#
    let message = Data(json.utf8)
    let compact = Base64URL.encode(message) + "." + Base64URL.encode(FakeVerifier.sign(message, secret: "fixture-secret"))
    let signed = try verify(compact).get()
    XCTAssertEqual(signed.claims, claims())
    XCTAssertNil(signed.claims.expiresAt)
    XCTAssertEqual(signed.claims.offlineUntil, issued.addingTimeInterval(14 * 86_400))
    XCTAssertThrowsError(try JSONDecoder().decode(EntitlementClaims.self, from: Data(json.replacingOccurrences(of: "1800000000", with: "1.5").utf8)))
  }

  func testTamperedPayloadOrSignatureIsRejected() throws {
    let compact = try FakeVerifier.assertion(claims())
    XCTAssertNoThrow(try verify(compact).get())
    let parts = compact.split(separator: ".").map(String.init)
    let forgedClaims = claims(graceDays: 3650)
    let forged = Base64URL.encode(try JSONEncoder().encode(forgedClaims)) + "." + parts[1]
    XCTAssertEqual(verify(forged).failure, .badSignature)
    let otherKey = try FakeVerifier.assertion(claims(), secret: "attacker")
    XCTAssertEqual(verify(otherKey).failure, .badSignature)
    for broken in ["", "a", parts[0], parts[0] + ".", "." + parts[1], compact + ".x", parts[0] + ".AAAA",
      "!!!." + parts[1], parts[0] + "=." + parts[1]]
    {
      XCTAssertEqual(verify(broken).failure, .malformed, broken)
    }
  }

  func testBindingVersionKeyAndActivityAreEnforced() throws {
    XCTAssertEqual(verify(try FakeVerifier.assertion(claims()), user: "someone-else").failure, .wrongUser)
    XCTAssertEqual(verify(try FakeVerifier.assertion(claims()), device: "FFFFFFFFFFFFFFFF").failure, .wrongDevice)
    XCTAssertEqual(verify(try FakeVerifier.assertion(claims(kid: "retired-or-unknown"))).failure, .unknownKey)
    XCTAssertEqual(verify(try FakeVerifier.assertion(claims(version: 2))).failure, .unsupportedVersion)
    XCTAssertEqual(verify(try FakeVerifier.assertion(claims(active: false))).failure, .inactive)
  }

  func testOfflineWindowExpiryAndClockRollback() throws {
    let signed = try verify(try FakeVerifier.assertion(claims())).get()
    let check = { (now: Date, highWater: Date?) in OfflineEntitlementPolicy.check(signed, now: now, highWater: highWater) }
    XCTAssertNil(check(issued.addingTimeInterval(60), nil))
    XCTAssertNil(check(issued.addingTimeInterval(14 * 86_400 - 1), nil))
    XCTAssertEqual(check(issued.addingTimeInterval(14 * 86_400), nil), .offlineWindowEnded)
    // A clock set before the server's own issue time is rejected even without a stored mark.
    XCTAssertNil(check(issued.addingTimeInterval(-299), nil))
    XCTAssertEqual(check(issued.addingTimeInterval(-301), nil), .clockRollback)
    let seen = issued.addingTimeInterval(10 * 86_400)
    XCTAssertNil(check(seen.addingTimeInterval(-200), seen))
    XCTAssertEqual(check(seen.addingTimeInterval(-3 * 86_400), seen), .clockRollback)
    XCTAssertEqual(OfflineEntitlementPolicy.advance(seen, to: issued), seen)
    XCTAssertEqual(OfflineEntitlementPolicy.advance(nil, to: issued), issued)
    XCTAssertEqual(OfflineEntitlementPolicy.advance(issued, to: seen), seen)

    let expiring = try verify(try FakeVerifier.assertion(claims(expires: issued.addingTimeInterval(86_400)))).get()
    XCTAssertNil(OfflineEntitlementPolicy.check(expiring, now: issued.addingTimeInterval(86_399), highWater: nil))
    XCTAssertEqual(OfflineEntitlementPolicy.check(expiring, now: issued.addingTimeInterval(86_400), highWater: nil), .expired)

    let excessive = try verify(try FakeVerifier.assertion(claims(graceDays: 365))).get()
    XCTAssertEqual(OfflineEntitlementPolicy.check(excessive, now: issued.addingTimeInterval(61 * 86_400), highWater: nil), .offlineWindowEnded)
  }

  func testLegacyServerWithoutAssertionUnlocksOnlineOnly() throws {
    let user = AccountUser(id: "user1", email: "a@b.co")
    let pro = Entitlement(plan: "pro", status: "active", active: true, maxDevices: 3)
    XCTAssertEqual(OnlineEntitlement.evaluate(AccountSnapshot(user: user, entitlement: pro), deviceId: "ABCDEF0123456789", verifier: verifier), .unsigned)
    let good = AccountSnapshot(user: user, entitlement: pro, entitlementAssertion: try FakeVerifier.assertion(claims()))
    guard case .signed(let signed) = OnlineEntitlement.evaluate(good, deviceId: "ABCDEF0123456789", verifier: verifier) else {
      return XCTFail("A valid assertion must verify")
    }
    XCTAssertEqual(signed.claims.userId, "user1")
    let forged = AccountSnapshot(user: user, entitlement: pro, entitlementAssertion: try FakeVerifier.assertion(claims(), secret: "attacker"))
    XCTAssertEqual(OnlineEntitlement.evaluate(forged, deviceId: "ABCDEF0123456789", verifier: verifier), .rejected(.badSignature))
    XCTAssertEqual(OnlineEntitlement.evaluate(good, deviceId: "another-device-0001", verifier: verifier), .rejected(.wrongDevice))
  }

  func testStoredRecordIsSessionBoundAndEditsDoNotGrantAccess() throws {
    let compact = try FakeVerifier.assertion(claims())
    let snapshot = AccountSnapshot(user: AccountUser(id: "user1", email: "a@b.co"),
      entitlement: Entitlement(plan: "pro", status: "active", active: true, maxDevices: 3))
    let record = OfflineEntitlementRecord(token: "token-a", userId: "user1", assertion: compact, highWater: issued, snapshot: snapshot)
    let decoded = try XCTUnwrap(OfflineEntitlementRecord.decode(try record.encoded()))
    XCTAssertEqual(decoded, record)
    XCTAssertNotNil(decoded.verified(token: "token-a", deviceId: "ABCDEF0123456789", verifier: verifier))
    XCTAssertNil(decoded.verified(token: "token-b", deviceId: "ABCDEF0123456789", verifier: verifier))
    XCTAssertNil(decoded.verified(token: "token-a", deviceId: "FFFFFFFFFFFFFFFF", verifier: verifier))
    XCTAssertNotNil(decoded.rebound(to: "token-b").verified(token: "token-b", deviceId: "ABCDEF0123456789", verifier: verifier))
    XCTAssertEqual(decoded.with(highWater: issued.addingTimeInterval(5)).highWater, issued.addingTimeInterval(5))

    // Editing the stored JSON (the old forgery: active, no expiry, fresh date) gains nothing.
    var object = try XCTUnwrap(try JSONSerialization.jsonObject(with: try record.encoded()) as? [String: Any])
    let payload = try XCTUnwrap(String(compact.split(separator: ".")[0]))
    var forgedClaims = try XCTUnwrap(try JSONSerialization.jsonObject(with: try XCTUnwrap(Base64URL.decode(payload))) as? [String: Any])
    forgedClaims["offline_until"] = 4_000_000_000
    let forgedPayload = Base64URL.encode(try JSONSerialization.data(withJSONObject: forgedClaims))
    object["assertion"] = forgedPayload + "." + compact.split(separator: ".")[1]
    let edited = try XCTUnwrap(OfflineEntitlementRecord.decode(try JSONSerialization.data(withJSONObject: object)))
    XCTAssertNil(edited.verified(token: "token-a", deviceId: "ABCDEF0123456789", verifier: verifier))
    object["userId"] = "someone-else"
    object["assertion"] = compact
    let rebound = try XCTUnwrap(OfflineEntitlementRecord.decode(try JSONSerialization.data(withJSONObject: object)))
    XCTAssertNil(rebound.verified(token: "token-a", deviceId: "ABCDEF0123456789", verifier: verifier))
    XCTAssertNil(OfflineEntitlementRecord.decode(Data("{\"tokenFingerprint\":1}".utf8)))
  }

  func testSnapshotDecodesTheAdditiveAssertionField() async throws {
    let json = """
      {"user":{"id":"u1","email":"a@b.co"},"entitlement":{"plan":"pro","status":"active","active":true,"expires_at":null,"max_devices":3},
       "devices":[],"entitlement_assertion":"abc.def"}
      """
    let client = AccountClient(baseURL: URL(string: "https://example.test")!) { request in
      (Data(json.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
    let snapshot = try await client.me(token: "t", deviceId: "ABCDEF0123456789")
    XCTAssertEqual(snapshot.entitlementAssertion, "abc.def")
    XCTAssertNil(snapshot.withoutAssertion.entitlementAssertion)
  }
}

private extension Result {
  var failure: Failure? {
    if case .failure(let error) = self { return error }
    return nil
  }
}
