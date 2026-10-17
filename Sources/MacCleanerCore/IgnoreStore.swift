import Foundation

public actor IgnoreStore {
  private let url: URL
  private let encoder: JSONEncoder
  private let decoder = JSONDecoder()

  public init(url: URL) {
    self.url = url
    self.encoder = JSONEncoder()
    self.encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
  }

  public func load() -> Set<String> {
    (try? loadChecked()) ?? []
  }

  public func loadChecked() throws -> Set<String> {
    let data: Data
    do { data = try Data(contentsOf: url) }
    catch let error as CocoaError where error.code == .fileReadNoSuchFile { return [] }
    let paths = try decoder.decode([String].self, from: data)
    return Set(paths.map { URL(fileURLWithPath: $0).standardizedFileURL.path })
  }

  public func add(_ itemURL: URL) throws -> Set<String> {
    var paths = try loadChecked()
    paths.insert(itemURL.standardizedFileURL.path)
    try persist(paths)
    return paths
  }

  public func remove(path: String) throws -> Set<String> {
    var paths = try loadChecked()
    paths.remove(URL(fileURLWithPath: path).standardizedFileURL.path)
    try persist(paths)
    return paths
  }

  public func clear() throws {
    do { _ = try loadChecked() }
    catch {
      // Explicitly resetting unreadable exclusions preserves their bytes for diagnosis.
      let backup = url.appendingPathExtension("preserved-" + UUID().uuidString)
      try FileManager.default.copyItem(at: url, to: backup)
    }
    try persist([])
  }

  private func persist(_ paths: Set<String>) throws {
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try FileSystem.writeDurably(encoder.encode(paths.sorted()), to: url)
  }
}
