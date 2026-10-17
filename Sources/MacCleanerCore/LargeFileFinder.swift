import Foundation

public actor LargeFileFinder {
  private let fileManager: FileManager

  public init(fileManager: FileManager = .default) { self.fileManager = fileManager }

  public func find(
    in roots: [URL],
    minimumSize: Int64 = 100 * 1_048_576,
    limit: Int = 500,
    excludedRoots: [URL] = [],
    ignoredPaths: Set<String> = []
  ) async -> [LargeFile] {
    await findReport(
      in: roots, minimumSize: minimumSize, limit: limit, excludedRoots: excludedRoots,
      ignoredPaths: ignoredPaths
    ).value
  }

  public func findReport(
    in roots: [URL],
    minimumSize: Int64 = 100 * 1_048_576,
    limit: Int = 500,
    excludedRoots: [URL] = [],
    ignoredPaths: Set<String> = []
  ) async -> ScanReport<[LargeFile]> {
    let started = Date()
    var found: [LargeFile] = []
    let collector = IssueCollector()

    for root in roots {
      if Task.isCancelled {
        return ScanReport(
          value: sorted(found, limit: limit), issues: collector.issues,
          duration: Date().timeIntervalSince(started), wasCancelled: true)
      }
      if FileSystem.isIgnored(root, ignoredPaths: ignoredPaths) || PhotoAnalysis.isInsideLibraryPackage(root.resolvingSymlinksInPath()) { continue }
      guard fileManager.fileExists(atPath: root.path) else {
        collector.append(
          ScanIssue(
            area: "Large Files", path: root.path, severity: .info,
            message: "Scan root does not exist."))
        continue
      }

      guard
        let enumerator = fileManager.enumerator(
          at: root,
          includingPropertiesForKeys: Array(FileSystem.resourceKeys),
          options: [.skipsHiddenFiles, .skipsPackageDescendants],
          errorHandler: { url, error in
            collector.append(
              ScanIssue(area: "Large Files", path: url.path, message: error.localizedDescription))
            return true
          }
        )
      else {
        collector.append(
          ScanIssue(
            area: "Large Files", path: root.path, message: "Could not enumerate this folder."))
        continue
      }

      FileSystem.walk(enumerator) { url in
        if Task.isCancelled { return .stop }
        if PhotoAnalysis.isInsideLibraryPackage(url) || shouldExclude(url, excludedRoots: excludedRoots, ignoredPaths: ignoredPaths) {
          return isDirectory(url) ? .skipDescendants : .continue
        }
        guard let meta = FileSystem.fileMetadata(at: url), meta.size >= minimumSize else {
          return .continue
        }
        found.append(
          LargeFile(
            url: url, size: meta.size, modifiedAt: meta.modified, accessedAt: meta.accessed,
            identity: FileSystem.fileIdentity(at: url))
        )
        return .continue
      }
      if Task.isCancelled {
        return ScanReport(
          value: sorted(found, limit: limit), issues: collector.issues,
          duration: Date().timeIntervalSince(started), wasCancelled: true)
      }
    }

    return ScanReport(
      value: sorted(found, limit: limit), issues: collector.issues,
      duration: Date().timeIntervalSince(started))
  }

  private func shouldExclude(_ url: URL, excludedRoots: [URL], ignoredPaths: Set<String>) -> Bool {
    FileSystem.isIgnored(url, ignoredPaths: ignoredPaths)
      || excludedRoots.contains { FileSystem.path(url, isInsideOrEqual: $0) }
  }

  private func isDirectory(_ url: URL) -> Bool {
    (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
  }

  private func sorted(_ files: [LargeFile], limit: Int) -> [LargeFile] {
    Array(files.sorted { $0.size > $1.size }.prefix(max(0, limit)))
  }
}
