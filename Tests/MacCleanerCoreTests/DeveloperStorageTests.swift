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
    XCTAssertTrue(items.allSatisfy { $0.removal == .trash && $0.rebuild == .rebuildable })
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
