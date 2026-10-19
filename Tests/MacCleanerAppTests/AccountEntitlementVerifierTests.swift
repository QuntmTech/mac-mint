import CryptoKit
import Foundation
import MacCleanerCore
import XCTest
@testable import MacCleanerApp

/// CryptoKit must accept exactly what the server's tweetnacl signer produces.
final class AccountEntitlementVerifierTests: XCTestCase {
  /// Produced by backend/pocketbase/pb_hooks/macmint_entitlement.js with the disposable test seed
  /// 000102…1f (backend/tests/entitlements.test.cjs), user1, ABCDEF0123456789, issued 1800000000.
  private let serverVector = "eyJhY3RpdmUiOnRydWUsImRldmljZV9pZCI6IkFCQ0RFRjAxMjM0NTY3ODkiLCJleHBpcmVzX2F0IjpudWxsLCJpc3N1ZWRfYXQiOjE4MDAwMDAwMDAsImtpZCI6Im1tLXRlc3QtMSIsIm9mZmxpbmVfdW50aWwiOjE4MDEyMDk2MDAsInBsYW4iOiJwcm8iLCJ1c2VyX2lkIjoidXNlcjEiLCJ2IjoxfQ.5ultdfhb-3pEE38G_aKeqPfbVrWmKHoM_shIY_zhNC78gdoGuQFPUnq1V6dBKwPeLru9DhFnv7gv0vlbid_TCQ"
  private let testKey = ["mm-test-1": "A6EHv/POEL4dcN0Y50vAmWfk1jCbpQ1fHdyGZBJVMbg="]

  func testServerSignedAssertionVerifiesWithCryptoKit() throws {
    let verifier = CryptoKitEntitlementVerifier(base64Keys: testKey)
    let signed = try SignedEntitlement.verify(serverVector, verifier: verifier, userId: "user1", deviceId: "ABCDEF0123456789")
    XCTAssertEqual(signed.claims.keyID, "mm-test-1")
    XCTAssertEqual(signed.claims.issuedAt, Date(timeIntervalSince1970: 1_800_000_000))
    XCTAssertEqual(signed.claims.offlineUntil, Date(timeIntervalSince1970: 1_800_000_000 + 14 * 86_400))
    XCTAssertNil(signed.claims.expiresAt)

    var signature = Array(serverVector.split(separator: ".")[1])
    signature[10] = signature[10] == "A" ? "B" : "A"
    let tampered = serverVector.split(separator: ".")[0] + "." + String(signature)
    XCTAssertThrowsError(try SignedEntitlement.verify(String(tampered), verifier: verifier, userId: "user1", deviceId: "ABCDEF0123456789")) {
      XCTAssertEqual($0 as? EntitlementAssertionError, .badSignature)
    }
  }

  func testProductionKeysAreWellFormedAndDoNotTrustTestKeys() throws {
    XCTAssertFalse(CryptoKitEntitlementVerifier.productionKeys.isEmpty)
    for (kid, encoded) in CryptoKitEntitlementVerifier.productionKeys {
      let raw = try XCTUnwrap(Data(base64Encoded: encoded), kid)
      XCTAssertNoThrow(try Curve25519.Signing.PublicKey(rawRepresentation: raw), kid)
      XCTAssertFalse(testKey.values.contains(encoded))
    }
    XCTAssertThrowsError(try SignedEntitlement.verify(serverVector, verifier: CryptoKitEntitlementVerifier.production,
      userId: "user1", deviceId: "ABCDEF0123456789")) {
      XCTAssertEqual($0 as? EntitlementAssertionError, .unknownKey)
    }
    let malformed = CryptoKitEntitlementVerifier(keys: ["mm-test-1": Data([1, 2, 3])])
    XCTAssertEqual(malformed.check(signature: Data(count: 64), message: Data(), keyID: "mm-test-1"), .unknownKey)
  }
}
