import XCTest

@testable import MacCleanerCore

final class MacCleanerCoreTests: XCTestCase {
  func testSHA256KnownVector() {
    XCTAssertEqual(
      SHA256.hexDigest(data: Data("abc".utf8)),
      "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
    )
  }

  func testStreamingSHA256MatchesInMemoryDigest() throws {
    let root = makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let bytes = Data((0..<(3 * 1_048_576 + 137)).map { UInt8($0 % 251) })
    let file = root.appendingPathComponent("large.bin")
    try bytes.write(to: file)
    XCTAssertEqual(try SHA256.hexDigest(file: file), SHA256.hexDigest(data: bytes))
  }

  func testStreamingSHA256HonorsCancellation() async throws {
    let root = makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("cancel.bin")
    try Data(repeating: 0x5A, count: 8 * 1_048_576).write(to: file)

    let task = Task { try SHA256.hexDigest(file: file) }
    task.cancel()

    do {
      _ = try await task.value
      XCTFail("Expected hashing to honor task cancellation")
    } catch is CancellationError {
      // Expected.
    }
  }

  func testSafetyPolicyBlocksPersonalFoldersAndSystem() {
    let home = URL(fileURLWithPath: "/Users/tester")
    let policy = SafetyPolicy(homeDirectory: home)
    XCTAssertFalse(
      policy.deletionDecision(for: URL(fileURLWithPath: "/System/Library/foo")).allowed)
    XCTAssertFalse(
      policy.deletionDecision(for: home.appendingPathComponent("Documents/tax.pdf")).allowed)
    XCTAssertTrue(
      policy.deletionDecision(for: home.appendingPathComponent("Library/Caches/foo")).allowed)
  }

  func testReviewedSafetyAllowsPersonalFilesButBlocksLibrary() {
    let home = URL(fileURLWithPath: "/Users/tester")
    let policy = SafetyPolicy(homeDirectory: home)
    XCTAssertTrue(
      policy.reviewedFileDecision(for: home.appendingPathComponent("Documents/video.mov")).allowed)
    XCTAssertFalse(
      policy.reviewedFileDecision(
        for: home.appendingPathComponent("Library/Application Support/app.db")
      ).allowed)
    XCTAssertFalse(
      policy.reviewedFileDecision(for: URL(fileURLWithPath: "/Library/LaunchDaemons/test.plist"))
        .allowed)
  }

  func testCleanupTargetPolicyRejectsCategoryPathMismatch() {
    let home = URL(fileURLWithPath: "/Users/tester")
    let policy = SafetyPolicy(homeDirectory: home)
    let malformed = CleanupTarget(
      category: .userCaches,
      url: home.appendingPathComponent(".ssh/config"),
      displayName: "config",
      size: 100,
      risk: .safe,
      reason: "malformed test target",
      isSelected: true
    )
    XCTAssertFalse(policy.cleanupTargetDecision(for: malformed).allowed)

    let legitimate = CleanupTarget(
      category: .userCaches,
      url: home.appendingPathComponent("Library/Caches/com.example.app"),
      displayName: "com.example.app",
      size: 100,
      risk: .safe,
      reason: "cache",
      isSelected: true
    )
    XCTAssertTrue(policy.cleanupTargetDecision(for: legitimate).allowed)
  }

  func testDeveloperCacheCatalogPathsPassCategorySafety() {
    let home = URL(fileURLWithPath: "/Users/tester")
    let policy = SafetyPolicy(homeDirectory: home)
    let paths = [
      "Library/Caches/pip",
      "Library/Caches/CocoaPods",
      "Library/Caches/Yarn",
      "Library/Caches/org.swift.swiftpm",
    ]

    for path in paths {
      let target = CleanupTarget(
        category: .developerJunk,
        url: home.appendingPathComponent(path),
        displayName: path,
        size: 1,
        risk: .safe,
        reason: "regenerable developer cache",
        isSelected: true
      )
      XCTAssertTrue(policy.cleanupTargetDecision(for: target).allowed, path)
    }
  }

  func testInstallerPolicyRequiresDownloadsAndApprovedExtension() {
    let home = URL(fileURLWithPath: "/Users/tester")
    let policy = SafetyPolicy(homeDirectory: home)
    let valid = CleanupTarget(
      category: .installers, url: home.appendingPathComponent("Downloads/old.dmg"),
      displayName: "old.dmg", size: 1, risk: .review, reason: "installer", isSelected: true)
    let wrongFolder = CleanupTarget(
      category: .installers, url: home.appendingPathComponent("Documents/old.dmg"),
      displayName: "old.dmg", size: 1, risk: .review, reason: "installer", isSelected: true)
    let wrongType = CleanupTarget(
      category: .installers, url: home.appendingPathComponent("Downloads/notes.txt"),
      displayName: "notes.txt", size: 1, risk: .review, reason: "installer", isSelected: true)
    XCTAssertTrue(policy.cleanupTargetDecision(for: valid).allowed)
    XCTAssertFalse(policy.cleanupTargetDecision(for: wrongFolder).allowed)
    XCTAssertFalse(policy.cleanupTargetDecision(for: wrongType).allowed)
  }

  func testDuplicateFinderFindsExactDuplicates() async throws {
    let root = makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let data = Data(repeating: 0x41, count: 2_000_000)
    try data.write(to: root.appendingPathComponent("a.bin"))
    try data.write(to: root.appendingPathComponent("b.bin"))
    try Data(repeating: 0x42, count: 2_000_000).write(to: root.appendingPathComponent("c.bin"))
    let groups = await DuplicateFinder().find(in: [root], minimumSize: 1)
    XCTAssertEqual(groups.count, 1)
    XCTAssertEqual(groups.first?.files.count, 2)
  }

  func testDuplicateFinderHonorsIgnoredPaths() async throws {
    let root = makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let ignored = root.appendingPathComponent("Ignored")
    try FileManager.default.createDirectory(at: ignored, withIntermediateDirectories: true)
    let data = Data(repeating: 7, count: 1_200_000)
    try data.write(to: root.appendingPathComponent("keep.bin"))
    try data.write(to: ignored.appendingPathComponent("skip.bin"))

    let groups = await DuplicateFinder().find(
      in: [root],
      minimumSize: 1,
      ignoredPaths: [ignored.standardizedFileURL.path]
    )
    XCTAssertTrue(groups.isEmpty)
  }

  func testCleanupScannerDoesNotSelectReviewItems() async throws {
    let home = makeTempDirectory()
    let archive = home.appendingPathComponent("Library/Developer/Xcode/Archives")
    try FileManager.default.createDirectory(at: archive, withIntermediateDirectories: true)
    try Data(repeating: 1, count: 1024).write(to: archive.appendingPathComponent("archive.dat"))
    defer { try? FileManager.default.removeItem(at: home) }
    let scanner = CleanupScanner(catalog: CleanupCatalog(homeDirectory: home))
    let targets = await scanner.scan()
    let item = try XCTUnwrap(targets.first(where: { $0.displayName == "Xcode Archives" }))
    XCTAssertEqual(item.risk, .review)
    XCTAssertFalse(item.isSelected)
  }

  func testCleanupScannerKeepsDeveloperCachesInDeveloperCategory() async throws {
    let home = makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: home) }
    let pip = home.appendingPathComponent("Library/Caches/pip")
    try FileManager.default.createDirectory(at: pip, withIntermediateDirectories: true)
    try Data(repeating: 2, count: 1024).write(to: pip.appendingPathComponent("wheel.bin"))

    let scanner = CleanupScanner(catalog: CleanupCatalog(homeDirectory: home))
    let targets = await scanner.scan()
    let target = try XCTUnwrap(
      targets.first { $0.url.standardizedFileURL.path == pip.standardizedFileURL.path }
    )
    XCTAssertEqual(target.category, .developerJunk)
  }

  func testCleanupScannerHonorsIgnoredPaths() async throws {
    let home = makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: home) }
    let cache = home.appendingPathComponent("Library/Caches/TestApp")
    try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
    try Data(repeating: 1, count: 4096).write(to: cache.appendingPathComponent("cache.bin"))

    let scanner = CleanupScanner(catalog: CleanupCatalog(homeDirectory: home))
    let targets = await scanner.scan(ignoredPaths: [cache.standardizedFileURL.path])
    XCTAssertFalse(targets.contains { $0.url.standardizedFileURL == cache.standardizedFileURL })
  }

  func testIgnoreStorePersistsAndRemovesPath() async throws {
    let root = makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = IgnoreStore(url: root.appendingPathComponent("ignore.json"))
    let path = root.appendingPathComponent("DoNotScan")

    let afterAdd = try await store.add(path)
    XCTAssertTrue(afterAdd.contains(path.standardizedFileURL.path))
    let persisted = await store.load()
    XCTAssertTrue(persisted.contains(path.standardizedFileURL.path))

    let afterRemove = try await store.remove(path: path.path)
    XCTAssertFalse(afterRemove.contains(path.standardizedFileURL.path))
  }

  func testAppScannerUsesBundleIdentifierForHighConfidenceLeftover() async throws {
    let home = makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: home) }
    let cache = home.appendingPathComponent("Library/Caches/com.example.Widget")
    try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
    try Data(repeating: 9, count: 2048).write(to: cache.appendingPathComponent("data.bin"))

    let app = AppRecord(
      url: home.appendingPathComponent("Applications/Widget.app"),
      name: "Widget",
      bundleIdentifier: "com.example.Widget",
      version: "1.0",
      bundleSize: 10,
      lastModified: nil
    )
    let report = await AppScanner(homeDirectory: home, applicationRoots: []).leftoversReport(
      for: app)
    let match = try XCTUnwrap(
      report.value.first(where: {
        $0.url.standardizedFileURL.path == cache.standardizedFileURL.path
      }))
    XCTAssertEqual(match.confidence, .high)
  }

  func testAppScannerDoesNotTreatLongerBundleIDAsExactMatch() async throws {
    let home = makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: home) }
    let unrelated = home.appendingPathComponent("Library/Caches/com.example.WidgetPro")
    try FileManager.default.createDirectory(at: unrelated, withIntermediateDirectories: true)
    try Data(repeating: 4, count: 512).write(to: unrelated.appendingPathComponent("data.bin"))

    let app = AppRecord(
      url: home.appendingPathComponent("Applications/Widget.app"),
      name: "Widget",
      bundleIdentifier: "com.example.Widget",
      version: "1.0",
      bundleSize: 10,
      lastModified: nil
    )
    let report = await AppScanner(homeDirectory: home, applicationRoots: []).leftoversReport(
      for: app)
    XCTAssertFalse(report.value.contains { $0.confidence == .high })
  }

  func testLargeFileFinderExcludesProtectedRoot() async throws {
    let root = makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let library = root.appendingPathComponent("Library")
    let docs = root.appendingPathComponent("Documents")
    try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: docs, withIntermediateDirectories: true)
    try Data(repeating: 1, count: 4096).write(to: library.appendingPathComponent("private.bin"))
    try Data(repeating: 2, count: 4096).write(to: docs.appendingPathComponent("visible.bin"))

    let files = await LargeFileFinder().find(in: [root], minimumSize: 1, excludedRoots: [library])
    XCTAssertEqual(files.count, 1)
    XCTAssertEqual(files.first?.url.lastPathComponent, "visible.bin")
  }

  func testCleanupEngineRejectsPersonalFileEvenIfTargetIsSelected() async throws {
    let home = makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: home) }
    let personal = home.appendingPathComponent("Documents/important.txt")
    try FileManager.default.createDirectory(
      at: personal.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("important".utf8).write(to: personal)

    let target = CleanupTarget(
      category: .userCaches,
      url: personal,
      displayName: "important.txt",
      size: 9,
      risk: .safe,
      reason: "malformed test target",
      isSelected: true
    )
    let trash = RecordingTrashService()
    let engine = CleanupEngine(trashService: trash, safetyPolicy: SafetyPolicy(homeDirectory: home))
    let result = await engine.execute([target])

    XCTAssertTrue(result.movedToTrash.isEmpty)
    XCTAssertEqual(result.failed.count, 1)
    let trashedURLs = await trash.urls
    XCTAssertTrue(trashedURLs.isEmpty)
    XCTAssertTrue(FileManager.default.fileExists(atPath: personal.path))
  }

  private func makeTempDirectory() -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try! FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
  }
}

private actor RecordingTrashService: TrashService {
  private(set) var urls: [URL] = []

  func trash(_ url: URL) async throws -> URL? {
    urls.append(url)
    return nil
  }
}
