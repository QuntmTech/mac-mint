import Foundation
import XCTest
@testable import MacCleanerApp

final class ResourceProbeSessionTests: XCTestCase {
  func testOnlyAnAbsoluteProbeFolderWithAManifestIsolatesSupportData() throws {
    let fm = FileManager.default
    let base = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? fm.removeItem(at: base) }
    let probe = base.appendingPathComponent("macmint-resource-probe-heavy")
    let other = base.appendingPathComponent("Documents")
    for folder in [probe, other] {
      try fm.createDirectory(at: folder, withIntermediateDirectories: true)
      try Data("{}".utf8).write(to: folder.appendingPathComponent("manifest.json"))
    }
    XCTAssertEqual(ResourceProbeSession.folder(arguments: ["MacMint", "--resource-probe", probe.path])?.path,
      probe.standardizedFileURL.path)
    XCTAssertNil(ResourceProbeSession.folder(arguments: ["MacMint", "--resource-probe", other.path]))
    XCTAssertNil(ResourceProbeSession.folder(arguments: ["MacMint", "--resource-probe", "macmint-resource-probe-heavy"]))
    XCTAssertNil(ResourceProbeSession.folder(arguments: ["MacMint", "--resource-probe"]))
    XCTAssertNil(ResourceProbeSession.folder(arguments: ["MacMint"]))
    try fm.removeItem(at: probe.appendingPathComponent("manifest.json"))
    XCTAssertNil(ResourceProbeSession.folder(arguments: ["MacMint", "--resource-probe", probe.path]))
    // Tests never run with the argument, so the app keeps its ordinary support folder.
    XCTAssertNil(ResourceProbeSession.folder)
  }
}
