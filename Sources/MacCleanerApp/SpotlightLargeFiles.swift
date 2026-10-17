import Foundation
import MacCleanerCore

/// Instant large-file candidates from the Spotlight index. Every hit is re-checked against the
/// filesystem (still exists, regular file, big enough, not excluded) before it is shown.
/// Returns nil when Spotlight can't answer (disabled, unindexed volume, timeout).
@MainActor
enum SpotlightLargeFiles {
  private final class QueryBox: @unchecked Sendable {
    let query = NSMetadataQuery()
    var observer: NSObjectProtocol?
    var finished = false
  }

  static func search(
    in root: URL, minimumSize: Int64, excludedRoots: [URL], ignoredPaths: Set<String>,
    limit: Int = 500, timeout: TimeInterval = 8
  ) async -> [LargeFile]? {
    guard let paths = await candidatePaths(in: root, minimumSize: minimumSize, timeout: timeout),
      !paths.isEmpty
    else { return nil }
    return await Task.detached(priority: .userInitiated) {
      verify(paths, root: root, minimumSize: minimumSize, excludedRoots: excludedRoots, ignoredPaths: ignoredPaths, limit: limit)
    }.value
  }

  private static func candidatePaths(in root: URL, minimumSize: Int64, timeout: TimeInterval) async -> [String]? {
    let box = QueryBox()
    box.query.searchScopes = [root]
    box.query.predicate = NSPredicate(format: "%K >= %lld", NSMetadataItemFSSizeKey, minimumSize)
    return await withCheckedContinuation { (continuation: CheckedContinuation<[String]?, Never>) in
      let finish: @Sendable ([String]?) -> Void = { result in
        MainActor.assumeIsolated {
          guard !box.finished else { return }
          box.finished = true
          box.query.stop()
          if let observer = box.observer { NotificationCenter.default.removeObserver(observer) }
          continuation.resume(returning: result)
        }
      }
      box.observer = NotificationCenter.default.addObserver(
        forName: .NSMetadataQueryDidFinishGathering, object: box.query, queue: .main
      ) { _ in
        MainActor.assumeIsolated {
          box.query.disableUpdates()
          let paths = (box.query.results as? [NSMetadataItem] ?? []).compactMap {
            $0.value(forAttribute: NSMetadataItemPathKey) as? String
          }
          finish(paths)
        }
      }
      guard box.query.start() else {
        finish(nil)
        return
      }
      DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { finish(nil) }
    }
  }

  nonisolated private static func verify(
    _ paths: [String], root: URL, minimumSize: Int64, excludedRoots: [URL], ignoredPaths: Set<String>,
    limit: Int
  ) -> [LargeFile] {
    var seen: Set<String> = []
    let files = paths.compactMap { path -> LargeFile? in
      let url = URL(fileURLWithPath: path)
      guard seen.insert(url.standardizedFileURL.path).inserted,
        FileSystem.path(url, isInsideOrEqual: root),
        !FileSystem.isIgnored(url, ignoredPaths: ignoredPaths),
        !PhotoAnalysis.isInsideLibraryPackage(url.resolvingSymlinksInPath()),
        !excludedRoots.contains(where: { FileSystem.path(url, isInsideOrEqual: $0) }),
        !url.standardizedFileURL.pathComponents.contains(where: { $0.hasPrefix(".") }),
        let meta = FileSystem.fileMetadata(at: url), meta.size >= minimumSize
      else { return nil }
      return LargeFile(
        url: url, size: meta.size, modifiedAt: meta.modified, accessedAt: meta.accessed,
        identity: FileSystem.fileIdentity(at: url))
    }
    return Array(files.sorted { $0.size > $1.size }.prefix(limit))
  }
}
