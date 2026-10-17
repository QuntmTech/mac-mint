import CryptoKit
import Foundation
import MacCleanerCore

/// Verifies server entitlement assertions with Ed25519 public keys compiled into the app.
/// Keys are listed by `kid` so a new key can ship before the server switches to it; remove a
/// key only after its assertions can no longer be within their offline window. docs/ENTITLEMENTS.md
struct CryptoKitEntitlementVerifier: EntitlementSignatureVerifier {
  /// Production signing keys (raw 32-byte Ed25519 public keys, base64).
  static let productionKeys: [String: String] = [
    "mm-ent-2026-10": "g9rOE6LVZtQmiwfDzIXhnEP7SEzGp49TZDw3iDs9rCw="
  ]

  static let production = CryptoKitEntitlementVerifier(base64Keys: productionKeys)

  private let keys: [String: Data]

  init(keys: [String: Data]) { self.keys = keys }

  init(base64Keys: [String: String]) {
    keys = base64Keys.compactMapValues { Data(base64Encoded: $0) }
  }

  func check(signature: Data, message: Data, keyID: String) -> EntitlementSignatureCheck {
    guard let raw = keys[keyID], let key = try? Curve25519.Signing.PublicKey(rawRepresentation: raw) else {
      return .unknownKey
    }
    return key.isValidSignature(signature, for: message) ? .valid : .invalid
  }
}
