import Foundation

public protocol TrashService: Sendable {
  /// Moves `url` to the Trash and returns where it ended up (the name can change on collision).
  func trash(_ url: URL) async throws -> URL?
}

public enum TrashServiceError: LocalizedError {
  case unsupported

  public var errorDescription: String? {
    switch self {
    case .unsupported: return "Moving items to Trash is only implemented by the macOS app layer."
    }
  }
}

public struct UnsupportedTrashService: TrashService {
  public init() {}
  public func trash(_ url: URL) async throws -> URL? { throw TrashServiceError.unsupported }
}

public actor CleanupEngine {
  private let trashService: any TrashService
  private let safetyPolicy: SafetyPolicy
  private let fileManager: FileManager

  public init(
    trashService: any TrashService,
    safetyPolicy: SafetyPolicy = SafetyPolicy(),
    fileManager: FileManager = .default
  ) {
    self.trashService = trashService
    self.safetyPolicy = safetyPolicy
    self.fileManager = fileManager
  }

  /// Re-validates every selected target against the current exclusions and safety policy
  /// immediately before moving it. Stops between items when the task is cancelled.
  public func execute(_ targets: [CleanupTarget], ignoredPaths: Set<String> = []) async
    -> CleanupResult
  {
    var moved: [URL] = []
    var failed: [OperationFailure] = []
    var receipts: [TrashReceipt] = []
    var attempted: Int64 = 0
    var bytesMoved: Int64 = 0
    var cancelled = false

    for target in targets where target.isSelected {
      if Task.isCancelled {
        cancelled = true
        break
      }
      attempted += target.size

      guard fileManager.fileExists(atPath: target.url.path) else {
        failed.append(
          OperationFailure(
            url: target.url, message: "Item no longer exists; it may already have been removed."))
        continue
      }

      if FileSystem.isIgnored(target.url, ignoredPaths: ignoredPaths) {
        failed.append(
          OperationFailure(url: target.url, message: "Item is on your exclusion list."))
        continue
      }
      if FileSystem.containsIgnoredDescendant(target.url, ignoredPaths: ignoredPaths) {
        failed.append(
          OperationFailure(
            url: target.url,
            message: "Folder contains an excluded item. Rescan to clean around it."))
        continue
      }

      let decision = safetyPolicy.cleanupTargetDecision(for: target)
      guard decision.allowed else {
        failed.append(OperationFailure(url: target.url, message: decision.reason))
        continue
      }
      guard target.risk != .restricted else {
        failed.append(
          OperationFailure(
            url: target.url, message: "Restricted items require a specific reviewed file target."))
        continue
      }

      // Re-read size immediately before the move. The scan can be stale by the time the user acts.
      let currentSize = FileSystem.itemSize(at: target.url, fileManager: fileManager)
      do {
        let trashURL = try await trashService.trash(target.url)
        moved.append(target.url)
        bytesMoved += currentSize
        receipts.append(
          TrashReceipt(
            originalPath: target.url.path, trashPath: trashURL?.path, bytes: currentSize))
      } catch {
        failed.append(OperationFailure(url: target.url, message: error.localizedDescription))
      }
    }

    return CleanupResult(
      movedToTrash: moved, failed: failed, bytesAttempted: attempted, bytesMoved: bytesMoved,
      receipts: receipts, wasCancelled: cancelled)
  }
}
