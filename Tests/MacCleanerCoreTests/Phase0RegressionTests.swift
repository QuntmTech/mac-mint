import XCTest

@testable import MacCleanerCore

#if canImport(Darwin)
  import Darwin
#elseif canImport(Glibc)
  import Glibc
#endif

/// Regression tests for the Phase 0 review findings: ownership matching, stale duplicate
/// removal, exclusion bypass, package sizing, hashing cost, silent permission failures,
/// and Trash receipts.
final class Phase0RegressionTests: XCTestCase {
  private let fm = FileManager.default

  // MARK: - SHA-256

  func testPortableSHA256KnownVectorsAcrossChunkBoundaries() {
    func digest(_ data: Data, chunk: Int) -> String {
      var hasher = PortableSHA256()
      var offset = 0
      while offset < data.count {
        let end = min(offset + chunk, data.count)
        hasher.update(data.subdata(in: offset..<end))
        offset = end
      }
      return hasher.finalizeHex()
    }
    XCTAssertEqual(
      digest(Data(), chunk: 1),
      "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
    let twoBlock = Data("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq".utf8)
    for chunk in [1, 7, 63, 64, 65, 1000] {
      XCTAssertEqual(
        digest(twoBlock, chunk: chunk),
        "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1")
    }
    let million = Data(repeating: UInt8(ascii: "a"), count: 1_000_000)
    XCTAssertEqual(
      digest(million, chunk: 4099),
      "cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0")
  }

  func testStreamingHasherMatchesPortableImplementation() {
    let bytes = Data((0..<(2 * 1_048_576 + 333)).map { UInt8(truncatingIfNeeded: $0 &* 31) })
    var portable = PortableSHA256()
    portable.update(bytes)
    XCTAssertEqual(SHA256.hexDigest(data: bytes), portable.finalizeHex())
  }

  // MARK: - App ownership

  func testSiblingBundleIDDataIsNotAttributedToApp() async throws {
    let home = makeTempDirectory()
    defer { try? fm.removeItem(at: home) }
    let ownPrefs = try makeFile(home, "Library/Preferences/com.example.widget.plist")
    _ = try makeFile(home, "Library/Preferences/com.example.widget.pro.plist")
    _ = try makeFile(home, "Library/Caches/com.example.widget.pro/data.bin")
    _ = try makeFile(home, "Library/Caches/com.example.widget.pro.helper/data.bin")

    let report = await AppScanner(homeDirectory: home, applicationRoots: []).leftoversReport(
      for: widgetApp(home), otherBundleIDs: ["com.example.widget.pro"])

    let paths = Set(report.value.map { $0.url.standardizedFileURL.path })
    XCTAssertEqual(paths, [ownPrefs.standardizedFileURL.path])
    XCTAssertEqual(report.value.first?.confidence, .high)
    XCTAssertEqual(report.value.first?.isSuggested, true)
  }

  func testExcludedSiblingAppStillProtectsItsData() async throws {
    let home = makeTempDirectory()
    defer { try? fm.removeItem(at: home) }
    let apps = home.appendingPathComponent("Applications")
    let pro = apps.appendingPathComponent("Widget Pro.app")
    try fm.createDirectory(at: pro.appendingPathComponent("Contents"), withIntermediateDirectories: true)
    try PropertyListSerialization.data(
      fromPropertyList: ["CFBundleIdentifier": "com.example.widget.pro"], format: .xml, options: 0
    ).write(to: pro.appendingPathComponent("Contents/Info.plist"))
    let ownPrefs = try makeFile(home, "Library/Preferences/com.example.widget.plist")
    _ = try makeFile(home, "Library/Caches/com.example.widget.pro/data.bin")

    // The caller only knows the visible (non-excluded) apps, so the excluded sibling is absent.
    let report = await AppScanner(homeDirectory: home, applicationRoots: [apps]).leftoversReport(
      for: widgetApp(home), otherBundleIDs: [], ignoredPaths: [pro.standardizedFileURL.path])

    XCTAssertEqual(Set(report.value.map { $0.url.standardizedFileURL.path }), [ownPrefs.standardizedFileURL.path])
  }

  func testHelperDataIsMediumConfidenceAndNotPreselected() async throws {
    let home = makeTempDirectory()
    defer { try? fm.removeItem(at: home) }
    _ = try makeFile(home, "Library/Caches/com.example.widget.updater/data.bin")

    let report = await AppScanner(homeDirectory: home, applicationRoots: []).leftoversReport(
      for: widgetApp(home))
    let match = try XCTUnwrap(report.value.first)
    XCTAssertEqual(match.confidence, .medium)
    XCTAssertFalse(match.isSuggested)
  }

  func testGroupContainersAreMarkedSharedAndNotPreselected() async throws {
    let home = makeTempDirectory()
    defer { try? fm.removeItem(at: home) }
    _ = try makeFile(home, "Library/Group Containers/ABCDE12345.com.example.widget/x.bin")
    _ = try makeFile(home, "Library/Group Containers/group.com.example.shared/x.bin")

    let report = await AppScanner(homeDirectory: home, applicationRoots: []).leftoversReport(
      for: widgetApp(home))
    XCTAssertEqual(report.value.count, 2)
    XCTAssertTrue(report.value.allSatisfy { $0.isShared && !$0.isSuggested })
  }

  // MARK: - Duplicates

  func testDuplicateVerifierRequiresLiveUnchangedKeeper() async throws {
    let root = makeTempDirectory()
    defer { try? fm.removeItem(at: root) }
    let content = Data(repeating: 7, count: 4096)
    let a = try makeFile(root, "a.bin", content)
    let b = try makeFile(root, "b.bin", content)
    let group = try await scanSingleGroup(root)

    // Keeper (a) is edited after the scan: removing b would lose the last original copy.
    try Data(repeating: 8, count: 4096).write(to: a)
    let selectB: Set<UUID> = Set(group.files.filter { $0.url.lastPathComponent == "b.bin" }.map(\.id))
    let plan = await DuplicateRemovalVerifier(safetyPolicy: SafetyPolicy(homeDirectory: root.deletingLastPathComponent()))
      .plan(groups: [group], selectedIDs: selectB)
    XCTAssertTrue(plan.approved.isEmpty)
    XCTAssertEqual(plan.skipped.map(\.url.lastPathComponent), ["b.bin"])
    XCTAssertTrue(fm.fileExists(atPath: b.path))
  }

  func testDuplicateVerifierSkipsChangedSelectionAndApprovesValidOne() async throws {
    let root = makeTempDirectory()
    defer { try? fm.removeItem(at: root) }
    let content = Data(repeating: 3, count: 4096)
    _ = try makeFile(root, "a.bin", content)
    _ = try makeFile(root, "b.bin", content)
    let c = try makeFile(root, "c.bin", content)
    let group = try await scanSingleGroup(root)
    try Data(repeating: 4, count: 4096).write(to: c)

    let selected = Set(group.files.filter { $0.url.lastPathComponent != "a.bin" }.map(\.id))
    let plan = await DuplicateRemovalVerifier(safetyPolicy: SafetyPolicy(homeDirectory: root.deletingLastPathComponent()))
      .plan(groups: [group], selectedIDs: selected)
    XCTAssertEqual(plan.approved.map(\.url.lastPathComponent), ["b.bin"])
    XCTAssertEqual(plan.skipped.map(\.url.lastPathComponent), ["c.bin"])
  }

  func testDuplicateVerifierRefusesWhenEveryCopyIsSelected() async throws {
    let root = makeTempDirectory()
    defer { try? fm.removeItem(at: root) }
    let content = Data(repeating: 5, count: 4096)
    _ = try makeFile(root, "a.bin", content)
    _ = try makeFile(root, "b.bin", content)
    let group = try await scanSingleGroup(root)

    let plan = await DuplicateRemovalVerifier(safetyPolicy: SafetyPolicy(homeDirectory: root.deletingLastPathComponent()))
      .plan(groups: [group], selectedIDs: Set(group.files.map(\.id)))
    XCTAssertTrue(plan.approved.isEmpty)
    XCTAssertEqual(plan.skipped.count, 2)
  }

  func testHardLinksAreNotReportedAsDuplicateSavings() async throws {
    let root = makeTempDirectory()
    defer { try? fm.removeItem(at: root) }
    let original = try makeFile(root, "original.bin", Data(repeating: 1, count: 4096))
    try fm.linkItem(at: original, to: root.appendingPathComponent("hardlink.bin"))

    let onlyLinks = await DuplicateFinder().find(in: [root], minimumSize: 1)
    XCTAssertTrue(onlyLinks.isEmpty, "Hard links to one file are not reclaimable duplicates")

    _ = try makeFile(root, "copy.bin", Data(repeating: 1, count: 4096))
    let groups = await DuplicateFinder().find(in: [root], minimumSize: 1)
    let group = try XCTUnwrap(groups.first)
    XCTAssertEqual(group.files.count, 3)
    XCTAssertEqual(group.physicalCopyCount, 2)
    XCTAssertEqual(group.reclaimableBytes, 4096)
  }

  // MARK: - Exclusions

  func testExcludedChildSplitsParentCacheInsteadOfIncludingIt() async throws {
    let home = makeTempDirectory()
    defer { try? fm.removeItem(at: home) }
    let keep = try makeFile(home, "Library/Caches/com.vendor.app/keep/important.db")
    _ = try makeFile(home, "Library/Caches/com.vendor.app/junk/a.bin")
    _ = try makeFile(home, "Library/Caches/com.vendor.app/b.bin")

    let ignored: Set<String> = [keep.deletingLastPathComponent().standardizedFileURL.path]
    let report = await CleanupScanner(catalog: CleanupCatalog(homeDirectory: home))
      .scanReport(ignoredPaths: ignored)
    let paths = report.value.map { $0.url.standardizedFileURL.path }

    let parent = home.appendingPathComponent("Library/Caches/com.vendor.app").standardizedFileURL.path
    XCTAssertFalse(paths.contains(parent))
    XCTAssertFalse(paths.contains { $0.hasPrefix(ignored.first!) })
    XCTAssertTrue(paths.contains(parent + "/junk"))
    XCTAssertTrue(paths.contains(parent + "/b.bin"))
  }

  func testCleanupEngineRefusesFolderContainingExcludedItem() async throws {
    let home = makeTempDirectory()
    defer { try? fm.removeItem(at: home) }
    let keep = try makeFile(home, "Library/Caches/com.vendor.app/keep.db")
    let folder = keep.deletingLastPathComponent()
    let target = CleanupTarget(
      category: .userCaches, url: folder, displayName: "com.vendor.app", size: 10, risk: .safe,
      reason: "test")
    let trash = MovingTrashService(trashDirectory: home.appendingPathComponent(".Trash"))
    let result = await CleanupEngine(trashService: trash, safetyPolicy: SafetyPolicy(homeDirectory: home))
      .execute([target], ignoredPaths: [keep.standardizedFileURL.path])

    XCTAssertTrue(result.movedToTrash.isEmpty)
    XCTAssertEqual(result.failed.count, 1)
    XCTAssertTrue(fm.fileExists(atPath: keep.path))
  }

  // MARK: - Sizing and access

  func testMeasureIncludesPackageContents() throws {
    let root = makeTempDirectory()
    defer { try? fm.removeItem(at: root) }
    _ = try makeFile(root, "Caches/Thing.app/Contents/Resources/big.bin", Data(repeating: 1, count: 64 * 1024))
    let measured = FileSystem.measure(at: root.appendingPathComponent("Caches"))
    XCTAssertGreaterThanOrEqual(measured.bytes, 64 * 1024)
    XCTAssertTrue(measured.isComplete)
  }

  func testUnreadableFolderIsReportedNotSilentlyEmpty() async throws {
    try XCTSkipIf(getuid() == 0, "Permission checks do not apply to root")
    let home = makeTempDirectory()
    let locked = home.appendingPathComponent("Library/Caches/com.locked.app")
    _ = try makeFile(home, "Library/Caches/com.locked.app/inner/secret.bin")
    _ = try makeFile(home, "Library/Caches/com.locked.app/visible.bin")
    let inner = locked.appendingPathComponent("inner")
    try fm.setAttributes([.posixPermissions: 0o000], ofItemAtPath: inner.path)
    defer {
      try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: inner.path)
      try? fm.removeItem(at: home)
    }

    let report = await CleanupScanner(catalog: CleanupCatalog(homeDirectory: home)).scanReport()
    // macOS reports /var temp paths as /private/var; compare resolved locations.
    let expected = locked.resolvingSymlinksInPath().path
    XCTAssertTrue(
      report.issues.contains {
        $0.path.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path } == expected
      },
      "Expected an access issue for \(locked.path), got \(report.issues)")
  }

  // MARK: - Receipts

  func testCleanupEngineRecordsTrashReceipts() async throws {
    let home = makeTempDirectory()
    defer { try? fm.removeItem(at: home) }
    let file = try makeFile(home, "Library/Caches/com.vendor.app/cache.bin")
    let target = CleanupTarget(
      category: .userCaches, url: file.deletingLastPathComponent(), displayName: "x", size: 10,
      risk: .safe, reason: "test")
    let trashDir = home.appendingPathComponent(".Trash")
    let result = await CleanupEngine(
      trashService: MovingTrashService(trashDirectory: trashDir),
      safetyPolicy: SafetyPolicy(homeDirectory: home)
    ).execute([target])

    let receipt = try XCTUnwrap(result.receipts.first)
    XCTAssertEqual(receipt.originalPath, file.deletingLastPathComponent().path)
    let trashPath = try XCTUnwrap(receipt.trashPath)
    XCTAssertTrue(fm.fileExists(atPath: trashPath))
    XCTAssertGreaterThan(receipt.bytes, 0)
  }

  // MARK: - Helpers

  private func widgetApp(_ home: URL) -> AppRecord {
    AppRecord(
      url: home.appendingPathComponent("Applications/Widget.app"), name: "Widget",
      bundleIdentifier: "com.example.widget", version: "1.0", bundleSize: 10, lastModified: nil)
  }

  private func scanSingleGroup(_ root: URL) async throws -> DuplicateGroup {
    let groups = await DuplicateFinder().find(in: [root], minimumSize: 1)
    XCTAssertEqual(groups.count, 1)
    return try XCTUnwrap(groups.first)
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

/// Test Trash that really moves items, so receipts and recovery can be checked.
actor MovingTrashService: TrashService {
  let trashDirectory: URL

  init(trashDirectory: URL) { self.trashDirectory = trashDirectory }

  func trash(_ url: URL) async throws -> URL? {
    try FileManager.default.createDirectory(at: trashDirectory, withIntermediateDirectories: true)
    var destination = trashDirectory.appendingPathComponent(url.lastPathComponent)
    var counter = 1
    while FileManager.default.fileExists(atPath: destination.path) {
      destination = trashDirectory.appendingPathComponent("\(url.lastPathComponent) \(counter)")
      counter += 1
    }
    try FileManager.default.moveItem(at: url, to: destination)
    return destination
  }
}
