import AppKit
import Foundation
import MacCleanerCore

/// Read-only measurement of the user's home Trash. Emptying is reviewed in Finder.
enum TrashBinService {
  struct Status: Equatable, Sendable {
    let bytes: Int64
    let items: Int
    /// False when the Trash cannot be fully inspected, including denied access.
    let isComplete: Bool
  }

  static var trashURL: URL {
    FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".Trash", isDirectory: true)
  }

  static func status() async -> Status {
    await Task.detached(priority: .utility) {
      let fm = FileManager.default
      guard let children = try? fm.contentsOfDirectory(at: trashURL, includingPropertiesForKeys: nil)
      else { return Status(bytes: 0, items: 0, isComplete: false) }
      let measured = FileSystem.measure(at: trashURL, fileManager: fm)
      return Status(bytes: measured.bytes, items: children.count, isComplete: measured.isComplete)
    }.value
  }

}
