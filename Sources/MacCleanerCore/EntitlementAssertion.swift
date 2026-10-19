import Foundation

// MARK: - Signed entitlement assertions (mirror backend/pocketbase/pb_hooks/macmint_entitlement.js)

/// Claims the server signs for one account and one Mac. Times are integer Unix seconds on the wire.
public struct EntitlementClaims: Hashable, Sendable {
  public let version: Int
  public let keyID: String
  public let userId: String
  public let deviceId: String
  public let plan: String
  public let active: Bool
  public let expiresAt: Date?
  public let issuedAt: Date
  public let offlineUntil: Date

  public init(
    version: Int = 1, keyID: String, userId: String, deviceId: String, plan: String = "pro",
    active: Bool = true, expiresAt: Date? = nil, issuedAt: Date, offlineUntil: Date
  ) {
    self.version = version
    self.keyID = keyID
    self.userId = userId
    self.deviceId = deviceId
    self.plan = plan
    self.active = active
    self.expiresAt = expiresAt
    self.issuedAt = issuedAt
    self.offlineUntil = offlineUntil
  }
}

extension EntitlementClaims: Codable {
  enum CodingKeys: String, CodingKey {
    case version = "v", keyID = "kid", userId = "user_id", deviceId = "device_id", plan, active
    case expiresAt = "expires_at", issuedAt = "issued_at", offlineUntil = "offline_until"
  }

  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    version = try c.decode(Int.self, forKey: .version)
    keyID = try c.decode(String.self, forKey: .keyID)
    userId = try c.decode(String.self, forKey: .userId)
    deviceId = try c.decode(String.self, forKey: .deviceId)
    plan = try c.decode(String.self, forKey: .plan)
    active = try c.decode(Bool.self, forKey: .active)
    expiresAt = try c.decodeIfPresent(Int64.self, forKey: .expiresAt).map(Self.date)
    issuedAt = Self.date(try c.decode(Int64.self, forKey: .issuedAt))
    offlineUntil = Self.date(try c.decode(Int64.self, forKey: .offlineUntil))
  }

  public func encode(to encoder: Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    try c.encode(version, forKey: .version)
    try c.encode(keyID, forKey: .keyID)
    try c.encode(userId, forKey: .userId)
    try c.encode(deviceId, forKey: .deviceId)
    try c.encode(plan, forKey: .plan)
    try c.encode(active, forKey: .active)
    if let expiresAt { try c.encode(Self.seconds(expiresAt), forKey: .expiresAt) } else { try c.encodeNil(forKey: .expiresAt) }
    try c.encode(Self.seconds(issuedAt), forKey: .issuedAt)
    try c.encode(Self.seconds(offlineUntil), forKey: .offlineUntil)
  }

  static func date(_ seconds: Int64) -> Date { Date(timeIntervalSince1970: TimeInterval(seconds)) }
  static func seconds(_ date: Date) -> Int64 { Int64(date.timeIntervalSince1970.rounded(.down)) }
}

public enum EntitlementSignatureCheck: Sendable, Equatable {
  case valid, invalid, unknownKey
}

/// Checks an Ed25519 signature against a public key the app trusts. The app supplies CryptoKit;
/// portable tests inject a fake.
public protocol EntitlementSignatureVerifier: Sendable {
  func check(signature: Data, message: Data, keyID: String) -> EntitlementSignatureCheck
}

public enum EntitlementAssertionError: Error, Equatable, Sendable {
  case malformed, unsupportedVersion, unknownKey, badSignature, wrongUser, wrongDevice, inactive
  case expired, offlineWindowEnded, clockRollback
}

/// A verified assertion: signature, version and the user/device binding hold. Time is separate,
/// because an online check must not depend on the local clock.
public struct SignedEntitlement: Hashable, Sendable {
  public static let supportedVersion = 1
  public let compact: String
  public let claims: EntitlementClaims

  public static func verify(
    _ compact: String, verifier: any EntitlementSignatureVerifier, userId: String, deviceId: String
  ) throws -> SignedEntitlement {
    let parts = compact.split(separator: ".", omittingEmptySubsequences: false)
    guard compact.count <= 4096, parts.count == 2, let message = Base64URL.decode(parts[0]),
      let signature = Base64URL.decode(parts[1]), signature.count == 64,
      let claims = try? JSONDecoder().decode(EntitlementClaims.self, from: message)
    else { throw EntitlementAssertionError.malformed }
    guard claims.version == supportedVersion else { throw EntitlementAssertionError.unsupportedVersion }
    switch verifier.check(signature: signature, message: message, keyID: claims.keyID) {
    case .valid: break
    case .invalid: throw EntitlementAssertionError.badSignature
    case .unknownKey: throw EntitlementAssertionError.unknownKey
    }
    guard claims.userId == userId else { throw EntitlementAssertionError.wrongUser }
    guard claims.deviceId == deviceId else { throw EntitlementAssertionError.wrongDevice }
    guard claims.active else { throw EntitlementAssertionError.inactive }
    return SignedEntitlement(compact: compact, claims: claims)
  }
}

public enum OfflineEntitlementPolicy {
  /// Tolerated backwards clock movement, e.g. an NTP correction after sleep.
  public static let clockSkew: TimeInterval = 300
  /// Defense in depth against a misconfigured server grace (it clamps to the same bound).
  public static let maximumWindow: TimeInterval = 60 * 86_400

  /// Whether a verified assertion unlocks without the server. `highWater` is the latest time this
  /// Mac has seen; the assertion's own issue time also counts, so deleting it gains nothing.
  public static func check(_ entitlement: SignedEntitlement, now: Date, highWater: Date?)
    -> EntitlementAssertionError?
  {
    let claims = entitlement.claims
    let seen = max(highWater ?? claims.issuedAt, claims.issuedAt)
    if now < seen.addingTimeInterval(-clockSkew) { return .clockRollback }
    if let expiry = claims.expiresAt, now >= expiry { return .expired }
    let until = min(claims.offlineUntil, claims.issuedAt.addingTimeInterval(maximumWindow))
    if now >= until { return .offlineWindowEnded }
    return nil
  }

  /// The high-water mark only moves forward.
  public static func advance(_ highWater: Date?, to now: Date) -> Date {
    guard let highWater else { return now }
    return max(highWater, now)
  }
}

/// What a successful online response means for access.
public enum OnlineEntitlement: Equatable, Sendable {
  /// The server predates signed assertions: unlock for this session only, nothing offline.
  case unsigned
  case signed(SignedEntitlement)
  case rejected(EntitlementAssertionError)

  public static func evaluate(
    _ snapshot: AccountSnapshot, deviceId: String, verifier: any EntitlementSignatureVerifier
  ) -> OnlineEntitlement {
    guard let compact = snapshot.entitlementAssertion else { return .unsigned }
    do {
      return .signed(
        try SignedEntitlement.verify(
          compact, verifier: verifier, userId: snapshot.user.id, deviceId: deviceId))
    } catch let error as EntitlementAssertionError {
      return .rejected(error)
    } catch {
      return .rejected(.malformed)
    }
  }
}

/// Persisted offline evidence (Keychain in the app). Nothing here is trusted until the assertion
/// verifies again; the snapshot is display-only and the high-water mark only blocks clock rollback.
public struct OfflineEntitlementRecord: Codable, Hashable, Sendable {
  public let tokenFingerprint: String
  public let userId: String
  public let assertion: String
  public let highWater: Date
  public let snapshot: AccountSnapshot?

  public init(token: String, userId: String, assertion: String, highWater: Date, snapshot: AccountSnapshot?) {
    self.init(fingerprint: Self.fingerprint(token), userId: userId, assertion: assertion,
      highWater: highWater, snapshot: snapshot)
  }

  init(fingerprint: String, userId: String, assertion: String, highWater: Date, snapshot: AccountSnapshot?) {
    self.tokenFingerprint = fingerprint
    self.userId = userId
    self.assertion = assertion
    self.highWater = highWater
    self.snapshot = snapshot
  }

  public func rebound(to token: String) -> Self {
    Self(token: token, userId: userId, assertion: assertion, highWater: highWater, snapshot: snapshot)
  }

  public func with(highWater: Date) -> Self {
    Self(fingerprint: tokenFingerprint, userId: userId, assertion: assertion, highWater: highWater, snapshot: snapshot)
  }

  public func belongs(to token: String) -> Bool { tokenFingerprint == Self.fingerprint(token) }

  public static func fingerprint(_ token: String) -> String { SHA256.hexDigest(data: Data(token.utf8)) }

  public func encoded() throws -> Data {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .secondsSince1970
    return try encoder.encode(self)
  }

  public static func decode(_ data: Data) -> Self? {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .secondsSince1970
    return try? decoder.decode(Self.self, from: data)
  }

  /// Re-verifies the stored assertion for this session and Mac; nil when anything is off.
  public func verified(token: String, deviceId: String, verifier: any EntitlementSignatureVerifier)
    -> SignedEntitlement?
  {
    guard belongs(to: token) else { return nil }
    return try? SignedEntitlement.verify(assertion, verifier: verifier, userId: userId, deviceId: deviceId)
  }
}

public enum Base64URL {
  public static func decode<S: StringProtocol>(_ text: S) -> Data? {
    var value = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
    guard !value.contains("=") else { return nil }
    if value.count % 4 == 1 { return nil }
    value += String(repeating: "=", count: (4 - value.count % 4) % 4)
    return Data(base64Encoded: value)
  }

  public static func encode(_ data: Data) -> String {
    data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
  }
}
