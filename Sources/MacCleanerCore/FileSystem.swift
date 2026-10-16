import Foundation

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

  public static func itemSize(
    at url: URL,
    fileManager: FileManager = .default,
    skipPackageDescendants: Bool = true
  ) -> Int64 {
    do {
      let values = try url.resourceValues(forKeys: resourceKeys)
      if values.isRegularFile == true {
        return Int64(values.totalFileAllocatedSize ?? values.fileSize ?? 0)
      }
      if values.isSymbolicLink == true { return 0 }
    } catch {
      return 0
    }

    let options: FileManager.DirectoryEnumerationOptions =
      skipPackageDescendants ? [.skipsPackageDescendants] : []
    guard
      let enumerator = fileManager.enumerator(
        at: url,
        includingPropertiesForKeys: Array(resourceKeys),
        options: options,
        errorHandler: { _, _ in true }
      )
    else { return 0 }

    var total: Int64 = 0
    for case let child as URL in enumerator {
      if Task.isCancelled { break }
      do {
        let values = try child.resourceValues(forKeys: resourceKeys)
        if values.isSymbolicLink == true { continue }
        if values.isRegularFile == true {
          total += Int64(values.totalFileAllocatedSize ?? values.fileSize ?? 0)
        }
      } catch { continue }
    }
    return total
  }

  /// Allocated bytes, useful for storage-reclamation estimates.
  public static func fileMetadata(at url: URL) -> (size: Int64, modified: Date?, accessed: Date?)? {
    do {
      let values = try url.resourceValues(forKeys: resourceKeys)
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
      let values = try url.resourceValues(forKeys: resourceKeys)
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

  public static func path(_ child: URL, isInsideOrEqual root: URL) -> Bool {
    let childPath = child.standardizedFileURL.path
    let rootPath = root.standardizedFileURL.path
    return childPath == rootPath || childPath.hasPrefix(rootPath + "/")
  }

  public static func isIgnored(_ url: URL, ignoredPaths: Set<String>) -> Bool {
    let path = url.standardizedFileURL.path
    return ignoredPaths.contains { ignored in path == ignored || path.hasPrefix(ignored + "/") }
  }
}
