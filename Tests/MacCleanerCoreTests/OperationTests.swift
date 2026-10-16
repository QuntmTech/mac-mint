import XCTest

@testable import MacCleanerCore

final class OperationTests: XCTestCase {
  private let fm = FileManager.default

  // MARK: Planner

  func testPlannerCollapsesChildrenOfSelectedFoldersAndRejectsExclusions() {
    let root = URL(fileURLWithPath: "/Users/t/Library/Caches")
    let parent = item(root.appendingPathComponent("com.a"))
    let child = item(root.appendingPathComponent("com.a/sub"))
    let other = item(root.appendingPathComponent("com.b"))
    let excluded = item(root.appendingPathComponent("com.c"))

    let plan = OperationPlanner.plan(
      title: "t", items: [child, other, parent, excluded],
      ignoredPaths: [root.appendingPathComponent("com.c").path])

    XCTAssertEqual(plan.items.map(\.id), [other.id, parent.id], "keeps caller order")
    XCTAssertEqual(plan.covered.map(\.id), [child.id])
    XCTAssertEqual(plan.excluded.map(\.url), [excluded.url])
  }

  func testPlannerRejectsFolderContainingExcludedItem() {
    let folder = URL(fileURLWithPath: "/Users/t/Library/Caches/com.a")
    let plan = OperationPlanner.plan(
      title: "t", items: [item(folder)], ignoredPaths: [folder.path + "/keep"])
    XCTAssertTrue(plan.items.isEmpty)
    XCTAssertEqual(plan.excluded.count, 1)
  }

  // MARK: Executor

  func testExecutorMovesItemsAndRecordsReceipts() async throws {
    let home = makeTempDirectory()
    defer { try? fm.removeItem(at: home) }
    let cache = try makeFile(home, "Library/Caches/com.vendor.app/c.bin").deletingLastPathComponent()
    let journal = home.appendingPathComponent("journal")

    let plan = OperationPlanner.plan(title: "Cleanup", items: [cleanupItem(cache)])
    let report = await executor(home, journal: journal).run(plan)

    XCTAssertEqual(report.moved.count, 1)
    XCTAssertFalse(fm.fileExists(atPath: cache.path))
    let trashPath = try XCTUnwrap(report.receipts.first?.trashPath)
    XCTAssertTrue(fm.fileExists(atPath: trashPath))
    XCTAssertGreaterThan(report.bytesMoved, 0)
    XCTAssertTrue(
      (try? fm.contentsOfDirectory(atPath: journal.path))?.isEmpty ?? true,
      "journal is removed after a completed run")
  }

  func testDependentItemsAreSkippedWhenTheirAppIsNotMoved() async throws {
    let home = makeTempDirectory()
    defer { try? fm.removeItem(at: home) }
    // An app outside any Applications folder fails the app-bundle rule.
    let app = try makeFile(home, "Elsewhere/Widget.app/Contents/Info.plist")
      .deletingLastPathComponent().deletingLastPathComponent()
    let data = try makeFile(home, "Library/Application Support/Widget/data.bin")
      .deletingLastPathComponent()

    let appItem = PlanItem(
      url: app, displayName: "Widget", kind: .appBundle, expectedBytes: 1, reason: "",
      source: "Uninstall Widget")
    let dataItem = PlanItem(
      url: data, displayName: "Widget data", kind: .appLeftover, expectedBytes: 1, reason: "",
      source: "Uninstall Widget", dependsOn: appItem.id)
    let report = await executor(home).run(
      OperationPlanner.plan(title: "Uninstall", items: [appItem, dataItem]))

    XCTAssertEqual(report.outcomes.map(\.status), [.skipped, .skipped])
    XCTAssertTrue(fm.fileExists(atPath: data.path))
  }

  func testReplacedItemIsNotMoved() async throws {
    let home = makeTempDirectory()
    defer { try? fm.removeItem(at: home) }
    let file = try makeFile(home, "Library/Caches/com.vendor.app")
    let planned = cleanupItem(file)
    try fm.removeItem(at: file)
    try makeFile(home, "Library/Caches/com.vendor.app", Data(repeating: 1, count: 10))

    let report = await executor(home).run(OperationPlanner.plan(title: "t", items: [planned]))
    XCTAssertEqual(report.outcomes.first?.status, .skipped)
    XCTAssertTrue(fm.fileExists(atPath: file.path))
  }

  func testCancelledRunLeavesItemsUntouchedAndReported() async throws {
    let home = makeTempDirectory()
    defer { try? fm.removeItem(at: home) }
    let cache = try makeFile(home, "Library/Caches/com.vendor.app/c.bin").deletingLastPathComponent()
    let plan = OperationPlanner.plan(title: "t", items: [cleanupItem(cache)])
    let exec = executor(home)

    let report = await Task { () async -> OperationReport in
      withUnsafeCurrentTask { $0?.cancel() }
      return await exec.run(plan)
    }.value

    XCTAssertTrue(report.wasCancelled)
    XCTAssertEqual(report.outcomes.map(\.status), [.notAttempted])
    XCTAssertTrue(fm.fileExists(atPath: cache.path))
  }

  func testInterruptedJournalIsRecoveredOnce() throws {
    let dir = makeTempDirectory()
    defer { try? fm.removeItem(at: dir) }
    let planned = item(URL(fileURLWithPath: "/Users/t/Library/Caches/x"))
    let report = OperationReport(
      id: UUID(), title: "Cleanup", startedAt: Date(),
      outcomes: [
        ItemOutcome(
          item: planned, status: .moved,
          receipt: TrashReceipt(originalPath: planned.url.path, trashPath: "/t/x", bytes: 5))
      ])
    try OperationJournal.encoder.encode(report).write(
      to: dir.appendingPathComponent("operation-\(report.id.uuidString).json"))

    let recovered = OperationJournal.recoverInterrupted(in: dir)
    XCTAssertEqual(recovered.count, 1)
    XCTAssertTrue(recovered[0].wasInterrupted)
    XCTAssertEqual(recovered[0].historyEntry().receipts?.count, 1)
    XCTAssertTrue(OperationJournal.recoverInterrupted(in: dir).isEmpty)
  }

  // MARK: Recovery

  func testRestorePutsItemBackAndNeverOverwrites() throws {
    let home = makeTempDirectory()
    defer { try? fm.removeItem(at: home) }
    let original = try makeFile(home, "Docs/report.pdf")
    let trashed = home.appendingPathComponent(".Trash/report.pdf")
    try fm.createDirectory(at: trashed.deletingLastPathComponent(), withIntermediateDirectories: true)
    try fm.moveItem(at: original, to: trashed)
    let receipt = TrashReceipt(originalPath: original.path, trashPath: trashed.path, bytes: 1)

    // Something new now occupies the original path.
    try makeFile(home, "Docs/report.pdf", Data("new".utf8))
    XCTAssertThrowsError(try RecoveryService().restore(receipt)) { error in
      XCTAssertEqual(error as? RestoreError, .destinationOccupied(original.path))
    }
    XCTAssertEqual(try Data(contentsOf: original), Data("new".utf8))

    let elsewhere = home.appendingPathComponent("Restored")
    let restored = try RecoveryService().restore(receipt, into: elsewhere)
    XCTAssertEqual(restored.path, elsewhere.appendingPathComponent("report.pdf").path)
    XCTAssertTrue(fm.fileExists(atPath: restored.path))
    XCTAssertFalse(fm.fileExists(atPath: trashed.path))

    XCTAssertThrowsError(try RecoveryService().restore(receipt)) { error in
      XCTAssertEqual(error as? RestoreError, .missingFromTrash("report.pdf"))
    }
  }

  func testRestoreRecreatesMissingParentFolders() throws {
    let home = makeTempDirectory()
    defer { try? fm.removeItem(at: home) }
    let trashed = try makeFile(home, ".Trash/com.vendor.app")
    let original = home.appendingPathComponent("Library/Caches/com.vendor.app")
    let receipt = TrashReceipt(originalPath: original.path, trashPath: trashed.path, bytes: 1)
    XCTAssertTrue(RecoveryService().canRestore(receipt))
    try RecoveryService().restore(receipt)
    XCTAssertTrue(fm.fileExists(atPath: original.path))
  }

  func testRestoreWithoutReceiptLocationExplainsWhy() {
    let receipt = TrashReceipt(originalPath: "/x", trashPath: nil, bytes: 0)
    XCTAssertFalse(RecoveryService().canRestore(receipt))
    XCTAssertThrowsError(try RecoveryService().restore(receipt)) { error in
      XCTAssertEqual(error as? RestoreError, .noTrashLocation)
    }
  }

  // MARK: History

  func testHistoryMarksRestoredItemsAndReadsLegacyEntries() async throws {
    let dir = makeTempDirectory()
    defer { try? fm.removeItem(at: dir) }
    let url = dir.appendingPathComponent("history.json")
    // Pre-receipt history format must still load.
    let legacy = """
      [{"id":"\(UUID().uuidString)","date":700000000,"action":"Cleanup","paths":["/a"],"bytes":5,"notes":"ok"}]
      """
    try Data(legacy.utf8).write(to: url)
    let store = HistoryStore(url: url)
    let legacyCount = await store.load().count
    XCTAssertEqual(legacyCount, 1)

    let receipts = [
      TrashReceipt(originalPath: "/x", trashPath: "/t/x", bytes: 1),
      TrashReceipt(originalPath: "/y", trashPath: "/t/y", bytes: 2),
    ]
    let entry = HistoryEntry(
      action: "Cleanup", paths: ["/x", "/y"], bytes: 3, notes: "", receipts: receipts)
    try await store.append(entry)
    try await store.markRestored(entryID: entry.id, originalPaths: ["/x"])

    let loaded = await store.load()
    let saved = try XCTUnwrap(loaded.first { $0.id == entry.id })
    XCTAssertEqual(saved.pendingReceipts.map(\.originalPath), ["/y"])
    XCTAssertTrue(saved.isRestored(receipts[0]))
  }

  // MARK: Helpers

  private func item(_ url: URL) -> PlanItem {
    PlanItem(
      url: url, displayName: url.lastPathComponent,
      kind: .cleanupTarget(category: .userCaches, risk: .safe), expectedBytes: 1, reason: "",
      source: "Cleaner")
  }

  private func cleanupItem(_ url: URL) -> PlanItem {
    PlanItem(
      url: url, displayName: url.lastPathComponent,
      kind: .cleanupTarget(category: .userCaches, risk: .safe), expectedBytes: 1, reason: "",
      source: "Cleaner", identity: FileSystem.fileIdentity(at: url))
  }

  private func executor(_ home: URL, journal: URL? = nil) -> OperationExecutor {
    OperationExecutor(
      trashService: MovingTrashService(trashDirectory: home.appendingPathComponent(".Trash")),
      safetyPolicy: SafetyPolicy(homeDirectory: home), journalDirectory: journal)
  }

  @discardableResult
  private func makeFile(_ root: URL, _ relative: String, _ data: Data = Data(repeating: 9, count: 2048))
    throws -> URL
  {
    let url = root.appendingPathComponent(relative)
    try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try data.write(to: url)
    return url
  }

  private func makeTempDirectory() -> URL {
    let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try! fm.createDirectory(at: root, withIntermediateDirectories: true)
    return root
  }
}
