import Foundation

#if canImport(Darwin)
  import Darwin
#elseif canImport(Glibc)
  import Glibc
#endif

public struct StorageNode: Identifiable, Hashable, Sendable {
  public enum Kind: String, Hashable, Sendable {
    case folder
    case package
    case file
    /// Many small items rolled into one node to keep the tree bounded.
    case aggregate
    case inaccessible
    /// A mount point for another volume; not descended into.
    case otherVolume
  }

  public let id: String
  public let url: URL
  public let name: String
  public let kind: Kind
  /// Space used on this disk (what freeing it would recover, before snapshots/clones).
  public let allocatedBytes: Int64
  /// Sum of file sizes, including cloud-only placeholders that use no local space.
  public let logicalBytes: Int64
  public let itemCount: Int
  public let cloudOnlyCount: Int
  public let modified: Date?
  public let children: [StorageNode]
  /// "device:inode" observed at scan time (nil for synthetic nodes).
  public let identity: String?

  public init(
    url: URL, name: String? = nil, kind: Kind, allocatedBytes: Int64, logicalBytes: Int64,
    itemCount: Int, cloudOnlyCount: Int = 0, modified: Date? = nil, children: [StorageNode] = [],
    id: String? = nil, identity: String? = nil
  ) {
    self.identity = identity
    self.id = id ?? url.standardizedFileURL.path
    self.url = url
    self.name = name ?? url.lastPathComponent
    self.kind = kind
    self.allocatedBytes = allocatedBytes
    self.logicalBytes = logicalBytes
    self.itemCount = itemCount
    self.cloudOnlyCount = cloudOnlyCount
    self.modified = modified
    self.children = children
  }

  public var isContainer: Bool { kind == .folder && !children.isEmpty }
  /// Real filesystem items can be revealed or reviewed; synthetic aggregates cannot.
  public var isActionable: Bool { kind == .folder || kind == .package || kind == .file }

  /// A copy of the tree without the given paths (and their contents), with totals recomputed.
  /// Used to reflect items moved to Trash without rescanning.
  public func removing(_ paths: Set<String>) -> StorageNode {
    guard kind == .folder, !children.isEmpty else { return self }
    let prefix = id == "/" ? "/" : id + "/"
    guard paths.contains(where: { $0.hasPrefix(prefix) }) else { return self }
    let kept = children.compactMap { child -> StorageNode? in
      paths.contains(child.id) && child.isActionable ? nil : child.removing(paths)
    }
    return StorageNode(
      url: url, name: name, kind: kind,
      allocatedBytes: kept.reduce(0) { $0 + $1.allocatedBytes },
      logicalBytes: kept.reduce(0) { $0 + $1.logicalBytes },
      itemCount: kept.reduce(0) { $0 + $1.itemCount },
      cloudOnlyCount: kept.reduce(0) { $0 + $1.cloudOnlyCount },
      modified: modified, children: kept, id: id, identity: identity)
  }

  /// Nodes from this one down to `path`, for breadcrumbs.
  public func trail(to path: String) -> [StorageNode] {
    if id == path { return [self] }
    let prefix = id == "/" ? "/" : id + "/"
    guard path.hasPrefix(prefix) else { return [] }
    for child in children {
      let rest = child.trail(to: path)
      if !rest.isEmpty { return [self] + rest }
    }
    return []
  }

  public func node(at path: String) -> StorageNode? {
    if id == path { return self }
    guard path.hasPrefix(id == "/" ? "/" : id + "/") else { return nil }
    for child in children {
      if let match = child.node(at: path) { return match }
    }
    return nil
  }
}

extension StorageNode {
  /// A smaller copy for when the full map isn't on screen: folders `levels` below this node
  /// keep their totals but drop their children, except folders in `expanding` (the visible
  /// trail and the ancestors of selections). Returns the IDs of folders whose children were
  /// dropped, so they can be mapped again when opened.
  public func compacted(levels: Int, expanding: Set<String>) -> (node: StorageNode, pruned: Set<String>) {
    var pruned = Set<String>()
    let node = compacting(depth: 0, levels: max(1, levels), expanding: expanding, pruned: &pruned)
    return (node, pruned)
  }

  private func compacting(depth: Int, levels: Int, expanding: Set<String>, pruned: inout Set<String>) -> StorageNode {
    guard kind == .folder, !children.isEmpty else { return self }
    if depth >= levels && !expanding.contains(id) {
      pruned.insert(id)
      return with(children: [])
    }
    return with(children: children.map {
      $0.compacting(depth: depth + 1, levels: levels, expanding: expanding, pruned: &pruned)
    })
  }

  /// Every folder from `path` up to (not including) this node's parent: what must stay
  /// expanded for the node at `path` to remain reachable.
  public static func ancestors(of path: String, within root: String) -> Set<String> {
    var result = Set<String>()
    var current = (path as NSString).deletingLastPathComponent
    while current.count >= root.count, current.hasPrefix(root) {
      result.insert(current)
      let parent = (current as NSString).deletingLastPathComponent
      if parent == current { break }
      current = parent
    }
    return result
  }

  /// This tree with the node at `id` replaced (for a folder mapped again on demand) and the
  /// totals of every ancestor recomputed.
  public func replacing(_ id: String, with replacement: StorageNode) -> StorageNode {
    if self.id == id { return replacement }
    let prefix = self.id == "/" ? "/" : self.id + "/"
    guard kind == .folder, id.hasPrefix(prefix) else { return self }
    let next = children.map { $0.replacing(id, with: replacement) }
    return StorageNode(
      url: url, name: name, kind: kind,
      allocatedBytes: next.reduce(0) { $0 + $1.allocatedBytes },
      logicalBytes: next.reduce(0) { $0 + $1.logicalBytes },
      itemCount: next.reduce(0) { $0 + $1.itemCount },
      cloudOnlyCount: next.reduce(0) { $0 + $1.cloudOnlyCount },
      modified: modified, children: next, id: self.id, identity: identity)
  }

  private func with(children: [StorageNode]) -> StorageNode {
    StorageNode(url: url, name: name, kind: kind, allocatedBytes: allocatedBytes, logicalBytes: logicalBytes,
      itemCount: itemCount, cloudOnlyCount: cloudOnlyCount, modified: modified, children: children, id: id,
      identity: identity)
  }
}

public struct StorageCoverage: Hashable, Sendable {
  public var scannedItems = 0
  public var inaccessiblePaths: [String] = []
  public var cloudOnlyItems = 0
  public var otherVolumes: [String] = []
  public var wasCancelled = false
  public var excludedItems = 0

  public init() {}
}

public struct StorageScan: Sendable {
  public let root: StorageNode
  public let coverage: StorageCoverage
  public let duration: TimeInterval

  public init(root: StorageNode, coverage: StorageCoverage, duration: TimeInterval) {
    self.root = root
    self.coverage = coverage
    self.duration = duration
  }
}

/// Builds a size tree of a folder for the Storage Explorer.
/// - Stays on the starting volume; other mounts are listed, not entered.
/// - Packages (.app, .photoslibrary…) are leaves sized with their contents.
/// - Hard links are counted once. Cloud-only placeholders are counted but never read.
/// - Files smaller than `detailThreshold` are rolled into one "smaller items" node per folder.
public actor StorageTreeScanner {
  public typealias ProgressHandler = @Sendable (Int, String) -> Void

  private let fileManager: FileManager
  private let detailThreshold: Int64
  private let maxChildren: Int

  private static let keys: Set<URLResourceKey> = [
    .isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .isPackageKey,
    .fileSizeKey, .totalFileAllocatedSizeKey, .contentModificationDateKey, .volumeIdentifierKey,
  ]

  public init(
    fileManager: FileManager = .default, detailThreshold: Int64 = 1_048_576, maxChildren: Int = 300
  ) {
    self.fileManager = fileManager
    self.detailThreshold = detailThreshold
    self.maxChildren = maxChildren
  }

  public func scan(_ root: URL, ignoredPaths: Set<String> = [], progress: ProgressHandler? = nil) async -> StorageScan {
    let started = Date()
    var state = ScanState(progress: progress, ignoredPaths: ignoredPaths)
    let volume = try? root.resourceValues(forKeys: [.volumeIdentifierKey]).volumeIdentifier
    state.rootVolume = volume.map { "\($0)" }
    let node = scanFolder(root, state: &state, isRoot: true)
    state.coverage.wasCancelled = Task.isCancelled
    return StorageScan(
      root: node, coverage: state.coverage, duration: Date().timeIntervalSince(started))
  }

  private struct ScanState {
    var coverage = StorageCoverage()
    var seenLinks: Set<String> = []
    var rootVolume: String?
    let progress: ProgressHandler?
    let ignoredPaths: Set<String>
    // Fast disks enumerate tens of thousands of items per second; publish about 5 times a second.
    var throttle = ProgressThrottle()

    mutating func tick(_ path: String) {
      coverage.scannedItems += 1
      if coverage.scannedItems % 64 == 0, progress != nil, throttle.shouldReport() {
        progress?(coverage.scannedItems, path)
      }
    }
  }

  private func scanFolder(_ url: URL, state: inout ScanState, isRoot: Bool = false) -> StorageNode {
    if FileSystem.isIgnored(url, ignoredPaths: state.ignoredPaths) {
      state.coverage.excludedItems += 1
      return StorageNode(url: url, name: "Excluded", kind: .aggregate, allocatedBytes: 0, logicalBytes: 0, itemCount: 0)
    }
    if PhotoAnalysis.isInsideLibraryPackage(url) {
      return measurePackage(url, modified: nil, state: &state)
    }
    let entries: [URL]
    do {
      entries = try fileManager.contentsOfDirectory(
        at: url, includingPropertiesForKeys: Array(Self.keys), options: [])
    } catch {
      state.coverage.inaccessiblePaths.append(url.path)
      return StorageNode(
        url: Self.retained(url), kind: .inaccessible, allocatedBytes: 0, logicalBytes: 0, itemCount: 0)
    }

    var children: [StorageNode] = []
    var small = (allocated: Int64(0), logical: Int64(0), count: 0, cloud: 0)
    for entry in entries {
      if Task.isCancelled { break }
      if FileSystem.isIgnored(entry, ignoredPaths: state.ignoredPaths) {
        state.coverage.excludedItems += 1
        continue
      }
      state.tick(entry.path)
      guard let values = try? entry.resourceValues(forKeys: Self.keys) else {
        state.coverage.inaccessiblePaths.append(entry.path)
        continue
      }
      if values.isSymbolicLink == true { continue }

      if values.isDirectory == true {
        if let volume = values.volumeIdentifier.map({ "\($0)" }), let rootVolume = state.rootVolume,
          volume != rootVolume
        {
          state.coverage.otherVolumes.append(entry.path)
          children.append(
            StorageNode(
              url: Self.retained(entry), kind: .otherVolume, allocatedBytes: 0, logicalBytes: 0, itemCount: 0))
          continue
        }
        if values.isPackage == true {
          children.append(measurePackage(entry, modified: values.contentModificationDate, state: &state))
        } else {
          children.append(scanFolder(entry, state: &state))
        }
        continue
      }

      guard values.isRegularFile == true else { continue }
      let logical = Int64(values.fileSize ?? 0)
      let cloudOnly = Self.isDataless(entry)
      var allocated = cloudOnly ? 0 : Int64(values.totalFileAllocatedSize ?? values.fileSize ?? 0)
      if FileSystem.linkCount(at: entry) > 1, let identity = FileSystem.fileIdentity(at: entry),
        !state.seenLinks.insert(identity).inserted
      {
        allocated = 0
      }
      if cloudOnly { state.coverage.cloudOnlyItems += 1 }

      if max(allocated, logical) >= detailThreshold {
        children.append(
          StorageNode(
            url: Self.retained(entry), kind: .file, allocatedBytes: allocated, logicalBytes: logical,
            itemCount: 1, cloudOnlyCount: cloudOnly ? 1 : 0,
            modified: values.contentModificationDate, identity: FileSystem.fileIdentity(at: entry)))
      } else {
        small.allocated += allocated
        small.logical += logical
        small.count += 1
        if cloudOnly { small.cloud += 1 }
      }
    }

    // Tiny subfolders are folded into the aggregate too, so huge trees stay small in memory.
    var kept: [StorageNode] = []
    for child in children {
      if child.kind == .folder, max(child.allocatedBytes, child.logicalBytes) < detailThreshold {
        small.allocated += child.allocatedBytes
        small.logical += child.logicalBytes
        small.count += child.itemCount
        small.cloud += child.cloudOnlyCount
      } else {
        kept.append(child)
      }
    }
    kept.sort { $0.allocatedBytes == $1.allocatedBytes ? $0.logicalBytes > $1.logicalBytes : $0.allocatedBytes > $1.allocatedBytes }
    if kept.count > maxChildren {
      for overflow in kept[maxChildren...] {
        small.allocated += overflow.allocatedBytes
        small.logical += overflow.logicalBytes
        small.count += overflow.itemCount
        small.cloud += overflow.cloudOnlyCount
      }
      kept = Array(kept.prefix(maxChildren))
    }
    if small.count > 0 {
      kept.append(
        StorageNode(
          url: url, name: "\(small.count) smaller item\(small.count == 1 ? "" : "s")",
          kind: .aggregate, allocatedBytes: small.allocated, logicalBytes: small.logical,
          itemCount: small.count, cloudOnlyCount: small.cloud,
          id: url.standardizedFileURL.path + "/\u{0}smaller"))
    }

    let modified = try? url.resourceValues(forKeys: [.contentModificationDateKey])
      .contentModificationDate
    return StorageNode(
      url: Self.retained(url), kind: .folder,
      allocatedBytes: kept.reduce(0) { $0 + $1.allocatedBytes },
      logicalBytes: kept.reduce(0) { $0 + $1.logicalBytes },
      itemCount: kept.reduce(0) { $0 + $1.itemCount },
      cloudOnlyCount: kept.reduce(0) { $0 + $1.cloudOnlyCount },
      modified: modified, children: kept, identity: FileSystem.fileIdentity(at: url))
  }

  private func measurePackage(_ url: URL, modified: Date?, state: inout ScanState) -> StorageNode {
    let measurement = FileSystem.measure(at: url, fileManager: fileManager, ignoredPaths: state.ignoredPaths)
    if !measurement.isComplete { state.coverage.inaccessiblePaths.append(url.path) }
    return StorageNode(
      url: Self.retained(url), kind: .package, allocatedBytes: measurement.bytes, logicalBytes: measurement.bytes,
      itemCount: 1, modified: modified, identity: FileSystem.fileIdentity(at: url))
  }

  /// Enumerated URLs carry the prefetched resource values (a per-URL cache of strings, data
  /// and dictionaries). Nodes keep the URL for later actions, which read fresh values anyway.
  static func retained(_ url: URL) -> URL {
    var plain = url
    plain.removeAllCachedResourceValues()
    return plain
  }

  /// Cloud placeholders (iCloud, Dropbox, OneDrive via File Provider) carry SF_DATALESS.
  static func isDataless(_ url: URL) -> Bool {
    #if os(macOS)
      var info = stat()
      guard lstat(url.path, &info) == 0 else { return false }
      return info.st_flags & 0x4000_0000 != 0
    #else
      return false
    #endif
  }
}

// MARK: - Treemap layout

public enum Treemap {
  public struct Rect: Hashable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
      self.x = x
      self.y = y
      self.width = width
      self.height = height
    }

    public var area: Double { width * height }
  }

  /// Squarified treemap (Bruls, Huizing & van Wijk). `values` must be sorted descending.
  /// Returns one rect per value, in the same order; zero values get zero-size rects.
  public static func layout(_ values: [Double], in bounds: Rect) -> [Rect] {
    let total = values.reduce(0) { $0 + max(0, $1) }
    guard total > 0, bounds.area > 0 else {
      return values.map { _ in Rect(x: bounds.x, y: bounds.y, width: 0, height: 0) }
    }
    let scale = bounds.area / total
    let areas = values.map { max(0, $0) * scale }
    var result = [Rect](repeating: Rect(x: 0, y: 0, width: 0, height: 0), count: values.count)
    var free = bounds
    var index = 0
    while index < areas.count {
      let side = min(free.width, free.height)
      guard side > 0 else { break }
      var row: [Int] = [index]
      var rowArea = areas[index]
      var next = index + 1
      while next < areas.count {
        let candidate = rowArea + areas[next]
        let current = worst(row.map { areas[$0] }, sum: rowArea, side: side)
        let extended = worst(row.map { areas[$0] } + [areas[next]], sum: candidate, side: side)
        guard extended <= current else { break }
        row.append(next)
        rowArea = candidate
        next += 1
      }
      // Lay the row along the shorter side of the remaining space.
      if free.width >= free.height {
        let columnWidth = rowArea / free.height
        var y = free.y
        for i in row {
          let h = columnWidth > 0 ? areas[i] / columnWidth : 0
          result[i] = Rect(x: free.x, y: y, width: columnWidth, height: h)
          y += h
        }
        free = Rect(x: free.x + columnWidth, y: free.y, width: free.width - columnWidth, height: free.height)
      } else {
        let rowHeight = rowArea / free.width
        var x = free.x
        for i in row {
          let w = rowHeight > 0 ? areas[i] / rowHeight : 0
          result[i] = Rect(x: x, y: free.y, width: w, height: rowHeight)
          x += w
        }
        free = Rect(x: free.x, y: free.y + rowHeight, width: free.width, height: free.height - rowHeight)
      }
      index = next
    }
    return result
  }

  private static func worst(_ row: [Double], sum: Double, side: Double) -> Double {
    guard sum > 0, let maxArea = row.max(), let minArea = row.min(), minArea > 0 else {
      return .infinity
    }
    let s2 = side * side
    let sum2 = sum * sum
    return max(s2 * maxArea / sum2, sum2 / (s2 * minArea))
  }
}
