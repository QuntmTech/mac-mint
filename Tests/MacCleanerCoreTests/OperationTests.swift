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
    XCTAssertEqual(OperationJournal.recoverInterrupted(in: journal).count, 1,
      "journal remains until history is committed")
    try OperationJournal.acknowledge(report.id, in: journal)
    XCTAssertTrue(OperationJournal.recoverInterrupted(in: journal).isEmpty)
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
    XCTAssertEqual(OperationJournal.recoverInterrupted(in: dir).count, 1)
    try OperationJournal.acknowledge(report.id, in: dir)
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

final class RunningOwnerTests: XCTestCase {
  func testItemsOwnedByARunningAppAreSkipped() async throws {
    let fm = FileManager.default
    let home = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? fm.removeItem(at: home) }
    let cache = home.appendingPathComponent("Library/Caches/BraveSoftware/Brave-Browser")
    try fm.createDirectory(at: cache, withIntermediateDirectories: true)
    try Data(repeating: 1, count: 4096).write(to: cache.appendingPathComponent("data_0"))

    let targets = await CleanupScanner(catalog: CleanupCatalog(homeDirectory: home)).scan()
    let brave = try XCTUnwrap(targets.first { $0.displayName == "Brave cache" })
    XCTAssertEqual(brave.category, .browserCaches)
    XCTAssertEqual(brave.ownerBundleID, "com.brave.Browser")
    XCTAssertFalse(
      targets.contains { $0.category == .userCaches && $0.url.path.contains("BraveSoftware") },
      "browser caches are not double-listed as generic app caches")

    let executor = OperationExecutor(
      trashService: MovingTrashService(trashDirectory: home.appendingPathComponent(".Trash")),
      safetyPolicy: SafetyPolicy(homeDirectory: home),
      isAppRunning: { $0 == "com.brave.Browser" })
    let report = await executor.run(OperationPlanner.plan(title: "t", items: [PlanItem.cleanup(brave)]))
    XCTAssertEqual(report.outcomes.first?.status, .skipped)
    XCTAssertTrue(fm.fileExists(atPath: cache.path))
  }

  func testGenericAppCachesCarryTheirOwnerSoRunningAppsAreSkipped() async throws {
    let fm = FileManager.default
    let home = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? fm.removeItem(at: home) }
    for name in ["com.tinyspeck.slackmacgap", "Spotify", "unowned-cache"] {
      let dir = home.appendingPathComponent("Library/Caches/\(name)")
      try fm.createDirectory(at: dir, withIntermediateDirectories: true)
      try Data(repeating: 1, count: 4096).write(to: dir.appendingPathComponent("blob"))
    }
    let targets = await CleanupScanner(catalog: CleanupCatalog(homeDirectory: home)).scan()
      .filter { $0.category == .userCaches }
    let owners = Dictionary(uniqueKeysWithValues: targets.map { ($0.url.lastPathComponent, $0.ownerBundleID) })
    XCTAssertEqual(owners["com.tinyspeck.slackmacgap"], "com.tinyspeck.slackmacgap")
    XCTAssertEqual(owners["Spotify"], "com.spotify.client")
    XCTAssertEqual(owners["unowned-cache"], .some(nil))

    let slack = try XCTUnwrap(targets.first { $0.url.lastPathComponent == "com.tinyspeck.slackmacgap" })
    let executor = OperationExecutor(
      trashService: MovingTrashService(trashDirectory: home.appendingPathComponent(".Trash")),
      safetyPolicy: SafetyPolicy(homeDirectory: home),
      isAppRunning: { $0.lowercased() == "com.tinyspeck.slackmacgap" })
    let report = await executor.run(OperationPlanner.plan(title: "t", items: [PlanItem.cleanup(slack)]))
    XCTAssertEqual(report.outcomes.first?.status, .skipped)
    XCTAssertTrue(fm.fileExists(atPath: slack.url.path))
  }
}

/// Replaces the planned item with a different file just before moving it, like a racing app.
private actor SwappingTrashService: TrashService {
  let inner: MovingTrashService
  init(trashDirectory: URL) { inner = MovingTrashService(trashDirectory: trashDirectory) }

  func trash(_ url: URL) async throws -> URL? {
    // Allocate the replacement before freeing the original so its inode can't be reused.
    let replacement = url.appendingPathExtension("replacement")
    try Data(repeating: 9, count: 4096).write(to: replacement)
    try FileManager.default.removeItem(at: url)
    try FileManager.default.moveItem(at: replacement, to: url)
    return try await inner.trash(url)
  }
}

final class MoveProofTests: XCTestCase {
  func testItemReplacedDuringTheMoveIsUncertainWithoutAReceipt() async throws {
    let fm = FileManager.default
    let home = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? fm.removeItem(at: home) }
    let file = home.appendingPathComponent("Downloads/big.dmg")
    try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(repeating: 1, count: 8192).write(to: file)
    let item = PlanItem(
      url: file, displayName: "big.dmg", kind: .reviewedFile, expectedBytes: 8192, reason: "Large", source: "Test",
      identity: FileSystem.fileIdentity(at: file))

    let executor = OperationExecutor(
      trashService: SwappingTrashService(trashDirectory: home.appendingPathComponent(".Trash")),
      safetyPolicy: SafetyPolicy(homeDirectory: home))
    let report = await executor.run(OperationPlanner.plan(title: "t", items: [item]))
    let outcome = try XCTUnwrap(report.outcomes.first)
    XCTAssertEqual(outcome.status, .uncertain)
    XCTAssertNil(outcome.receipt, "a receipt would claim the reviewed item is restorable from Trash")
  }
}
