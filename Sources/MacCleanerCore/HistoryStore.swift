import Foundation

public enum HistoryRecoveryKind: String, Codable, Hashable, Sendable { case trash, photos }

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
  /// Physical destinations, including restores to another folder. Optional for old history.
  public let restoredLocations: [String: String]?
  /// Interrupted moves whose destinations could not be proven. Retain this evidence even
  /// when there is no Trash receipt and the operation is older than the normal History cap.
  public let unresolvedPaths: [String]?
  public let recoveryKind: HistoryRecoveryKind?
  public var restoresThroughPhotos: Bool { recoveryKind == .photos || (recoveryKind == nil && action.hasPrefix("Photos:") && paths.isEmpty && receipts == nil) }

  public init(
    id: UUID = UUID(), date: Date = Date(), action: String, paths: [String], bytes: Int64,
    notes: String, receipts: [TrashReceipt]? = nil, restoredPaths: [String]? = nil,
    recoveryKind: HistoryRecoveryKind? = nil, restoredLocations: [String: String]? = nil,
    unresolvedPaths: [String]? = nil
  ) {
    self.id = id
    self.date = date
    self.action = action
    self.paths = paths
    self.bytes = bytes
    self.notes = notes
    self.receipts = receipts
    self.restoredPaths = restoredPaths
    self.restoredLocations = restoredLocations
    self.unresolvedPaths = unresolvedPaths
    self.recoveryKind = recoveryKind
  }

  public func isRestored(_ receipt: TrashReceipt) -> Bool {
    restoredPaths?.contains(receipt.originalPath) == true
  }

  public var pendingReceipts: [TrashReceipt] { (receipts ?? []).filter { !isRestored($0) } }

  func markingRestored(_ paths: [String], locations: [String: String] = [:]) -> HistoryEntry {
    let merged = Array(Set((restoredPaths ?? []) + paths + Array(locations.keys))).sorted()
    let destinations = (restoredLocations ?? [:]).merging(locations) { _, new in new }
    return HistoryEntry(
      id: id, date: date, action: action, paths: self.paths, bytes: bytes, notes: notes,
      receipts: receipts, restoredPaths: merged, recoveryKind: recoveryKind,
      restoredLocations: destinations.isEmpty ? nil : destinations, unresolvedPaths: unresolvedPaths)
  }
}

public actor HistoryStore {
  private let url: URL
  private let encoder: JSONEncoder
  private let decoder = JSONDecoder()
  private let writer: @Sendable (Data, URL) throws -> Void

  public init(url: URL, writer: (@Sendable (Data, URL) throws -> Void)? = nil) {
    self.url = url
    self.writer = writer ?? { try FileSystem.writeDurably($0, to: $1) }
    encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
  }

  public func load() -> [HistoryEntry] { (try? loadChecked()) ?? [] }

  /// Distinguishes a fresh installation from an unreadable or corrupt recovery store.
  public func loadChecked() throws -> [HistoryEntry] {
    do { return try decoder.decode([HistoryEntry].self, from: Data(contentsOf: url)).sorted { $0.date > $1.date } }
    catch let error as CocoaError where error.code == .fileReadNoSuchFile { return [] }
  }

  public func append(_ entry: HistoryEntry) throws {
    // Do not overwrite a damaged store with a seemingly empty history.
    var items = try loadChecked()
    if let previous = items.first(where: { $0.id == entry.id }) {
      items.removeAll { $0.id == entry.id }
      items.insert(entry.markingRestored(previous.restoredPaths ?? [],
        locations: previous.restoredLocations ?? [:]), at: 0)
    } else { items.insert(entry, at: 0) }
    try persist(items)
  }

  /// Records that some of an entry's items were restored from the Trash.
  public func markRestored(entryID: UUID, originalPaths: [String]) throws {
    try markRestored(entryID: entryID, locations: Dictionary(originalPaths.map { ($0, $0) }, uniquingKeysWith: { a, _ in a }))
  }

  public func markRestored(entryID: UUID, locations: [String: String]) throws {
    let current = try loadChecked()
    guard current.contains(where: { $0.id == entryID }) else {
      throw CocoaError(.fileReadUnknown, userInfo: [NSLocalizedDescriptionKey: "The matching History operation could not be found. Its recovery evidence must be checked."])
    }
    let items = current.map { $0.id == entryID ? $0.markingRestored([], locations: locations) : $0 }
    try persist(items)
  }

  private func persist(_ items: [HistoryEntry]) throws {
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let ordered = items.sorted { $0.date > $1.date }
    // Never evict live recovery receipts merely because 200 newer operations exist.
    let retained = ordered.enumerated().filter {
      $0.offset < 200 || !$0.element.pendingReceipts.isEmpty || !($0.element.unresolvedPaths ?? []).isEmpty
    }.map(\.element)
    try writer(encoder.encode(retained), url)
  }
}
