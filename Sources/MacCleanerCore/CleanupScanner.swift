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

      for piece in FileSystem.eligiblePieces(
        of: rule.url, ignoredPaths: ignoredPaths, fileManager: fileManager)
      {
        if Task.isCancelled { break }
        let measurement = FileSystem.measure(at: piece, fileManager: fileManager)
        issues.append(contentsOf: accessIssues(measurement, area: rule.name, url: piece))
        guard measurement.bytes > 0 else { continue }
        let isWholeRule = piece.standardizedFileURL == rule.url.standardizedFileURL
        results.append(
          CleanupTarget(
            category: rule.category,
            url: piece,
            displayName: isWholeRule ? rule.name : "\(rule.name): \(piece.lastPathComponent)",
            detail: piece.path,
            size: measurement.bytes,
            risk: rule.risk,
            reason: rule.reason,
            isSelected: rule.risk == .safe,
            ownerBundleID: rule.ownerBundleID,
            identity: FileSystem.fileIdentity(at: piece)
          ))
      }
    }

    let value = deduplicated(results).sorted { lhs, rhs in
      if lhs.risk != rhs.risk { return lhs.risk == .safe }
      return lhs.size > rhs.size
    }
    return ScanReport(
      value: value, issues: issues, duration: Date().timeIntervalSince(started),
      wasCancelled: Task.isCancelled)
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
      var items: [CleanupTarget] = []
      var issues: [ScanIssue] = []
      for entry in entries where !rule.excludedChildNames.contains(entry.lastPathComponent) {
        // Firmware folders also hold signatures and metadata; only the .ipsw images are offered.
        if rule.category == .deviceFirmware, entry.pathExtension.lowercased() != "ipsw" { continue }
        for piece in FileSystem.eligiblePieces(
          of: entry, ignoredPaths: ignoredPaths, fileManager: fileManager)
        {
          if Task.isCancelled { return (items, issues) }
          let measurement = FileSystem.measure(at: piece, fileManager: fileManager)
          issues.append(contentsOf: accessIssues(measurement, area: rule.name, url: piece))
          guard measurement.bytes > 0 else { continue }
          items.append(
            CleanupTarget(
              category: rule.category,
              url: piece,
              displayName: piece == entry
                ? entry.lastPathComponent
                : "\(entry.lastPathComponent)/\(piece.lastPathComponent)",
              detail: rule.name,
              size: measurement.bytes,
              risk: rule.risk,
              reason: rule.reason,
              isSelected: rule.risk == .safe,
              ownerBundleID: rule.ownerBundleID,
              identity: FileSystem.fileIdentity(at: piece)
            ))
        }
      }
      return (items, issues)
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
          isSelected: false,
          identity: FileSystem.fileIdentity(at: url)
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

  private func accessIssues(_ measurement: SizeMeasurement, area: String, url: URL) -> [ScanIssue]
  {
    guard !measurement.isComplete else { return [] }
    let detail = measurement.firstError.map { " (\($0))" } ?? ""
    return [
      ScanIssue(
        area: area, path: url.path,
        message:
          "\(measurement.inaccessibleCount) item(s) could not be read; size shown is a minimum.\(detail)"
      )
    ]
  }

  private func isIgnored(_ url: URL, ignoredPaths: Set<String>) -> Bool {
    FileSystem.isIgnored(url, ignoredPaths: ignoredPaths)
  }

  private func deduplicated(_ items: [CleanupTarget]) -> [CleanupTarget] {
    var seen: Set<String> = []
    return items.filter { seen.insert($0.url.standardizedFileURL.path).inserted }
  }
}
