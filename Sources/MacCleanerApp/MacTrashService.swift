import Foundation
import MacCleanerCore

struct MacTrashService: TrashService, Sendable {
  func trash(_ url: URL) async throws -> URL? {
    var resulting: NSURL?
    try FileManager.default.trashItem(at: url, resultingItemURL: &resulting)
    return resulting as URL?
  }
}
