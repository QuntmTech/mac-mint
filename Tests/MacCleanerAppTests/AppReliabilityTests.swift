import AppKit
import Foundation
import MacCleanerCore
import XCTest
@testable import MacCleanerApp

@MainActor
final class AppReliabilityTests: XCTestCase {
  // MARK: Queue summary (planner work stays out of view reads)

  func testQueueSummaryFollowsSelectionsAndCountsLibraryPhotosOutsideThePlan() async throws {
    let (model, folder) = try await readyModel()
    defer { try? FileManager.default.removeItem(at: folder) }
    let file = LargeFile(url: folder.appendingPathComponent("large.bin"), size: 4096, modifiedAt: nil, accessedAt: nil)
    model.largeFiles = [file]
    model.setFileSelection(file.url, selected: true)
    XCTAssertEqual(model.queuedCount, 0, "Reads return the stored summary; planning happens after selections settle")
    try await waitUntil { model.queuedCount == 1 }
    XCTAssertEqual(model.queuedBytes, 4096)

    let asset = PhotoFingerprint(url: URL(fileURLWithPath: "/Photos/asset-1"), bytes: 0, hash: 1, sharpness: 1,
      pixelWidth: 10, pixelHeight: 10, assetID: "asset-1")
    model.photoSource = .library
    model.photoScan = PhotoScanResult(photos: [asset], similarGroups: [], blurry: [], screenshots: [],
      skippedLibraries: [], issues: [], wasCancelled: false)
    model.togglePhoto(asset)
    try await waitUntil { model.queuedCount == 2 }
    XCTAssertEqual(model.queuedLibraryPhotoCount, 1, "Review and badges count queued library assets")
    XCTAssertEqual(model.queuedItems.map(\.url), [file.url], "Library assets never join the Trash plan")

    model.clearQueue()
    try await waitUntil { model.queuedCount == 0 }
    XCTAssertEqual(model.queuedBytes, 0)
  }

  func testBulkPhotoSelectionRefreshesTheQueueSummary() async throws {
    let (model, folder) = try await readyModel()
    defer { try? FileManager.default.removeItem(at: folder) }
    let photos = ["a.jpg", "b.jpg", "c.jpg"].map {
      PhotoFingerprint(url: folder.appendingPathComponent($0), bytes: 100, hash: 1, sharpness: 1, pixelWidth: 10, pixelHeight: 10)
    }
    model.photoSource = .folder(folder)
    model.photoScan = PhotoScanResult(photos: photos, similarGroups: [], blurry: [], screenshots: [],
      skippedLibraries: [], issues: [], wasCancelled: false)
    model.setPhotoSelection(photos, selected: true)
    try await waitUntil { model.queuedCount == 3 }
    XCTAssertEqual(model.queuedBytes, 300)
    model.setPhotoSelection(photos, selected: false)
    try await waitUntil { model.queuedCount == 0 }
  }

  func testCleanupEstimatesAndVolumeReadingAreCached() async throws {
    let (model, folder) = try await readyModel()
    defer { try? FileManager.default.removeItem(at: folder) }
    let gib: Int64 = 1_073_741_824
    model.cleanupTargets = [
      CleanupTarget(category: .userCaches, url: folder.appendingPathComponent("Library/Caches/one"), displayName: "One",
        size: gib, risk: .safe, reason: "Rebuilds"),
      CleanupTarget(category: .deviceBackups, url: folder.appendingPathComponent("Backup"), displayName: "Backup",
        size: 2 * gib, risk: .review, reason: "Personal", isSelected: false),
    ]
    let leftovers = [
      AppLeftover(url: folder.appendingPathComponent("Library/Caches/com.example.app"), size: 300, confidence: .high, reason: "Exact"),
      AppLeftover(url: folder.appendingPathComponent("Library/Group Containers/group.example"), size: 700, confidence: .medium,
        reason: "Shared", isShared: true),
    ]
    model.appLeftovers = leftovers
    model.selectedLeftoverIDs = [leftovers[0].id]
    model.refreshQueueSummaryNow()
    XCTAssertEqual(model.selectedCleanupBytes, gib)
    XCTAssertEqual(model.reclaimableBytes, gib)
    XCTAssertEqual(model.reviewableBytes, 2 * gib)
    XCTAssertEqual(model.queueSummary.selectedLeftoverBytes, 300, "Uninstall totals use the stored summary")
    model.selectedLeftoverIDs = Set(leftovers.map(\.id))
    try await waitUntil { model.queueSummary.selectedLeftoverBytes == 1_000 }

    let reading = await model.refreshVolumeSummary()
    XCTAssertGreaterThan(reading.total, 0)
    XCTAssertEqual(model.volume, reading)
    XCTAssertEqual(model.volumeName, reading.name)
  }

  // MARK: Plan preparation

  func testPreparingReviewBlocksScansAndCancellationNeverPresentsALateSheet() async throws {
    let (model, folder) = try await readyModel()
    defer { try? FileManager.default.removeItem(at: folder) }
    let content = Data(repeating: 1, count: 64)
    let urls = ["keep.bin", "copy.bin"].map { folder.appendingPathComponent($0) }
    for url in urls { try content.write(to: url) }
    let files = urls.map { LargeFile(url: $0, size: 64, modifiedAt: nil, accessedAt: nil) }
    model.duplicateGroups = [DuplicateGroup(fingerprint: "slow", files: files)]
    model.selectedDuplicateIDs = [files[1].id]
    let hashes = Counter()
    model.duplicateVerifier = DuplicateRemovalVerifier(hash: { _ in
      hashes.increment()
      Thread.sleep(forTimeInterval: 0.3)
      return "slow"
    })

    model.reviewDuplicates()
    XCTAssertTrue(model.isPreparingPlan)
    XCTAssertEqual(model.operationTitle, "Preparing review")
    XCTAssertFalse(model.beginScan(title: "Quick Scan", message: "Must wait"))
    XCTAssertFalse(model.isScanning)
    XCTAssertTrue(model.statusMessage.contains("being prepared"), model.statusMessage)

    try await waitUntil { hashes.value >= 1 }
    model.cancelCurrentOperation()
    XCTAssertFalse(model.isPreparingPlan)
    XCTAssertNil(model.operationTitle)
    try await Task.sleep(for: .milliseconds(800))
    XCTAssertNil(model.pendingPlan, "A cancelled preparation must not present its result")
    XCTAssertTrue(model.statusMessage.contains("cancelled"), model.statusMessage)

    model.reviewDuplicates()
    try await waitUntil(seconds: 5) { !model.isPreparingPlan }
    XCTAssertNotNil(model.pendingPlan)
    XCTAssertFalse(model.beginScan(title: "Quick Scan", message: "Must wait"), "An open review blocks new scans")
    XCTAssertFalse(model.isScanning)
  }

  // MARK: AI review survives Overview revisits

  func testRecommendationRefreshKeepsReviewAndQuestionUntilItsContextChanges() async throws {
    let previous = UserDefaults.standard.object(forKey: AppViewModel.aiEnabledKey)
    defer { UserDefaults.standard.set(previous, forKey: AppViewModel.aiEnabledKey) }
    UserDefaults.standard.set(true, forKey: AppViewModel.aiEnabledKey)
    let (model, folder) = try await readyModel()
    defer { try? FileManager.default.removeItem(at: folder) }
    let fixture = AIFixture(), tokens = Tokens()
    let store = AccountStore(supportDirectory: folder.appendingPathComponent("Account"),
      client: AccountClient(transport: { try await fixture.respond($0) }),
      deviceInfo: DeviceInfo(deviceId: "reliability-device", name: "Fixture", model: "Fixture", osVersion: "test", appVersion: "test"),
      tokenStorage: tokens.storage)
    await store.signIn(email: "fixture@example.invalid", password: "fixture")
    XCTAssertTrue(store.isUnlocked)

    let gib: Int64 = 1_073_741_824
    model.cleanupTargets = [CleanupTarget(category: .userCaches, url: folder.appendingPathComponent("Library/Caches/fixture"),
      displayName: "Fixture cache", size: gib, risk: .safe, reason: "Rebuilds")]
    model.refreshRecommendations()
    XCTAssertFalse(model.recommendations.isEmpty)
    model.aiReview = try JSONDecoder().decode(AIReview.self, from: Data("""
      {"headline":"Fixture","notes":[],"insights":[],"cautions":[],"model":null}
      """.utf8))
    model.aiOrderRecommendations = true

    await fixture.holdAsk()
    model.ask("What is using space?", account: store)
    try await waitUntil { await fixture.isHoldingAsk }
    XCTAssertTrue(model.assistantBusy)

    model.refreshRecommendations() // Overview onAppear with unchanged inputs
    XCTAssertNotNil(model.aiReview, "Revisiting Overview must not discard the review")
    XCTAssertTrue(model.aiOrderRecommendations)
    XCTAssertTrue(model.assistantBusy, "A recommendation refresh never cancels the assistant")

    model.cleanupTargets = []
    model.refreshRecommendations()
    XCTAssertNil(model.aiReview, "Changed recommendations retire the old review")
    XCTAssertTrue(model.assistantBusy)

    await fixture.releaseAsk()
    try await waitUntil { !model.assistantBusy }
    XCTAssertEqual(model.assistantTurns.last?.text, "Fixture answer")

    UserDefaults.standard.set(false, forKey: AppViewModel.aiEnabledKey)
    model.ask("Another question", account: store)
    XCTAssertTrue(model.aiConsentPending)
    model.refreshRecommendations()
    XCTAssertTrue(model.aiConsentPending, "Unchanged context keeps the consent preview valid")
    model.cleanupTargets = [CleanupTarget(category: .userLogs, url: folder.appendingPathComponent("Library/Logs/fixture"),
      displayName: "Fixture logs", size: gib, risk: .safe, reason: "Rebuilds")]
    model.refreshRecommendations()
    XCTAssertFalse(model.aiConsentPending, "A changed context invalidates pending consent")
    XCTAssertNil(model.pendingAIAction)
  }

  // MARK: Exclusions

  func testExclusionThatCannotBeSavedReportsTheErrorAndKeepsState() async throws {
    let (model, folder) = try await readyModel()
    defer { try? FileManager.default.removeItem(at: folder) }
    let target = folder.appendingPathComponent("Documents/keep.txt")
    let store = folder.appendingPathComponent("ignored-paths.json")
    try Data("damaged".utf8).write(to: store)
    let failure = await model.addExclusion(target)
    XCTAssertNotNil(failure)
    XCTAssertFalse(model.ignoredPaths.contains(target.standardizedFileURL.path))

    try FileManager.default.removeItem(at: store)
    let success = await model.addExclusion(target)
    XCTAssertNil(success)
    XCTAssertTrue(model.ignoredPaths.contains(target.standardizedFileURL.path))
  }

  // MARK: Window and quit

  func testMenuBarReusesTheOpenWorkspaceWindow() throws {
    _ = NSApplication.shared
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 240, height: 160), styleMask: [.titled],
      backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    defer { window.orderOut(nil) }
    MainWindow.register(window)
    window.orderFront(nil)
    guard window.isVisible else { throw XCTSkip("Ordering a window requires a WindowServer session") }
    XCTAssertTrue(MainWindow.focusExisting(), "An open window is brought forward rather than duplicated")
    window.orderOut(nil)
    XCTAssertFalse(MainWindow.focusExisting(), "A closed window is reopened through the scene")
  }

  func testQuitIsImmediateWhenNothingIsMoving() async throws {
    let (model, folder) = try await readyModel()
    defer { try? FileManager.default.removeItem(at: folder) }
    let delegate = AppDelegate()
    delegate.model = model
    XCTAssertEqual(delegate.applicationShouldTerminate(NSApplication.shared), .terminateNow)
  }

  // MARK: Helpers

  private func readyModel() async throws -> (AppViewModel, URL) {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("MacMintReliability-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let model = AppViewModel(supportDirectory: folder)
    try await waitUntil { model.exclusionsReady }
    return (model, folder)
  }

  private func waitUntil(seconds: Double = 3, _ condition: @MainActor () async -> Bool) async throws {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
      if await condition() { return }
      try await Task.sleep(for: .milliseconds(10))
    }
    XCTFail("Condition was not met within \(seconds) seconds")
  }
}

private final class Counter: @unchecked Sendable {
  private let lock = NSLock()
  private var count = 0
  func increment() { lock.lock(); count += 1; lock.unlock() }
  var value: Int { lock.lock(); defer { lock.unlock() }; return count }
}

@MainActor
private final class Tokens {
  var value: String?
  var storage: AccountTokenStorage {
    AccountTokenStorage(load: { self.value }, save: { self.value = $0; return true }, delete: { self.value = nil })
  }
}

/// Signs in, reports AI as available, and can hold an Ask request at the network boundary.
private actor AIFixture {
  private var holding = false
  private var pending: CheckedContinuation<Void, Never>?
  var isHoldingAsk: Bool { pending != nil }
  func holdAsk() { holding = true }
  func releaseAsk() { holding = false; pending?.resume(); pending = nil }

  func respond(_ request: URLRequest) async throws -> (Data, URLResponse) {
    let path = request.url!.path
    var body: [String: Any]
    if path.hasSuffix("auth-with-password") || path.hasSuffix("auth-refresh") {
      body = ["token": "fixture-token", "record": ["id": "fixture", "email": "fixture@example.invalid", "verified": true]]
    } else if path.contains("app_config") {
      body = ["items": [["value": ["enabled": true]]]]
    } else if path.hasSuffix("/ask") {
      if holding { await withCheckedContinuation { pending = $0 } }
      body = ["answer": "Fixture answer", "actions": []]
    } else {
      body = ["user": ["id": "fixture", "email": "fixture@example.invalid", "verified": true],
        "entitlement": ["plan": "pro", "status": "active", "active": true, "max_devices": 1],
        "devices": [["id": "device", "device_id": "reliability-device", "name": "Fixture", "model": "Fixture",
          "os_version": "test", "app_version": "test", "last_seen": ""]]]
    }
    return (try JSONSerialization.data(withJSONObject: body),
      HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
  }
}
