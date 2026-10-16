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
    var issues: [ScanIssue] = []

    for root in roots {
      if Task.isCancelled {
        return ScanReport(
          value: sorted(found, limit: limit), issues: issues,
          duration: Date().timeIntervalSince(started), wasCancelled: true)
      }
      guard fileManager.fileExists(atPath: root.path) else {
        issues.append(
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
            issues.append(
              ScanIssue(area: "Large Files", path: url.path, message: error.localizedDescription))
            return true
          }
        )
      else {
        issues.append(
          ScanIssue(
            area: "Large Files", path: root.path, message: "Could not enumerate this folder."))
        continue
      }

      for case let url as URL in enumerator {
        if Task.isCancelled {
          return ScanReport(
            value: sorted(found, limit: limit), issues: issues,
            duration: Date().timeIntervalSince(started), wasCancelled: true)
        }

        if shouldExclude(url, excludedRoots: excludedRoots, ignoredPaths: ignoredPaths) {
          if isDirectory(url) { enumerator.skipDescendants() }
          continue
        }

        guard let meta = FileSystem.fileMetadata(at: url), meta.size >= minimumSize else {
          continue
        }
        found.append(
          LargeFile(url: url, size: meta.size, modifiedAt: meta.modified, accessedAt: meta.accessed)
        )
      }
    }

    return ScanReport(
      value: sorted(found, limit: limit), issues: issues,
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
