import Foundation

#if canImport(CoreServices)
  import CoreServices
#endif

/// What macOS knows about how a file or app has been used, from the Spotlight index.
/// Filesystem access time is deliberately never used: it changes on backups, scans, and Quick
/// Look, so it can't prove anything was "used". Unknown stays unknown.
public struct UsageEvidence: Codable, Hashable, Sendable {
  /// Last time it was opened through Launch Services (double-click, Open With, app launch).
  public let lastUsed: Date?
  /// When it arrived in its folder (download, copy, AirDrop).
  public let added: Date?
  public let useCount: Int?
  /// Download source, when the browser recorded one.
  public let source: String?
  /// False when Spotlight has no metadata for it (excluded folder, indexing off).
  public let isIndexed: Bool

  public init(
    lastUsed: Date? = nil, added: Date? = nil, useCount: Int? = nil, source: String? = nil,
    isIndexed: Bool = false
  ) {
    self.lastUsed = lastUsed
    self.added = added
    self.useCount = useCount
    self.source = source
    self.isIndexed = isIndexed
  }

  public static let unknown = UsageEvidence()

  /// Indexed, arrived at a known time, and never opened since.
  public var neverOpened: Bool { isIndexed && lastUsed == nil && (useCount ?? 0) == 0 }

  /// Whole days since it was last opened, or (if never opened) since it arrived.
  public func idleDays(now: Date = Date()) -> Int? {
    guard isIndexed, let since = lastUsed ?? (neverOpened ? added : nil) else { return nil }
    return max(0, Int(now.timeIntervalSince(since) / 86_400))
  }
}

public protocol UsageProviding: Sendable {
  func evidence(for url: URL) -> UsageEvidence
}

/// Spotlight-backed usage on macOS; `.unknown` elsewhere.
public struct SpotlightUsage: UsageProviding {
  public init() {}

  public func evidence(for url: URL) -> UsageEvidence {
    #if canImport(CoreServices) && os(macOS)
      guard let item = MDItemCreateWithURL(kCFAllocatorDefault, url as CFURL) else { return .unknown }
      let contentType = MDItemCopyAttribute(item, kMDItemContentType) as? String
      let lastUsed = MDItemCopyAttribute(item, kMDItemLastUsedDate) as? Date
      let added = MDItemCopyAttribute(item, kMDItemDateAdded) as? Date
      // The use-count attribute has no exported constant; Spotlight still accepts its name.
      let useCount = (MDItemCopyAttribute(item, "kMDItemUseCount" as CFString) as? NSNumber)?.intValue
      let source = (MDItemCopyAttribute(item, kMDItemWhereFroms) as? [String])?.first
      return UsageEvidence(
        lastUsed: lastUsed, added: added, useCount: useCount,
        source: source.flatMap(Self.host), isIndexed: contentType != nil)
    #else
      return .unknown
    #endif
  }

  /// Just the site, never the full URL (which can contain tokens).
  static func host(_ string: String) -> String? {
    guard let host = URL(string: string)?.host, !host.isEmpty else { return nil }
    return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
  }
}

/// Fixed answers, for tests and previews.
public struct StaticUsage: UsageProviding {
  public let byPath: [String: UsageEvidence]

  public init(_ byPath: [String: UsageEvidence]) { self.byPath = byPath }

  public func evidence(for url: URL) -> UsageEvidence {
    byPath[url.standardizedFileURL.path] ?? .unknown
  }
}

public enum RelativeAge {
  /// "today", "3 days", "5 months", "2 years" — for evidence text.
  public static func describe(days: Int) -> String {
    switch days {
    case ..<1: return "today"
    case 1: return "1 day"
    case ..<45: return "\(days) days"
    case ..<548: return "\(max(1, Int((Double(days) / 30.4).rounded()))) months"
    default: return "\(Int((Double(days) / 365).rounded())) years"
    }
  }
}
