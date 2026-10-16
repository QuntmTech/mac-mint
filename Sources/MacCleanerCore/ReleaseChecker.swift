import Foundation

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

public struct ReleaseInfo: Codable, Hashable, Sendable {
  public let version: String
  public let build: Int?
  public let downloadUrl: String?
  public let minOs: String?
  public let notes: String?
  public let sha256: String?

  public init(
    version: String, build: Int? = nil, downloadUrl: String? = nil, minOs: String? = nil,
    notes: String? = nil, sha256: String? = nil
  ) {
    self.version = version
    self.build = build
    self.downloadUrl = downloadUrl
    self.minOs = minOs
    self.notes = notes
    self.sha256 = sha256
  }
}

public enum UpdateStatus: Hashable, Sendable {
  case current
  case available(ReleaseInfo)
  /// This build is older than the minimum version the service still supports.
  case required(ReleaseInfo?, minimum: String)
}

/// Dotted numeric version comparison ("0.10.0" > "0.9.3"); non-numeric parts count as 0.
public struct AppVersion: Comparable, Hashable, Sendable, CustomStringConvertible {
  public let parts: [Int]

  public init(_ string: String) {
    parts = string.split(separator: ".").map { Int($0.prefix { $0.isNumber }) ?? 0 }
  }

  public var description: String { parts.map(String.init).joined(separator: ".") }

  public static func < (lhs: AppVersion, rhs: AppVersion) -> Bool {
    let count = max(lhs.parts.count, rhs.parts.count)
    for index in 0..<count {
      let l = index < lhs.parts.count ? lhs.parts[index] : 0
      let r = index < rhs.parts.count ? rhs.parts[index] : 0
      if l != r { return l < r }
    }
    return false
  }

  public static func == (lhs: AppVersion, rhs: AppVersion) -> Bool { !(lhs < rhs) && !(rhs < lhs) }
}

/// Reads the newest published stable release and the minimum supported version from the
/// public PocketBase collections. Never downloads or installs anything by itself.
public struct ReleaseChecker: Sendable {
  public typealias Transport = AccountClient.Transport

  private let baseURL: URL
  private let transport: Transport

  public init(baseURL: URL = AccountClient.defaultBaseURL, transport: Transport? = nil) {
    self.baseURL = baseURL
    self.transport = transport ?? { request in try await URLSession.shared.data(for: request) }
  }

  public func check(currentVersion: String) async throws -> UpdateStatus {
    async let latest = latestRelease()
    async let minimum = minimumVersion()
    let (release, minVersion) = try await (latest, minimum)
    return Self.status(current: currentVersion, latest: release, minimum: minVersion)
  }

  public static func status(current: String, latest: ReleaseInfo?, minimum: String?) -> UpdateStatus {
    let mine = AppVersion(current)
    if let minimum, mine < AppVersion(minimum) { return .required(latest, minimum: minimum) }
    if let latest, mine < AppVersion(latest.version) { return .available(latest) }
    return .current
  }

  private struct ListResponse: Decodable { let items: [ReleaseInfo] }
  private struct ConfigResponse: Decodable {
    struct Item: Decodable { let value: ClientConfig? }
    let items: [Item]
  }
  private struct ClientConfig: Decodable { let minVersion: String? }

  private static let decoder: JSONDecoder = {
    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    return decoder
  }()

  func latestRelease() async throws -> ReleaseInfo? {
    let response: ListResponse = try await get(
      "/api/collections/app_releases/records",
      query: [
        URLQueryItem(name: "filter", value: "channel='stable'"),
        URLQueryItem(name: "sort", value: "-published_at,-build"),
        URLQueryItem(name: "perPage", value: "1"),
      ])
    return response.items.first
  }

  func minimumVersion() async throws -> String? {
    let response: ConfigResponse = try await get(
      "/api/collections/app_config/records",
      query: [URLQueryItem(name: "filter", value: "key='client'"), URLQueryItem(name: "perPage", value: "1")])
    return response.items.first?.value?.minVersion
  }

  private func get<T: Decodable>(_ path: String, query: [URLQueryItem]) async throws -> T {
    var components = URLComponents(
      url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
    components.queryItems = query
    var request = URLRequest(url: components.url!)
    request.timeoutInterval = 15
    let (data, response) = try await transport(request)
    guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
      throw URLError(.badServerResponse)
    }
    return try Self.decoder.decode(T.self, from: data)
  }
}
