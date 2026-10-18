import Foundation
import XCTest
@testable import MacCleanerCore

final class AppUninstallTests: XCTestCase {
  private let fm = FileManager.default
  private func root() throws -> URL {
    let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try fm.createDirectory(at: root, withIntermediateDirectories: true); return root
  }
  private func write(_ home: URL, _ path: String) throws -> URL {
    let url = home.appendingPathComponent(path)
    try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data([1, 2, 3]).write(to: url); return url
  }
  private func app(_ root: URL) -> AppRecord {
    .init(url: root.appendingPathComponent("Applications/Widget.app"), name: "Widget",
      bundleIdentifier: "com.example.Widget", version: "1", bundleSize: 100, lastModified: nil)
  }
  func testFindsCacheSettingsAndPerHostPreferencesWithConsequences() async throws {
    let root = try root(); defer { try? fm.removeItem(at: root) }
    let cache = try write(root, "Library/Caches/com.example.Widget/item")
    let settings = try write(root, "Library/Preferences/com.example.Widget.plist")
    let byHost = try write(root, "Library/Preferences/ByHost/com.example.Widget.\(UUID().uuidString).plist")
    let items = await AppScanner(homeDirectory: root, applicationRoots: []).leftovers(for: app(root))
    XCTAssertEqual(items.count, 3)
    XCTAssertEqual(items.first { $0.url == cache.deletingLastPathComponent() }?.category, .caches)
    XCTAssertEqual(items.first { $0.url == settings }?.category, .settings)
    XCTAssertEqual(items.first { $0.url == byHost }?.confidence, .high)
    XCTAssertTrue(items.filter(\.isDisposableData).allSatisfy { $0.category == .caches })
  }
  func testExcludedDescendantAndSymlinkDoNotBecomeSelectedAppData() async throws {
    let root = try root(); defer { try? fm.removeItem(at: root) }
    let excluded = try write(root, "Library/Caches/com.example.Widget/keep.bin")
    let external = try write(root, "Personal/Widget/data")
    let alias = root.appendingPathComponent("Library/Application Support/Widget")
    try fm.createDirectory(at: alias.deletingLastPathComponent(), withIntermediateDirectories: true)
    try fm.createSymbolicLink(at: alias, withDestinationURL: external.deletingLastPathComponent())
    let items = await AppScanner(homeDirectory: root, applicationRoots: []).leftovers(
      for: app(root), ignoredPaths: [excluded.path])
    XCTAssertTrue(items.isEmpty)
  }
  func testAnotherInstalledCopyMakesAllSharedDataExplicitOptIn() async throws {
    let root = try root(); defer { try? fm.removeItem(at: root) }
    _ = try write(root, "Library/Caches/com.example.Widget/item")
    let report = await AppScanner(homeDirectory: root, applicationRoots: []).leftoversReport(
      for: app(root), hasOtherInstallation: true)
    XCTAssertEqual(report.value.count, 1)
    XCTAssertTrue(report.value.allSatisfy { $0.isShared && !$0.isSuggested })
  }
  func testNestedAppCannotBeUninstalledSeparately() throws {
    let root = try root(); defer { try? fm.removeItem(at: root) }
    let policy = SafetyPolicy(homeDirectory: root)
    XCTAssertFalse(policy.appBundleDecision(for: root.appendingPathComponent("Applications/Outer.app/Contents/Helpers/Inner.app")).allowed)
    XCTAssertTrue(policy.appBundleDecision(for: root.appendingPathComponent("Applications/Standalone.app")).allowed)
  }
  func testReviewedUninstallMovesAppAndDataButLeavesUnselectedSettings() async throws {
    let root = try root(); defer { try? fm.removeItem(at: root) }
    let bundle = try write(root, "Applications/Widget.app/Contents/Info.plist").deletingLastPathComponent().deletingLastPathComponent()
    let cache = try write(root, "Library/Caches/com.example.Widget/cache").deletingLastPathComponent()
    let settings = try write(root, "Library/Preferences/com.example.Widget.plist")
    let bundleItem = PlanItem(url: bundle, displayName: "Widget", kind: .appBundle, expectedBytes: 3,
      reason: "Uninstall", source: "Apps", identity: FileSystem.fileIdentity(at: bundle))
    let data = PlanItem(url: cache, displayName: "Cache", kind: .appLeftover, expectedBytes: 3,
      reason: "Rebuildable", source: "Apps", dependsOn: bundleItem.id, identity: FileSystem.fileIdentity(at: cache))
    let trash = FixtureTrash(root: root.appendingPathComponent(".Trash"))
    let report = await OperationExecutor(trashService: trash, safetyPolicy: .init(homeDirectory: root),
      journalDirectory: root.appendingPathComponent("journal")).run(OperationPlanner.plan(title: "Uninstall", items: [bundleItem, data]))
    XCTAssertEqual(report.moved.count, 2); XCTAssertEqual(report.receipts.count, 2)
    XCTAssertTrue(fm.fileExists(atPath: settings.path)); XCTAssertFalse(fm.fileExists(atPath: bundle.path))
  }
}

private struct FixtureTrash: TrashService {
  let root: URL
  func trash(_ url: URL) async throws -> URL? {
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let target = root.appendingPathComponent(UUID().uuidString + "-" + url.lastPathComponent)
    try FileManager.default.moveItem(at: url, to: target)
    return target
  }
}
