import Foundation
import XCTest
@testable import MacCleanerCore

final class RestoreDurabilityTests: XCTestCase {
  private let fm = FileManager.default

  private func fixture() throws -> (URL, TrashReceipt, HistoryEntry) {
    let root = fm.temporaryDirectory.appendingPathComponent("macmint-restore-" + UUID().uuidString)
    let source = root.appendingPathComponent(".Trash/item.txt")
    try fm.createDirectory(at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("original".utf8).write(to: source)
    let receipt = TrashReceipt(originalPath: root.appendingPathComponent("Documents/item.txt").path,
      trashPath: source.path, bytes: 8, identity: FileSystem.fileIdentity(at: source))
    return (root, receipt, HistoryEntry(action: "Cleanup", paths: [receipt.originalPath], bytes: 8,
      notes: "Test", receipts: [receipt]))
  }

  func testUnwritableRestoreJournalPreventsMovement() async throws {
    let (root, receipt, entry) = try fixture()
    defer { try? fm.removeItem(at: root) }
    let history = HistoryStore(url: root.appendingPathComponent("history.json"))
    try await history.append(entry)
    let recovery = RestoreCoordinator(journalDirectory: root.appendingPathComponent("Restores"), history: history,
      writer: { _, _ in throw CocoaError(.fileWriteOutOfSpace) })
    do { try await recovery.restore(receipt, entryID: entry.id); XCTFail("Must fail before moving") } catch {}
    XCTAssertTrue(fm.fileExists(atPath: receipt.trashPath!))
    XCTAssertFalse(fm.fileExists(atPath: receipt.originalPath))
  }

  func testHistoryFailureAfterMoveRecoversAlternateDestinationIdempotently() async throws {
    let (root, receipt, entry) = try fixture()
    defer { try? fm.removeItem(at: root) }
    let historyURL = root.appendingPathComponent("history.json")
    let working = HistoryStore(url: historyURL)
    try await working.append(entry)
    let failing = HistoryStore(url: historyURL, writer: { _, _ in throw CocoaError(.fileWriteOutOfSpace) })
    let directory = root.appendingPathComponent("Restores")
    let alternate = root.appendingPathComponent("Elsewhere")
    let destination = alternate.appendingPathComponent("item.txt")
    let recovery = RestoreCoordinator(journalDirectory: directory, history: failing)
    do { try await recovery.restore(receipt, entryID: entry.id, into: alternate); XCTFail("Must surface failed History commit") }
    catch { XCTAssertTrue(error.localizedDescription.contains("restore record is retained")) }
    XCTAssertEqual(try Data(contentsOf: destination), Data("original".utf8))
    XCTAssertFalse(fm.fileExists(atPath: receipt.trashPath!))
    XCTAssertEqual(try fm.contentsOfDirectory(atPath: directory.path).count, 1)
    let firstWarnings = await RestoreCoordinator.recover(in: directory, history: working)
    XCTAssertTrue(firstWarnings.isEmpty)
    let secondWarnings = await RestoreCoordinator.recover(in: directory, history: working)
    XCTAssertTrue(secondWarnings.isEmpty)
    let loaded = try await working.loadChecked()
    XCTAssertEqual(loaded.first?.restoredLocations?[receipt.originalPath], destination.path)
    XCTAssertEqual(loaded.first?.pendingReceipts.count, 0)
    // Replaying a cleanup journal must preserve the restore location.
    try await working.append(entry)
    let replayed = try await working.loadChecked()
    XCTAssertEqual(replayed.first?.restoredLocations?[receipt.originalPath], destination.path)
    XCTAssertTrue(try fm.contentsOfDirectory(atPath: directory.path).isEmpty)
  }

  func testInterruptedRestoreRequiresIdentityProofAndPreservesCorruptEvidence() async throws {
    let (root, receipt, entry) = try fixture()
    defer { try? fm.removeItem(at: root) }
    let history = HistoryStore(url: root.appendingPathComponent("history.json"))
    try await history.append(entry)
    let directory = root.appendingPathComponent("Restores")
    try fm.createDirectory(at: directory, withIntermediateDirectories: true)
    let intent = RestoreRecord(id: UUID(), entryID: entry.id, receipt: receipt,
      destination: receipt.originalPath, identity: receipt.identity!)
    let journal = directory.appendingPathComponent("intent.json")
    try JSONEncoder().encode(intent).write(to: journal)
    try Data("corrupt".utf8).write(to: directory.appendingPathComponent("corrupt.json"))
    // Missing source alone cannot prove a restore. No actual destination exists.
    try fm.removeItem(atPath: receipt.trashPath!)
    let warnings = await RestoreCoordinator.recover(in: directory, history: history)
    XCTAssertEqual(warnings.count, 2)
    XCTAssertTrue(fm.fileExists(atPath: journal.path))
    let entries = try await history.loadChecked()
    XCTAssertEqual(entries.first?.pendingReceipts.count, 1)
  }

  func testConflictPreservesBothFilesAndLeavesReceiptPending() async throws {
    let (root, receipt, entry) = try fixture()
    defer { try? fm.removeItem(at: root) }
    let original = URL(fileURLWithPath: receipt.originalPath)
    try fm.createDirectory(at: original.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("replacement".utf8).write(to: original)
    let history = HistoryStore(url: root.appendingPathComponent("history.json"))
    try await history.append(entry)
    let directory = root.appendingPathComponent("Restores")
    let recovery = RestoreCoordinator(journalDirectory: directory, history: history)
    do { try await recovery.restore(receipt, entryID: entry.id); XCTFail("Must not overwrite") }
    catch let error as RestoreError { XCTAssertEqual(error, .destinationOccupied(original.path)) }
    XCTAssertEqual(try Data(contentsOf: original), Data("replacement".utf8))
    XCTAssertTrue(fm.fileExists(atPath: receipt.trashPath!))
    let warnings = await RestoreCoordinator.recover(in: directory, history: history)
    XCTAssertTrue(warnings.isEmpty)
    let entries = try await history.loadChecked()
    XCTAssertEqual(entries.first?.pendingReceipts.count, 1)
  }

  func testSymlinkInsideTrashCannotRedirectRestoreToAnUnrelatedFile() throws {
    let (root, _, _) = try fixture()
    defer { try? fm.removeItem(at: root) }
    let other = root.appendingPathComponent("outside")
    try fm.createDirectory(at: other, withIntermediateDirectories: true)
    try Data("unrelated".utf8).write(to: other.appendingPathComponent("file"))
    let link = root.appendingPathComponent(".Trash/alias")
    try fm.createSymbolicLink(at: link, withDestinationURL: other)
    let receipt = TrashReceipt(originalPath: root.appendingPathComponent("Documents/file").path,
      trashPath: link.appendingPathComponent("file").path, bytes: 9)
    XCTAssertFalse(RecoveryService().canRestore(receipt))
    XCTAssertThrowsError(try RecoveryService().restore(receipt))
    XCTAssertTrue(fm.fileExists(atPath: other.appendingPathComponent("file").path))
  }

  func testUncertainMoveEvidenceSurvivesHistoryRetentionWithoutAReceipt() async throws {
    let (root, receipt, _) = try fixture()
    defer { try? fm.removeItem(at: root) }
    let url = root.appendingPathComponent("history.json")
    let item = PlanItem(url: URL(fileURLWithPath: receipt.originalPath), displayName: "uncertain",
      kind: .reviewedFile, expectedBytes: 8, reason: "Test", source: "Test")
    let report = OperationReport(id: UUID(), title: "Interrupted", startedAt: .distantPast,
      outcomes: [ItemOutcome(item: item, status: .uncertain)], wasInterrupted: true)
    let uncertain = report.historyEntry()
    let newer = (0..<201).map { HistoryEntry(date: Date(timeIntervalSince1970: Double($0)),
      action: "Fixture", paths: [], bytes: 0, notes: "Complete") }
    try JSONEncoder().encode(newer + [uncertain]).write(to: url)
    let history = HistoryStore(url: url)
    try await history.append(HistoryEntry(action: "Newest", paths: [], bytes: 0, notes: "Complete"))
    let entries = try await history.loadChecked()
    let saved = try XCTUnwrap(entries.first { $0.id == uncertain.id })
    XCTAssertEqual(saved.unresolvedPaths, [receipt.originalPath])
    XCTAssertTrue(saved.pendingReceipts.isEmpty)
    XCTAssertEqual(entries.count, 201)
  }
}
