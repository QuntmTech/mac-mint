import XCTest

@testable import MacCleanerCore

/// Regression tests for the safety review of the removal pipeline.
final class SafetyHardeningTests: XCTestCase {
  private let fm = FileManager.default

  // MARK: Duplicates keep a copy across screens and through edits

  func testDuplicateIsRefusedWhenItsKeeperIsAlsoQueued() async throws {
    let home = makeTempDirectory()
    defer { try? fm.removeItem(at: home) }
    let content = Data(repeating: 4, count: 8192)
    let a = try write(home, "Photos/a.jpg", content)
    _ = try write(home, "Photos/b.jpg", content)
    let groupGroups = await DuplicateFinder().find(in: [home.appendingPathComponent("Photos")], minimumSize: 1)
    let group = try XCTUnwrap(groupGroups.first)
    let keeper = try XCTUnwrap(group.files.first { $0.url.lastPathComponent == "a.jpg" })
    let copy = try XCTUnwrap(group.files.first { $0.url.lastPathComponent == "b.jpg" })

    // Keeper selected directly in Large Files.
    let direct = OperationPlanner.plan(
      title: "t",
      items: [PlanItem.duplicate(copy, keeper: keeper), PlanItem.largeFile(keeper)])
    XCTAssertEqual(direct.items.map(\.url.lastPathComponent), ["a.jpg"])
    XCTAssertEqual(direct.excluded.map(\.url.lastPathComponent), ["b.jpg"])

    // Keeper inside a folder selected in Storage.
    let folder = PlanItem(
      url: a.deletingLastPathComponent(), displayName: "Photos", kind: .reviewedFile,
      expectedBytes: 1, reason: "", source: "Storage")
    let viaFolder = OperationPlanner.plan(
      title: "t", items: [PlanItem.duplicate(copy, keeper: keeper), folder])
    XCTAssertFalse(viaFolder.items.contains { $0.kind == .duplicateCopy })
  }

  func testDuplicateEditedInPlaceOrLostKeeperIsSkipped() async throws {
    let home = makeTempDirectory()
    defer { try? fm.removeItem(at: home) }
    let content = Data(repeating: 4, count: 8192)
    let a = try write(home, "Docs/a.bin", content)
    let b = try write(home, "Docs/b.bin", content)
    let groupGroups = await DuplicateFinder().find(in: [home.appendingPathComponent("Docs")], minimumSize: 1)
    let group = try XCTUnwrap(groupGroups.first)
    let keeper = try XCTUnwrap(group.files.first { $0.url == a || $0.url.lastPathComponent == "a.bin" })
    let copy = try XCTUnwrap(group.files.first { $0.url.lastPathComponent == "b.bin" })
    let plan = OperationPlanner.plan(title: "t", items: [PlanItem.duplicate(copy, keeper: keeper)])

    // Edit b in place (same inode, new content and mtime).
    let handle = try FileHandle(forWritingTo: b)
    try handle.write(contentsOf: Data(repeating: 9, count: 100))
    try handle.close()
    try fm.setAttributes([.modificationDate: Date().addingTimeInterval(60)], ofItemAtPath: b.path)
    var report = await executor(home).run(plan)
    XCTAssertEqual(report.outcomes.first?.status, .skipped)
    XCTAssertTrue(fm.fileExists(atPath: b.path))

    // Restore b's state, then remove the keeper: b must stay.
    try content.write(to: b)
    let freshGroups = await DuplicateFinder().find(in: [home.appendingPathComponent("Docs")], minimumSize: 1)
    let fresh = try XCTUnwrap(freshGroups.first)
    let freshKeeper = try XCTUnwrap(fresh.files.first { $0.url.lastPathComponent == "a.bin" })
    let freshCopy = try XCTUnwrap(fresh.files.first { $0.url.lastPathComponent == "b.bin" })
    let plan2 = OperationPlanner.plan(title: "t", items: [PlanItem.duplicate(freshCopy, keeper: freshKeeper)])
    try fm.removeItem(at: a)
    report = await executor(home).run(plan2)
    XCTAssertEqual(report.outcomes.first?.status, .skipped)
    XCTAssertTrue(fm.fileExists(atPath: b.path))
  }

  func testKeeperMovedEarlierInSameRunProtectsTheCopy() async throws {
    let home = makeTempDirectory()
    defer { try? fm.removeItem(at: home) }
    let content = Data(repeating: 4, count: 8192)
    _ = try write(home, "Docs/a.bin", content)
    let b = try write(home, "Docs/b.bin", content)
    let groupGroups = await DuplicateFinder().find(in: [home.appendingPathComponent("Docs")], minimumSize: 1)
    let group = try XCTUnwrap(groupGroups.first)
    let keeper = try XCTUnwrap(group.files.first { $0.url.lastPathComponent == "a.bin" })
    let copy = try XCTUnwrap(group.files.first { $0.url.lastPathComponent == "b.bin" })
    // Bypass the planner to prove the executor enforces it too.
    let plan = OperationPlan(title: "t", items: [PlanItem.largeFile(keeper), PlanItem.duplicate(copy, keeper: keeper)])
    let report = await executor(home).run(plan)
    XCTAssertEqual(report.outcomes.map(\.status), [.moved, .skipped])
    XCTAssertTrue(fm.fileExists(atPath: b.path))
  }

  // MARK: Policy

  func testRootsCannotBeRemovedWhole() {
    let home = URL(fileURLWithPath: "/Users/t")
    let policy = SafetyPolicy(homeDirectory: home)
    XCTAssertFalse(policy.cleanupDecision(for: home.appendingPathComponent("Library/Caches"), category: .userCaches).allowed)
    XCTAssertTrue(policy.cleanupDecision(for: home.appendingPathComponent("Library/Caches/com.a"), category: .userCaches).allowed)
    XCTAssertFalse(policy.appLeftoverDecision(for: home.appendingPathComponent("Library/Application Support")).allowed)
    XCTAssertFalse(policy.appLeftoverDecision(for: home.appendingPathComponent("Library/Preferences")).allowed)
    XCTAssertFalse(policy.cleanupDecision(for: home.appendingPathComponent("Library/Application Support/MobileSync/Backup"), category: .deviceBackups).allowed)
  }

  func testAppleDataAndTrashAreNeverTargets() {
    let home = URL(fileURLWithPath: "/Users/t")
    let policy = SafetyPolicy(homeDirectory: home)
    XCTAssertFalse(policy.appLeftoverDecision(for: home.appendingPathComponent("Library/Containers/com.apple.Notes")).allowed)
    XCTAssertFalse(policy.appLeftoverDecision(for: home.appendingPathComponent("Library/Group Containers/group.com.apple.notes")).allowed)
    XCTAssertTrue(policy.appLeftoverDecision(for: home.appendingPathComponent("Library/Containers/com.vendor.notes")).allowed)
    XCTAssertFalse(policy.reviewedFileDecision(for: home.appendingPathComponent(".Trash")).allowed)
    XCTAssertFalse(policy.reviewedFileDecision(for: home.appendingPathComponent(".Trash/old.zip")).allowed)
  }

  func testCaseVariantsAndSymlinkedParentsCannotReachLibrary() throws {
    let home = makeTempDirectory()
    defer { try? fm.removeItem(at: home) }
    let policy = SafetyPolicy(homeDirectory: home)
    XCTAssertFalse(policy.reviewedFileDecision(for: home.appendingPathComponent("library/Preferences/x.plist")).allowed)
    XCTAssertFalse(policy.reviewedFileDecision(for: home.appendingPathComponent("LIBRARY/Caches")).allowed)

    try fm.createDirectory(at: home.appendingPathComponent("Library/Preferences"), withIntermediateDirectories: true)
    try write(home, "Library/Preferences/secret.plist", Data("x".utf8))
    try fm.createDirectory(at: home.appendingPathComponent("Docs"), withIntermediateDirectories: true)
    try fm.createSymbolicLink(
      at: home.appendingPathComponent("Docs/link"), withDestinationURL: home.appendingPathComponent("Library"))
    XCTAssertFalse(
      policy.reviewedFileDecision(for: home.appendingPathComponent("Docs/link/Preferences/secret.plist")).allowed)
  }

  func testDeveloperRuleRequiresMarkerOnDisk() throws {
    let home = makeTempDirectory()
    defer { try? fm.removeItem(at: home) }
    let policy = SafetyPolicy(homeDirectory: home)
    try write(home, "Documents/Novel/target/chapter1.txt", Data("words".utf8))
    XCTAssertFalse(policy.developerArtifactDecision(for: home.appendingPathComponent("Documents/Novel/target")).allowed)
    try write(home, "Code/app/Cargo.toml", Data("[package]".utf8))
    try write(home, "Code/app/target/debug/app", Data("bin".utf8))
    XCTAssertTrue(policy.developerArtifactDecision(for: home.appendingPathComponent("Code/app/target")).allowed)
  }

  func testCustomCacheRootsMustBeDedicatedFolders() {
    let home = URL(fileURLWithPath: "/Users/t")
    let valid = DeveloperStorageScanner.validatedRoots(
      [
        home, home.appendingPathComponent("Documents/hf"), URL(fileURLWithPath: "/Users"),
        home.appendingPathComponent("models"), home.appendingPathComponent("models/hf/hub"),
      ], home: home)
    XCTAssertEqual(valid.map(\.path), ["/Users/t/models/hf/hub"])
    let policy = SafetyPolicy(homeDirectory: home)
    XCTAssertFalse(
      policy.developerArtifactDecision(for: home.appendingPathComponent("Documents/hf/x"), extraRoots: [home.appendingPathComponent("Documents/hf")]).allowed)
  }

  // MARK: Restore and journal

  func testRestoreRefusesADifferentItemOrNonTrashLocation() throws {
    let home = makeTempDirectory()
    defer { try? fm.removeItem(at: home) }
    let trashed = try write(home, ".Trash/Foo", Data("new unrelated".utf8))
    let receipt = TrashReceipt(
      originalPath: home.appendingPathComponent("Foo").path, trashPath: trashed.path, bytes: 1,
      identity: "0:0")
    XCTAssertFalse(RecoveryService().canRestore(receipt))
    XCTAssertThrowsError(try RecoveryService().restore(receipt)) {
      XCTAssertEqual($0 as? RestoreError, .notTheSameItem("Foo"))
    }
    let elsewhere = try write(home, "Docs/Foo", Data("x".utf8))
    let bogus = TrashReceipt(originalPath: home.appendingPathComponent("Bar").path, trashPath: elsewhere.path, bytes: 1)
    XCTAssertThrowsError(try RecoveryService().restore(bogus)) {
      XCTAssertEqual($0 as? RestoreError, .noTrashLocation)
    }
    XCTAssertTrue(fm.fileExists(atPath: elsewhere.path))
  }

  func testInFlightJournalEntriesAreResolvedOnRecovery() throws {
    let dir = makeTempDirectory()
    defer { try? fm.removeItem(at: dir) }
    let stillHere = try write(dir, "still-here.bin", Data("x".utf8))
    let gone = dir.appendingPathComponent("gone.bin")
    let items = [stillHere, gone].map {
      ItemOutcome(
        item: PlanItem(url: $0, displayName: $0.lastPathComponent, kind: .reviewedFile, expectedBytes: 5, reason: "", source: "t"),
        status: .inFlight)
    }
    let report = OperationReport(id: UUID(), title: "t", startedAt: Date(), outcomes: items)
    try OperationJournal.encoder.encode(report).write(to: dir.appendingPathComponent("operation-\(report.id).json"))

    let recovered = try XCTUnwrap(OperationJournal.recoverInterrupted(in: dir).first)
    XCTAssertEqual(recovered.outcomes.map(\.status), [.notAttempted, .moved])
    XCTAssertEqual(recovered.receipts.map(\.originalPath), [gone.path])
  }

  // MARK: Ownership

  func testAppleContainersAreNotNameMatchedForThirdPartyApps() async throws {
    let home = makeTempDirectory()
    defer { try? fm.removeItem(at: home) }
    try write(home, "Library/Containers/com.apple.Notes/Data/x", Data("x".utf8))
    try write(home, "Library/Group Containers/group.com.apple.notes/x", Data("x".utf8))
    try write(home, "Library/Application Support/Notes Pro/x", Data("x".utf8))
    let app = AppRecord(
      url: home.appendingPathComponent("Applications/Notes.app"), name: "Notes",
      bundleIdentifier: "com.indie.notes", version: "1", bundleSize: 1, lastModified: nil)
    let found = await AppScanner(homeDirectory: home, applicationRoots: []).leftoversReport(for: app).value
    XCTAssertFalse(found.contains { $0.url.lastPathComponent.lowercased().contains("com.apple") })
  }

  // MARK: Helpers

  private func executor(_ home: URL) -> OperationExecutor {
    OperationExecutor(
      trashService: MovingTrashService(trashDirectory: home.appendingPathComponent(".Trash")),
      safetyPolicy: SafetyPolicy(homeDirectory: home), developerRoots: [])
  }

  @discardableResult
  private func write(_ root: URL, _ relative: String, _ data: Data) throws -> URL {
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
