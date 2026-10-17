import Foundation
import MacCleanerCore
import XCTest
@testable import MacCleanerApp

/// Uses the real macOS Trash adapter, only for files created in a unique test directory.
/// Never enumerates or empties Trash, and restores only receipts created by this test.
final class NativeRecoveryTests: XCTestCase, @unchecked Sendable {
  private func home() throws -> URL {
    let url = FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent("MacMintIntegration-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  private func write(_ home: URL, _ path: String) throws -> URL {
    let url = home.appendingPathComponent(path)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(repeating: 42, count: 4096).write(to: url)
    return url
  }

  private func plan(_ urls: [URL]) -> OperationPlan {
    OperationPlanner.plan(title: "Native recovery fixture", items: urls.map {
      PlanItem(url: $0, displayName: $0.lastPathComponent, kind: .reviewedFile,
        expectedBytes: FileSystem.itemSize(at: $0), reason: "Test-created fixture", source: "Integration",
        identity: FileSystem.fileIdentity(at: $0), snapshot: FileSnapshot.current($0))
    })
  }

  private func cleanUp(_ receipts: [TrashReceipt], in home: URL) {
    let folder = home.appendingPathComponent("Recovered fixtures")
    for receipt in receipts {
      if RecoveryService().canRestore(receipt) { _ = try? RecoveryService().restore(receipt) }
      else if let path = receipt.trashPath, FileManager.default.fileExists(atPath: path) {
        // Identity is checked by restore; a conflict must not leave this test's own data behind.
        _ = try? RecoveryService().restore(receipt, into: folder.appendingPathComponent(UUID().uuidString))
      }
    }
    try? FileManager.default.removeItem(at: home)
  }

  func testRealTrashReceiptsSurviveHistoryCommitAndRestoreFilesAndFolders() async throws {
    let home = try home()
    var receipts: [TrashReceipt] = []
    defer { cleanUp(receipts, in: home) }
    let file = try write(home, "file.bin")
    let child = try write(home, "Folder/nested.bin")
    let folder = child.deletingLastPathComponent()
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    let original = try Data(contentsOf: file)
    let journals = home.appendingPathComponent("Operations")
    let operation = plan([file, folder])
    let report = await OperationExecutor(trashService: MacTrashService(), safetyPolicy: SafetyPolicy(homeDirectory: home),
      journalDirectory: journals).run(operation)
    receipts = report.receipts
    XCTAssertEqual(receipts.count, 2, report.outcomes.map { $0.message ?? "" }.joined(separator: "; "))
    XCTAssertNil(report.persistenceError)
    XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    XCTAssertFalse(FileManager.default.fileExists(atPath: child.path))
    XCTAssertEqual(OperationJournal.recoverInterrupted(in: journals).count, 1)
    let history = HistoryStore(url: home.appendingPathComponent("history.json"))
    try await history.append(report.historyEntry())
    try await history.append(report.historyEntry())
    try OperationJournal.acknowledge(operation.id, in: journals)
    XCTAssertTrue(OperationJournal.recoverInterrupted(in: journals).isEmpty)
    let committed = try await history.loadChecked()
    XCTAssertEqual(committed.count, 1)
    for receipt in receipts {
      XCTAssertNotNil(receipt.trashPath)
      XCTAssertNotNil(receipt.identity)
      XCTAssertTrue(RecoveryService().canRestore(receipt))
      try RecoveryService().restore(receipt)
      try await history.markRestored(entryID: operation.id, originalPaths: [receipt.originalPath])
    }
    XCTAssertEqual(try Data(contentsOf: file), original)
    XCTAssertTrue(FileManager.default.fileExists(atPath: child.path))
    let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
    XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    let restored = try await history.loadChecked()
    XCTAssertTrue(restored[0].pendingReceipts.isEmpty)
  }

  func testRealTrashNameCollisionsHaveDistinctVerifiedReceipts() async throws {
    let home = try home()
    var receipts: [TrashReceipt] = []
    defer { cleanUp(receipts, in: home) }
    let urls = [try write(home, "A/same.bin"), try write(home, "B/same.bin")]
    let report = await OperationExecutor(trashService: MacTrashService(), safetyPolicy: SafetyPolicy(homeDirectory: home)).run(plan(urls))
    receipts = report.receipts
    XCTAssertEqual(receipts.count, 2)
    XCTAssertEqual(Set(receipts.compactMap(\.trashPath)).count, 2)
    XCTAssertEqual(Set(receipts.compactMap(\.identity)).count, 2)
    for receipt in receipts { try RecoveryService().restore(receipt) }
    for url in urls { XCTAssertTrue(FileManager.default.fileExists(atPath: url.path)) }
  }

  func testRealRestoreRefusesOccupiedLocationAndSupportsAlternateFolder() async throws {
    let home = try home()
    var receipts: [TrashReceipt] = []
    defer { cleanUp(receipts, in: home) }
    let file = try write(home, "important.bin")
    let report = await OperationExecutor(trashService: MacTrashService(), safetyPolicy: SafetyPolicy(homeDirectory: home)).run(plan([file]))
    receipts = report.receipts
    let receipt = try XCTUnwrap(receipts.first)
    let replacement = Data("New content must survive".utf8)
    try replacement.write(to: file)
    XCTAssertThrowsError(try RecoveryService().restore(receipt)) {
      XCTAssertEqual($0 as? RestoreError, .destinationOccupied(file.path))
    }
    XCTAssertEqual(try Data(contentsOf: file), replacement)
    let destination = try RecoveryService().restore(receipt, into: home.appendingPathComponent("Elsewhere"))
    XCTAssertEqual(try Data(contentsOf: destination), Data(repeating: 42, count: 4096))
    XCTAssertEqual(try Data(contentsOf: file), replacement)
  }

  func testRealRestoreTreatsDanglingSymlinkAsAnOccupiedDestination() async throws {
    let home = try home()
    var receipts: [TrashReceipt] = []
    defer { cleanUp(receipts, in: home) }
    let file = try write(home, "link-conflict.bin")
    let report = await OperationExecutor(trashService: MacTrashService(), safetyPolicy: SafetyPolicy(homeDirectory: home)).run(plan([file]))
    receipts = report.receipts
    let receipt = try XCTUnwrap(receipts.first)
    let absent = home.appendingPathComponent("does-not-exist")
    try FileManager.default.createSymbolicLink(at: file, withDestinationURL: absent)
    XCTAssertThrowsError(try RecoveryService().restore(receipt)) {
      XCTAssertEqual($0 as? RestoreError, .destinationOccupied(file.path))
    }
    XCTAssertFalse(FileManager.default.fileExists(atPath: absent.path))
    _ = try RecoveryService().restore(receipt, into: home.appendingPathComponent("Elsewhere"))
    XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: file.path), absent.path)
  }
}
