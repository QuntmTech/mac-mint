import Foundation
import MacCleanerCore
import XCTest
@testable import MacCleanerApp

@MainActor
final class AppTamingControllerTests: XCTestCase {
  private let identity = TamingIdentity(pid: 40001, started: 10, boot: "test", bundleID: "example.app", path: "/Applications/App.app")
  private func fixture() -> (AppTamingController, FakeTamingBackend, TamingStore, URL) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let store = TamingStore(url: root.appendingPathComponent("journal.json"))
    let backend = FakeTamingBackend(); backend.onApply = { _ in XCTAssertFalse((try? store.load().receipts.isEmpty) ?? true) }
    let controller = AppTamingController(store: store, backend: backend); controller.activate()
    return (controller, backend, store, root)
  }
  func testIntentIsDurableBeforeSlowdownAndNormalRestoreClearsIt() throws {
    let (controller, backend, store, root) = fixture(); defer { try? FileManager.default.removeItem(at: root) }
    controller.slow(identity, name: "App", now: Date())
    XCTAssertEqual(backend.calls, [true]); XCTAssertEqual(try store.load().receipts.count, 1)
    controller.restoreAll()
    XCTAssertEqual(backend.calls, [true, false]); XCTAssertTrue(try store.load().receipts.isEmpty)
  }
  func testNeverSlowSurvivesRelaunchAndRestoresAlreadyControlledApp() throws {
    let (controller, backend, store, root) = fixture(); defer { try? FileManager.default.removeItem(at: root) }
    controller.slow(identity, name: "App", now: Date())
    controller.setException(bundleID: "EXAMPLE.APP", name: "App", protected: true)
    XCTAssertEqual(backend.calls, [true, false]); XCTAssertTrue(controller.isExcepted(identity.bundleID))
    let next = AppTamingController(store: store, backend: backend); next.activate()
    next.slow(identity, name: "App", now: Date())
    XCTAssertEqual(backend.calls, [true, false]); XCTAssertFalse(next.autoEnabled)
  }
  func testRelaunchRecoversIntentButNeverSignalsReplacedProcess() throws {
    let (controller, backend, store, root) = fixture(); defer { try? FileManager.default.removeItem(at: root) }
    controller.slow(identity, name: "App", now: Date())
    let recovery = AppTamingController(store: store, backend: backend); recovery.activate()
    XCTAssertEqual(backend.calls, [true, false]); XCTAssertTrue(try store.load().receipts.isEmpty)
    recovery.slow(identity, name: "App", now: Date())
    backend.current = false
    let replaced = AppTamingController(store: store, backend: backend); replaced.activate()
    XCTAssertEqual(backend.calls, [true, false, true]); XCTAssertTrue(try store.load().receipts.isEmpty)
  }
  func testFailedRestoreKeepsReceiptForRetryAndForegroundRestoresManual() throws {
    let (controller, backend, store, root) = fixture(); defer { try? FileManager.default.removeItem(at: root) }
    controller.slow(identity, name: "App", now: Date()); backend.failRestore = true
    controller.restoreAll(); XCTAssertEqual(try store.load().receipts.count, 1)
    backend.unknown = true; controller.restoreAll()
    XCTAssertEqual(try store.load().receipts.count, 1, "Unable to query must not be treated as a vanished process")
    backend.unknown = false
    backend.failRestore = false; controller.foregroundChanged(identity.bundleID)
    XCTAssertTrue(try store.load().receipts.isEmpty)
  }
  func testUnwritableAndCorruptJournalFailClosed() throws {
    let (controller, backend, store, root) = fixture(); defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try Data("block directory".utf8).write(to: store.url)
    let corrupt = AppTamingController(store: store, backend: backend); corrupt.activate()
    corrupt.slow(identity, name: "App", now: Date()); XCTAssertTrue(backend.calls.isEmpty)
    try FileManager.default.removeItem(at: root)
    try Data().write(to: root) // Parent is a file: intent cannot be saved.
    controller.slow(identity, name: "App", now: Date()); XCTAssertTrue(backend.calls.isEmpty)
  }
  func testAutomaticExcludesSystemAndCallingApps() {
    XCTAssertFalse(AppTamingController.allowsAutomatic("com.apple.Safari"))
    XCTAssertFalse(AppTamingController.allowsAutomatic("us.zoom.xos"))
    XCTAssertFalse(AppTamingController.allowsAutomatic("com.microsoft.teams2"))
    XCTAssertTrue(AppTamingController.allowsAutomatic("com.example.editor"))
  }
}

@MainActor
private final class FakeTamingBackend: TamingBackend {
  var calls: [Bool] = []
  var current = true
  var unknown = false
  var failRestore = false
  var onApply: ((Bool) -> Void)?
  func status(_ identity: TamingIdentity) -> TamingTargetStatus { unknown ? .unavailable : current ? .current : .goneOrChanged }
  func setBackground(_ background: Bool, for identity: TamingIdentity) throws {
    onApply?(background)
    if !background && failRestore { throw CocoaError(.fileWriteNoPermission) }
    calls.append(background)
  }
}
