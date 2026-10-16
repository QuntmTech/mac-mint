import Foundation

public actor AppScanner {
  private let fileManager: FileManager
  private let homeDirectory: URL
  private let applicationRoots: [URL]
  private let usage: any UsageProviding

  public init(
    fileManager: FileManager = .default,
    homeDirectory: URL? = nil,
    applicationRoots: [URL]? = nil,
    usage: any UsageProviding = SpotlightUsage()
  ) {
    self.fileManager = fileManager
    self.usage = usage
    let home = homeDirectory ?? fileManager.homeDirectoryForCurrentUser
    self.homeDirectory = home
    self.applicationRoots =
      applicationRoots ?? [
        URL(fileURLWithPath: "/Applications"),
        home.appendingPathComponent("Applications"),
      ]
  }

  public func installedApps(extraRoots: [URL] = []) async -> [AppRecord] {
    await installedAppsReport(extraRoots: extraRoots).value
  }

  public func installedAppsReport(extraRoots: [URL] = []) async -> ScanReport<[AppRecord]> {
    let started = Date()
    var records: [AppRecord] = []
    let collector = IssueCollector()
    var seen: Set<String> = []

    for root in applicationRoots + extraRoots {
      if Task.isCancelled {
        return ScanReport(
          value: sort(records), issues: collector.issues,
          duration: Date().timeIntervalSince(started), wasCancelled: true)
      }
      guard fileManager.fileExists(atPath: root.path) else { continue }

      guard
        let enumerator = fileManager.enumerator(
          at: root,
          includingPropertiesForKeys: [
            .isDirectoryKey, .isPackageKey, .contentModificationDateKey,
          ],
          options: [.skipsHiddenFiles, .skipsPackageDescendants],
          errorHandler: { url, error in
            collector.append(
              ScanIssue(area: "Applications", path: url.path, message: error.localizedDescription))
            return true
          }
        )
      else {
        collector.append(
          ScanIssue(
            area: "Applications", path: root.path,
            message: "Could not enumerate this Applications folder."))
        continue
      }

      var apps: [URL] = []
      FileSystem.walk(enumerator) { url in
        if Task.isCancelled { return .stop }
        guard url.pathExtension.lowercased() == "app" else { return .continue }
        if seen.insert(url.standardizedFileURL.path).inserted { apps.append(url) }
        return .skipDescendants
      }
      for url in apps {
        if Task.isCancelled { break }
        records.append(record(for: url))
      }
    }

    return ScanReport(
      value: sort(records), issues: collector.issues, duration: Date().timeIntervalSince(started),
      wasCancelled: Task.isCancelled)
  }

  public func leftovers(
    for app: AppRecord, otherBundleIDs: Set<String> = [], ignoredPaths: Set<String> = []
  ) async -> [AppLeftover] {
    await leftoversReport(for: app, otherBundleIDs: otherBundleIDs, ignoredPaths: ignoredPaths)
      .value
  }

  /// `otherBundleIDs` are the bundle identifiers of every other installed app. They keep a
  /// sibling (e.g. `com.vendor.app.pro` vs `com.vendor.app`) from being matched as this app's data.
  public func leftoversReport(
    for app: AppRecord, otherBundleIDs: Set<String> = [], ignoredPaths: Set<String> = []
  ) async -> ScanReport<[AppLeftover]> {
    let started = Date()
    let roots = leftoverRoots()
    let bundleID = app.bundleIdentifier?.lowercased()
    let others = Set(otherBundleIDs.map { $0.lowercased() }).subtracting(bundleID.map { [$0] } ?? [])
    let appTokens = meaningfulTokens(in: app.name)
    let context = MatchContext(bundleID: bundleID, appTokens: appTokens, otherBundleIDs: others)
    var matches: [AppLeftover] = []
    var issues: [ScanIssue] = []
    var seen: Set<String> = []

    for root in roots {
      if Task.isCancelled {
        return ScanReport(
          value: sort(matches), issues: issues, duration: Date().timeIntervalSince(started),
          wasCancelled: true)
      }
      guard fileManager.fileExists(atPath: root.path) else { continue }

      do {
        let entries = try fileManager.contentsOfDirectory(
          at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
        for entry in entries {
          if Task.isCancelled {
            return ScanReport(
              value: sort(matches), issues: issues, duration: Date().timeIntervalSince(started),
              wasCancelled: true)
          }
          let entryPath = entry.standardizedFileURL.path
          guard !isIgnored(entryPath, ignoredPaths: ignoredPaths) else { continue }

          if let match = match(entry, root: root, context: context),
            seen.insert(entryPath).inserted
          {
            matches.append(match)
          }

          // Application Support and Group Containers often nest app data one level deeper.
          if shouldInspectOneLevelDeeper(root: root, entry: entry) {
            let children: [URL]
            do {
              children = try fileManager.contentsOfDirectory(
                at: entry, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
            } catch {
              issues.append(
                ScanIssue(
                  area: "App Leftovers", path: entry.path, message: error.localizedDescription))
              continue
            }
            for child in children {
              let childPath = child.standardizedFileURL.path
              guard !isIgnored(childPath, ignoredPaths: ignoredPaths),
                seen.insert(childPath).inserted
              else { continue }
              if let match = match(child, root: root, context: context) {
                matches.append(match)
              }
            }
          }
        }
      } catch {
        issues.append(
          ScanIssue(area: "App Leftovers", path: root.path, message: error.localizedDescription))
      }
    }

    return ScanReport(
      value: sort(matches), issues: issues, duration: Date().timeIntervalSince(started))
  }

  private func record(for url: URL) -> AppRecord {
    let bundle = Bundle(url: url)
    let info = bundle?.infoDictionary
    let name =
      (info?["CFBundleDisplayName"] as? String)
      ?? (info?["CFBundleName"] as? String)
      ?? url.deletingPathExtension().lastPathComponent
    let version =
      (info?["CFBundleShortVersionString"] as? String) ?? (info?["CFBundleVersion"] as? String)
    let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
      .contentModificationDate
    return AppRecord(
      url: url,
      name: name,
      bundleIdentifier: bundle?.bundleIdentifier,
      version: version,
      bundleSize: FileSystem.itemSize(at: url, fileManager: fileManager),
      lastModified: modified,
      identity: FileSystem.fileIdentity(at: url),
      lastUsed: usage.evidence(for: url).lastUsed
    )
  }

  private func leftoverRoots() -> [URL] {
    [
      homeDirectory.appendingPathComponent("Library/Application Support"),
      homeDirectory.appendingPathComponent("Library/Application Scripts"),
      homeDirectory.appendingPathComponent("Library/Caches"),
      homeDirectory.appendingPathComponent("Library/Preferences"),
      homeDirectory.appendingPathComponent("Library/Logs"),
      homeDirectory.appendingPathComponent("Library/Saved Application State"),
      homeDirectory.appendingPathComponent("Library/WebKit"),
      homeDirectory.appendingPathComponent("Library/Containers"),
      homeDirectory.appendingPathComponent("Library/Group Containers"),
      homeDirectory.appendingPathComponent("Library/HTTPStorages"),
      homeDirectory.appendingPathComponent("Library/Cookies"),
      homeDirectory.appendingPathComponent("Library/LaunchAgents"),
    ]
  }

  private func shouldInspectOneLevelDeeper(root: URL, entry: URL) -> Bool {
    let rootName = root.lastPathComponent
    guard rootName == "Application Support" || rootName == "Group Containers" else { return false }
    return (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
  }

  struct MatchContext {
    let bundleID: String?
    let appTokens: Set<String>
    let otherBundleIDs: Set<String>
  }

  /// File-name suffixes macOS appends to a bundle identifier for per-app data.
  private static let dataSuffixes = [".plist", ".savedstate", ".binarycookies"]

  static func stem(of filename: String) -> String {
    var stem = filename.lowercased()
    var stripped = true
    while stripped {
      stripped = false
      for suffix in dataSuffixes where stem.hasSuffix(suffix) {
        stem.removeLast(suffix.count)
        stripped = true
      }
    }
    return stem
  }

  /// Group containers are named "<TEAMID>.<id>" or "group.<id>".
  static func groupContainerID(_ stem: String) -> String? {
    if stem.hasPrefix("group.") { return String(stem.dropFirst("group.".count)) }
    let parts = stem.split(separator: ".", maxSplits: 1)
    guard parts.count == 2, parts[0].count == 10, parts[0].allSatisfy({ $0.isLetter || $0.isNumber })
    else { return nil }
    return String(parts[1])
  }

  /// True when `id` belongs to `owner` itself or to one of its nested helpers/extensions.
  private static func id(_ id: String, isOwnedBy owner: String) -> Bool {
    id == owner || id.hasPrefix(owner + ".")
  }

  /// The most specific installed app identifier that owns `id`, if it is not this app.
  private static func belongsToOtherApp(_ id: String, context: MatchContext) -> Bool {
    let ownerLength = context.bundleID.map { Self.id(id, isOwnedBy: $0) ? $0.count : -1 } ?? -1
    return context.otherBundleIDs.contains { other in
      Self.id(id, isOwnedBy: other) && other.count > ownerLength
    }
  }

  /// com.apple.*, group.com.apple.*, and team-prefixed Apple containers.
  static func isAppleOwned(_ stem: String) -> Bool {
    let id = groupContainerID(stem) ?? stem
    return id.hasPrefix("com.apple.") || stem.hasPrefix("com.apple.")
  }

  private func match(_ url: URL, root: URL, context: MatchContext) -> AppLeftover? {
    let stem = Self.stem(of: url.lastPathComponent)
    let inGroupContainers = root.lastPathComponent == "Group Containers"
    // macOS's own data is never offered as a third-party app's leftovers.
    if Self.isAppleOwned(stem), context.bundleID?.hasPrefix("com.apple.") != true { return nil }

    if let bundleID = context.bundleID {
      let candidateID = inGroupContainers ? (Self.groupContainerID(stem) ?? stem) : stem
      if Self.belongsToOtherApp(candidateID, context: context) { return nil }

      if candidateID == bundleID {
        return leftover(
          url,
          confidence: inGroupContainers ? .medium : .high,
          reason: inGroupContainers
            ? "App group container for this app; other apps from the developer may share it."
            : "Named with this app's exact bundle identifier.",
          isShared: inGroupContainers)
      }
      if candidateID.hasPrefix(bundleID + ".") {
        return leftover(
          url, confidence: .medium,
          reason: "Appears to belong to a helper or extension of this app (\(candidateID)).",
          isShared: inGroupContainers)
      }
      if inGroupContainers, sharesVendor(candidateID, with: bundleID) {
        return leftover(
          url, confidence: .low,
          reason: "Shared container from the same developer; it may be used by other apps.",
          isShared: true)
      }
    }

    let fileTokens = meaningfulTokens(in: stem)
    let overlap = context.appTokens.intersection(fileTokens)
    if !context.appTokens.isEmpty, overlap.count == context.appTokens.count {
      return leftover(
        url, confidence: .medium,
        reason: "Name matches the application name; review before removal.",
        isShared: inGroupContainers)
    }

    return nil
  }

  private func sharesVendor(_ id: String, with bundleID: String) -> Bool {
    let vendor = bundleID.split(separator: ".").prefix(2)
    guard vendor.count == 2 else { return false }
    return id.split(separator: ".").prefix(2) == vendor
  }

  private func leftover(
    _ url: URL, confidence: MatchConfidence, reason: String, isShared: Bool
  ) -> AppLeftover {
    AppLeftover(
      url: url,
      size: FileSystem.itemSize(at: url, fileManager: fileManager),
      confidence: confidence,
      reason: reason,
      isShared: isShared,
      identity: FileSystem.fileIdentity(at: url)
    )
  }

  private func meaningfulTokens(in value: String) -> Set<String> {
    let tokens = value.lowercased()
      .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
      .map(String.init)
      .filter { $0.count >= 3 && !["app", "the", "inc", "llc", "mac"].contains($0) }
    return Set(tokens)
  }

  private func isIgnored(_ path: String, ignoredPaths: Set<String>) -> Bool {
    ignoredPaths.contains { ignored in path == ignored || path.hasPrefix(ignored + "/") }
  }

  private func sort(_ records: [AppRecord]) -> [AppRecord] {
    records.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
  }

  private func sort(_ matches: [AppLeftover]) -> [AppLeftover] {
    matches.sorted { lhs, rhs in
      if lhs.confidence != rhs.confidence { return lhs.confidence.rank < rhs.confidence.rank }
      return lhs.size > rhs.size
    }
  }
}
