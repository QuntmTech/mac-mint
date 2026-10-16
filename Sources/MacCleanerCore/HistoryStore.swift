import Foundation

public struct HistoryEntry: Identifiable, Codable, Hashable, Sendable {
  public let id: UUID
  public let date: Date
  public let action: String
  public let paths: [String]
  public let bytes: Int64
  public let notes: String

  public init(
    id: UUID = UUID(), date: Date = Date(), action: String, paths: [String], bytes: Int64,
    notes: String
  ) {
    self.id = id
    self.date = date
    self.action = action
    self.paths = paths
    self.bytes = bytes
    self.notes = notes
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
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try encoder.encode(Array(items.prefix(200))).write(to: url, options: .atomic)
  }
}
