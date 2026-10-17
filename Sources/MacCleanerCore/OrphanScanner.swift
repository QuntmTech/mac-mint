import Foundation

/// Data left in ~/Library by an app that is no longer installed. Always review-only: evidence is
/// a reverse-DNS bundle identifier that no installed app (or its helpers/extensions) claims.
public struct OrphanedItem: Identifiable, Hashable, Sendable {
  public let id: String
  public let url: URL
  public let bundleID: String
  /// Library area it was found in ("Preferences", "Containers"…).
  public let location: String
  public let bytes: Int64
  public let modified: Date?
  public let identity: String?
  public let confidence: MatchConfidence
  public let reason: String

  public init(
    url: URL, bundleID: String, location: String, bytes: Int64, modified: Date?,
    identity: String?, confidence: MatchConfidence, reason: String
  ) {
    self.id = url.standardizedFileURL.path
    self.url = url
    self.bundleID = bundleID
    self.location = location
    self.bytes = bytes
    self.modified = modified
    self.identity = identity
    self.confidence = confidence
    self.reason = reason
  }
}

public actor OrphanScanner {
  private let fileManager: FileManager
  private let homeDirectory: URL
  private let applicationRoots: [URL]
  /// Folders where vendors install helper apps outside Applications (searched a few levels deep).
  private let helperRoots: [URL]
  private let recentWindow: TimeInterval

  /// First labels of reverse-DNS identifiers we accept as evidence of a bundle ID.
  static let reverseDNSPrefixes: Set<String> = [
    "com", "org", "net", "io", "co", "app", "dev", "me", "de", "uk", "us", "ai", "fr", "jp", "ru",
    "ca", "au", "nl", "se", "ch", "it", "es", "info", "biz", "tv", "cc", "cn", "kr", "in", "br",
    "pl", "at", "be", "dk", "fi", "no", "nz", "cz", "eu", "xyz", "so", "is", "im", "sh", "to",
  ]

  /// Library areas scanned (top level only), with the label shown to the user.
  static let locations: [(String, String)] = [
    ("Library/Preferences", "Preferences"),
    ("Library/Application Support", "Application Support"),
    ("Library/Caches", "Caches"),
    ("Library/Containers", "Containers"),
    ("Library/Group Containers", "Group Containers"),
    ("Library/Saved Application State", "Saved Application State"),
    ("Library/HTTPStorages", "HTTP Storage"),
    ("Library/WebKit", "WebKit"),
    ("Library/Logs", "Logs"),
    ("Library/Application Scripts", "Application Scripts"),
    ("Library/Cookies", "Cookies"),
  ]

  public init(
    fileManager: FileManager = .default, homeDirectory: URL? = nil, applicationRoots: [URL]? = nil,
    helperRoots: [URL]? = nil, recentWindow: TimeInterval = 30 * 86_400
  ) {
    let home = homeDirectory ?? fileManager.homeDirectoryForCurrentUser
    self.fileManager = fileManager
    self.homeDirectory = home
    self.applicationRoots =
      applicationRoots ?? [
        URL(fileURLWithPath: "/Applications"), URL(fileURLWithPath: "/System/Applications"),
        home.appendingPathComponent("Applications"),
      ]
    self.helperRoots =
      helperRoots ?? [
        URL(fileURLWithPath: "/Library/Application Support"),
        URL(fileURLWithPath: "/Library/PrivilegedHelperTools"),
        home.appendingPathComponent("Library/Application Support"),
      ]
    self.recentWindow = recentWindow
  }

  /// `knownBundleIDs` adds identifiers that are in use but not in an Applications folder
  /// (e.g. currently running apps).
  public func scan(knownBundleIDs: Set<String> = [], ignoredPaths: Set<String> = []) async
    -> ScanReport<[OrphanedItem]>
  {
    let started = Date()
    // Exclusions limit what is offered, never what counts as evidence that an app is installed.
    let installed = installedBundleIDs().union(knownBundleIDs.map { $0.lowercased() })
    let vendors = Set(installed.compactMap(Self.vendor))
    var items: [OrphanedItem] = []
    var issues: [ScanIssue] = []

    for (relative, label) in Self.locations {
      if Task.isCancelled { break }
      let root = homeDirectory.appendingPathComponent(relative)
      guard fileManager.fileExists(atPath: root.path) else { continue }
      let entries: [URL]
      do {
        entries = try fileManager.contentsOfDirectory(
          at: root, includingPropertiesForKeys: [.contentModificationDateKey], options: [])
      } catch {
        issues.append(ScanIssue(area: "Orphaned data", path: root.path, message: error.localizedDescription))
        continue
      }
      for entry in entries {
        if FileSystem.isIgnored(entry, ignoredPaths: ignoredPaths) { continue }
        guard let candidate = Self.bundleID(fromName: entry.lastPathComponent, inGroupContainers: label == "Group Containers"),
          !Self.isProtected(candidate), !Self.isClaimed(candidate, by: installed)
        else { continue }

        let modified = (try? entry.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        let sameVendor = Self.vendor(candidate).map(vendors.contains) ?? false
        let confidence = Self.confidence(modified: modified, recentWindow: recentWindow, sameVendor: sameVendor)
        var reason = "No matching owner was found in the inspected app locations for \(candidate)."
        if sameVendor { reason += " Another app from the same developer is installed and may share it." }
        if let modified, Date().timeIntervalSince(modified) < recentWindow {
          reason += " Changed recently — something may still use it."
        } else if modified == nil {
          reason += " Its last change could not be read, so recent use can't be ruled out."
        }

        items.append(
          OrphanedItem(
            url: entry, bundleID: candidate, location: label,
            bytes: FileSystem.itemSize(at: entry, fileManager: fileManager), modified: modified,
            identity: FileSystem.fileIdentity(at: entry), confidence: confidence, reason: reason))
      }
    }
    let sorted = items.filter { $0.bytes > 0 }.sorted {
      $0.confidence.rank == $1.confidence.rank ? $0.bytes > $1.bytes : $0.confidence.rank < $1.confidence.rank
    }
    return ScanReport(
      value: sorted, issues: issues, duration: Date().timeIntervalSince(started),
      wasCancelled: Task.isCancelled)
  }

  // MARK: Installed apps

  func installedBundleIDs() -> Set<String> {
    var ids: Set<String> = []
    for root in applicationRoots {
      if Task.isCancelled { break }
      guard
        let enumerator = fileManager.enumerator(
          at: root, includingPropertiesForKeys: [.isDirectoryKey],
          options: [.skipsHiddenFiles, .skipsPackageDescendants], errorHandler: { _, _ in true })
      else { continue }
      FileSystem.walk(enumerator) { url in
        if Task.isCancelled { return .stop }
        guard url.pathExtension.lowercased() == "app" else { return .continue }
        ids.formUnion(bundleIDs(inApp: url))
        return .skipDescendants
      }
    }
    for root in helperRoots { ids.formUnion(helperBundleIDs(in: root, depth: 6)) }
    return ids
  }

  /// Vendor-installed apps and helpers outside Applications (updaters, Toolbox-managed IDEs,
  /// privileged helpers), searched to a shallow depth so this stays fast.
  private func helperBundleIDs(in folder: URL, depth: Int) -> Set<String> {
    guard depth > 0, !Task.isCancelled,
      let children = try? fileManager.contentsOfDirectory(
        at: folder, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
    else { return [] }
    var ids: Set<String> = []
    let isPrivilegedHelpers = folder.lastPathComponent == "PrivilegedHelperTools"
    for child in children {
      let ext = child.pathExtension.lowercased()
      if ["app", "bundle", "xpc", "appex"].contains(ext) {
        ids.formUnion(bundleIDs(inApp: child))
      } else if isPrivilegedHelpers {
        // Privileged helper tools are bare executables named by their bundle identifier.
        ids.insert(child.lastPathComponent.lowercased())
      } else if (try? child.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
        ids.formUnion(helperBundleIDs(in: child, depth: depth - 1))
      }
    }
    return ids
  }

  /// The app's own identifier plus those of its embedded helpers, login items, and extensions.
  private func bundleIDs(inApp app: URL) -> Set<String> {
    var ids: Set<String> = []
    if let id = Self.readBundleID(app) { ids.insert(id) }
    let contents = app.appendingPathComponent("Contents")
    for folder in ["Library/LoginItems", "Library/LaunchServices", "Helpers", "PlugIns", "XPCServices", "Frameworks", "Applications", "MacOS"] {
      let dir = contents.appendingPathComponent(folder)
      for child in (try? fileManager.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [] {
        if ["app", "appex", "xpc", "bundle", "framework"].contains(child.pathExtension.lowercased()),
          let id = Self.readBundleID(child)
        {
          ids.insert(id)
        }
      }
    }
    return ids
  }

  static func readBundleID(_ bundle: URL) -> String? {
    let candidates = [
      bundle.appendingPathComponent("Contents/Info.plist"),
      bundle.appendingPathComponent("Info.plist"),
      bundle.appendingPathComponent("Resources/Info.plist"),
    ]
    for plist in candidates {
      guard let data = FileManager.default.contents(atPath: plist.path),
        let object = try? PropertyListSerialization.propertyList(from: data, format: nil),
        let id = (object as? [String: Any])?["CFBundleIdentifier"] as? String
      else { continue }
      return id.lowercased()
    }
    return nil
  }

  // MARK: Matching

  /// Reverse-DNS identifier encoded in a Library entry name, or nil when the name isn't one.
  static func bundleID(fromName name: String, inGroupContainers: Bool) -> String? {
    var stem = AppScanner.stem(of: name)
    if inGroupContainers {
      stem = AppScanner.groupContainerID(stem) ?? stem
    }
    let parts = stem.split(separator: ".", omittingEmptySubsequences: false)
    guard parts.count >= 3, let first = parts.first, reverseDNSPrefixes.contains(String(first)),
      parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" } })
    else { return nil }
    return stem
  }

  static func isProtected(_ id: String) -> Bool {
    id.hasPrefix("com.apple.") || id.hasPrefix("co.macmint.") || id == "com.apple"
  }

  /// Claimed when an installed identifier equals it, owns it (prefix), or is owned by it.
  static func isClaimed(_ id: String, by installed: Set<String>) -> Bool {
    installed.contains { app in id == app || id.hasPrefix(app + ".") || app.hasPrefix(id + ".") }
  }

  /// Unknown activity is not proof of inactivity, so an unreadable date stays low confidence.
  static func confidence(modified: Date?, recentWindow: TimeInterval, sameVendor: Bool) -> MatchConfidence {
    guard let modified, !sameVendor else { return .low }
    return Date().timeIntervalSince(modified) < recentWindow ? .low : .medium
  }

  static func vendor(_ id: String) -> String? {
    let parts = id.split(separator: ".")
    return parts.count >= 2 ? parts.prefix(2).joined(separator: ".") : nil
  }
}
