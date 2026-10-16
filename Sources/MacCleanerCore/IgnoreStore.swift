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
    guard let data = try? Data(contentsOf: url),
      let paths = try? decoder.decode([String].self, from: data)
    else { return [] }
    return Set(paths.map { URL(fileURLWithPath: $0).standardizedFileURL.path })
  }

  public func add(_ itemURL: URL) throws -> Set<String> {
    var paths = load()
    paths.insert(itemURL.standardizedFileURL.path)
    try persist(paths)
    return paths
  }

  public func remove(path: String) throws -> Set<String> {
    var paths = load()
    paths.remove(URL(fileURLWithPath: path).standardizedFileURL.path)
    try persist(paths)
    return paths
  }

  public func clear() throws {
    try persist([])
  }

  private func persist(_ paths: Set<String>) throws {
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try encoder.encode(paths.sorted()).write(to: url, options: .atomic)
  }
}
