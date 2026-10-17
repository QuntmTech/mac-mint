import XCTest
@testable import MacCleanerApp

final class PerformancePresentationTests: XCTestCase {
  private func app(_ pid: Int32, name: String = "Editor", memory: Int64 = 1, cpu: Double? = 0,
    bundleID: String? = nil, started: UInt64 = 1) -> PerformancePresentation.App {
    .init(id: .init(pid: pid, started: started), name: name, bundleID: bundleID, memoryBytes: memory, cpuPercent: cpu)
  }

  func testUnknownInvalidCPUStaysLastInEitherDirectionAndMeasuredZeroIsKnown() {
    let rows = [app(4, cpu: .nan), app(6, cpu: .infinity), app(7, cpu: -1), app(5, cpu: nil), app(2, cpu: 0), app(3, cpu: 210)]
    for direction in [PerformancePresentation.Direction.ascending, .descending] {
      let result = PerformancePresentation.apps(rows, query: "", sort: .init(key: .cpu, direction: direction))
      XCTAssertEqual(Array(result.prefix(2)).map(\.id.pid), direction == .descending ? [3, 2] : [2, 3])
      XCTAssertEqual(Array(result.suffix(4)).map(\.id.pid), [4, 5, 6, 7])
    }
  }

  func testMetricTiesAreStableAcrossInputOrderAndPreserveDistinctProcessBirths() {
    let rows = [app(20, name: "Zebra"), app(10, name: "Editor", started: 2), app(10, name: "editor", started: 1), app(2, name: "Editor")]
    let expected = [rows[3].id, rows[2].id, rows[1].id, rows[0].id]
    for key in [PerformancePresentation.SortKey.cpu, .memory] {
      for direction in [PerformancePresentation.Direction.ascending, .descending] {
        let sort = PerformancePresentation.Sort(key: key, direction: direction)
        XCTAssertEqual(PerformancePresentation.apps(rows, query: "", sort: sort).map(\.id), expected)
        XCTAssertEqual(PerformancePresentation.apps(Array(rows.reversed()), query: "", sort: sort).map(\.id), expected)
      }
    }
  }

  func testMemorySortingUsesExactIntegerBytesAndUnknownMemoryIsLast() {
    let rows = [app(2, memory: Int64.max - 1), app(3, memory: Int64.max), app(1, memory: -1)]
    XCTAssertEqual(PerformancePresentation.apps(rows, query: "", sort: .init()).map(\.id.pid), [3, 2, 1])
    XCTAssertEqual(PerformancePresentation.apps(rows, query: "", sort: .init(key: .memory, direction: .ascending)).map(\.id.pid), [2, 3, 1])
  }

  func testTrimmedSearchMatchesAppBundleAndPIDWithoutChangingMetricOrder() {
    let rows = [app(42, name: "Code Studio", memory: 20, bundleID: "com.example.editor"),
      app(43, name: "Browser", memory: 10, bundleID: "com.example.browser"), app(44, name: "Other", memory: 30)]
    XCTAssertEqual(PerformancePresentation.apps(rows, query: " \nSTUDIO\t", sort: .init()).map(\.id.pid), [42])
    XCTAssertEqual(PerformancePresentation.apps(rows, query: "EXAMPLE", sort: .init()).map(\.id.pid), [42, 43])
    XCTAssertEqual(PerformancePresentation.apps(rows, query: "43", sort: .init()).map(\.id.pid), [43])
    XCTAssertEqual(PerformancePresentation.apps(rows, query: "  \n", sort: .init()).map(\.id.pid), [44, 42, 43])
    XCTAssertTrue(PerformancePresentation.apps(rows, query: "missing", sort: .init()).isEmpty)
  }

  func testCardsChooseHighestUsageAndHeadersCanReverseOrSelectName() {
    var sort = PerformancePresentation.Sort(key: .memory, direction: .ascending)
    sort.select(.cpu)
    XCTAssertEqual(sort, .init(key: .cpu, direction: .descending))
    sort.select(.cpu, toggle: true)
    XCTAssertEqual(sort.direction, .ascending)
    sort.select(.cpu)
    XCTAssertEqual(sort.direction, .descending)
    sort.select(.name)
    XCTAssertEqual(sort.direction, .ascending)
    sort.select(.name, toggle: true)
    XCTAssertEqual(sort.direction, .descending)
  }

  func testResourceMetersClampFiniteValuesAndPreserveUnknownMeasurements() {
    XCTAssertEqual(PerformancePresentation.cpuFraction(200, logicalCPUCount: 8), 0.25)
    XCTAssertEqual(PerformancePresentation.cpuFraction(1200, logicalCPUCount: 8), 1)
    XCTAssertEqual(PerformancePresentation.cpuFraction(0, logicalCPUCount: 8), 0)
    for invalid in [Double.nan, .infinity, -.infinity, -1] {
      XCTAssertNil(PerformancePresentation.cpuFraction(invalid, logicalCPUCount: 8))
    }
    XCTAssertNil(PerformancePresentation.cpuFraction(nil, logicalCPUCount: 8))
    XCTAssertNil(PerformancePresentation.cpuFraction(20, logicalCPUCount: 0))
    XCTAssertEqual(PerformancePresentation.memoryFraction(20, physicalMemory: 16), 1)
    XCTAssertEqual(PerformancePresentation.memoryFraction(8, physicalMemory: 16), 0.5)
    XCTAssertNil(PerformancePresentation.memoryFraction(-1, physicalMemory: 16))
    XCTAssertNil(PerformancePresentation.memoryFraction(nil, physicalMemory: 16))
    XCTAssertNil(PerformancePresentation.memoryFraction(8, physicalMemory: 0))
    XCTAssertNil(PerformancePresentation.fraction(1, capacity: .nan))
    XCTAssertNil(PerformancePresentation.fraction(1, capacity: .infinity))
  }
}
