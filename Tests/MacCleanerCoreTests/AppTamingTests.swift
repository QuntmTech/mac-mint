import Foundation
import XCTest
@testable import MacCleanerCore

final class AppTamingTests: XCTestCase {
  private let now = Date(timeIntervalSince1970: 1000)
  private func id(_ pid: Int32 = 41, started: UInt64 = 10) -> TamingIdentity {
    .init(pid: pid, started: started, boot: "boot", bundleID: "example.app", path: "/Applications/Example.app")
  }
  func testRequiresSustainedLoadAndIgnoresUnknownOrNonfiniteReadings() {
    var policy = AutoTamingPolicy()
    for second in [0, 8, 16] {
      XCTAssertTrue(policy.evaluate(candidates: [.init(identity: id(), cpu: 90, eligible: true)], active: [],
        systemCPU: 0.8, now: now.addingTimeInterval(Double(second)), enabled: true).slow.isEmpty)
    }
    XCTAssertEqual(policy.evaluate(candidates: [.init(identity: id(), cpu: 90, eligible: true)], active: [],
      systemCPU: 0.8, now: now.addingTimeInterval(24), enabled: true).slow, [id()])
    for cpu: Double? in [nil, .nan, .infinity, -1, 50] {
      XCTAssertTrue(policy.evaluate(candidates: [.init(identity: id(), cpu: cpu, eligible: true)], active: [],
        systemCPU: 0.8, now: now.addingTimeInterval(32), enabled: true).slow.isEmpty)
    }
  }
  func testNoTamingWithoutSystemContentionAndNoTamingAcrossSleepGaps() {
    var policy = AutoTamingPolicy()
    let candidates = [AutoTamingPolicy.Candidate(identity: id(), cpu: 400, eligible: true)]
    for second in [0, 8, 24, 32] {
      XCTAssertTrue(policy.evaluate(candidates: candidates, active: [], systemCPU: 0.3,
        now: now.addingTimeInterval(Double(second)), enabled: true).slow.isEmpty)
    }
    _ = policy.evaluate(candidates: candidates, active: [], systemCPU: 0.9, now: now, enabled: true)
    XCTAssertTrue(policy.evaluate(candidates: candidates, active: [], systemCPU: 0.9,
      now: now.addingTimeInterval(80), enabled: true).slow.isEmpty)
  }
  func testProtectingForegroundOrExceptionRestoresManualAndAutomaticImmediately() {
    var policy = AutoTamingPolicy()
    for automatic in [false, true] {
      let receipt = TamingReceipt(identity: id(), name: "app", automatic: automatic, expires: now.addingTimeInterval(100))
      let result = policy.evaluate(candidates: [.init(identity: id(), cpu: 90, eligible: false)], active: [receipt],
        systemCPU: 0.8, now: now, enabled: true)
      XCTAssertEqual(result.restore, [id()]); XCTAssertTrue(result.slow.isEmpty)
    }
  }
  func testLimitTwoAndNeverTreatReusedPIDAsOldProcess() {
    var policy = AutoTamingPolicy()
    let candidates = (1...4).map { AutoTamingPolicy.Candidate(identity: id(Int32($0)), cpu: 90, eligible: true) }
    for second in [0, 8, 16] {
      _ = policy.evaluate(candidates: candidates, active: [], systemCPU: 0.8, now: now.addingTimeInterval(Double(second)), enabled: true)
    }
    XCTAssertEqual(policy.evaluate(candidates: candidates, active: [], systemCPU: 0.8,
      now: now.addingTimeInterval(24), enabled: true).slow.count, 2)
    let receipt = TamingReceipt(identity: id(), name: "app", automatic: true, expires: now.addingTimeInterval(100))
    let result = policy.evaluate(candidates: [.init(identity: id(started: 11), cpu: 90, eligible: true)], active: [receipt],
      systemCPU: 0.8, now: now.addingTimeInterval(24), enabled: true)
    XCTAssertEqual(result.restore, [id()]); XCTAssertTrue(result.slow.isEmpty)
  }
  func testCoolingHysteresisExpiryAndCooldown() {
    var policy = AutoTamingPolicy()
    let receipt = TamingReceipt(identity: id(), name: "app", automatic: true, expires: now.addingTimeInterval(300))
    let candidate = AutoTamingPolicy.Candidate(identity: id(), cpu: 10, eligible: true)
    for second in [0, 8, 16, 24] {
      XCTAssertTrue(policy.evaluate(candidates: [candidate], active: [receipt], systemCPU: 0.9,
        now: now.addingTimeInterval(Double(second)), enabled: true).restore.isEmpty)
    }
    XCTAssertEqual(policy.evaluate(candidates: [candidate], active: [receipt], systemCPU: 0.9,
      now: now.addingTimeInterval(32), enabled: true).restore, [id()])
    policy.restored(id(), now: now.addingTimeInterval(32))
    for second in [40, 48, 56, 64] {
      XCTAssertTrue(policy.evaluate(candidates: [.init(identity: id(), cpu: 90, eligible: true)], active: [], systemCPU: 0.9,
        now: now.addingTimeInterval(Double(second)), enabled: true).slow.isEmpty)
    }
    XCTAssertEqual(policy.evaluate(candidates: [.init(identity: id(), cpu: 90, eligible: true)], active: [receipt], systemCPU: 0.9,
      now: now.addingTimeInterval(301), enabled: true).restore, [id()])
  }
  func testTurningOffOnlyRestoresAutomaticReceipts() {
    var policy = AutoTamingPolicy()
    let active = [TamingReceipt(identity: id(1), name: "auto", automatic: true, expires: now.addingTimeInterval(100)),
      TamingReceipt(identity: id(2), name: "manual", automatic: false, expires: now.addingTimeInterval(100))]
    let result = policy.evaluate(candidates: active.map { .init(identity: $0.identity, cpu: 90, eligible: true) },
      active: active, systemCPU: 0.8, now: now, enabled: false)
    XCTAssertEqual(result.restore, [id(1)]); XCTAssertTrue(result.slow.isEmpty)
  }
  func testJournalRoundTripAndCorruptionPreserved() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = TamingStore(url: root.appendingPathComponent("journal.json"))
    XCTAssertTrue(try store.load().receipts.isEmpty)
    var state = TamingState(); state.exceptions = ["example.app": "App"]
    state.receipts = [.init(identity: id(), name: "App", automatic: false, expires: now)]
    try store.save(state); XCTAssertEqual(try store.load(), state)
    let corrupt = Data("not JSON".utf8); try corrupt.write(to: store.url)
    XCTAssertThrowsError(try store.load()); XCTAssertEqual(try Data(contentsOf: store.url), corrupt)
  }
}
