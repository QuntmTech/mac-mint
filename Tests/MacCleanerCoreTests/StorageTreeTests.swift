import XCTest

@testable import MacCleanerCore

final class StorageTreeTests: XCTestCase {
  private let fm = FileManager.default

  func testTreeTotalsMatchFixtureAndAggregateSmallFiles() async throws {
    let root = makeTempDirectory()
    defer { try? fm.removeItem(at: root) }
    try write(root, "Movies/big.mov", 3 * 1_048_576)
    try write(root, "Docs/a.txt", 1000)
    try write(root, "Docs/b.txt", 2000)
    try write(root, "Docs/large.pdf", 2 * 1_048_576)

    let scan = await StorageTreeScanner(detailThreshold: 1_048_576).scan(root)
    let tree = scan.root
    XCTAssertEqual(tree.logicalBytes, Int64(3 * 1_048_576 + 3000 + 2 * 1_048_576))
    XCTAssertEqual(tree.children.first?.name, "Movies", "children are sorted largest first")

    let docs = try XCTUnwrap(tree.node(at: root.appendingPathComponent("Docs").standardizedFileURL.path))
    XCTAssertEqual(docs.children.map(\.kind), [.file, .aggregate])
    XCTAssertEqual(docs.children.last?.itemCount, 2)
    XCTAssertEqual(docs.children.last?.logicalBytes, 3000)
    XCTAssertEqual(scan.coverage.scannedItems, 6)
  }

  func testPackagesAreLeavesSizedWithContents() async throws {
    let root = makeTempDirectory()
    defer { try? fm.removeItem(at: root) }
    try write(root, "Thing.app/Contents/MacOS/bin", 2 * 1_048_576)

    let tree = await StorageTreeScanner().scan(root).root
    // On Linux there is no package concept, so the bundle is scanned as a folder; either way
    // its full size is attributed to it.
    let app = try XCTUnwrap(tree.children.first)
    XCTAssertEqual(app.name, "Thing.app")
    XCTAssertGreaterThanOrEqual(app.allocatedBytes, 2 * 1_048_576)
  }

  func testHardLinksCountOnce() async throws {
    let root = makeTempDirectory()
    defer { try? fm.removeItem(at: root) }
    let original = try write(root, "a/original.bin", 2 * 1_048_576)
    try fm.createDirectory(at: root.appendingPathComponent("b"), withIntermediateDirectories: true)
    try fm.linkItem(at: original, to: root.appendingPathComponent("b/link.bin"))

    let tree = await StorageTreeScanner().scan(root).root
    let single = FileSystem.itemSize(at: original)
    XCTAssertEqual(tree.allocatedBytes, single)
    XCTAssertEqual(tree.logicalBytes, Int64(4 * 1_048_576))
  }

  func testUnreadableFolderIsReportedInCoverage() async throws {
    try XCTSkipIf(getuid() == 0, "Permission checks do not apply to root")
    let root = makeTempDirectory()
    let locked = root.appendingPathComponent("locked")
    try write(root, "locked/secret.bin", 10)
    try fm.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked.path)
    defer {
      try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path)
      try? fm.removeItem(at: root)
    }

    let scan = await StorageTreeScanner().scan(root)
    XCTAssertEqual(scan.coverage.inaccessiblePaths.map { URL(fileURLWithPath: $0).lastPathComponent }, ["locked"])
  }

  func testRemovingPathsUpdatesTotalsAndTrail() async throws {
    let root = makeTempDirectory()
    defer { try? fm.removeItem(at: root) }
    try write(root, "A/one.bin", 2 * 1_048_576)
    let two = try write(root, "A/B/two.bin", 3 * 1_048_576)

    let tree = await StorageTreeScanner().scan(root).root
    let twoPath = two.standardizedFileURL.path
    XCTAssertEqual(tree.trail(to: twoPath).map(\.name), [root.lastPathComponent, "A", "B", "two.bin"])

    let pruned = tree.removing([twoPath])
    XCTAssertEqual(pruned.logicalBytes, Int64(2 * 1_048_576))
    XCTAssertNil(pruned.node(at: twoPath))
    XCTAssertEqual(tree.logicalBytes, Int64(5 * 1_048_576), "original tree is unchanged")
  }

  func testTreemapFillsBoundsProportionally() {
    let bounds = Treemap.Rect(x: 0, y: 0, width: 600, height: 400)
    let values: [Double] = [6, 6, 4, 3, 2, 2, 1]
    let rects = Treemap.layout(values, in: bounds)
    XCTAssertEqual(rects.count, values.count)

    let total = values.reduce(0, +)
    for (value, rect) in zip(values, rects) {
      XCTAssertEqual(rect.area, bounds.area * value / total, accuracy: 0.5)
      XCTAssertGreaterThanOrEqual(rect.x, -0.001)
      XCTAssertGreaterThanOrEqual(rect.y, -0.001)
      XCTAssertLessThanOrEqual(rect.x + rect.width, bounds.width + 0.001)
      XCTAssertLessThanOrEqual(rect.y + rect.height, bounds.height + 0.001)
    }
    let covered = rects.reduce(0) { $0 + $1.area }
    XCTAssertEqual(covered, bounds.area, accuracy: 1)
    // Squarified layouts keep tiles reasonably square.
    let worstAspect = rects.map { max($0.width / $0.height, $0.height / $0.width) }.max() ?? 0
    XCTAssertLessThan(worstAspect, 4)
  }

  func testTreemapHandlesEmptyAndZeroValues() {
    let bounds = Treemap.Rect(x: 0, y: 0, width: 100, height: 100)
    XCTAssertTrue(Treemap.layout([], in: bounds).isEmpty)
    XCTAssertEqual(Treemap.layout([0, 0], in: bounds).map(\.area), [0, 0])
  }

  func testProgressThrottleReportsFirstCallThenAtMostOncePerInterval() {
    final class Clock: @unchecked Sendable { var now: TimeInterval = 100 }
    let clock = Clock()
    var throttle = ProgressThrottle(interval: 0.2, now: { clock.now })
    XCTAssertTrue(throttle.shouldReport())
    clock.now += 0.05
    XCTAssertFalse(throttle.shouldReport())
    clock.now += 0.1
    XCTAssertFalse(throttle.shouldReport())
    clock.now += 0.06
    XCTAssertTrue(throttle.shouldReport())
    XCTAssertFalse(throttle.shouldReport())
  }

  func testStorageProgressIsThrottledWithoutLosingTheFinalCount() async throws {
    let root = makeTempDirectory()
    defer { try? fm.removeItem(at: root) }
    for index in 0..<200 { try write(root, "Many/\(index).txt", 1) }
    final class Reports: @unchecked Sendable {
      private let lock = NSLock()
      private var values: [Int] = []
      func append(_ value: Int) { lock.lock(); values.append(value); lock.unlock() }
      var all: [Int] { lock.lock(); defer { lock.unlock() }; return values }
    }
    let reports = Reports()
    let scan = await StorageTreeScanner().scan(root) { count, _ in reports.append(count) }
    XCTAssertEqual(scan.coverage.scannedItems, 201)
    XCTAssertFalse(reports.all.isEmpty, "Scans shorter than the old 500-item step still report progress")
    // The old scanner reported every 500 items regardless of speed; a fast local scan now
    // reports at most a handful of times per second.
    let seconds = max(scan.duration, 0.001)
    XCTAssertLessThanOrEqual(Double(reports.all.count), seconds / 0.2 + 1)
  }

  @discardableResult
  private func write(_ root: URL, _ relative: String, _ bytes: Int) throws -> URL {
    let url = root.appendingPathComponent(relative)
    try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(repeating: 7, count: bytes).write(to: url)
    return url
  }

  private func makeTempDirectory() -> URL {
    let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try! fm.createDirectory(at: root, withIntermediateDirectories: true)
    return root
  }
}
