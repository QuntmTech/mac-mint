import Foundation
import MacCleanerCore
import XCTest
@testable import MacCleanerApp

@MainActor
final class RecoveryGateTests: XCTestCase {
  func testUnreadableHistoryPausesNewRemovalUntilAnExplicitReset() async throws {
    let fm = FileManager.default
    let support = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let home = fm.homeDirectoryForCurrentUser.appendingPathComponent("MacMintRecoveryGate-" + UUID().uuidString)
    defer { try? fm.removeItem(at: support); try? fm.removeItem(at: home) }
    try fm.createDirectory(at: support, withIntermediateDirectories: true)
    let damaged = Data("{damaged history".utf8)
    try damaged.write(to: support.appendingPathComponent("history.json"))
    let file = home.appendingPathComponent("Downloads/keep-me.bin")
    try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(repeating: 1, count: 4096).write(to: file)

    let model = AppViewModel(supportDirectory: support)
    model.authorizeRemoval = { true }
    for _ in 0..<200 {
      if model.recoveryReady { break }
      try await Task.sleep(for: .milliseconds(10))
    }
    XCTAssertTrue(model.recoveryReady)
    XCTAssertFalse(model.historyReadable)

    let plan = OperationPlanner.plan(title: "Gate", items: [
      PlanItem(url: file, displayName: "keep-me.bin", kind: .reviewedFile, expectedBytes: 4096,
        reason: "Test fixture", source: "Test", identity: FileSystem.fileIdentity(at: file)),
    ])
    model.pendingPlan = plan
    model.execute(plan)
    XCTAssertFalse(model.isWorking)
    XCTAssertNotNil(model.pendingPlan, "a refused confirmation keeps the review open")
    XCTAssertTrue(fm.fileExists(atPath: file.path))

    model.resetDamagedHistory()
    for _ in 0..<200 {
      if model.historyReadable { break }
      try await Task.sleep(for: .milliseconds(10))
    }
    XCTAssertTrue(model.historyReadable)
    let backups = try fm.contentsOfDirectory(atPath: support.path).filter { $0.hasPrefix("history.json.preserved-") }
    XCTAssertEqual(backups.count, 1)
    XCTAssertEqual(try Data(contentsOf: support.appendingPathComponent(backups[0])), damaged)
  }
}
