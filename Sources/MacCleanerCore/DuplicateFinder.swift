import Foundation

public actor DuplicateFinder {
  private let fileManager: FileManager

  public init(fileManager: FileManager = .default) {
    self.fileManager = fileManager
  }

  public func find(
    in roots: [URL],
    minimumSize: Int64 = 1_048_576,
    excludedRoots: [URL] = [],
    ignoredPaths: Set<String> = []
  ) async -> [DuplicateGroup] {
    await findReport(
      in: roots, minimumSize: minimumSize, excludedRoots: excludedRoots, ignoredPaths: ignoredPaths
    ).value
  }

  public func findReport(
    in roots: [URL],
    minimumSize: Int64 = 1_048_576,
    excludedRoots: [URL] = [],
    ignoredPaths: Set<String> = []
  ) async -> ScanReport<[DuplicateGroup]> {
    let started = Date()
    var bySize: [Int64: [LargeFile]] = [:]
    var issues: [ScanIssue] = []

    for root in roots {
      if Task.isCancelled {
        return ScanReport(
          value: [], issues: issues, duration: Date().timeIntervalSince(started), wasCancelled: true
        )
      }
      guard fileManager.fileExists(atPath: root.path) else {
        issues.append(
          ScanIssue(
            area: "Duplicates", path: root.path, severity: .info,
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
              ScanIssue(area: "Duplicates", path: url.path, message: error.localizedDescription))
            return true
          }
        )
      else {
        issues.append(
          ScanIssue(
            area: "Duplicates", path: root.path, message: "Could not enumerate this folder."))
        continue
      }

      for case let url as URL in enumerator {
        if Task.isCancelled {
          return ScanReport(
            value: [], issues: issues, duration: Date().timeIntervalSince(started),
            wasCancelled: true)
        }

        if shouldExclude(url, excludedRoots: excludedRoots, ignoredPaths: ignoredPaths) {
          if isDirectory(url) { enumerator.skipDescendants() }
          continue
        }

        guard let meta = FileSystem.logicalFileMetadata(at: url), meta.size >= minimumSize else {
          continue
        }
        bySize[meta.size, default: []].append(
          LargeFile(url: url, size: meta.size, modifiedAt: meta.modified, accessedAt: meta.accessed)
        )
      }
    }

    var groups: [DuplicateGroup] = []
    for (_, sameSize) in bySize where sameSize.count > 1 {
      if Task.isCancelled {
        return ScanReport(
          value: groups.sorted { $0.reclaimableBytes > $1.reclaimableBytes }, issues: issues,
          duration: Date().timeIntervalSince(started), wasCancelled: true)
      }

      var bySample: [String: [LargeFile]] = [:]
      for file in sameSize {
        if Task.isCancelled { break }
        do {
          let sample = try SHA256.hexDigest(file: file.url, sampleLimit: 64 * 1024)
          bySample[sample, default: []].append(file)
        } catch is CancellationError {
          return ScanReport(
            value: groups.sorted { $0.reclaimableBytes > $1.reclaimableBytes },
            issues: issues, duration: Date().timeIntervalSince(started), wasCancelled: true)
        } catch {
          issues.append(
            ScanIssue(
              area: "Duplicates", path: file.url.path,
              message: "Could not sample file: \(error.localizedDescription)"))
        }
      }

      for (_, candidates) in bySample where candidates.count > 1 {
        var byFull: [String: [LargeFile]] = [:]
        for file in candidates {
          if Task.isCancelled { break }
          do {
            let full = try SHA256.hexDigest(file: file.url)
            byFull[full, default: []].append(file)
          } catch is CancellationError {
            return ScanReport(
              value: groups.sorted { $0.reclaimableBytes > $1.reclaimableBytes },
              issues: issues, duration: Date().timeIntervalSince(started), wasCancelled: true)
          } catch {
            issues.append(
              ScanIssue(
                area: "Duplicates", path: file.url.path,
                message: "Could not hash file: \(error.localizedDescription)"))
          }
        }
        for (hash, exact) in byFull where exact.count > 1 {
          groups.append(
            DuplicateGroup(fingerprint: hash, files: exact.sorted { $0.url.path < $1.url.path }))
        }
      }
    }

    return ScanReport(
      value: groups.sorted { $0.reclaimableBytes > $1.reclaimableBytes }, issues: issues,
      duration: Date().timeIntervalSince(started), wasCancelled: Task.isCancelled)
  }

  private func shouldExclude(_ url: URL, excludedRoots: [URL], ignoredPaths: Set<String>) -> Bool {
    FileSystem.isIgnored(url, ignoredPaths: ignoredPaths)
      || excludedRoots.contains { FileSystem.path(url, isInsideOrEqual: $0) }
  }

  private func isDirectory(_ url: URL) -> Bool {
    (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
  }
}
