import XCTest

@testable import MacCleanerCore

final class DeveloperStorageTests: XCTestCase {
  private let fm = FileManager.default

  func testXcodeDerivedDataIsNamedByProjectAndSuggestedWhenIdle() async throws {
    let home = makeTempDirectory()
    defer { try? fm.removeItem(at: home) }
    let project = try write(home, "Library/Developer/Xcode/DerivedData/MacMint-abcxyz/Build/x.o")
      .deletingLastPathComponent().deletingLastPathComponent()
    try age(project, days: 10)

    let items = await scanner(home).scan().value
    let item = try XCTUnwrap(items.first { $0.group == .xcode })
    XCTAssertEqual(item.title, "MacMint")
    XCTAssertEqual(item.rebuild, .rebuildable)
    XCTAssertTrue(item.isSuggested)
  }

  func testRecentlyUsedItemsAreActiveAndNotSuggested() async throws {
    let home = makeTempDirectory()
    defer { try? fm.removeItem(at: home) }
    try write(home, "Library/Developer/Xcode/DerivedData/Live-123/Build/x.o")

    let scanned = await scanner(home).scan().value
    let item = try XCTUnwrap(scanned.first)
    XCTAssertTrue(item.isActive)
    XCTAssertFalse(item.isSuggested)
  }

  func testProjectArtifactsRequireTheirToolMarker() async throws {
    let home = makeTempDirectory()
    defer { try? fm.removeItem(at: home) }
    try write(home, "Code/web/package.json", 10)
    try write(home, "Code/web/node_modules/react/index.js")
    try write(home, "Code/notes/target/keep-me.txt")  // no Cargo.toml / pom.xml
    try write(home, "Code/rusty/Cargo.toml", 10)
    try write(home, "Code/rusty/target/debug/app")

    let items = await scanner(home).scan(projectRoots: [home.appendingPathComponent("Code")]).value
      .filter { $0.group == .projects }
    XCTAssertEqual(Set(items.map(\.title)), ["web", "rusty"])
    XCTAssertTrue(items.allSatisfy { $0.removal == .trash })
    XCTAssertEqual(items.first { $0.title == "rusty" }?.rebuild, .rebuildable, "Compiler output rebuilds")
    XCTAssertEqual(items.first { $0.title == "web" }?.rebuild, .review, "Installed packages are not build output")
  }

  func testInstalledDependenciesAreNeverSuggestedEvenWhenIdle() async throws {
    let home = makeTempDirectory()
    defer { try? fm.removeItem(at: home) }
    // A CocoaPods project with a locally patched pod, and a Node project using patch-package.
    try write(home, "Code/ios/Podfile", 10)
    try write(home, "Code/ios/Pods/SomeKit/Source.swift")
    try write(home, "Code/ios/patches/SomeKit.patch", 10)
    try write(home, "Code/bot/package.json", 10)
    try write(home, "Code/bot/node_modules/private-lib/index.js")
    try write(home, "Code/bot/patches/private-lib+1.0.0.patch", 10)
    for project in ["Code/ios", "Code/bot"] { try age(home.appendingPathComponent(project), days: 120) }

    let items = await scanner(home).scan(projectRoots: [home.appendingPathComponent("Code")]).value
      .filter { $0.group == .projects }
    XCTAssertEqual(Set(items.map(\.tool)), ["Pods", "node_modules"])
    XCTAssertTrue(items.allSatisfy { $0.rebuild == .review && !$0.isSuggested })
    XCTAssertTrue(items.allSatisfy { $0.subtitle.contains("local edits") })
    XCTAssertFalse(items.contains { $0.url?.lastPathComponent == "patches" }, "The project itself is never offered")
  }

  func testBuildFoldersWithDebugSymbolsOrCheckoutsAreReviewOnly() async throws {
    let home = makeTempDirectory()
    defer { try? fm.removeItem(at: home) }
    let derived = "Library/Developer/Xcode/DerivedData"
    try write(home, "\(derived)/Shipped-aaa/Build/Products/Release-iphoneos/Shipped.app.dSYM/Contents/Info.plist")
    try write(home, "\(derived)/Shipped-aaa/Build/Products/Release-iphoneos/Shipped.app/Shipped")
    try write(home, "\(derived)/Patched-bbb/SourcePackages/checkouts/swift-thing/Sources/a.swift")
    try write(home, "\(derived)/Plain-ccc/Build/Intermediates.noindex/x.o")
    for name in ["Shipped-aaa", "Patched-bbb", "Plain-ccc"] {
      try age(home.appendingPathComponent("\(derived)/\(name)"), days: 30)
    }
    try write(home, "Code/pkg/Package.swift", 10)
    try write(home, "Code/pkg/.build/checkouts/dep/Package.swift")
    try write(home, "Code/pkg2/Package.swift", 10)
    try write(home, "Code/pkg2/.build/debug/pkg2")

    let items = await scanner(home).scan(projectRoots: [home.appendingPathComponent("Code")]).value
    let byTitle = Dictionary(items.map { ($0.title, $0) }, uniquingKeysWith: { first, _ in first })
    XCTAssertEqual(byTitle["Shipped"]?.rebuild, .review, "A dSYM matches one exact build; a rebuild doesn't recreate it")
    XCTAssertTrue(byTitle["Shipped"]?.subtitle.contains("1 debug symbol file") ?? false)
    XCTAssertEqual(byTitle["Patched"]?.rebuild, .review, "Package checkouts can be edited in place")
    XCTAssertEqual(byTitle["Plain"]?.rebuild, .rebuildable)
    XCTAssertTrue(byTitle["Plain"]?.isSuggested ?? false, "Plain build output is still suggested once idle")
    XCTAssertEqual(byTitle["pkg"]?.rebuild, .review)
    XCTAssertEqual(byTitle["pkg2"]?.rebuild, .rebuildable)
  }

  func testAFolderThatCantBeLookedIntoIsNotCalledPlainBuildOutput() throws {
    let home = makeTempDirectory()
    defer {
      try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: home.appendingPathComponent("Build/Products").path)
      try? fm.removeItem(at: home)
    }
    let products = try write(home, "Build/Products/Release/App").deletingLastPathComponent().deletingLastPathComponent()
    try fm.setAttributes([.posixPermissions: 0o000], ofItemAtPath: products.path)
    XCTAssertNotNil(DeveloperStorageScanner.preservedBuildEvidence(in: home), "Couldn't check is not the same as clean")
  }

  func testUvCacheIsClearedWithUvsOwnCommandNotTheTrash() async throws {
    let home = makeTempDirectory()
    defer { try? fm.removeItem(at: home) }
    try write(home, ".cache/uv/wheels-v5/pkg.whl")
    let scanned = await scanner(home).scan().value
    let item = try XCTUnwrap(scanned.first { $0.tool == "uv" })
    XCTAssertEqual(item.removal, .command("uv cache prune"))
    XCTAssertFalse(item.canTrash, "uv locks its cache; files are never moved behind its back")
    XCTAssertFalse(item.isSuggested)
  }

  func testOllamaModelsAreSizedFromManifestsAndRemovedWithOllama() async throws {
    let home = makeTempDirectory()
    defer { try? fm.removeItem(at: home) }
    let manifest = """
      {"layers":[{"digest":"sha256:a","size":4000000000},{"digest":"sha256:b","size":1200}]}
      """
    try write(
      home, ".ollama/models/manifests/registry.ollama.ai/library/llama3/8b", Data(manifest.utf8))

    let scanned = await scanner(home).scan().value
    let item = try XCTUnwrap(scanned.first { $0.tool == "Ollama" })
    XCTAssertEqual(item.title, "llama3:8b")
    XCTAssertEqual(item.bytes, 4_000_001_200)
    XCTAssertEqual(item.removal, .command("ollama rm -- 'llama3:8b'"))
    XCTAssertFalse(item.canTrash)
    XCTAssertNil(PlanItem.developer(item), "managed models never become Trash plan items")
  }

  func testHostileOllamaManifestSizesDoNotCrashTheScan() async throws {
    let home = makeTempDirectory()
    defer { try? fm.removeItem(at: home) }
    let manifest = """
      {"layers":[{"size":9223372036854775807},{"size":9223372036854775807},{"size":-5}]}
      """
    try write(
      home, ".ollama/models/manifests/registry.ollama.ai/library/huge/latest", Data(manifest.utf8))

    let scanned = await scanner(home).scan().value
    let item = try XCTUnwrap(scanned.first { $0.tool == "Ollama" })
    XCTAssertEqual(item.bytes, Int64.max, "sizes saturate instead of trapping; negative sizes are ignored")
  }

  func testHuggingFaceReposAreWholeRepositoryItems() async throws {
    let home = makeTempDirectory()
    defer { try? fm.removeItem(at: home) }
    try write(home, ".cache/huggingface/hub/models--meta-llama--Llama-3-8B/blobs/abc")

    let scanned = await scanner(home).scan().value
    let item = try XCTUnwrap(scanned.first { $0.tool == "Hugging Face" })
    XCTAssertEqual(item.title, "meta-llama/Llama-3-8B")
    XCTAssertEqual(item.rebuild, .review)
    XCTAssertTrue(item.canTrash)
  }

  func testDeveloperSafetyRule() throws {
    let home = makeTempDirectory()
    defer { try? fm.removeItem(at: home) }
    let policy = SafetyPolicy(homeDirectory: home)
    let allow: (String) -> Bool = { policy.developerArtifactDecision(for: home.appendingPathComponent($0)).allowed }
    try write(home, "Documents/Projects/site/package.json", 10)
    try write(home, "Documents/Projects/site/node_modules/x.js")
    try write(home, "node_modules/x.js")

    XCTAssertTrue(allow("Library/Developer/Xcode/DerivedData/App-1"))
    XCTAssertTrue(allow(".cache/huggingface/hub/models--a--b"))
    XCTAssertTrue(allow("Documents/Projects/site/node_modules"), "projects may live in Documents")
    XCTAssertFalse(allow("node_modules"), "not directly in home")
    XCTAssertFalse(allow("Documents/Projects/site"), "the project itself is never a target")
    XCTAssertFalse(allow("Library/Application Support/target"), "Library needs a known cache root")
    XCTAssertFalse(policy.developerArtifactDecision(for: URL(fileURLWithPath: "/usr/local/node_modules")).allowed)
    _ = home
  }

  func testExecutorMovesDeveloperArtifactThroughItsRule() async throws {
    let home = makeTempDirectory()
    defer { try? fm.removeItem(at: home) }
    try write(home, "Code/web/package.json", 10)
    let modules = try write(home, "Code/web/node_modules/x.js").deletingLastPathComponent()
    try age(modules, days: 30)
    let items = await scanner(home).scan(projectRoots: [home.appendingPathComponent("Code")]).value
    let planItem = try XCTUnwrap(items.compactMap(PlanItem.developer).first)

    let report = await OperationExecutor(
      trashService: MovingTrashService(trashDirectory: home.appendingPathComponent(".Trash")),
      safetyPolicy: SafetyPolicy(homeDirectory: home), developerRoots: []
    ).run(OperationPlanner.plan(title: "Developer", items: [planItem]))
    XCTAssertEqual(report.moved.count, 1)
    XCTAssertFalse(fm.fileExists(atPath: modules.path))
  }

  // MARK: Helpers

  private func scanner(_ home: URL) -> DeveloperStorageScanner {
    DeveloperStorageScanner(homeDirectory: home, environment: [:])
  }

  @discardableResult
  private func write(_ root: URL, _ relative: String, _ data: Data = Data(repeating: 1, count: 4096))
    throws -> URL
  {
    let url = root.appendingPathComponent(relative)
    try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try data.write(to: url)
    return url
  }

  @discardableResult
  private func write(_ root: URL, _ relative: String, _ bytes: Int) throws -> URL {
    try write(root, relative, Data(repeating: 1, count: bytes))
  }

  private func age(_ url: URL, days: Double) throws {
    try fm.setAttributes(
      [.modificationDate: Date().addingTimeInterval(-days * 86_400)], ofItemAtPath: url.path)
  }

  private func makeTempDirectory() -> URL {
    let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try! fm.createDirectory(at: root, withIntermediateDirectories: true)
    return root
  }
}
