import Foundation

/// Write-ahead evidence for each restore. Kept independently from cleanup journals so an
/// interrupted restore never masquerades as a cleanup operation or loses its destination.
struct RestoreRecord: Codable, Sendable {
  let id: UUID
  let entryID: UUID
  let receipt: TrashReceipt
  let destination: String
  let identity: String
}

public actor RestoreCoordinator {
  private let directory: URL
  private let history: HistoryStore
  private let writer: @Sendable (Data, URL) throws -> Void

  public init(journalDirectory: URL, history: HistoryStore,
    writer: (@Sendable (Data, URL) throws -> Void)? = nil) {
    directory = journalDirectory
    self.history = history
    self.writer = writer ?? { try FileSystem.writeDurably($0, to: $1) }
  }

  @discardableResult
  public func restore(_ receipt: TrashReceipt, entryID: UUID, into folder: URL? = nil) async throws -> URL {
    // A missing/corrupt History must be resolved before moving its only recovery evidence.
    let entries = try await history.loadChecked()
    guard let entry = entries.first(where: { $0.id == entryID }),
      entry.pendingReceipts.contains(receipt) else {
      throw RestoreError.failed("This receipt is no longer pending in History. Refresh History before restoring it.")
    }
    guard let path = receipt.trashPath, RecoveryService.isTrashLocation(path),
      let identity = FileSystem.fileIdentity(at: URL(fileURLWithPath: path)) else {
      throw RestoreError.missingFromTrash(URL(fileURLWithPath: receipt.originalPath).lastPathComponent)
    }
    if let expected = receipt.identity, expected != identity {
      throw RestoreError.notTheSameItem(URL(fileURLWithPath: receipt.originalPath).lastPathComponent)
    }
    let destination = RecoveryService.destination(for: receipt, into: folder)
    try RecoveryService.validateDestination(destination, source: URL(fileURLWithPath: path))
    let record = RestoreRecord(id: UUID(), entryID: entryID, receipt: receipt,
      destination: destination.path, identity: identity)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let journal = directory.appendingPathComponent(record.id.uuidString + ".json")
    try writer(JSONEncoder().encode(record), journal)
    // Bind old receipts to the identity actually observed before writing the intent.
    let bound = TrashReceipt(originalPath: receipt.originalPath, trashPath: path,
      bytes: receipt.bytes, identity: identity)
    let restored = try RecoveryService().restore(bound, to: destination)
    do {
      try await history.markRestored(entryID: entryID, locations: [receipt.originalPath: restored.path])
    } catch {
      throw RestoreError.failed("Restored to \(restored.path), but History could not be updated. The restore record is retained and will be reconciled when MacMint restarts. \(error.localizedDescription)")
    }
    // Failure to remove an already committed intent is harmless; recovery is idempotent.
    try? FileManager.default.removeItem(at: journal)
    return restored
  }

  /// Never infer success merely from a missing Trash item. Prove the recorded identity at
  /// the recorded destination, commit it to History, and only then acknowledge the intent.
  public static func recover(in directory: URL, history: HistoryStore) async -> [ScanIssue] {
    let fm = FileManager.default
    guard fm.fileExists(atPath: directory.path) else { return [] }
    let files: [URL]
    do { files = try fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) }
    catch { return [ScanIssue(area: "Restore", path: directory.path, message: "Restore records could not be inspected. They have been preserved.")] }
    var warnings: [ScanIssue] = []
    for file in files where file.pathExtension == "json" {
      do {
        let record = try JSONDecoder().decode(RestoreRecord.self, from: Data(contentsOf: file))
        let entries = try await history.loadChecked()
        guard let entry = entries.first(where: { $0.id == record.entryID }),
          entry.receipts?.contains(record.receipt) == true else {
          throw RestoreError.failed("The matching History receipt could not be found.")
        }
        if entry.restoredLocations?[record.receipt.originalPath] == record.destination {
          try fm.removeItem(at: file)
          continue
        }
        guard let source = record.receipt.trashPath else { throw RestoreError.noTrashLocation }
        let sourceURL = URL(fileURLWithPath: source)
        let destination = URL(fileURLWithPath: record.destination)
        let sourceExists = try FileSystem.entryExists(at: sourceURL)
        if !sourceExists, FileSystem.fileIdentity(at: destination) == record.identity {
          try await history.markRestored(entryID: record.entryID,
            locations: [record.receipt.originalPath: record.destination])
          try fm.removeItem(at: file)
        } else if sourceExists, FileSystem.fileIdentity(at: sourceURL) == record.identity,
          FileSystem.fileIdentity(at: destination) != record.identity {
          // No move occurred. Keep the receipt pending, including ordinary restore conflicts.
          try fm.removeItem(at: file)
        } else {
          throw RestoreError.failed("The restore destination could not be verified. Inspect both the recorded destination and Trash.")
        }
      } catch {
        warnings.append(ScanIssue(area: "Restore", path: file.path,
          message: "A restore record needs attention and has been preserved: \(error.localizedDescription)"))
      }
    }
    return warnings
  }
}
