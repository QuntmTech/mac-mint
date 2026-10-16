import Foundation
import MacCleanerCore

struct MacTrashService: TrashService, Sendable {
  func trash(_ url: URL) async throws {
    try FileManager.default.trashItem(at: url, resultingItemURL: nil)
  }
}
