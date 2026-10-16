import Foundation

public actor CleanupScanner {
  private let fileManager: FileManager
  private let catalog: CleanupCatalog

  public init(fileManager: FileManager = .default, catalog: CleanupCatalog = CleanupCatalog()) {
    self.fileManager = fileManager
    self.catalog = catalog
  }

  public func scan(ignoredPaths: Set<String> = []) async -> [CleanupTarget] {
    await scanReport(ignoredPaths: ignoredPaths).value
  }

  public func scanReport(ignoredPaths: Set<String> = []) async -> ScanReport<[CleanupTarget]> {
    let started = Date()
    var results: [CleanupTarget] = []
    var issues: [ScanIssue] = []

    for rule in catalog.rules() {
      if Task.isCancelled {
        return ScanReport(
          value: deduplicated(results), issues: issues, duration: Date().timeIntervalSince(started),
          wasCancelled: true)
      }

      if isIgnored(rule.url, ignoredPaths: ignoredPaths) { continue }

      if rule.category == .installers {
        let report = scanInstallers(in: rule.url, ignoredPaths: ignoredPaths)
        results.append(contentsOf: report.items)
        issues.append(contentsOf: report.issues)
        continue
      }

      guard fileManager.fileExists(atPath: rule.url.path) else { continue }

      if rule.expandChildren {
        let report = scanChildren(for: rule, ignoredPaths: ignoredPaths)
        results.append(contentsOf: report.items)
        issues.append(contentsOf: report.issues)
        continue
      }

      let size = FileSystem.itemSize(at: rule.url, fileManager: fileManager)
      guard size > 0 else { continue }
      results.append(
        CleanupTarget(
          category: rule.category,
          url: rule.url,
          displayName: rule.name,
          detail: rule.url.path,
          size: size,
          risk: rule.risk,
          reason: rule.reason,
          isSelected: rule.risk == .safe
        ))
    }

    let value = deduplicated(results).sorted { lhs, rhs in
      if lhs.risk != rhs.risk { return lhs.risk == .safe }
      return lhs.size > rhs.size
    }
    return ScanReport(
      value: value, issues: issues, duration: Date().timeIntervalSince(started), wasCancelled: false
    )
  }

  private func scanChildren(for rule: CleanupRule, ignoredPaths: Set<String>) -> (
    items: [CleanupTarget], issues: [ScanIssue]
  ) {
    do {
      let entries = try fileManager.contentsOfDirectory(
        at: rule.url,
        includingPropertiesForKeys: nil,
        options: [.skipsHiddenFiles]
      )
      let items = entries.compactMap { url -> CleanupTarget? in
        guard !rule.excludedChildNames.contains(url.lastPathComponent),
          !isIgnored(url, ignoredPaths: ignoredPaths)
        else { return nil }
        let size = FileSystem.itemSize(at: url, fileManager: fileManager)
        guard size > 0 else { return nil }
        return CleanupTarget(
          category: rule.category,
          url: url,
          displayName: url.lastPathComponent,
          detail: rule.name,
          size: size,
          risk: rule.risk,
          reason: rule.reason,
          isSelected: rule.risk == .safe
        )
      }
      return (items, [])
    } catch {
      return (
        [], [ScanIssue(area: rule.name, path: rule.url.path, message: error.localizedDescription)]
      )
    }
  }

  private func scanInstallers(in downloads: URL, ignoredPaths: Set<String>) -> (
    items: [CleanupTarget], issues: [ScanIssue]
  ) {
    guard fileManager.fileExists(atPath: downloads.path) else { return ([], []) }
    do {
      let entries = try fileManager.contentsOfDirectory(
        at: downloads,
        includingPropertiesForKeys: [
          .isRegularFileKey, .fileSizeKey, .totalFileAllocatedSizeKey, .contentModificationDateKey,
        ],
        options: [.skipsHiddenFiles]
      )

      let extensions = Set(["dmg", "pkg", "iso", "zip", "xip"])
      let cutoff = Date().addingTimeInterval(-30 * 24 * 60 * 60)
      let items = entries.compactMap { url -> CleanupTarget? in
        guard !isIgnored(url, ignoredPaths: ignoredPaths),
          extensions.contains(url.pathExtension.lowercased())
        else { return nil }
        let values = try? url.resourceValues(forKeys: [
          .isRegularFileKey, .fileSizeKey, .totalFileAllocatedSizeKey, .contentModificationDateKey,
        ])
        guard values?.isRegularFile == true else { return nil }
        if let modified = values?.contentModificationDate, modified > cutoff { return nil }
        let size = Int64(values?.totalFileAllocatedSize ?? values?.fileSize ?? 0)
        guard size > 0 else { return nil }
        return CleanupTarget(
          category: .installers,
          url: url,
          displayName: url.lastPathComponent,
          detail: "Downloaded installer/archive older than 30 days",
          size: size,
          risk: .review,
          reason: "Likely one-time-use installer or archive in Downloads.",
          isSelected: false
        )
      }
      return (items, [])
    } catch {
      return (
        [],
        [
          ScanIssue(
            area: "Old Installers", path: downloads.path, message: error.localizedDescription)
        ]
      )
    }
  }

  private func isIgnored(_ url: URL, ignoredPaths: Set<String>) -> Bool {
    let path = url.standardizedFileURL.path
    return ignoredPaths.contains { ignored in path == ignored || path.hasPrefix(ignored + "/") }
  }

  private func deduplicated(_ items: [CleanupTarget]) -> [CleanupTarget] {
    var seen: Set<String> = []
    return items.filter { seen.insert($0.url.standardizedFileURL.path).inserted }
  }
}
