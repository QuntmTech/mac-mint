import Foundation

public struct HistoryEntry: Identifiable, Codable, Hashable, Sendable {
  public let id: UUID
  public let date: Date
  public let action: String
  public let paths: [String]
  public let bytes: Int64
  public let notes: String
  /// Trash locations for each moved item (absent in entries written before receipts existed).
  public let receipts: [TrashReceipt]?
  /// Original paths of receipts that have been restored from the Trash.
  public let restoredPaths: [String]?

  public init(
    id: UUID = UUID(), date: Date = Date(), action: String, paths: [String], bytes: Int64,
    notes: String, receipts: [TrashReceipt]? = nil, restoredPaths: [String]? = nil
  ) {
    self.id = id
    self.date = date
    self.action = action
    self.paths = paths
    self.bytes = bytes
    self.notes = notes
    self.receipts = receipts
    self.restoredPaths = restoredPaths
  }

  public func isRestored(_ receipt: TrashReceipt) -> Bool {
    restoredPaths?.contains(receipt.originalPath) == true
  }

  public var pendingReceipts: [TrashReceipt] { (receipts ?? []).filter { !isRestored($0) } }

  func markingRestored(_ paths: [String]) -> HistoryEntry {
    let merged = Array(Set((restoredPaths ?? []) + paths)).sorted()
    return HistoryEntry(
      id: id, date: date, action: action, paths: self.paths, bytes: bytes, notes: notes,
      receipts: receipts, restoredPaths: merged)
  }
}

public actor HistoryStore {
  private let url: URL
  private let encoder: JSONEncoder
  private let decoder = JSONDecoder()

  public init(url: URL) {
    self.url = url
    encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
  }

  public func load() -> [HistoryEntry] {
    guard let data = try? Data(contentsOf: url),
      let items = try? decoder.decode([HistoryEntry].self, from: data)
    else { return [] }
    return items.sorted { $0.date > $1.date }
  }

  public func append(_ entry: HistoryEntry) throws {
    var items = load()
    items.insert(entry, at: 0)
    try persist(items)
  }

  /// Records that some of an entry's items were restored from the Trash.
  public func markRestored(entryID: UUID, originalPaths: [String]) throws {
    let items = load().map { $0.id == entryID ? $0.markingRestored(originalPaths) : $0 }
    try persist(items)
  }

  private func persist(_ items: [HistoryEntry]) throws {
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try encoder.encode(Array(items.sorted { $0.date > $1.date }.prefix(200))).write(
      to: url, options: .atomic)
  }
}
