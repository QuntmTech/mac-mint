import XCTest

@testable import MacCleanerCore

final class OrphanScannerTests: XCTestCase {
  private let fm = FileManager.default

  func testFindsDataForUninstalledAppsOnly() async throws {
    let home = makeTempDirectory()
    defer { try? fm.removeItem(at: home) }
    let apps = home.appendingPathComponent("Apps")
    try makeApp(apps, "Widget.app", id: "com.example.Widget", helpers: ["Contents/Library/LoginItems/Helper.app": "com.example.widgethelper"])

    try write(home, "Library/Preferences/com.example.Widget.plist")            // installed
    try write(home, "Library/Preferences/com.example.widgethelper.plist")      // installed helper
    try write(home, "Library/Caches/com.example.Widget.Extension/c")           // owned by installed prefix
    let gone = try write(home, "Library/Application Support/com.gone.Editor/data.db")  // orphan
    try write(home, "Library/Preferences/com.apple.finder.plist")              // Apple: never
    try write(home, "Library/Application Support/Google/cache.db")             // not a bundle id
    try write(home, "Library/Application Support/notes.v2.db")                 // not reverse-DNS

    let items = await scanner(home, apps: [apps]).scan().value
    XCTAssertEqual(items.map(\.bundleID), ["com.gone.editor"])
    XCTAssertEqual(items.first?.url.lastPathComponent, gone.deletingLastPathComponent().lastPathComponent)
    XCTAssertEqual(items.first?.location, "Application Support")
  }

  func testRecentOrSameVendorItemsAreLowConfidence() async throws {
    let home = makeTempDirectory()
    defer { try? fm.removeItem(at: home) }
    let apps = home.appendingPathComponent("Apps")
    try makeApp(apps, "Word.app", id: "com.vendor.word")
    let old = try write(home, "Library/Preferences/com.other.oldapp.plist")
    try age(old, days: 400)
    let sibling = try write(home, "Library/Preferences/com.vendor.removedapp.plist")
    try age(sibling, days: 400)
    try write(home, "Library/Preferences/com.other.freshapp.plist")

    let items = await scanner(home, apps: [apps]).scan().value
    let byID = Dictionary(uniqueKeysWithValues: items.map { ($0.bundleID, $0.confidence) })
    XCTAssertEqual(byID["com.other.oldapp"], .medium)
    XCTAssertEqual(byID["com.vendor.removedapp"], .low, "same developer as an installed app")
    XCTAssertEqual(byID["com.other.freshapp"], .low, "changed recently")
    XCTAssertEqual(items.first?.bundleID, "com.other.oldapp", "medium confidence sorts first")
  }

  func testRunningAppsAndExclusionsAreRespected() async throws {
    let home = makeTempDirectory()
    defer { try? fm.removeItem(at: home) }
    try write(home, "Library/Containers/com.cli.tool/data")
    let ignored = try write(home, "Library/Containers/com.ignored.app/data").deletingLastPathComponent()

    let items = await scanner(home, apps: []).scan(
      knownBundleIDs: ["com.cli.tool"], ignoredPaths: [ignored.standardizedFileURL.path]
    ).value
    XCTAssertTrue(items.isEmpty)
  }

  func testGroupContainerIdentifiers() {
    XCTAssertEqual(OrphanScanner.bundleID(fromName: "ABCDE12345.com.vendor.shared", inGroupContainers: true), "com.vendor.shared")
    XCTAssertEqual(OrphanScanner.bundleID(fromName: "group.com.vendor.app", inGroupContainers: true), "com.vendor.app")
    XCTAssertNil(OrphanScanner.bundleID(fromName: "Google", inGroupContainers: false))
    XCTAssertTrue(OrphanScanner.isProtected("com.apple.mail"))
  }

  func testExcludedLibraryRootsAndDescendantsAreNotMeasuredOrOfferedAsWholeOrphans() async throws {
    let home = makeTempDirectory()
    defer { try? fm.removeItem(at: home) }
    let excluded = try write(home, "Library/Caches/com.gone.editor/keep.db")
    let included = try write(home, "Library/Caches/com.other.app/data.db").deletingLastPathComponent()
    let report = await scanner(home, apps: []).scan(ignoredPaths: [excluded.path])
    XCTAssertEqual(report.value.map { $0.url.resolvingSymlinksInPath() }, [included.resolvingSymlinksInPath()])
    let preferences = try write(home, "Library/Preferences")
    let blocked = await scanner(home, apps: []).scan(ignoredPaths: [preferences.path])
    XCTAssertFalse(blocked.issues.contains { $0.path == preferences.path })
  }

  func testOrphanItemsPassTheAppLeftoverSafetyRule() async throws {
    let home = makeTempDirectory()
    defer { try? fm.removeItem(at: home) }
    try write(home, "Library/Application Support/com.gone.editor/data.db")
    let found = await scanner(home, apps: []).scan().value
    let item = try XCTUnwrap(found.first)
    XCTAssertTrue(SafetyPolicy(homeDirectory: home).appLeftoverDecision(for: item.url).allowed)
  }

  // MARK: Helpers

  func testVendorHelpersOutsideApplicationsCountAsInstalled() async throws {
    let home = makeTempDirectory()
    defer { try? fm.removeItem(at: home) }
    let support = home.appendingPathComponent("Library/Application Support")
    try makeApp(support.appendingPathComponent("JetBrains/Toolbox/apps"), "IDE.app", id: "com.jetbrains.ide")
    try write(home, "Library/Caches/com.jetbrains.ide/cache.bin")

    let items = await OrphanScanner(homeDirectory: home, applicationRoots: [], helperRoots: [support])
      .scan().value
    XCTAssertFalse(items.contains { $0.bundleID == "com.jetbrains.ide" })
  }

  private func scanner(_ home: URL, apps: [URL]) -> OrphanScanner {
    OrphanScanner(homeDirectory: home, applicationRoots: apps, helperRoots: [])
  }

  private func makeApp(_ root: URL, _ name: String, id: String, helpers: [String: String] = [:]) throws {
    let app = root.appendingPathComponent(name)
    try writePlist(app.appendingPathComponent("Contents/Info.plist"), id: id)
    for (relative, helperID) in helpers {
      try writePlist(app.appendingPathComponent(relative).appendingPathComponent("Contents/Info.plist"), id: helperID)
    }
  }

  private func writePlist(_ url: URL, id: String) throws {
    try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let data = try PropertyListSerialization.data(
      fromPropertyList: ["CFBundleIdentifier": id], format: .xml, options: 0)
    try data.write(to: url)
  }

  @discardableResult
  private func write(_ root: URL, _ relative: String) throws -> URL {
    let url = root.appendingPathComponent(relative)
    try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(repeating: 3, count: 4096).write(to: url)
    return url
  }

  private func age(_ url: URL, days: Double) throws {
    try fm.setAttributes([.modificationDate: Date().addingTimeInterval(-days * 86_400)], ofItemAtPath: url.path)
  }

  private func makeTempDirectory() -> URL {
    let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try! fm.createDirectory(at: root, withIntermediateDirectories: true)
    return root
  }
}

final class SystemJunkTests: XCTestCase {
  private let fm = FileManager.default

  func testFirmwareAndMailAttachmentsAreOfferedWithTheRightRisk() async throws {
    let home = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? fm.removeItem(at: home) }
    let ipsw = home.appendingPathComponent("Library/iTunes/iPhone Software Updates/iPhone17,1_26.0_Restore.ipsw")
    let signature = home.appendingPathComponent("Library/iTunes/iPhone Software Updates/iPhone.signature")
    let attachment = home.appendingPathComponent(
      "Library/Containers/com.apple.mail/Data/Library/Mail Downloads/1A2B/invoice.pdf")
    for url in [ipsw, signature, attachment] {
      try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      try Data(repeating: 1, count: 8192).write(to: url)
    }

    let targets = await CleanupScanner(catalog: CleanupCatalog(homeDirectory: home)).scanReport().value
    let firmware = targets.filter { $0.category == .deviceFirmware }
    XCTAssertEqual(firmware.map(\.url.lastPathComponent), [ipsw.lastPathComponent])
    XCTAssertEqual(firmware.first?.risk, .safe)
    let mail = targets.filter { $0.category == .mailAttachments }
    XCTAssertEqual(mail.map(\.url.lastPathComponent), ["1A2B"])
    XCTAssertEqual(mail.first?.risk, .review)
    XCTAssertEqual(mail.first?.isSelected, false)
  }

  func testJunkAllowlistsRejectOtherPaths() {
    let home = URL(fileURLWithPath: "/Users/t")
    let policy = SafetyPolicy(homeDirectory: home)
    let firmwareRoot = home.appendingPathComponent("Library/iTunes/iPhone Software Updates")
    XCTAssertTrue(policy.cleanupDecision(for: firmwareRoot.appendingPathComponent("x.ipsw"), category: .deviceFirmware).allowed)
    XCTAssertFalse(policy.cleanupDecision(for: firmwareRoot, category: .deviceFirmware).allowed, "never the folder itself")
    XCTAssertFalse(policy.cleanupDecision(for: firmwareRoot.appendingPathComponent("notes.txt"), category: .deviceFirmware).allowed)
    XCTAssertFalse(policy.cleanupDecision(for: home.appendingPathComponent("Downloads/x.ipsw"), category: .deviceFirmware).allowed)

    let mailRoot = home.appendingPathComponent("Library/Containers/com.apple.mail/Data/Library/Mail Downloads")
    XCTAssertTrue(policy.cleanupDecision(for: mailRoot.appendingPathComponent("ABC"), category: .mailAttachments).allowed)
    XCTAssertFalse(policy.cleanupDecision(for: mailRoot, category: .mailAttachments).allowed)
    XCTAssertFalse(
      policy.cleanupDecision(
        for: home.appendingPathComponent("Library/Containers/com.apple.mail/Data/Library/Mail/V10"),
        category: .mailAttachments
      ).allowed, "the mailbox store itself is never a target")
  }
}
