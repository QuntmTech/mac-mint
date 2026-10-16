import Foundation
import XCTest
@testable import MacCleanerCore

final class TrustRegressionTests: XCTestCase {
  private let fm = FileManager.default
  private func temporaryHome() throws -> URL {
    let url = fm.temporaryDirectory.appendingPathComponent("macmint-trust-" + UUID().uuidString)
    try fm.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }
  private func write(_ home: URL, _ path: String) throws -> URL {
    let url = home.appendingPathComponent(path)
    try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(repeating: 1, count: 16384).write(to: url)
    return url
  }
  private func item(_ url: URL, keeper: URL? = nil) -> PlanItem {
    PlanItem(url: url, displayName: url.lastPathComponent, kind: .reviewedFile,
      expectedBytes: 16384, reason: "Explicit test selection", source: "Test",
      identity: FileSystem.fileIdentity(at: url),
      keeper: keeper.map { KeeperSnapshot(path: $0.path, identity: FileSystem.fileIdentity(at: $0), snapshot: FileSnapshot.current($0)) })
  }

  func testSelectedAncestorCannotRemoveBothCopyAndKeeper() async throws {
    let home = try temporaryHome()
    defer { try? fm.removeItem(at: home) }
    let a = try write(home, "Album/a.jpg")
    let b = try write(home, "Album/b.jpg")
    let folder = a.deletingLastPathComponent()
    let planned = OperationPlanner.plan(title: "test", items: [item(b, keeper: a), item(folder)])
    XCTAssertFalse(planned.items.contains { $0.url == folder })
    XCTAssertTrue(planned.excluded.contains { $0.url == folder })
    let executor = OperationExecutor(trashService: FixtureTrash(home: home), safetyPolicy: SafetyPolicy(homeDirectory: home))
    // Even a caller bypassing the planner cannot trash the ancestor and its protected keeper.
    let result = await executor.run(OperationPlan(title: "raw", items: [item(folder), item(b, keeper: a)]))
    XCTAssertEqual(result.outcomes.first?.status, .skipped)
    XCTAssertTrue(fm.fileExists(atPath: a.path))
  }

  func testCoveredPhotoConstraintChecksMissingKeeper() async throws {
    let home = try temporaryHome()
    defer { try? fm.removeItem(at: home) }
    let a = try write(home, "Keep/a.jpg")
    let b = try write(home, "Remove/b.jpg")
    let plan = OperationPlanner.plan(title: "photos", items: [item(b, keeper: a), item(b.deletingLastPathComponent())])
    XCTAssertEqual(plan.covered.count, 1)
    try fm.removeItem(at: a)
    let result = await OperationExecutor(trashService: FixtureTrash(home: home), safetyPolicy: SafetyPolicy(homeDirectory: home)).run(plan)
    XCTAssertTrue(result.moved.isEmpty)
    XCTAssertTrue(fm.fileExists(atPath: b.path))
  }

  func testUnwritableJournalStopsBeforeAnyMove() async throws {
    let home = try temporaryHome()
    defer { try? fm.removeItem(at: home) }
    let source = try write(home, "Docs/a")
    let notADirectory = try write(home, "blocked")
    let result = await OperationExecutor(trashService: FixtureTrash(home: home), safetyPolicy: SafetyPolicy(homeDirectory: home), journalDirectory: notADirectory)
      .run(OperationPlan(title: "journal", items: [item(source)]))
    XCTAssertNotNil(result.persistenceError)
    XCTAssertTrue(result.moved.isEmpty)
    XCTAssertTrue(fm.fileExists(atPath: source.path))
  }

  func testFullDiskBeforeIntentStopsMovementAndFullDiskAfterMoveRetainsUncertainty() async throws {
    for failedWrite in [2, 3] {
      let home = try temporaryHome()
      defer { try? fm.removeItem(at: home) }
      let source = try write(home, "Docs/a")
      let writer = FailingJournal(failAt: failedWrite)
      let journals = home.appendingPathComponent("operations")
      let executor = OperationExecutor(trashService: FixtureTrash(home: home),
        safetyPolicy: SafetyPolicy(homeDirectory: home), journalDirectory: journals,
        journalWriter: { try writer.write($0, to: $1) })
      let report = await executor.run(OperationPlan(title: "full disk", items: [item(source)]))
      XCTAssertNotNil(report.persistenceError)
      if failedWrite == 2 {
        XCTAssertTrue(report.moved.isEmpty)
        XCTAssertTrue(fm.fileExists(atPath: source.path))
      } else {
        XCTAssertEqual(report.receipts.count, 1)
        let recovered = try XCTUnwrap(OperationJournal.recoverInterrupted(in: journals).first)
        XCTAssertEqual(recovered.outcomes.first?.status, .uncertain)
        XCTAssertTrue(recovered.receipts.isEmpty)
      }
      XCTAssertFalse(OperationJournal.recoverInterrupted(in: journals).isEmpty)
    }
  }

  func testCoveredChildStillProtectsRunningOwnerAndReplacement() async throws {
    let home = try temporaryHome()
    defer { try? fm.removeItem(at: home) }
    let child = try write(home, "Docs/cache")
    let owned = PlanItem(url: child, displayName: "cache", kind: .reviewedFile, expectedBytes: 16384,
      reason: "Owned cache", source: "Test", identity: FileSystem.fileIdentity(at: child), ownerBundleID: "com.example.tool")
    let plan = OperationPlanner.plan(title: "parent", items: [owned, item(child.deletingLastPathComponent())])
    let report = await OperationExecutor(trashService: FixtureTrash(home: home), safetyPolicy: SafetyPolicy(homeDirectory: home),
      isAppRunning: { $0 == "com.example.tool" }).run(plan)
    XCTAssertTrue(report.moved.isEmpty)
    let replacement = try write(home, "replacement")
    try fm.removeItem(at: child)
    try fm.moveItem(at: replacement, to: child)
    let replaced = await OperationExecutor(trashService: FixtureTrash(home: home), safetyPolicy: SafetyPolicy(homeDirectory: home)).run(plan)
    XCTAssertTrue(replaced.moved.isEmpty)
  }

  func testJournalRemainsUntilIdempotentHistoryCommitIsAcknowledged() async throws {
    let home = try temporaryHome()
    defer { try? fm.removeItem(at: home) }
    let source = try write(home, "Docs/a")
    let journals = home.appendingPathComponent("operations")
    let report = await OperationExecutor(trashService: FixtureTrash(home: home), safetyPolicy: SafetyPolicy(homeDirectory: home), journalDirectory: journals)
      .run(OperationPlan(title: "journal", items: [item(source)]))
    XCTAssertEqual(report.moved.count, 1)
    XCTAssertEqual(OperationJournal.recoverInterrupted(in: journals).count, 1)
    XCTAssertEqual(OperationJournal.recoverInterrupted(in: journals).count, 1)
    let store = HistoryStore(url: home.appendingPathComponent("history.json"))
    try await store.append(report.historyEntry())
    try await store.append(report.historyEntry())
    let history = await store.load()
    XCTAssertEqual(history.count, 1)
    try OperationJournal.acknowledge(report.id, in: journals)
    XCTAssertTrue(OperationJournal.recoverInterrupted(in: journals).isEmpty)
  }

  func testUncertainMoveDoesNotInventTrashReceiptAndCorruptJournalSurvives() throws {
    let home = try temporaryHome()
    defer { try? fm.removeItem(at: home) }
    let report = OperationReport(id: UUID(), title: "interrupted", startedAt: Date(), outcomes: [ItemOutcome(item: item(home.appendingPathComponent("missing")), status: .inFlight)])
    let journal = home.appendingPathComponent("operation-\(report.id).json")
    try OperationJournal.encoder.encode(report).write(to: journal)
    let corrupt = home.appendingPathComponent("operation-corrupt.json")
    try Data("invalid".utf8).write(to: corrupt)
    let recovered = try XCTUnwrap(OperationJournal.recoverInterrupted(in: home).first)
    XCTAssertEqual(recovered.outcomes.first?.status, .uncertain)
    XCTAssertTrue(recovered.receipts.isEmpty)
    XCTAssertTrue(fm.fileExists(atPath: journal.path))
    XCTAssertTrue(fm.fileExists(atPath: corrupt.path))
    XCTAssertEqual(OperationJournal.unreadableJournals(in: home), [corrupt])
  }

  func testManagedLibraryRootsAndContentsAreNeverGenericTargets() async throws {
    let home = try temporaryHome()
    defer { try? fm.removeItem(at: home) }
    let source = try write(home, "Pictures/My.photoslibrary/originals/unique.jpg")
    let policy = SafetyPolicy(homeDirectory: home)
    XCTAssertFalse(policy.reviewedFileDecision(for: source).allowed)
    XCTAssertFalse(policy.reviewedFileDecision(for: source.deletingLastPathComponent().deletingLastPathComponent()).allowed)
    let files = await LargeFileFinder().find(in: [source.deletingLastPathComponent()], minimumSize: 1)
    XCTAssertTrue(files.isEmpty)
    let groups = await DuplicateFinder().find(in: [source.deletingLastPathComponent()], minimumSize: 1)
    XCTAssertTrue(groups.isEmpty)
  }

  func testSelectedAncestorCannotMoveManagedPhotoLibrary() async throws {
    let home = try temporaryHome()
    defer { try? fm.removeItem(at: home) }
    let source = try write(home, "Pictures/My.photoslibrary/originals/unique.jpg")
    let pictures = home.appendingPathComponent("Pictures")
    let report = await OperationExecutor(trashService: FixtureTrash(home: home), safetyPolicy: SafetyPolicy(homeDirectory: home))
      .run(OperationPlan(title: "folder", items: [item(pictures)]))
    XCTAssertEqual(report.outcomes.first?.status, .skipped)
    XCTAssertTrue(fm.fileExists(atPath: source.path))
  }

  func testCorruptHistoryCannotBeOverwrittenByAppendOrRestore() async throws {
    let home = try temporaryHome()
    defer { try? fm.removeItem(at: home) }
    let url = try write(home, "history.json")
    let before = try Data(contentsOf: url)
    let store = HistoryStore(url: url)
    do { try await store.append(HistoryEntry(action: "test", paths: [], bytes: 0, notes: "")); XCTFail("Must preserve corrupt history") } catch {}
    do { try await store.markRestored(entryID: UUID(), originalPaths: ["x"]); XCTFail("Must preserve corrupt history") } catch {}
    XCTAssertEqual(try Data(contentsOf: url), before)
  }

  func testExclusionsResolveParentAliasesAndReachStorageAndDeveloper() async throws {
    let home = try temporaryHome()
    defer { try? fm.removeItem(at: home) }
    let source = try write(home, "Code/App/node_modules/a")
    _ = try write(home, "Code/App/package.json")
    let code = home.appendingPathComponent("Code")
    let alias = home.appendingPathComponent("alias")
    try fm.createSymbolicLink(at: alias, withDestinationURL: code)
    let excluded = home.appendingPathComponent("Code/App")
    XCTAssertTrue(FileSystem.isIgnored(alias.appendingPathComponent("App/node_modules/a"), ignoredPaths: [excluded.path]))
    let tree = await StorageTreeScanner(detailThreshold: 1).scan(home, ignoredPaths: [excluded.path])
    XCTAssertNil(tree.root.node(at: source.path))
    let dev = await DeveloperStorageScanner(homeDirectory: home).scan(projectRoots: [code], ignoredPaths: [excluded.path])
    XCTAssertFalse(dev.value.contains { $0.group == .projects })
  }

  func testActiveDeveloperEvidenceCannotBeOverriddenByCleanerParent() {
    let home = URL(fileURLWithPath: "/Users/test")
    let root = home.appendingPathComponent("Library/Developer/Xcode/DerivedData")
    var inputs = RecommendationEngine.Inputs()
    inputs.cleanupTargets = [CleanupTarget(category: .developerJunk, url: root, displayName: "DerivedData", size: 100_000_000, risk: .safe, reason: "cache")]
    inputs.developer = [DevStorageItem(group: .xcode, tool: "Xcode", title: "Active", url: root.appendingPathComponent("Project"), bytes: 100_000_000, rebuild: .rebuildable, removal: .trash, isActive: true)]
    XCTAssertTrue(RecommendationEngine.safeItems(RecommendationEngine.recommend(inputs)).isEmpty)
    XCTAssertEqual(CleanupCatalog(homeDirectory: home).rules().first { $0.url == root }?.ownerBundleID, "com.apple.dt.Xcode")
  }
}

private actor FixtureTrash: TrashService {
  let home: URL
  init(home: URL) { self.home = home }
  func trash(_ url: URL) throws -> URL? {
    let folder = home.appendingPathComponent(".Trash")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let destination = folder.appendingPathComponent(UUID().uuidString)
    try FileManager.default.moveItem(at: url, to: destination)
    return destination
  }
}

private final class FailingJournal: @unchecked Sendable {
  private let lock = NSLock()
  private var count = 0
  let failAt: Int
  init(failAt: Int) { self.failAt = failAt }
  func write(_ data: Data, to url: URL) throws {
    lock.lock(); defer { lock.unlock() }
    count += 1
    if count >= failAt { throw NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC)) }
    try FileSystem.writeDurably(data, to: url)
  }
}
