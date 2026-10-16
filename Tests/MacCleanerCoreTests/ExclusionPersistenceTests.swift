import Foundation
import XCTest
@testable import MacCleanerCore

final class ExclusionPersistenceTests: XCTestCase {
  func testCorruptExclusionsCannotBeMistakenForAnEmptyStoreOrOverwrittenByEdits() async throws {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try fm.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: root) }
    let url = root.appendingPathComponent("ignored-paths.json")
    let original = Data("damaged exclusion evidence".utf8)
    try original.write(to: url)
    let store = IgnoreStore(url: url)
    do { _ = try await store.loadChecked(); XCTFail("Must surface corrupted exclusions") } catch {}
    do { _ = try await store.add(root.appendingPathComponent("personal")); XCTFail("Must not replace the unreadable store") } catch {}
    do { _ = try await store.remove(path: "/personal"); XCTFail("Must not replace the unreadable store") } catch {}
    XCTAssertEqual(try Data(contentsOf: url), original)
    // An explicit reset preserves the damaged bytes and produces a readable empty list.
    try await store.clear()
    let reset = try await store.loadChecked()
    XCTAssertTrue(reset.isEmpty)
    let backup = try XCTUnwrap(try fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
      .first { $0.lastPathComponent.contains("preserved-") })
    XCTAssertEqual(try Data(contentsOf: backup), original)
  }
}
