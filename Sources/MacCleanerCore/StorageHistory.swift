import Foundation

// MARK: - Folder-size snapshots ("what grew since last time")

/// Sizes of the meaningful folders in one Storage scan.
public struct StorageSnapshot: Codable, Hashable, Sendable {
  public let takenAt: Date
  public let root: String
  /// Folder path → allocated bytes.
  public let folders: [String: Int64]

  public init(takenAt: Date, root: String, folders: [String: Int64]) {
    self.takenAt = takenAt
    self.root = root
    self.folders = folders
  }

  /// Folders down to `maxDepth` levels below the root, at least `minimumBytes` large.
  public init(
    tree: StorageNode, takenAt: Date = Date(), maxDepth: Int = 4,
    minimumBytes: Int64 = 50 * 1_048_576
  ) {
    var folders: [String: Int64] = [:]
    func visit(_ node: StorageNode, depth: Int) {
      guard node.kind == .folder, node.allocatedBytes >= minimumBytes else { return }
      folders[node.id] = node.allocatedBytes
      guard depth < maxDepth else { return }
      for child in node.children { visit(child, depth: depth + 1) }
    }
    visit(tree, depth: 0)
    self.init(takenAt: takenAt, root: tree.id, folders: folders)
  }
}

public struct StorageGrowth: Identifiable, Hashable, Sendable {
  public let path: String
  public let before: Int64
  public let after: Int64
  public var id: String { path }
  public var delta: Int64 { after - before }
  public var isNew: Bool { before == 0 }
}

public enum StorageGrowthAnalyzer {
  /// Folders that grew by at least `minimumDelta`, most specific first: a parent is only listed
  /// when no single child explains most (80%) of its growth, so the list points at the cause.
  public static func growth(
    from old: StorageSnapshot, to new: StorageSnapshot, minimumDelta: Int64 = 200 * 1_048_576
  ) -> [StorageGrowth] {
    guard old.root == new.root else { return [] }
    let grown = new.folders.compactMap { path, after -> StorageGrowth? in
      let before = old.folders[path] ?? 0
      return after - before >= minimumDelta ? StorageGrowth(path: path, before: before, after: after) : nil
    }
    let explained = Set(
      grown.compactMap { parent -> String? in
        let prefix = parent.path == "/" ? "/" : parent.path + "/"
        let explainedByChild = grown.contains { child in
          child.path.hasPrefix(prefix) && Double(child.delta) >= 0.8 * Double(parent.delta)
        }
        return explainedByChild ? parent.path : nil
      })
    return grown.filter { !explained.contains($0.path) }.sorted { $0.delta > $1.delta }
  }
}

/// Bounded JSON history of snapshots per scanned root.
public actor StorageSnapshotStore {
  private let url: URL
  private let limit: Int

  public init(url: URL, limit: Int = 30) {
    self.url = url
    self.limit = limit
  }

  public func load() -> [StorageSnapshot] {
    guard let data = try? Data(contentsOf: url) else { return [] }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return (try? decoder.decode([StorageSnapshot].self, from: data)) ?? []
  }

  /// Most recent snapshot of `root` before this one, if any.
  public func previous(root: String) -> StorageSnapshot? {
    load().filter { $0.root == root }.max { $0.takenAt < $1.takenAt }
  }

  public func append(_ snapshot: StorageSnapshot) throws {
    var all = load()
    all.append(snapshot)
    // Keep the newest `limit` per root.
    let grouped = Dictionary(grouping: all, by: \.root)
    let trimmed = grouped.values.flatMap { $0.sorted { $0.takenAt > $1.takenAt }.prefix(limit) }
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try encoder.encode(trimmed.sorted { $0.takenAt < $1.takenAt }).write(to: url, options: .atomic)
  }
}

// MARK: - Free-space history

public struct SpaceSample: Codable, Hashable, Sendable, Identifiable {
  public let day: Date
  public let freeBytes: Int64
  public let totalBytes: Int64
  public var id: Date { day }
  public var usedBytes: Int64 { max(0, totalBytes - freeBytes) }

  public init(day: Date, freeBytes: Int64, totalBytes: Int64) {
    self.day = day
    self.freeBytes = freeBytes
    self.totalBytes = totalBytes
  }
}

/// One sample per day (the latest reading wins), kept for `retentionDays`.
public actor SpaceHistoryStore {
  private let url: URL
  private let retentionDays: Int
  private let calendar: Calendar

  public init(url: URL, retentionDays: Int = 90, calendar: Calendar = .current) {
    self.url = url
    self.retentionDays = retentionDays
    self.calendar = calendar
  }

  public func load() -> [SpaceSample] {
    guard let data = try? Data(contentsOf: url) else { return [] }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return ((try? decoder.decode([SpaceSample].self, from: data)) ?? []).sorted { $0.day < $1.day }
  }

  @discardableResult
  public func record(freeBytes: Int64, totalBytes: Int64, at date: Date = Date()) throws -> [SpaceSample] {
    guard totalBytes > 0 else { return load() }
    let day = calendar.startOfDay(for: date)
    var samples = load().filter { $0.day != day }
    samples.append(SpaceSample(day: day, freeBytes: freeBytes, totalBytes: totalBytes))
    let cutoff = calendar.date(byAdding: .day, value: -retentionDays, to: day) ?? day
    samples = samples.filter { $0.day > cutoff }.sorted { $0.day < $1.day }
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try encoder.encode(samples).write(to: url, options: .atomic)
    return samples
  }
}

public enum SpaceTrend {
  /// Change in free space over the last `days` (negative = the disk is filling up), using the
  /// oldest sample inside the window; nil with fewer than two samples.
  public static func freeSpaceChange(_ samples: [SpaceSample], days: Int, now: Date = Date()) -> Int64? {
    let cutoff = now.addingTimeInterval(-Double(days) * 86_400)
    let window = samples.filter { $0.day >= Calendar.current.startOfDay(for: cutoff) }
    guard let first = window.first, let last = window.last, first.day != last.day else { return nil }
    return last.freeBytes - first.freeBytes
  }
}
