import Foundation
import XCTest
@testable import MacCleanerCore

final class OrganizationTests: XCTestCase {
  private let fm = FileManager.default
  private func fixture() throws -> (URL, URL) {
    let home = fm.temporaryDirectory.appendingPathComponent("organize-" + UUID().uuidString)
    let root = home.appendingPathComponent("Downloads")
    try fm.createDirectory(at: root.appendingPathComponent("Documents"), withIntermediateDirectories: true)
    try Data("important document".utf8).write(to: root.appendingPathComponent("invoice.pdf"))
    return (home, root)
  }
  func testPreviewApplyIdempotencyAndUndoNeverOverwrite() async throws {
    let (home, root) = try fixture(); defer { try? fm.removeItem(at: home) }
    let store = OrganizationStore(directory: home.appendingPathComponent("receipts"), home: home)
    let inventory = try await store.inspect(root), suggestions = await store.localSuggestions(inventory)
    XCTAssertEqual(suggestions.count, 1)
    XCTAssertTrue(fm.fileExists(atPath: root.appendingPathComponent("invoice.pdf").path))
    let result = try await store.apply(inventory, proposals: suggestions)
    XCTAssertEqual(result.items.first?.state, .moved)
    let repeated = try await store.apply(inventory, proposals: suggestions)
    XCTAssertEqual(repeated.id, result.id)
    try Data("new file".utf8).write(to: root.appendingPathComponent("invoice.pdf"))
    let conflict = try await store.undo(recordID: result.id)
    XCTAssertEqual(conflict.items.first?.state, .moved)
    XCTAssertNotNil(conflict.items.first?.message)
    XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("invoice.pdf"), encoding: .utf8), "new file")
    try fm.removeItem(at: root.appendingPathComponent("invoice.pdf"))
    let restored = try await store.undo(recordID: result.id)
    XCTAssertEqual(restored.items.first?.state, .undone)
    XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("invoice.pdf"), encoding: .utf8), "important document")
  }
  func testUnwritableJournalPreventsAllMovesAndSourceReplacementIsRejected() async throws {
    let (home, root) = try fixture(); defer { try? fm.removeItem(at: home) }
    let store = OrganizationStore(directory: home.appendingPathComponent("receipts"), home: home,
      writer: { _,_ in throw CocoaError(.fileWriteOutOfSpace) })
    let inventory = try await store.inspect(root), suggestions = await store.localSuggestions(inventory)
    do { _ = try await store.apply(inventory, proposals: suggestions); XCTFail("Expected journal failure") } catch {}
    XCTAssertTrue(fm.fileExists(atPath: root.appendingPathComponent("invoice.pdf").path))
    try fm.removeItem(at: root.appendingPathComponent("invoice.pdf"))
    try Data("replacement".utf8).write(to: root.appendingPathComponent("invoice.pdf"))
    let issue = await store.problem(suggestions[0], in: inventory)
    XCTAssertNotNil(issue)
  }
  func testRejectsTraversalUnknownIDsExtensionsSymlinksAndExclusions() async throws {
    let (home, root) = try fixture(); defer { try? fm.removeItem(at: home) }
    let store = OrganizationStore(directory: home.appendingPathComponent("receipts"), home: home)
    let inventory = try await store.inspect(root), file = try XCTUnwrap(inventory.files.first)
    for name in ["../outside.pdf", "/tmp/out.pdf", "hidden.app", "a\u{0000}.pdf", ".secret.pdf"] {
      let issue = await store.problem(.init(fileID: file.id, folderID: "root", name: name, reason: "test"), in: inventory)
      XCTAssertNotNil(issue, name)
    }
    let valid = OrganizationProposal(fileID: file.id, folderID: "root", name: "renamed.pdf", reason: "test")
    let blocked = await store.problem(valid, in: inventory, ignoredPaths: [root.path])
    XCTAssertNotNil(blocked)
    try fm.removeItem(at: root.appendingPathComponent("Documents"))
    try fm.createSymbolicLink(at: root.appendingPathComponent("Documents"), withDestinationURL: home)
    let destination = OrganizationProposal(fileID: file.id, folderID: inventory.folders[1].id, name: "invoice.pdf", reason: "test")
    let symlink = await store.problem(destination, in: inventory)
    XCTAssertNotNil(symlink)
    let payload = try JSONEncoder().encode(AIOrganizationRequest(inventory))
    XCTAssertFalse(String(decoding: payload, as: UTF8.self).contains(home.path))
  }
  func testCrashAfterRenameRecoversDurableIntentAndCorruptRecordIsPreserved() async throws {
    let (home, root) = try fixture(); defer { try? fm.removeItem(at: home) }
    let directory = home.appendingPathComponent("receipts")
    let writes = LockedCounter()
    let store = OrganizationStore(directory: directory, home: home, writer: { data, url in
      if writes.next() == 3 { throw CocoaError(.fileWriteOutOfSpace) }
      try FileSystem.writeDurably(data, to: url)
    })
    let inventory = try await store.inspect(root), suggestions = await store.localSuggestions(inventory)
    do { _ = try await store.apply(inventory, proposals: suggestions); XCTFail("Expected post-move failure") } catch {}
    let restarted = OrganizationStore(directory: directory, home: home)
    let recovered = try await restarted.history()
    XCTAssertEqual(recovered.count, 1); XCTAssertEqual(recovered[0].items[0].state, .moved)
    let undone = try await restarted.undo(recordID: inventory.id)
    XCTAssertEqual(undone.items[0].state, .undone)
    let corrupt = directory.appendingPathComponent("broken.json")
    try Data("broken".utf8).write(to: corrupt)
    do { _ = try await restarted.history(); XCTFail("Corruption must be visible") } catch {}
    XCTAssertTrue(fm.fileExists(atPath: corrupt.path))
    let partial = try await restarted.historyReport()
    XCTAssertEqual(partial.records.count, 1); XCTAssertEqual(partial.warnings.count, 1)
  }
  func testLastMomentCollisionAndSourceChangeCannotBypassFinalChecks() async throws {
    for race in ["collision", "replacement"] {
      let (home, root) = try fixture(); defer { try? fm.removeItem(at: home) }
      let destination = root.appendingPathComponent("Documents/invoice.pdf")
      let store = OrganizationStore(directory: home.appendingPathComponent("receipts"), home: home, writer: { data, url in
        try FileSystem.writeDurably(data, to: url)
        let record = try JSONDecoder().decode(OrganizationRecord.self, from: data)
        if record.items.first?.state == .moving {
          if race == "collision" { try Data("must not overwrite".utf8).write(to: destination) }
          else {
            let source = root.appendingPathComponent("invoice.pdf")
            try FileManager.default.removeItem(at: source)
            try Data("replacement after preparation".utf8).write(to: source)
          }
        }
      })
      let inventory = try await store.inspect(root), suggestions = await store.localSuggestions(inventory)
      let result = try await store.apply(inventory, proposals: suggestions)
      XCTAssertEqual(result.items[0].state, .failed)
      XCTAssertTrue(fm.fileExists(atPath: root.appendingPathComponent("invoice.pdf").path))
      if race == "collision" { XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), "must not overwrite") }
      else { XCTAssertFalse(fm.fileExists(atPath: destination.path)) }
    }
  }

  func testInspectionIsShallowAndLimitedAndSkipsManagedPackagesAndRepositories() async throws {
    let (home, root) = try fixture(); defer { try? fm.removeItem(at: home) }
    try fm.createDirectory(at: root.appendingPathComponent("Project/.git"), withIntermediateDirectories: true)
    try fm.createDirectory(at: root.appendingPathComponent("Library.photoslibrary"), withIntermediateDirectories: true)
    for i in 0..<550 { try Data().write(to: root.appendingPathComponent("file\(i).txt")) }
    let store = OrganizationStore(directory: home.appendingPathComponent("receipts"), home: home)
    let inventory = try await store.inspect(root)
    XCTAssertLessThanOrEqual(inventory.files.count, 100); XCTAssertTrue(inventory.wasLimited)
    XCTAssertFalse(inventory.folders.contains { $0.name == "Project" || $0.name == "Library.photoslibrary" })
    do { _ = try await store.inspect(root.appendingPathComponent("Project")); XCTFail("Repository") } catch {}
  }
}

private final class LockedCounter: @unchecked Sendable {
  private let lock = NSLock(); private var value = 0
  func next() -> Int { lock.lock(); defer { lock.unlock() }; value += 1; return value }
}
