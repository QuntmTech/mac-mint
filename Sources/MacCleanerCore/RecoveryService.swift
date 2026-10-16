import Foundation

public enum RestoreError: LocalizedError, Equatable, Sendable {
  case noTrashLocation
  case missingFromTrash(String)
  case destinationOccupied(String)
  case notTheSameItem(String)
  case failed(String)

  public var errorDescription: String? {
    switch self {
    case .noTrashLocation:
      return "This item was moved before MacMint recorded Trash locations. Restore it from the Trash in Finder."
    case .missingFromTrash(let name):
      return "“\(name)” is no longer in the Trash. It may have been emptied or moved."
    case .destinationOccupied(let path):
      return "Something already exists at \(path). Choose another location to restore to."
    case .notTheSameItem(let name):
      return "The “\(name)” in the Trash isn't the item MacMint moved, so it was left alone."
    case .failed(let message):
      return message
    }
  }
}

/// Moves items MacMint put in the Trash back to where they came from. Never overwrites.
public struct RecoveryService: Sendable {
  public init() {}

  public func canRestore(_ receipt: TrashReceipt, fileManager: FileManager = .default) -> Bool {
    guard let trashPath = receipt.trashPath, Self.isTrashLocation(trashPath) else { return false }
    return fileManager.fileExists(atPath: trashPath)
      && !fileManager.fileExists(atPath: receipt.originalPath)
      && Self.isSameItem(receipt, at: URL(fileURLWithPath: trashPath))
  }

  /// Only items inside a Trash folder are ever moved back.
  static func isTrashLocation(_ path: String) -> Bool {
    path.components(separatedBy: "/").contains { $0 == ".Trash" || $0 == ".Trashes" }
  }

  static func isSameItem(_ receipt: TrashReceipt, at url: URL) -> Bool {
    guard let expected = receipt.identity else { return true }
    return FileSystem.fileIdentity(at: url) == expected
  }

  /// Restores to the original path, or into `folder` (keeping the original name) when given.
  @discardableResult
  public func restore(
    _ receipt: TrashReceipt, into folder: URL? = nil, fileManager: FileManager = .default
  ) throws -> URL {
    guard let trashPath = receipt.trashPath, Self.isTrashLocation(trashPath) else {
      throw RestoreError.noTrashLocation
    }
    let original = URL(fileURLWithPath: receipt.originalPath)
    guard fileManager.fileExists(atPath: trashPath) else {
      throw RestoreError.missingFromTrash(original.lastPathComponent)
    }
    guard Self.isSameItem(receipt, at: URL(fileURLWithPath: trashPath)) else {
      throw RestoreError.notTheSameItem(original.lastPathComponent)
    }
    let destination = folder?.appendingPathComponent(original.lastPathComponent) ?? original
    // lstat-based check so a dangling symlink at the destination also counts as occupied.
    if fileManager.fileExists(atPath: destination.path)
      || FileSystem.fileIdentity(at: destination) != nil
    {
      throw RestoreError.destinationOccupied(destination.path)
    }
    do {
      try fileManager.createDirectory(
        at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
      try fileManager.moveItem(at: URL(fileURLWithPath: trashPath), to: destination)
    } catch {
      throw RestoreError.failed(error.localizedDescription)
    }
    return destination
  }
}
