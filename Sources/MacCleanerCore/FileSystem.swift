import Foundation

#if canImport(Darwin)
  import Darwin
#elseif canImport(Glibc)
  import Glibc
#endif

/// Result of measuring an item on disk. `inaccessibleCount` > 0 means the total is a lower bound.
public struct SizeMeasurement: Sendable, Hashable {
  public let bytes: Int64
  public let inaccessibleCount: Int
  public let firstError: String?

  public init(bytes: Int64, inaccessibleCount: Int = 0, firstError: String? = nil) {
    self.bytes = bytes
    self.inaccessibleCount = inaccessibleCount
    self.firstError = firstError
  }

  public var isComplete: Bool { inaccessibleCount == 0 }
}

/// Thread-safe collector for issues raised from FileManager enumerator error handlers.
public final class IssueCollector: @unchecked Sendable {
  private let lock = NSLock()
  private var storage: [ScanIssue] = []

  public init() {}

  public func append(_ issue: ScanIssue) {
    lock.lock()
    storage.append(issue)
    lock.unlock()
  }

  public func append(contentsOf issues: [ScanIssue]) {
    lock.lock()
    storage.append(contentsOf: issues)
    lock.unlock()
  }

  public var issues: [ScanIssue] {
    lock.lock()
    defer { lock.unlock() }
    return storage
  }
}

public enum FileSystem {
  public static let resourceKeys: Set<URLResourceKey> = [
    .isRegularFileKey,
    .isDirectoryKey,
    .isSymbolicLinkKey,
    .fileSizeKey,
    .totalFileAllocatedSizeKey,
    .contentModificationDateKey,
    .contentAccessDateKey,
    .isPackageKey,
  ]

  public enum Visit {
    case `continue`
    case skipDescendants
    case stop
  }

  /// Synchronous enumeration wrapper. `DirectoryEnumerator`'s iterator is unavailable from
  /// async contexts in Swift 6, so actors call this instead of iterating directly.
  public static func walk(
    _ enumerator: FileManager.DirectoryEnumerator,
    _ visit: (URL) -> Visit
  ) {
    while let next = enumerator.nextObject() {
      guard let url = next as? URL else { continue }
      switch visit(url) {
      case .continue: break
      case .skipDescendants: enumerator.skipDescendants()
      case .stop: return
      }
    }
  }

  /// Allocated size of a file or folder, including package contents, with unreadable
  /// descendants counted instead of silently treated as empty.
  public static func measure(at url: URL, fileManager: FileManager = .default) -> SizeMeasurement {
    let url = fresh(url)
    let values: URLResourceValues
    do {
      values = try url.resourceValues(forKeys: resourceKeys)
    } catch {
      return SizeMeasurement(bytes: 0, inaccessibleCount: 1, firstError: error.localizedDescription)
    }
    if values.isSymbolicLink == true { return SizeMeasurement(bytes: 0) }
    if values.isRegularFile == true {
      return SizeMeasurement(bytes: Int64(values.totalFileAllocatedSize ?? values.fileSize ?? 0))
    }

    let errors = ErrorCounter()
    guard
      let enumerator = fileManager.enumerator(
        at: url,
        includingPropertiesForKeys: Array(resourceKeys),
        options: [],
        errorHandler: { _, error in
          errors.record(error)
          return true
        }
      )
    else {
      return SizeMeasurement(
        bytes: 0, inaccessibleCount: 1, firstError: "Could not enumerate this folder.")
    }

    var total: Int64 = 0
    var seenIdentities: Set<String> = []
    walk(enumerator) { child in
      if Task.isCancelled { return .stop }
      guard let childValues = try? child.resourceValues(forKeys: resourceKeys) else {
        errors.record(nil)
        return .continue
      }
      if childValues.isSymbolicLink == true { return .continue }
      if childValues.isRegularFile == true {
        // Hard links inside one tree occupy space once.
        if let identity = fileIdentity(at: child), linkCount(at: child) > 1 {
          guard seenIdentities.insert(identity).inserted else { return .continue }
        }
        total += Int64(childValues.totalFileAllocatedSize ?? childValues.fileSize ?? 0)
      }
      return .continue
    }
    return SizeMeasurement(
      bytes: total, inaccessibleCount: errors.count, firstError: errors.firstMessage)
  }

  /// Allocated bytes including package contents. Prefer `measure(at:)` when completeness matters.
  public static func itemSize(at url: URL, fileManager: FileManager = .default) -> Int64 {
    measure(at: url, fileManager: fileManager).bytes
  }

  /// A URL with no cached resource values. Foundation caches values per URL instance on macOS,
  /// so safety re-checks must never reuse the URL object captured at scan time.
  public static func fresh(_ url: URL) -> URL { URL(fileURLWithPath: url.path) }

  /// Allocated bytes, useful for storage-reclamation estimates.
  public static func fileMetadata(at url: URL) -> (size: Int64, modified: Date?, accessed: Date?)? {
    do {
      let values = try fresh(url).resourceValues(forKeys: resourceKeys)
      guard values.isRegularFile == true, values.isSymbolicLink != true else { return nil }
      return (
        Int64(values.totalFileAllocatedSize ?? values.fileSize ?? 0),
        values.contentModificationDate,
        values.contentAccessDate
      )
    } catch {
      return nil
    }
  }

  /// Logical bytes, required for exact duplicate candidate grouping.
  public static func logicalFileMetadata(at url: URL) -> (
    size: Int64, modified: Date?, accessed: Date?
  )? {
    do {
      let values = try fresh(url).resourceValues(forKeys: resourceKeys)
      guard values.isRegularFile == true, values.isSymbolicLink != true else { return nil }
      return (
        Int64(values.fileSize ?? 0),
        values.contentModificationDate,
        values.contentAccessDate
      )
    } catch {
      return nil
    }
  }

  /// "device:inode" for the item itself (symlinks are not followed). Two paths with the same
  /// identity are the same physical file (hard links).
  public static func fileIdentity(at url: URL) -> String? {
    var info = stat()
    guard lstat(url.path, &info) == 0 else { return nil }
    return "\(info.st_dev):\(info.st_ino)"
  }

  public static func linkCount(at url: URL) -> Int {
    var info = stat()
    guard lstat(url.path, &info) == 0 else { return 0 }
    return Int(info.st_nlink)
  }

  public static func path(_ child: URL, isInsideOrEqual root: URL) -> Bool {
    let childPath = child.standardizedFileURL.path
    let rootPath = root.standardizedFileURL.path
    return childPath == rootPath || childPath.hasPrefix(rootPath + "/")
  }

  public static func isIgnored(_ url: URL, ignoredPaths: Set<String>) -> Bool {
    let path = url.standardizedFileURL.path
    return ignoredPaths.contains { ignored in path == ignored || path.hasPrefix(ignored + "/") }
  }

  /// True when an excluded path lives strictly inside `url`, so acting on `url` as a whole
  /// would also act on something the user asked to protect.
  public static func containsIgnoredDescendant(_ url: URL, ignoredPaths: Set<String>) -> Bool {
    let path = url.standardizedFileURL.path
    return ignoredPaths.contains { $0.hasPrefix(path + "/") }
  }

  /// Splits `url` into the largest pieces that do not include any excluded path. Returns
  /// `[url]` when nothing inside is excluded and `[]` when `url` itself is excluded.
  public static func eligiblePieces(
    of url: URL, ignoredPaths: Set<String>, fileManager: FileManager = .default
  ) -> [URL] {
    if isIgnored(url, ignoredPaths: ignoredPaths) { return [] }
    guard containsIgnoredDescendant(url, ignoredPaths: ignoredPaths) else { return [url] }
    guard
      let children = try? fileManager.contentsOfDirectory(
        at: url, includingPropertiesForKeys: nil, options: [])
    else { return [] }
    return children.flatMap {
      eligiblePieces(of: $0, ignoredPaths: ignoredPaths, fileManager: fileManager)
    }
  }
}

private final class ErrorCounter: @unchecked Sendable {
  private let lock = NSLock()
  private(set) var count = 0
  private(set) var firstMessage: String?

  func record(_ error: Error?) {
    lock.lock()
    count += 1
    if firstMessage == nil, let error { firstMessage = error.localizedDescription }
    lock.unlock()
  }
}
