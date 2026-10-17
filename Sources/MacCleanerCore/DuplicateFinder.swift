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
    let collector = IssueCollector()

    for root in roots {
      if Task.isCancelled {
        return ScanReport(
          value: [], issues: collector.issues, duration: Date().timeIntervalSince(started), wasCancelled: true
        )
      }
      if FileSystem.isIgnored(root, ignoredPaths: ignoredPaths) || PhotoAnalysis.isInsideLibraryPackage(root.resolvingSymlinksInPath()) { continue }
      guard fileManager.fileExists(atPath: root.path) else {
        collector.append(
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
            collector.append(
              ScanIssue(area: "Duplicates", path: url.path, message: error.localizedDescription))
            return true
          }
        )
      else {
        collector.append(
          ScanIssue(
            area: "Duplicates", path: root.path, message: "Could not enumerate this folder."))
        continue
      }

      FileSystem.walk(enumerator) { url in
        if Task.isCancelled { return .stop }
        if PhotoAnalysis.isInsideLibraryPackage(url) || shouldExclude(url, excludedRoots: excludedRoots, ignoredPaths: ignoredPaths) {
          return isDirectory(url) ? .skipDescendants : .continue
        }
        if FileSystem.isCloudPlaceholder(url) {
          collector.append(ScanIssue(area: "Duplicates", path: url.path, severity: .info, message: "Cloud-only file was not downloaded or hashed."))
          return .continue
        }
        guard let meta = FileSystem.logicalFileMetadata(at: url), meta.size >= minimumSize else {
          return .continue
        }
        bySize[meta.size, default: []].append(
          LargeFile(
            url: url, size: meta.size, modifiedAt: meta.modified, accessedAt: meta.accessed,
            identity: FileSystem.fileIdentity(at: url))
        )
        return .continue
      }
      if Task.isCancelled {
        return ScanReport(
          value: [], issues: collector.issues, duration: Date().timeIntervalSince(started),
          wasCancelled: true)
      }
    }

    var groups: [DuplicateGroup] = []
    for (_, sameSize) in bySize where sameSize.count > 1 {
      if Task.isCancelled {
        return ScanReport(
          value: groups.sorted { $0.reclaimableBytes > $1.reclaimableBytes }, issues: collector.issues,
          duration: Date().timeIntervalSince(started), wasCancelled: true)
      }

      // Hard links share content by definition; hash one path per physical file.
      let physical = Self.groupByIdentity(sameSize)
      guard physical.count > 1 else { continue }

      var bySample: [String: [[LargeFile]]] = [:]
      for links in physical {
        let file = links[0]
        if Task.isCancelled { break }
        do {
          if FileSystem.isCloudPlaceholder(file.url) { continue }
          let sample = try SHA256.hexDigest(file: file.url, sampleLimit: 64 * 1024)
          bySample[sample, default: []].append(links)
        } catch is CancellationError {
          return ScanReport(
            value: groups.sorted { $0.reclaimableBytes > $1.reclaimableBytes },
            issues: collector.issues, duration: Date().timeIntervalSince(started), wasCancelled: true)
        } catch {
          collector.append(
            ScanIssue(
              area: "Duplicates", path: file.url.path,
              message: "Could not sample file: \(error.localizedDescription)"))
        }
      }

      for (_, candidates) in bySample where candidates.count > 1 {
        var byFull: [String: [LargeFile]] = [:]
        for links in candidates {
          let file = links[0]
          if Task.isCancelled { break }
          do {
            if FileSystem.isCloudPlaceholder(file.url) { continue }
            let full = try SHA256.hexDigest(file: file.url)
            byFull[full, default: []].append(contentsOf: links)
          } catch is CancellationError {
            return ScanReport(
              value: groups.sorted { $0.reclaimableBytes > $1.reclaimableBytes },
              issues: collector.issues, duration: Date().timeIntervalSince(started), wasCancelled: true)
          } catch {
            collector.append(
              ScanIssue(
                area: "Duplicates", path: file.url.path,
                message: "Could not hash file: \(error.localizedDescription)"))
          }
        }
        for (hash, exact) in byFull {
          let group = DuplicateGroup(
            fingerprint: hash, files: exact.sorted { $0.url.path < $1.url.path })
          if group.physicalCopyCount > 1 { groups.append(group) }
        }
      }
    }

    return ScanReport(
      value: groups.sorted { $0.reclaimableBytes > $1.reclaimableBytes }, issues: collector.issues,
      duration: Date().timeIntervalSince(started), wasCancelled: Task.isCancelled)
  }

  static func groupByIdentity(_ files: [LargeFile]) -> [[LargeFile]] {
    var order: [String] = []
    var buckets: [String: [LargeFile]] = [:]
    for file in files {
      let key = file.identity ?? "path:" + file.url.standardizedFileURL.path
      if buckets[key] == nil { order.append(key) }
      buckets[key, default: []].append(file)
    }
    return order.compactMap { buckets[$0] }
  }

  private func shouldExclude(_ url: URL, excludedRoots: [URL], ignoredPaths: Set<String>) -> Bool {
    FileSystem.isIgnored(url, ignoredPaths: ignoredPaths)
      || excludedRoots.contains { FileSystem.path(url, isInsideOrEqual: $0) }
  }

  private func isDirectory(_ url: URL) -> Bool {
    (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
  }
}
