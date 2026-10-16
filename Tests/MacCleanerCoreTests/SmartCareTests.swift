import XCTest

@testable import MacCleanerCore

final class SmartCareTests: XCTestCase {
  private let fm = FileManager.default
  private let now = Date(timeIntervalSince1970: 1_800_000_000)
  private func daysAgo(_ days: Double) -> Date { now.addingTimeInterval(-days * 86_400) }

  // MARK: Usage evidence

  func testUnknownUsageIsNeverIdle() {
    XCTAssertNil(UsageEvidence.unknown.idleDays(now: now))
    XCTAssertFalse(UsageEvidence.unknown.neverOpened)
    let opened = UsageEvidence(lastUsed: daysAgo(40), added: daysAgo(400), useCount: 3, isIndexed: true)
    XCTAssertEqual(opened.idleDays(now: now), 40)
    let never = UsageEvidence(added: daysAgo(200), useCount: 0, isIndexed: true)
    XCTAssertTrue(never.neverOpened)
    XCTAssertEqual(never.idleDays(now: now), 200)
  }

  func testRelativeAgeWording() {
    XCTAssertEqual(RelativeAge.describe(days: 0), "today")
    XCTAssertEqual(RelativeAge.describe(days: 12), "12 days")
    XCTAssertEqual(RelativeAge.describe(days: 180), "6 months")
    XCTAssertEqual(RelativeAge.describe(days: 800), "2 years")
  }

  func testDownloadSourceKeepsOnlyTheHost() {
    XCTAssertEqual(SpotlightUsage.host("https://www.example.com/file.dmg?token=secret"), "example.com")
    XCTAssertNil(SpotlightUsage.host("not a url"))
  }

  // MARK: Downloads

  func testDownloadsScannerUsesEvidenceAndSkipsRecentSmallAndPartial() async throws {
    let downloads = makeTempDirectory()
    defer { try? fm.removeItem(at: downloads) }
    let never = try write(downloads, "Installer.dmg", mb: 30)
    let recent = try write(downloads, "Recent.zip", mb: 30)
    // Well under 5 MB even where corelibs over-reports allocation (Linux).
    let small = try write(downloads, "note.pdf", kb: 100)
    let partial = try write(downloads, "big.mov.crdownload", mb: 30)
    let unindexedOld = try write(downloads, "Old.mov", mb: 30)
    try age(unindexedOld, days: 500)

    let usage = StaticUsage([
      never.path: UsageEvidence(added: daysAgo(200), useCount: 0, source: "example.com", isIndexed: true),
      recent.path: UsageEvidence(lastUsed: daysAgo(3), added: daysAgo(300), isIndexed: true),
      small.path: UsageEvidence(added: daysAgo(400), isIndexed: true),
      partial.path: UsageEvidence(added: daysAgo(400), isIndexed: true),
    ])
    let fixedNow = now
    let report = await DownloadsScanner(downloadsDirectory: downloads, usage: usage, now: { fixedNow })
      .scan()
    let byName = Dictionary(uniqueKeysWithValues: report.value.map { ($0.url.lastPathComponent, $0) })
    XCTAssertEqual(Set(byName.keys), ["Installer.dmg", "Old.mov"])
    XCTAssertEqual(byName["Installer.dmg"]?.kind, .installer)
    XCTAssertEqual(byName["Installer.dmg"]?.evidence, "Downloaded 7 months ago from example.com with no recorded opens")
    XCTAssertFalse(byName["Old.mov"]!.usage.neverOpened, "no Spotlight record is not 'never opened'")
    XCTAssertTrue(byName["Old.mov"]!.evidence.hasPrefix("Not changed in"))
  }

  func testDownloadPlanItemsNeedAttentionAndCarrySnapshots() throws {
    let item = DownloadItem(
      url: URL(fileURLWithPath: "/Users/u/Downloads/a.zip"), kind: .archive, bytes: 100,
      usage: .unknown, modified: daysAgo(400), logicalSize: 99, identity: "1:2", idleDays: 400)
    let plan = PlanItem.download(item)
    XCTAssertTrue(plan.needsAttention)
    XCTAssertEqual(plan.kind, .reviewedFile)
    XCTAssertEqual(plan.snapshot?.size, 99)
    XCTAssertEqual(plan.identity, "1:2")
    XCTAssertTrue(SafetyPolicy(homeDirectory: URL(fileURLWithPath: "/Users/u")).reviewedFileDecision(for: plan.url).allowed)
  }

  // MARK: Unused apps

  func testAppScannerRecordsLastUsedFromSpotlightOnly() async throws {
    let root = makeTempDirectory()
    defer { try? fm.removeItem(at: root) }
    let app = root.appendingPathComponent("Old.app")
    try fm.createDirectory(at: app.appendingPathComponent("Contents"), withIntermediateDirectories: true)
    let usage = StaticUsage([app.path: UsageEvidence(lastUsed: daysAgo(300), isIndexed: true)])
    let apps = await AppScanner(homeDirectory: root, applicationRoots: [root], usage: usage).installedApps()
    XCTAssertEqual(apps.first?.lastUsed, daysAgo(300))
  }

  // MARK: Recommendations

  func testRecommendationsRankByConfidenceWeightedBytesAndNeverDoubleCount() {
    var inputs = RecommendationEngine.Inputs()
    inputs.now = now
    let cache = target(.userCaches, "/Users/u/Library/Caches/com.a", mb: 500, risk: .safe)
    inputs.cleanupTargets = [cache, target(.mailAttachments, "/Users/u/Library/Containers/com.apple.mail/Data/Library/Mail Downloads/X", mb: 300, risk: .review)]
    let neverOpened = download("/Users/u/Downloads/big.mov", mb: 900, neverOpened: true)
    inputs.downloads = [neverOpened, download("/Users/u/Downloads/stale.zip", mb: 200, neverOpened: false, idle: 500)]
    inputs.apps = [
      app("Old", id: "com.vendor.old", mb: 400, lastUsed: daysAgo(400)),
      app("Unknown", id: "com.vendor.unknown", mb: 900, lastUsed: nil),
      app("Safari", id: "com.apple.Safari", mb: 100, lastUsed: daysAgo(900)),
    ]
    inputs.trashBytes = 1_500 * 1_048_576

    let recs = RecommendationEngine.recommend(inputs)
    let ids = recs.map(\.id)
    // 900 MB × 0.6 (likely) = 540 ranks above 500 MB × 1.0 (safe) = 500; trash 1.5 GB × 0.3 = 450.
    XCTAssertEqual(Array(ids.prefix(3)), ["downloads-never-opened", "caches", "trash"])
    let unused = recs.first { $0.id == "unused-apps" }
    XCTAssertEqual(unused?.count, 1, "unknown last-used and Apple apps are never 'unused'")
    XCTAssertTrue(unused?.items.isEmpty ?? false, "uninstalls are reviewed per app")
    let paths = recs.flatMap(\.items).map(\.url.path)
    XCTAssertEqual(paths.count, Set(paths).count, "each path appears in one recommendation only")
    XCTAssertTrue(recs.flatMap(\.items).allSatisfy { $0.kind != .appBundle })
  }

  func testTinyRecommendationsAreDropped() {
    var inputs = RecommendationEngine.Inputs()
    inputs.cleanupTargets = [target(.userCaches, "/Users/u/Library/Caches/tiny", mb: 1, risk: .safe)]
    XCTAssertTrue(RecommendationEngine.recommend(inputs).isEmpty)
  }

  func testSafeItemsOnlyIncludesSafeRecommendations() {
    var inputs = RecommendationEngine.Inputs()
    inputs.now = now
    inputs.cleanupTargets = [target(.userCaches, "/Users/u/Library/Caches/com.a", mb: 100, risk: .safe)]
    inputs.downloads = [download("/Users/u/Downloads/a.mov", mb: 100, neverOpened: true)]
    let safe = RecommendationEngine.safeItems(RecommendationEngine.recommend(inputs))
    XCTAssertEqual(safe.map(\.url.lastPathComponent), ["com.a"])
  }

  // MARK: Growth + history

  func testGrowthPointsAtTheMostSpecificFolder() {
    let old = StorageSnapshot(
      takenAt: daysAgo(7), root: "/Users/u",
      folders: ["/Users/u": 100_000, "/Users/u/Library": 50_000, "/Users/u/Library/Caches": 10_000,
                "/Users/u/Movies": 20_000])
    let new = StorageSnapshot(
      takenAt: now, root: "/Users/u",
      folders: ["/Users/u": 160_000, "/Users/u/Library": 100_000, "/Users/u/Library/Caches": 58_000,
                "/Users/u/Movies": 30_000, "/Users/u/Projects": 1_000])
    let growth = StorageGrowthAnalyzer.growth(from: old, to: new, minimumDelta: 5_000)
    XCTAssertEqual(growth.map(\.path), ["/Users/u/Library/Caches", "/Users/u/Movies"])
    XCTAssertEqual(growth.first?.delta, 48_000)
  }

  func testSnapshotFromTreeKeepsMeaningfulFolders() {
    let leaf = StorageNode(url: URL(fileURLWithPath: "/r/a/b"), kind: .folder, allocatedBytes: 80, logicalBytes: 80, itemCount: 1)
    let small = StorageNode(url: URL(fileURLWithPath: "/r/s"), kind: .folder, allocatedBytes: 5, logicalBytes: 5, itemCount: 1)
    let a = StorageNode(url: URL(fileURLWithPath: "/r/a"), kind: .folder, allocatedBytes: 80, logicalBytes: 80, itemCount: 1, children: [leaf])
    let root = StorageNode(url: URL(fileURLWithPath: "/r"), kind: .folder, allocatedBytes: 85, logicalBytes: 85, itemCount: 2, children: [a, small])
    let snapshot = StorageSnapshot(tree: root, takenAt: now, maxDepth: 1, minimumBytes: 10)
    XCTAssertEqual(Set(snapshot.folders.keys), ["/r", "/r/a"])
  }

  func testSnapshotStoreIsBoundedPerRoot() async throws {
    let dir = makeTempDirectory()
    defer { try? fm.removeItem(at: dir) }
    let store = StorageSnapshotStore(url: dir.appendingPathComponent("snapshots.json"), limit: 3)
    for i in 0..<5 {
      try await store.append(StorageSnapshot(takenAt: daysAgo(Double(10 - i)), root: "/a", folders: ["/a": Int64(i)]))
    }
    try await store.append(StorageSnapshot(takenAt: now, root: "/b", folders: [:]))
    let all = await store.load()
    XCTAssertEqual(all.filter { $0.root == "/a" }.count, 3)
    let previous = await store.previous(root: "/a")
    XCTAssertEqual(previous?.folders["/a"], 4)
  }

  func testSpaceHistoryKeepsOneSamplePerDayWithinRetention() async throws {
    let dir = makeTempDirectory()
    defer { try? fm.removeItem(at: dir) }
    let store = SpaceHistoryStore(url: dir.appendingPathComponent("space.json"), retentionDays: 30)
    try await store.record(freeBytes: 100, totalBytes: 1000, at: daysAgo(40))
    try await store.record(freeBytes: 500, totalBytes: 1000, at: daysAgo(10))
    try await store.record(freeBytes: 300, totalBytes: 1000, at: now)
    let samples = try await store.record(freeBytes: 250, totalBytes: 1000, at: now.addingTimeInterval(60))
    XCTAssertEqual(samples.map(\.freeBytes), [500, 250], "old sample expired; today's latest wins")
    XCTAssertEqual(SpaceTrend.freeSpaceChange(samples, days: 30, now: now), -250)
    XCTAssertNil(SpaceTrend.freeSpaceChange([samples[1]], days: 30, now: now))
  }

  // MARK: Helpers

  private func target(_ category: CleanupCategory, _ path: String, mb: Int64, risk: CleanupRisk) -> CleanupTarget {
    CleanupTarget(
      category: category, url: URL(fileURLWithPath: path), displayName: URL(fileURLWithPath: path).lastPathComponent,
      size: mb * 1_048_576, risk: risk, reason: "test")
  }

  private func download(_ path: String, mb: Int64, neverOpened: Bool, idle: Int = 200) -> DownloadItem {
    DownloadItem(
      url: URL(fileURLWithPath: path), kind: DownloadKind.of(URL(fileURLWithPath: path), isDirectory: false),
      bytes: mb * 1_048_576,
      usage: neverOpened
        ? UsageEvidence(added: daysAgo(Double(idle)), useCount: 0, isIndexed: true)
        : UsageEvidence(lastUsed: daysAgo(Double(idle)), isIndexed: true),
      modified: daysAgo(Double(idle)), logicalSize: mb * 1_048_576, identity: nil, idleDays: idle)
  }

  private func app(_ name: String, id: String, mb: Int64, lastUsed: Date?) -> AppRecord {
    AppRecord(
      url: URL(fileURLWithPath: "/Applications/\(name).app"), name: name, bundleIdentifier: id,
      version: "1", bundleSize: mb * 1_048_576, lastModified: nil, lastUsed: lastUsed)
  }

  @discardableResult
  private func write(_ dir: URL, _ name: String, mb: Int = 0, kb: Int = 0) throws -> URL {
    let url = dir.appendingPathComponent(name)
    try Data(repeating: 1, count: mb * 1_048_576 + kb * 1024).write(to: url)
    return url
  }

  private func age(_ url: URL, days: Double) throws {
    try fm.setAttributes([.modificationDate: daysAgo(days)], ofItemAtPath: url.path)
  }

  private func makeTempDirectory() -> URL {
    let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try! fm.createDirectory(at: root, withIntermediateDirectories: true)
    return root
  }
}
