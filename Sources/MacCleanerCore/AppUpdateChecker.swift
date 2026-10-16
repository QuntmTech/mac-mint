import Foundation

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif
#if canImport(FoundationXML)
  import FoundationXML
#endif

public enum UpdateSource: Hashable, Sendable {
  /// Mac App Store app; `pageURL` opens its App Store page.
  case appStore(pageURL: URL?)
  /// The app updates itself through Sparkle ("Check for Updates…" inside the app).
  case sparkle(feed: URL)
  /// Installed with Homebrew; update with `brew upgrade --cask <token>`.
  case homebrew(token: String)
  case unsupported

  public var label: String {
    switch self {
    case .appStore: return "App Store"
    case .sparkle: return "Developer"
    case .homebrew: return "Homebrew"
    case .unsupported: return "Unsupported source"
    }
  }
}

public enum AppUpdateCheckState: String, Sendable {
  case checked = "Checked"
  case failed = "Check failed"
  case unsupported = "Unsupported source"
  case notChecked = "Not checked"
}

public struct AppUpdate: Identifiable, Hashable, Sendable {
  public let id: String
  public let appName: String
  public let appURL: URL
  public let bundleIdentifier: String?
  public let installedVersion: String
  /// nil when the source is known but its latest version couldn't be determined (Homebrew).
  public let availableVersion: String?
  public let source: UpdateSource
  public let minimumSystem: String?
  public let checkState: AppUpdateCheckState

  public init(id: String, appName: String, appURL: URL, bundleIdentifier: String?, installedVersion: String,
    availableVersion: String?, source: UpdateSource, minimumSystem: String?, checkState: AppUpdateCheckState? = nil) {
    self.id = id; self.appName = appName; self.appURL = appURL; self.bundleIdentifier = bundleIdentifier
    self.installedVersion = installedVersion; self.availableVersion = availableVersion; self.source = source
    self.minimumSystem = minimumSystem
    self.checkState = checkState ?? (availableVersion == nil ? .notChecked : .checked)
  }

  public var statusLabel: String {
    checkState == .checked ? (hasUpdate ? "Update available" : "Up to date") : checkState.rawValue
  }


  public var hasUpdate: Bool {
    guard let availableVersion else { return false }
    return AppVersion(installedVersion) < AppVersion(availableVersion)
  }
}

/// Finds newer versions of installed apps from the sources that manage them. Read-only:
/// it never downloads or installs — updates happen in the App Store, the app, or Homebrew.
public actor AppUpdateChecker {
  public typealias Transport = AccountClient.Transport

  private let transport: Transport
  private let fileManager: FileManager
  private let caskroots: [URL]
  private let country: String

  public init(
    transport: Transport? = nil, fileManager: FileManager = .default,
    caskroots: [URL] = [
      URL(fileURLWithPath: "/opt/homebrew/Caskroom"), URL(fileURLWithPath: "/usr/local/Caskroom"),
    ],
    country: String = Locale.current.region?.identifier.lowercased() ?? "us"
  ) {
    self.transport = transport ?? { request in try await URLSession.shared.data(for: request) }
    self.fileManager = fileManager
    self.caskroots = caskroots
    self.country = country
  }

  public func check(_ apps: [AppRecord], maxConcurrent: Int = 6) async -> [AppUpdate] {
    let casks = installedCasks()
    var results: [AppUpdate] = []
    await withTaskGroup(of: AppUpdate?.self) { group in
      var iterator = apps.makeIterator()
      var running = 0
      func addNext() -> Bool {
        guard let app = iterator.next() else { return false }
        group.addTask { await self.update(for: app, casks: casks) }
        return true
      }
      while running < maxConcurrent, addNext() { running += 1 }
      for await result in group {
        if let result { results.append(result) }
        if Task.isCancelled { group.cancelAll(); break }
        _ = addNext()
      }
    }
    return results.sorted { lhs, rhs in
      if lhs.hasUpdate != rhs.hasUpdate { return lhs.hasUpdate }
      return lhs.appName.localizedCaseInsensitiveCompare(rhs.appName) == .orderedAscending
    }
  }

  private func update(for app: AppRecord, casks: [String: String]) async -> AppUpdate? {
    guard let info = NSDictionary(contentsOf: app.url.appendingPathComponent("Contents/Info.plist"))
      as? [String: Any]
    else { return AppUpdate(id: app.url.standardizedFileURL.path, appName: app.name, appURL: app.url, bundleIdentifier: app.bundleIdentifier,
      installedVersion: app.version ?? "Unknown", availableVersion: nil, source: .unsupported, minimumSystem: nil, checkState: .failed) }
    let installed =
      (info["CFBundleShortVersionString"] as? String) ?? (info["CFBundleVersion"] as? String) ?? "0"
    let make: (String?, UpdateSource, String?) -> AppUpdate = { available, source, minOS in
      AppUpdate(
        id: app.url.standardizedFileURL.path, appName: app.name, appURL: app.url,
        bundleIdentifier: app.bundleIdentifier, installedVersion: installed,
        availableVersion: available, source: source, minimumSystem: minOS,
        checkState: available != nil ? .checked : (source.label == "Homebrew" ? .notChecked : .failed))
    }

    if fileManager.fileExists(atPath: app.url.appendingPathComponent("Contents/_MASReceipt/receipt").path),
      let bundleID = app.bundleIdentifier
    {
      let lookup = try? await appStoreLookup(bundleID: bundleID)
      return make(lookup?.version, .appStore(pageURL: lookup?.url), lookup?.minimumOsVersion)
    }
    if let token = casks[app.url.lastPathComponent] {
      return make(nil, .homebrew(token: token), nil)
    }
    if let feedString = info["SUFeedURL"] as? String, let feed = URL(string: feedString),
      feed.scheme == "https"
    {
      let latest = try? await sparkleLatest(feed: feed)
      return make(latest?.version, .sparkle(feed: feed), latest?.minimumSystem)
    }
    return AppUpdate(id: app.url.standardizedFileURL.path, appName: app.name, appURL: app.url, bundleIdentifier: app.bundleIdentifier,
      installedVersion: installed, availableVersion: nil, source: .unsupported, minimumSystem: nil, checkState: .unsupported)
  }

  // MARK: App Store

  struct LookupResult: Decodable {
    let version: String
    let trackViewUrl: String?
    let minimumOsVersion: String?

    var url: URL? { trackViewUrl.flatMap(URL.init(string:)) }
  }

  private struct LookupResponse: Decodable { let results: [LookupResult] }

  func appStoreLookup(bundleID: String) async throws -> LookupResult? {
    var components = URLComponents(string: "https://itunes.apple.com/lookup")!
    components.queryItems = [
      URLQueryItem(name: "bundleId", value: bundleID), URLQueryItem(name: "entity", value: "macSoftware"),
      URLQueryItem(name: "country", value: country),
    ]
    let data = try await fetch(components.url!)
    return try JSONDecoder().decode(LookupResponse.self, from: data).results.first
  }

  // MARK: Sparkle

  struct AppcastItem: Hashable {
    var version: String?
    var shortVersion: String?
    var minimumSystem: String?
    var channel: String?

    var displayVersion: String? { shortVersion ?? version }
  }

  func sparkleLatest(feed: URL) async throws -> (version: String, minimumSystem: String?)? {
    Self.latest(in: Self.parseAppcast(try await fetch(feed)))
  }

  /// Newest stable item (items on a named channel such as "beta" are ignored).
  static func latest(in items: [AppcastItem]) -> (version: String, minimumSystem: String?)? {
    items.filter { $0.channel == nil && $0.displayVersion != nil }
      .max { AppVersion($0.displayVersion!) < AppVersion($1.displayVersion!) }
      .map { ($0.displayVersion!, $0.minimumSystem) }
  }

  static func parseAppcast(_ data: Data) -> [AppcastItem] {
    let delegate = AppcastParser()
    let parser = XMLParser(data: data)
    parser.delegate = delegate
    parser.parse()
    return delegate.items
  }

  // MARK: Homebrew

  /// Maps "Some App.app" → cask token, from Caskroom/<token>/<version>/<App>.app entries.
  private func installedCasks() -> [String: String] {
    var map: [String: String] = [:]
    for root in caskroots {
      let tokens = (try? fileManager.contentsOfDirectory(atPath: root.path)) ?? []
      for token in tokens where !token.hasPrefix(".") {
        let versions = (try? fileManager.contentsOfDirectory(atPath: root.appendingPathComponent(token).path)) ?? []
        for version in versions where !version.hasPrefix(".") {
          let contents =
            (try? fileManager.contentsOfDirectory(
              atPath: root.appendingPathComponent(token).appendingPathComponent(version).path)) ?? []
          for entry in contents where entry.hasSuffix(".app") { map[entry] = token }
        }
      }
    }
    return map
  }

  private func fetch(_ url: URL) async throws -> Data {
    var request = URLRequest(url: url)
    request.timeoutInterval = 10
    request.setValue("MacMint update check", forHTTPHeaderField: "User-Agent")
    let (data, response) = try await transport(request)
    guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
      throw URLError(.badServerResponse)
    }
    return data
  }
}

/// Minimal Sparkle appcast reader: versions may be on <enclosure> attributes or child elements.
private final class AppcastParser: NSObject, XMLParserDelegate {
  var items: [AppStoreItemBuffer.Item] = []
  private var current: AppStoreItemBuffer.Item?
  private var text = ""

  func parser(
    _ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
    qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]
  ) {
    text = ""
    if elementName == "item" { current = AppStoreItemBuffer.Item() }
    if elementName == "enclosure", var item = current {
      item.version = item.version ?? attributeDict["sparkle:version"]
      item.shortVersion = item.shortVersion ?? attributeDict["sparkle:shortVersionString"]
      current = item
    }
  }

  func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }

  func parser(
    _ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
    qualifiedName qName: String?
  ) {
    let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
    switch elementName {
    case "sparkle:version": if !value.isEmpty { current?.version = value }
    case "sparkle:shortVersionString": if !value.isEmpty { current?.shortVersion = value }
    case "sparkle:minimumSystemVersion": if !value.isEmpty { current?.minimumSystem = value }
    case "sparkle:channel": if !value.isEmpty { current?.channel = value }
    case "item":
      if let current { items.append(current) }
      current = nil
    default: break
    }
    text = ""
  }
}

enum AppStoreItemBuffer {
  typealias Item = AppUpdateChecker.AppcastItem
}
