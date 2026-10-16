import Foundation

public actor AppScanner {
  private let fileManager: FileManager
  private let homeDirectory: URL
  private let applicationRoots: [URL]

  public init(
    fileManager: FileManager = .default,
    homeDirectory: URL? = nil,
    applicationRoots: [URL]? = nil
  ) {
    self.fileManager = fileManager
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
    var issues: [ScanIssue] = []
    var seen: Set<String> = []

    for root in applicationRoots + extraRoots {
      if Task.isCancelled {
        return ScanReport(
          value: sort(records), issues: issues, duration: Date().timeIntervalSince(started),
          wasCancelled: true)
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
            issues.append(
              ScanIssue(area: "Applications", path: url.path, message: error.localizedDescription))
            return true
          }
        )
      else {
        issues.append(
          ScanIssue(
            area: "Applications", path: root.path,
            message: "Could not enumerate this Applications folder."))
        continue
      }

      for case let url as URL in enumerator {
        if Task.isCancelled {
          return ScanReport(
            value: sort(records), issues: issues, duration: Date().timeIntervalSince(started),
            wasCancelled: true)
        }
        guard url.pathExtension.lowercased() == "app" else { continue }
        let path = url.standardizedFileURL.path
        guard seen.insert(path).inserted else { continue }
        records.append(record(for: url))
      }
    }

    return ScanReport(
      value: sort(records), issues: issues, duration: Date().timeIntervalSince(started))
  }

  public func leftovers(for app: AppRecord, ignoredPaths: Set<String> = []) async -> [AppLeftover] {
    await leftoversReport(for: app, ignoredPaths: ignoredPaths).value
  }

  public func leftoversReport(for app: AppRecord, ignoredPaths: Set<String> = []) async
    -> ScanReport<[AppLeftover]>
  {
    let started = Date()
    let roots = leftoverRoots()
    let bundleID = app.bundleIdentifier?.lowercased()
    let appTokens = meaningfulTokens(in: app.name)
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

          if let match = match(entry, app: app, bundleID: bundleID, appTokens: appTokens),
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
              if let match = match(child, app: app, bundleID: bundleID, appTokens: appTokens) {
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
      bundleSize: FileSystem.itemSize(
        at: url, fileManager: fileManager, skipPackageDescendants: false),
      lastModified: modified
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

  private func match(_ url: URL, app: AppRecord, bundleID: String?, appTokens: Set<String>)
    -> AppLeftover?
  {
    let filename = url.lastPathComponent.lowercased()
    let compact = filename.filter { $0.isLetter || $0.isNumber || $0 == "." }

    if let bundleID {
      let bundleCompact = bundleID.filter { $0.isLetter || $0.isNumber || $0 == "." }
      if compact == bundleCompact || compact.hasPrefix(bundleCompact + ".")
        || compact.hasSuffix("." + bundleCompact) || compact.contains("." + bundleCompact + ".")
      {
        return AppLeftover(
          url: url,
          size: FileSystem.itemSize(at: url, fileManager: fileManager),
          confidence: .high,
          reason: "Path contains the exact app bundle identifier."
        )
      }
    }

    let fileTokens = meaningfulTokens(in: filename)
    let overlap = appTokens.intersection(fileTokens)
    if !appTokens.isEmpty, overlap.count == appTokens.count {
      return AppLeftover(
        url: url,
        size: FileSystem.itemSize(at: url, fileManager: fileManager),
        confidence: .medium,
        reason: "Path tokens match the application name; review before removal."
      )
    }

    return nil
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
      if lhs.confidence != rhs.confidence { return lhs.confidence == .high }
      return lhs.size > rhs.size
    }
  }
}
