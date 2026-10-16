import Foundation

enum AppPaths {
  /// ~/Library/Application Support/MacMint. Copies history/exclusions from the pre-rebrand
  /// "MacCleanerHybridBase" folder the first time it runs.
  static let supportDirectory: URL = {
    let fm = FileManager.default
    let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
    let current = base.appendingPathComponent("MacMint", isDirectory: true)
    let legacy = base.appendingPathComponent("MacCleanerHybridBase", isDirectory: true)
    try? fm.createDirectory(at: current, withIntermediateDirectories: true)
    for name in ["history.json", "ignored-paths.json"] {
      let target = current.appendingPathComponent(name)
      let source = legacy.appendingPathComponent(name)
      if !fm.fileExists(atPath: target.path), fm.fileExists(atPath: source.path) {
        try? fm.copyItem(at: source, to: target)
      }
    }
    return current
  }()

  /// In-progress operation journals; anything left here after a crash is recovered at launch.
  static var journalDirectory: URL { supportDirectory.appendingPathComponent("Operations", isDirectory: true) }
}
