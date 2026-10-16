import AppKit
import Foundation
import MacCleanerCore

/// The user's Trash. Emptying it is permanent and invalidates every Restore receipt, so it is
/// never part of an OperationPlan: it is a separate, explicit action, and Finder does the work.
enum TrashBinService {
  struct Status: Equatable {
    let bytes: Int64
    let items: Int
    /// False when macOS privacy settings hide the Trash (Full Disk Access not granted).
    let isComplete: Bool
  }

  enum EmptyError: LocalizedError {
    case finderRefused(String)

    var errorDescription: String? {
      switch self {
      case .finderRefused(let message):
        return "Finder couldn't empty the Trash: \(message). Allow MacMint to control Finder in System Settings ▸ Privacy & Security ▸ Automation, or empty it from the Dock."
      }
    }
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

  /// Asks Finder to empty the Trash and returns the measured change in free space.
  @MainActor
  static func empty() throws -> Int64 {
    let before = availableBytes()
    var error: NSDictionary?
    let script = NSAppleScript(source: "tell application \"Finder\" to empty trash")
    script?.executeAndReturnError(&error)
    if let error {
      throw EmptyError.finderRefused(
        (error[NSAppleScript.errorMessage] as? String) ?? "permission was denied")
    }
    return max(0, availableBytes() - before)
  }

  private static func availableBytes() -> Int64 {
    let values = try? FileManager.default.homeDirectoryForCurrentUser.resourceValues(forKeys: [
      .volumeAvailableCapacityForImportantUsageKey
    ])
    return values?.volumeAvailableCapacityForImportantUsage ?? 0
  }
}
