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
  /// The published archive digest when well formed, for comparing a downloaded archive.
  public var expectedSHA256: String? {
    guard let sha256, sha256.count == 64, sha256.allSatisfy({ $0.isHexDigit && !$0.isUppercase }) else { return nil }
    return sha256
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

  public func hash(into hasher: inout Hasher) {
    // Equality ignores trailing zero components, so hashing must ignore them too.
    var count = parts.count
    while count > 0, parts[count - 1] == 0 { count -= 1 }
    hasher.combine(count)
    for part in parts.prefix(count) { hasher.combine(part) }
  }
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

  /// Opened instead of a missing or untrusted feed download URL.
  public static let fallbackDownloadURL = URL(string: "https://macmint.co/account")!

  /// Feed URLs open in the browser, so only first-party HTTPS locations are trusted: the
  /// MacMint site and QuntmTech/mac-mint GitHub release assets. GitHub redirects those to
  /// signed githubusercontent URLs, which serve any repository's assets and are therefore
  /// not accepted directly. No credentials, ports, queries, fragments, percent-encoding or
  /// dot segments. Mirrors `trustedDownloadURL` in backend macmint_payments_lib.js.
  public static func trustedDownloadURL(_ string: String?) -> URL? {
    guard let parsed = plainHTTPSURL(string) else { return nil }
    switch parsed.host {
    case "macmint.co":
      return parsed.url
    case "github.com":
      return isReleaseAsset(parsed.segments, allowLatest: false) ? parsed.url : nil
    default:
      return nil
    }
  }

  /// Sparkle feeds and update archives: QuntmTech/mac-mint GitHub release assets only, at a
  /// fixed tag (`releases/download/<tag>/<asset>`) or in the newest stable release
  /// (`releases/latest/download/<asset>`). Sparkle additionally requires each archive's
  /// EdDSA signature from the key in Info.plist.
  public static func trustedUpdateURL(_ string: String?) -> URL? {
    guard let parsed = plainHTTPSURL(string), parsed.host == "github.com",
      isReleaseAsset(parsed.segments, allowLatest: true)
    else { return nil }
    return parsed.url
  }

  private static func isReleaseAsset(_ segments: [String], allowLatest: Bool) -> Bool {
    guard segments.count == 6, segments[0] == "QuntmTech", segments[1] == "mac-mint", segments[2] == "releases",
      !segments[5].isEmpty
    else { return false }
    if segments[3] == "download" { return !segments[4].isEmpty }
    return allowLatest && segments[3] == "latest" && segments[4] == "download"
  }

  private static func plainHTTPSURL(_ string: String?) -> (host: String, segments: [String], url: URL)? {
    guard let string, string.count <= 2000, string.hasPrefix("https://"),
      let components = URLComponents(string: string),
      components.user == nil, components.password == nil, components.port == nil,
      components.query == nil, components.fragment == nil,
      components.percentEncodedHost?.contains("%") == false,
      let host = components.host?.lowercased(), let url = components.url
    else { return nil }
    let path = components.percentEncodedPath
    let pathCharacters = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._~+/-")
    guard path.hasPrefix("/"), path.allSatisfy(pathCharacters.contains) else { return nil }
    let segments = path.split(separator: "/", omittingEmptySubsequences: false).dropFirst().map(String.init)
    guard !segments.contains(where: { $0 == "." || $0 == ".." }) else { return nil }
    return (host, segments, url)
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
