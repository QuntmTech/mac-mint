import XCTest
@testable import MacCleanerCore

final class ProcessFamiliesTests: XCTestCase {
  private func process(_ pid: Int32, _ parent: Int32, started: UInt64 = 10, _ name: String = "helper") -> ProcessRecord {
    ProcessRecord(pid: pid, parent: parent, started: started, name: name)
  }

  /// An editor with several windows and an extension host running a tool server, a browser
  /// with renderers, a detached helper and a terminal that started an app from a shell.
  private var workload: [ProcessRecord] {
    [
      process(1, 0, started: 0, "launchd"),
      process(100, 1, started: 10, "Code"),
      process(101, 100, started: 11, "Code Helper (GPU)"),
      process(102, 100, started: 12, "Code Helper (Renderer)"),
      process(103, 100, started: 13, "Code Helper (Renderer)"),
      process(104, 100, started: 14, "Code Helper (Renderer)"),
      process(105, 100, started: 15, "Code Helper (Plugin)"),
      process(106, 105, started: 16, "node"),
      process(107, 106, started: 17, "python3"),
      process(200, 1, started: 20, "Brave Browser"),
      process(201, 200, started: 21, "Brave Browser Helper (Renderer)"),
      process(202, 200, started: 22, "Brave Browser Helper (Renderer)"),
      process(203, 200, started: 23, "Brave Browser Helper (GPU)"),
      process(250, 1, started: 25, "detached-agent"),
      process(400, 1, started: 40, "Terminal"),
      process(401, 400, started: 41, "zsh"),
      process(402, 401, started: 42, "Preview"),
      process(403, 402, started: 43, "Preview helper"),
    ]
  }

  func testEditorWindowsBrowserRenderersAndToolServersBelongToTheirApp() {
    let families = ProcessFamilies.members(of: [100, 200, 400, 402], in: workload)
    XCTAssertEqual(Set(families[100] ?? []), [101, 102, 103, 104, 105, 106, 107])
    XCTAssertEqual(Set(families[200] ?? []), [201, 202, 203])
    XCTAssertEqual(Set(families[400] ?? []), [401], "An app started from a shell is its own family")
    XCTAssertEqual(Set(families[402] ?? []), [403])
  }

  func testEveryProcessIsCountedAtMostOnceAndRootsAreNeverMembers() {
    let roots: Set<Int32> = [100, 200, 400, 402]
    let members = ProcessFamilies.members(of: roots, in: workload + workload).values.flatMap { $0 }
    XCTAssertEqual(members.count, Set(members).count, "Duplicate listing entries are counted once")
    XCTAssertTrue(roots.isDisjoint(with: members))
    XCTAssertFalse(members.contains(250), "Helpers started by launchd are not guessed")
    XCTAssertFalse(members.contains(1))
  }

  func testReusedOrMissingParentsLeaveAProcessUnattributed() {
    let listing = [
      process(100, 1, started: 50, "Editor"),
      // The real parent 100 exited; the PID now belongs to an app that started later.
      process(300, 100, started: 40, "orphan from an earlier process"),
      process(301, 300, started: 41, "orphan child"),
      // Parent exited and is no longer listed.
      process(302, 999, started: 60, "exited parent"),
      process(303, 100, started: 70, "real child"),
    ]
    let families = ProcessFamilies.members(of: [100], in: listing)
    XCTAssertEqual(families[100], [303])
  }

  func testExitedRootsAndSelfOrCyclicParentsAreHandled() {
    let listing = [
      process(10, 10, started: 1, "self parent"),
      process(20, 21, started: 1, "cycle a"),
      process(21, 20, started: 1, "cycle b"),
      process(30, 1, started: 1, "app"),
    ]
    let families = ProcessFamilies.members(of: [30, 99], in: listing)
    XCTAssertEqual(families[30], [])
    XCTAssertNil(families[99], "A root that exited before the listing has no family")
  }

  func testHelperTotalsSkipUnknownReadingsAndKeepTheLargest() {
    let helpers = ProcessFamilies.Helpers([
      .init(pid: 5, name: "renderer", memoryBytes: 300, cpuPercent: 12.5),
      .init(pid: 6, name: "gpu", memoryBytes: 500, cpuPercent: nil),
      .init(pid: 7, name: "utility", memoryBytes: 300, cpuPercent: .nan),
      .init(pid: 8, name: "exited", memoryBytes: -1, cpuPercent: 40),
      .init(pid: 9, name: "network", memoryBytes: 100, cpuPercent: 2.5),
    ], keep: 3)
    XCTAssertEqual(helpers.count, 4)
    XCTAssertEqual(helpers.memoryBytes, 1_200)
    XCTAssertEqual(helpers.cpuPercent, 15)
    XCTAssertEqual(helpers.largest.map(\.pid), [6, 5, 7])
    XCTAssertEqual(ProcessFamilies.Helpers([]), .none)
  }

  func testByteTotalsSaturateAndUnknownStaysUnknown() {
    XCTAssertEqual(ProcessFamilies.add(.max - 1, 5), .max)
    XCTAssertEqual(ProcessFamilies.add(-1, 5), -1)
    XCTAssertEqual(ProcessFamilies.add(2, 3), 5)
  }
}
