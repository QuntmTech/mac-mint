import Foundation

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

// MARK: - Models (mirror backend/pocketbase/pb_hooks/macmint.pb.js)

public struct AccountUser: Codable, Hashable, Sendable {
  public let id: String
  public let email: String
  public let name: String?
  public let verified: Bool?

  public init(id: String, email: String, name: String? = nil, verified: Bool? = nil) {
    self.id = id
    self.email = email
    self.name = name
    self.verified = verified
  }
}

public struct Entitlement: Codable, Hashable, Sendable {
  public let plan: String
  public let status: String
  public let active: Bool
  public let expiresAt: String?
  public let maxDevices: Int
  public let source: String?

  public init(
    plan: String, status: String, active: Bool, expiresAt: String? = nil, maxDevices: Int,
    source: String? = nil
  ) {
    self.plan = plan
    self.status = status
    self.active = active
    self.expiresAt = expiresAt
    self.maxDevices = maxDevices
    self.source = source
  }

  public var expiryDate: Date? { expiresAt.flatMap(AccountDates.parse) }
  public var isLifetime: Bool { active && plan == "pro" && status == "active" && expiresAt == nil }
}

public struct RegisteredDevice: Codable, Hashable, Sendable, Identifiable {
  public let id: String
  public let deviceId: String
  public let name: String
  public let model: String?
  public let osVersion: String?
  public let appVersion: String?
  public let lastSeen: String?

  public init(
    id: String, deviceId: String, name: String, model: String? = nil, osVersion: String? = nil,
    appVersion: String? = nil, lastSeen: String? = nil
  ) {
    self.id = id
    self.deviceId = deviceId
    self.name = name
    self.model = model
    self.osVersion = osVersion
    self.appVersion = appVersion
    self.lastSeen = lastSeen
  }

  public var lastSeenDate: Date? { lastSeen.flatMap(AccountDates.parse) }
}

public struct AccountSnapshot: Codable, Hashable, Sendable {
  public let user: AccountUser
  public let entitlement: Entitlement
  public let devices: [RegisteredDevice]
  public let device: RegisteredDevice?
  public let serverTime: String?

  public init(
    user: AccountUser, entitlement: Entitlement, devices: [RegisteredDevice] = [],
    device: RegisteredDevice? = nil, serverTime: String? = nil
  ) {
    self.user = user
    self.entitlement = entitlement
    self.devices = devices
    self.device = device
    self.serverTime = serverTime
  }
}

public struct AuthSession: Codable, Hashable, Sendable {
  public let token: String
  public let user: AccountUser
}

public struct DeviceInfo: Codable, Hashable, Sendable {
  public let deviceId: String
  public let name: String
  public let model: String
  public let osVersion: String
  public let appVersion: String

  public init(deviceId: String, name: String, model: String, osVersion: String, appVersion: String)
  {
    self.deviceId = deviceId
    self.name = name
    self.model = model
    self.osVersion = osVersion
    self.appVersion = appVersion
  }
}

public struct AccountAPIError: LocalizedError, Hashable, Sendable {
  public let status: Int
  public let code: String
  public let message: String
  public let devices: [RegisteredDevice]

  public init(status: Int, code: String, message: String, devices: [RegisteredDevice] = []) {
    self.status = status
    self.code = code
    self.message = message
    self.devices = devices
  }

  public var errorDescription: String? { message }
  /// The stored session is no longer valid and the user must sign in again.
  public var isUnauthorized: Bool { status == 401 || status == 403 && code == "unauthorized" }
  public var isNetwork: Bool { status == 0 }
}

public enum AccountDates {
  /// Accepts ISO 8601 and PocketBase's "yyyy-MM-dd HH:mm:ss.SSSZ" format.
  public static func parse(_ value: String) -> Date? {
    let trimmed = value.trimmingCharacters(in: .whitespaces)
    guard !trimmed.isEmpty else { return nil }
    let normalized = trimmed.replacingOccurrences(of: " ", with: "T")
    let withFraction = ISO8601DateFormatter()
    withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = withFraction.date(from: normalized) { return date }
    let plain = ISO8601DateFormatter()
    plain.formatOptions = [.withInternetDateTime]
    return plain.date(from: normalized)
  }
}

// MARK: - Access policy

public struct CachedAccess: Codable, Hashable, Sendable {
  public let snapshot: AccountSnapshot
  public let verifiedAt: Date

  public init(snapshot: AccountSnapshot, verifiedAt: Date) {
    self.snapshot = snapshot
    self.verifiedAt = verifiedAt
  }
}

public enum AccessPolicy {
  public static let defaultOfflineGraceDays = 14

  /// Whether a previously verified entitlement may unlock the app while the server is unreachable.
  public static func allowsOffline(
    _ cached: CachedAccess?, now: Date = Date(), graceDays: Int = defaultOfflineGraceDays
  ) -> Bool {
    guard let cached, cached.snapshot.entitlement.active,
      cached.snapshot.entitlement.plan == "pro", cached.snapshot.entitlement.status == "active",
      graceDays >= 0 else { return false }
    if cached.snapshot.entitlement.expiresAt != nil && cached.snapshot.entitlement.expiryDate == nil { return false }
    if let expiry = cached.snapshot.entitlement.expiryDate, expiry <= now { return false }
    let age = now.timeIntervalSince(cached.verifiedAt)
    return age >= -300 && age <= Double(graceDays) * 86_400
  }
}

// MARK: - Client

public struct AccountClient: Sendable {
  public typealias Transport = @Sendable (URLRequest) async throws -> (Data, URLResponse)

  public static let defaultBaseURL = URL(string: "https://macmint.cloudpod.pro")!

  public let baseURL: URL
  let transport: Transport

  public init(baseURL: URL = AccountClient.defaultBaseURL, transport: Transport? = nil) {
    self.baseURL = baseURL
    self.transport =
      transport ?? { request in try await URLSession.shared.data(for: request) }
  }

  public func signIn(email: String, password: String) async throws -> AuthSession {
    let response: AuthResponse = try await send(
      "POST", "/api/collections/users/auth-with-password",
      body: ["identity": email.trimmingCharacters(in: .whitespaces), "password": password])
    return AuthSession(token: response.token, user: response.record)
  }

  public func signUp(email: String, password: String, name: String) async throws -> AuthSession {
    let trimmedEmail = email.trimmingCharacters(in: .whitespaces)
    let _: AccountUser = try await send(
      "POST", "/api/collections/users/records",
      body: [
        "email": trimmedEmail, "password": password, "passwordConfirm": password,
        "name": name.trimmingCharacters(in: .whitespaces),
      ])
    return try await signIn(email: trimmedEmail, password: password)
  }

  public func refresh(token: String) async throws -> AuthSession {
    let response: AuthResponse = try await send(
      "POST", "/api/collections/users/auth-refresh", token: token)
    return AuthSession(token: response.token, user: response.record)
  }

  public func requestPasswordReset(email: String) async throws {
    let _: EmptyResponse = try await send(
      "POST", "/api/collections/users/request-password-reset",
      body: ["email": email.trimmingCharacters(in: .whitespaces)])
  }

  public func me(token: String) async throws -> AccountSnapshot {
    try await send("GET", "/api/macmint/me", token: token)
  }

  public func redeem(code: String, token: String) async throws -> AccountSnapshot {
    try await send("POST", "/api/macmint/redeem", token: token, body: ["code": code])
  }

  public func activate(_ device: DeviceInfo, token: String) async throws -> AccountSnapshot {
    let fields: [String: Any] = [
      "device_id": device.deviceId, "reactivate": true, "name": device.name, "model": device.model,
      "os_version": device.osVersion, "app_version": device.appVersion,
    ]
    return try await send("POST", "/api/macmint/devices/activate", token: token,
      bodyData: JSONSerialization.data(withJSONObject: fields))
  }

  public func deactivate(deviceId: String, token: String) async throws {
    let _: EmptyResponse = try await send(
      "POST", "/api/macmint/devices/deactivate", token: token, body: ["device_id": deviceId])
  }

  // MARK: Transport

  private struct AuthResponse: Decodable {
    let token: String
    let record: AccountUser
  }

  private struct EmptyResponse: Decodable {}

  private struct ErrorBody: Decodable {
    let error: String?
    let message: String?
    let devices: [RegisteredDevice]?
    let data: [String: FieldError]?
  }

  private struct FieldError: Decodable {
    let code: String?
    let message: String?
  }

  private static let decoder: JSONDecoder = {
    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    return decoder
  }()

  private func send<T: Decodable>(
    _ method: String, _ path: String, token: String? = nil, body: [String: String]? = nil
  ) async throws -> T {
    try await send(
      method, path, token: token,
      bodyData: try body.map { try JSONSerialization.data(withJSONObject: $0) })
  }

  /// Sends any Encodable body (camelCase keys) — used by the AI routes.
  func send<T: Decodable, Body: Encodable>(
    _ method: String, _ path: String, token: String?, json body: Body, timeout: TimeInterval
  ) async throws -> T {
    try await send(method, path, token: token, bodyData: try JSONEncoder().encode(body), timeout: timeout)
  }

  private func send<T: Decodable>(
    _ method: String, _ path: String, token: String?, bodyData: Data?, timeout: TimeInterval = 20
  ) async throws -> T {
    var request = URLRequest(url: baseURL.appendingPathComponent(path))
    request.httpMethod = method
    request.timeoutInterval = timeout
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    if let token { request.setValue(token, forHTTPHeaderField: "Authorization") }
    if let bodyData {
      request.setValue("application/json", forHTTPHeaderField: "Content-Type")
      request.httpBody = bodyData
    }

    let data: Data
    let response: URLResponse
    do {
      (data, response) = try await transport(request)
    } catch {
      throw AccountAPIError(
        status: 0, code: "network",
        message: "Couldn't reach MacMint. Check your internet connection and try again.")
    }
    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
    guard (200..<300).contains(status) else { throw Self.apiError(status: status, data: data) }
    if T.self == EmptyResponse.self, let empty = EmptyResponse() as? T { return empty }
    do {
      return try Self.decoder.decode(T.self, from: data)
    } catch {
      throw AccountAPIError(
        status: status, code: "bad_response", message: "MacMint sent an unexpected response.")
    }
  }

  static func apiError(status: Int, data: Data) -> AccountAPIError {
    let body = try? decoder.decode(ErrorBody.self, from: data)
    let fieldMessage = body?.data?.sorted { $0.key < $1.key }.compactMap { key, value in
      value.message.map { "\(key.capitalized): \($0)" }
    }.first
    let code = body?.error ?? (status == 401 ? "unauthorized" : "http_\(status)")
    let fallback: String
    switch status {
    case 400: fallback = "Please check what you entered and try again."
    case 401: fallback = "Your session has expired. Please sign in again."
    case 429: fallback = "Too many attempts. Wait a minute and try again."
    case 500...: fallback = "MacMint is having trouble right now. Please try again shortly."
    default: fallback = "Something went wrong (\(status))."
    }
    let message = fieldMessage ?? body?.message.flatMap { $0.isEmpty ? nil : $0 } ?? fallback
    return AccountAPIError(
      status: status, code: code, message: message, devices: body?.devices ?? [])
  }
}
