import XCTest

@testable import MacCleanerCore

final class AppCacheTests: XCTestCase {
  private let fm = FileManager.default

  private func makeHome() throws -> URL {
    let home = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try fm.createDirectory(at: home, withIntermediateDirectories: true)
    return home
  }

  private func folder(_ home: URL, _ relative: String) throws {
    let url = home.appendingPathComponent(relative)
    try fm.createDirectory(at: url, withIntermediateDirectories: true)
    try Data(repeating: 1, count: 4096).write(to: url.appendingPathComponent("blob"))
  }

  func testVSCodeKeepsTheCurrentVersionsCodeCacheAndNeverTouchesSettingsOrExtensions() async throws {
    let home = try makeHome()
    defer { try? fm.removeItem(at: home) }
    let code = "Library/Application Support/Code"
    for path in ["Cache", "CachedData/oldcommit", "CachedData/currentcommit", "CachedExtensionVSIXs", "User", "WebStorage"] {
      try folder(home, "\(code)/\(path)")
    }
    let apps = home.appendingPathComponent("Apps")
    let product = apps.appendingPathComponent("Visual Studio Code.app/Contents/Resources/app/product.json")
    try fm.createDirectory(at: product.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(#"{"commit":"currentcommit"}"#.utf8).write(to: product)

    let catalog = CleanupCatalog(homeDirectory: home)
    let rules = catalog.appCacheRules(applicationRoots: [apps])
    XCTAssertEqual(rules.first { $0.name == "VS Code code caches" }?.excludedChildNames, ["currentcommit"])
    XCTAssertTrue(rules.allSatisfy { $0.ownerBundleID == CleanupCatalog.vsCodeBundleID })
    XCTAssertFalse(rules.contains { ["User", "WebStorage"].contains($0.url.lastPathComponent) })

    let policy = SafetyPolicy(homeDirectory: home)
    func allowed(_ relative: String) -> Bool {
      policy.cleanupDecision(for: home.appendingPathComponent("\(code)/\(relative)"), category: .appCaches).allowed
    }
    XCTAssertTrue(allowed("Cache"))
    XCTAssertTrue(allowed("CachedData/oldcommit"))
    XCTAssertTrue(allowed("CachedExtensionVSIXs"))
    XCTAssertFalse(allowed("User"))
    XCTAssertFalse(allowed("CachedData"), "The folder itself, not just old versions in it")
    XCTAssertFalse(policy.cleanupDecision(for: home.appendingPathComponent(code), category: .appCaches).allowed)
  }

  func testUnknownVSCodeVersionMakesCodeCachesReviewOnly() throws {
    let home = try makeHome()
    defer { try? fm.removeItem(at: home) }
    try folder(home, "Library/Application Support/Code/CachedData/abc")
    let rule = CleanupCatalog(homeDirectory: home).appCacheRules(applicationRoots: [])
      .first { $0.name == "VS Code code caches" }
    XCTAssertEqual(rule?.risk, .review)
  }

  func testWebCatalogOffersOnlyNamedCacheFoldersAsReview() throws {
    let home = try makeHome()
    defer { try? fm.removeItem(at: home) }
    let root = "Library/Application Support/WebCatalog/photon"
    try folder(home, "\(root)/profiles/mail/Partitions/app/Cache")
    try folder(home, "\(root)/profiles/mail/Partitions/app/Code Cache")
    try folder(home, "\(root)/profiles/mail/Partitions/app/Cookies")
    try folder(home, "\(root)/profiles/mail/Partitions/app/Local Storage/leveldb")
    try folder(home, "\(root)/profiles/mail/Partitions/app/IndexedDB/Cache")  // site data, never searched
    try folder(home, "\(root)/profiles/chat/GPUCache")

    let rules = CleanupCatalog(homeDirectory: home).appCacheRules(applicationRoots: [])
    let names = Set(rules.map { $0.url.lastPathComponent })
    XCTAssertEqual(names, ["Cache", "Code Cache", "GPUCache"])
    XCTAssertTrue(rules.allSatisfy { $0.risk == .review && $0.ownerBundleID == CleanupCatalog.webCatalogBundleID })
    XCTAssertFalse(rules.contains { $0.url.path.contains("IndexedDB") })

    let policy = SafetyPolicy(homeDirectory: home)
    func allowed(_ relative: String) -> Bool {
      policy.cleanupDecision(for: home.appendingPathComponent("\(root)/\(relative)"), category: .appCaches).allowed
    }
    XCTAssertTrue(allowed("profiles/mail/Partitions/app/Cache"))
    XCTAssertFalse(allowed("profiles/mail/Partitions/app/Cookies"))
    XCTAssertFalse(allowed("profiles/mail/Partitions/app"), "Never a profile or partition")
    XCTAssertFalse(allowed("profiles/mail/Partitions/app/IndexedDB/Cache"), "Nothing inside site data")
  }

  func testCachesOfOpenAppsAreShownAsPotentialSpaceWithNothingToReview() {
    var inputs = RecommendationEngine.Inputs()
    inputs.cleanupTargets = [CleanupTarget(
      category: .appCaches, url: URL(fileURLWithPath: "/Users/u/Library/Application Support/Code/Cache"),
      displayName: "VS Code cache", size: 400 * 1_048_576, risk: .safe, reason: "test",
      ownerBundleID: CleanupCatalog.vsCodeBundleID)]
    XCTAssertEqual(RecommendationEngine.recommend(inputs).first { $0.id == "caches" }?.items.count, 1)

    inputs.runningBundleIDs = [CleanupCatalog.vsCodeBundleID]
    let recs = RecommendationEngine.recommend(inputs)
    XCTAssertNil(recs.first { $0.id == "caches" }, "Never offered while the app is open")
    let blocked = recs.first { $0.id == "caches-open-apps" }
    XCTAssertEqual(blocked?.bytes, 400 * 1_048_576)
    XCTAssertTrue(blocked?.items.isEmpty ?? false, "Nothing to review until the app is closed")
    XCTAssertFalse(blocked?.canReview ?? true)
  }
}
