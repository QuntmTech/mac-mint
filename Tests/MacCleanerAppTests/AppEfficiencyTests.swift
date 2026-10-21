import AppKit
import Foundation
import MacCleanerCore
import XCTest
@testable import MacCleanerApp

@MainActor
private final class Box<Value> {
  var value: Value
  init(_ value: Value) { self.value = value }
}

private final class LockedValue<Value: Sendable>: @unchecked Sendable {
  private let lock = NSLock()
  private var stored: Value
  init(_ value: Value) { stored = value }
  var value: Value {
    get { lock.lock(); defer { lock.unlock() }; return stored }
    set { lock.lock(); stored = newValue; lock.unlock() }
  }
}

@MainActor
private struct QuietTamingBackend: TamingBackend {
  func status(_ identity: TamingIdentity) -> TamingTargetStatus { .current }
  func setBackground(_ background: Bool, for identity: TamingIdentity) throws {}
}

@MainActor
final class AppEfficiencyTests: XCTestCase {
  func testDiskCapacityIsReadAtMostOncePerMinuteAndReusedBetweenSamples() async {
    let now = LockedValue<TimeInterval>(0)
    let reads = LockedValue(0)
    let sampler = ResourceSampler(readDisk: { reads.value += 1; return (free: 7, total: 10) }, clock: { now.value })
    for second in stride(from: 0.0, to: 60, by: 4) {
      now.value = second
      let result = await sampler.read(pids: [])
      XCTAssertEqual(result.snapshot.freeBytes, 7); XCTAssertEqual(result.snapshot.totalBytes, 10)
    }
    XCTAssertEqual(reads.value, 1, "Fifteen 4-second samples share one important-usage reading")
    now.value = 60; _ = await sampler.read(pids: [])
    XCTAssertEqual(reads.value, 2)
    await sampler.reset(); now.value = 64; _ = await sampler.read(pids: [])
    XCTAssertEqual(reads.value, 2, "Pausing sampling keeps the cached capacity")
    let diskReads = await sampler.diskReads
    XCTAssertEqual(diskReads, 2)
  }

  func testFailedDiskReadsAreUnknownOrStaleNeverAFabricatedZero() async {
    let now = LockedValue<TimeInterval>(0)
    let next = LockedValue<(free: Int64, total: Int64)?>(nil)
    let sampler = ResourceSampler(readDisk: { next.value }, clock: { now.value })
    var snapshot = await sampler.read(pids: []).snapshot
    XCTAssertFalse(snapshot.hasDiskReading); XCTAssertNil(snapshot.diskUsedFraction)
    XCTAssertFalse(snapshot.diskStale, "Nothing was ever measured, so nothing is stale")
    next.value = (free: 0, total: 0); now.value = 60
    snapshot = await sampler.read(pids: []).snapshot
    XCTAssertFalse(snapshot.hasDiskReading, "A zero capacity is a missing reading, not a full disk")
    next.value = (free: 40, total: 100); now.value = 120
    snapshot = await sampler.read(pids: []).snapshot
    XCTAssertEqual(snapshot.freeBytes, 40); XCTAssertEqual(snapshot.diskUsedFraction, 0.6); XCTAssertFalse(snapshot.diskStale)
    next.value = nil; now.value = 180
    snapshot = await sampler.read(pids: []).snapshot
    XCTAssertEqual(snapshot.freeBytes, 40, "A failed read keeps the last good capacity")
    XCTAssertEqual(snapshot.totalBytes, 100); XCTAssertTrue(snapshot.diskStale)
    next.value = (free: 30, total: 100); now.value = 240
    snapshot = await sampler.read(pids: []).snapshot
    XCTAssertEqual(snapshot.freeBytes, 30); XCTAssertFalse(snapshot.diskStale)
  }

  func testVolumeSummaryTreatsMissingCapacityAsUnmeasured() {
    XCTAssertFalse(VolumeSummary.summary(name: nil, total: nil, free: 5).isMeasured)
    XCTAssertFalse(VolumeSummary.summary(name: "Data", total: 100, free: nil).isMeasured)
    XCTAssertFalse(VolumeSummary.summary(name: "Data", total: 0, free: 0).isMeasured)
    let measured = VolumeSummary.summary(name: "Data", total: 100, free: 0)
    XCTAssertTrue(measured.isMeasured, "A measured zero is a real full disk")
    XCTAssertEqual(measured.used, 100); XCTAssertEqual(measured.name, "Data")
  }

  func testWindowLeasesSampleOnlyWhileTheWorkspaceIsInFront() {
    let front = Box(false)
    let activity = AppActivity(center: NotificationCenter(), evaluate: { front.value })
    let monitor = SystemMonitor(activity: activity)
    let window = UUID(), popover = UUID()
    monitor.start(lease: window, interval: 20)
    XCTAssertEqual(monitor.activeLeaseCount, 1)
    XCTAssertNil(monitor.samplingInterval, "Hidden, inactive, minimized or covered windows don't sample")
    front.value = true; activity.refresh()
    XCTAssertEqual(monitor.samplingInterval, 20); XCTAssertTrue(monitor.publishesReadings)
    front.value = false; activity.refresh()
    XCTAssertNil(monitor.samplingInterval); XCTAssertFalse(monitor.publishesReadings)
    monitor.start(lease: popover, interval: 15, kind: .popover)
    XCTAssertEqual(monitor.samplingInterval, 15, "An open menu bar popover keeps its own live readings")
    XCTAssertTrue(monitor.publishesReadings)
    monitor.stop(lease: popover); XCTAssertNil(monitor.samplingInterval)
    monitor.stop(lease: window); XCTAssertEqual(monitor.activeLeaseCount, 0)
  }

  func testAutoTameAddsNoPollingWhileOffAndSharesTheSamplerSilentlyWhileOn() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let controller = AppTamingController(store: TamingStore(url: root.appendingPathComponent("journal.json")),
      backend: QuietTamingBackend())
    let monitor = SystemMonitor(tamingController: controller,
      activity: AppActivity(center: NotificationCenter(), evaluate: { false }))
    monitor.activateControls()
    XCTAssertEqual(monitor.activeLeaseCount, 0); XCTAssertNil(monitor.samplingInterval)
    monitor.setAutomaticTaming(true)
    XCTAssertEqual(monitor.activeLeaseCount, 1); XCTAssertEqual(monitor.samplingInterval, 8)
    XCTAssertFalse(monitor.publishesReadings, "Background control sampling never re-renders views")
    let window = UUID()
    monitor.start(lease: window)
    XCTAssertEqual(monitor.samplingInterval, 8, "One timer serves every consumer")
    monitor.setAutomaticTaming(false)
    XCTAssertEqual(monitor.activeLeaseCount, 1); XCTAssertNil(monitor.samplingInterval)
    monitor.stop(lease: window)
  }

  func testActivityNotifiesObserversOnlyWhenForegroundStateChanges() {
    let center = NotificationCenter()
    let front = Box(true)
    let activity = AppActivity(center: center, evaluate: { front.value })
    let events = Box<[Bool]>([])
    activity.observe { events.value.append($0) }
    func post(_ name: Notification.Name) {
      center.post(name: name, object: nil)
      RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    }
    front.value = false
    post(NSApplication.didHideNotification)
    post(NSWindow.didChangeOcclusionStateNotification)
    post(NSApplication.didResignActiveNotification)
    front.value = true
    post(NSApplication.didBecomeActiveNotification)
    XCTAssertEqual(events.value, [false, true])
    XCTAssertTrue(activity.isForeground)
  }

  func testBackgroundReleaseWaitsThenPurgesCompactsAndRelieves() async throws {
    let counts = Box((purge: 0, compact: 0, relieve: 0))
    let held = Box(true)
    let relief = MemoryRelief(delay: 0.05, purge: { counts.value.purge += 1; return held.value },
      relieve: { counts.value.relieve += 1 })
    relief.register { counts.value.compact += 1; return false }
    relief.foregroundChanged(false); relief.foregroundChanged(true)
    try await Task.sleep(for: .milliseconds(200))
    XCTAssertEqual(relief.releases, 0, "Returning before the delay keeps caches warm")
    relief.foregroundChanged(false)
    for _ in 0..<100 where relief.releases == 0 { try await Task.sleep(for: .milliseconds(50)) }
    XCTAssertEqual(relief.releases, 1)
    XCTAssertEqual(counts.value.purge, 1); XCTAssertEqual(counts.value.compact, 1); XCTAssertEqual(counts.value.relieve, 1)
    held.value = false
    relief.release()
    XCTAssertEqual(relief.releases, 2)
    XCTAssertEqual(counts.value.relieve, 1, "Nothing dropped, so the allocator walk is skipped")
  }

  func testMemoryReleaseKeepsSelectionsQueueAndHistory() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let model = AppViewModel(supportDirectory: root)
    model.selectedPhotoIDs = ["photos:keep"]; model.selectedStoragePaths = ["/tmp/keep"]
    model.history = [HistoryEntry(action: "Fixture", paths: [], bytes: 1, notes: "")]
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 16, pixelsHigh: 16, bitsPerSample: 8,
      samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 64, bitsPerPixel: 32)!
    let image = NSImage(size: NSSize(width: 16, height: 16)); image.addRepresentation(bitmap)
    PreviewCaches.photos.insert(image, for: "fixture")
    MemoryRelief(delay: 0).release()
    XCTAssertEqual(PreviewCaches.photos.storedCost, 0)
    XCTAssertEqual(model.selectedPhotoIDs, ["photos:keep"]); XCTAssertEqual(model.selectedStoragePaths, ["/tmp/keep"])
    XCTAssertEqual(model.history.count, 1)
  }

  func testLeavingStorageCompactsTheMapButKeepsSelectionsTrailAndTotals() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    func folder(_ path: String, _ children: [StorageNode]) -> StorageNode {
      StorageNode(url: URL(fileURLWithPath: path, isDirectory: true), kind: .folder,
        allocatedBytes: children.reduce(0) { $0 + $1.allocatedBytes }, logicalBytes: children.reduce(0) { $0 + $1.logicalBytes },
        itemCount: children.reduce(0) { $0 + $1.itemCount }, children: children)
    }
    func file(_ path: String) -> StorageNode {
      StorageNode(url: URL(fileURLWithPath: path), kind: .file, allocatedBytes: 4_096, logicalBytes: 4_096, itemCount: 1)
    }
    let tree = folder("/h", [folder("/h/a", [folder("/h/a/b", [folder("/h/a/b/c", [file("/h/a/b/c/x")]), file("/h/a/b/y")])]),
      folder("/h/d", [folder("/h/d/e", [folder("/h/d/e/f", [file("/h/d/e/f/z")])])])])
    let model = AppViewModel(supportDirectory: root)
    model.storageScan = StorageScan(root: tree, coverage: StorageCoverage(), duration: 1)
    model.selectedStoragePaths = ["/h/a/b/c/x"]
    model.storagePath = "/h/d"
    model.compactStorageMap()
    let compact = try XCTUnwrap(model.storageScan?.root)
    XCTAssertEqual(compact.allocatedBytes, tree.allocatedBytes)
    XCTAssertNotNil(compact.node(at: "/h/a/b/c/x"), "Selected items stay reachable")
    XCTAssertEqual(model.queuedStorageNodes.map(\.id), ["/h/a/b/c/x"])
    XCTAssertNil(compact.node(at: "/h/d/e/f"), "Deep levels off screen are released")
    let pruned = try XCTUnwrap(compact.node(at: "/h/d/e"))
    XCTAssertTrue(pruned.children.isEmpty)
    XCTAssertTrue(model.canOpenStorageNode(pruned), "A released folder can still be opened (it is mapped again)")
    XCTAssertEqual(model.storagePath, "/h/d")
    XCTAssertEqual(model.selectedStoragePaths, ["/h/a/b/c/x"])
  }

  func testFileIconsAreReusedBoundedAndReleased() {
    FileIcons.removeAll()
    let first = FileIcons.icon(forPath: "/System/Applications/Calculator.app")
    XCTAssertTrue(first === FileIcons.icon(forPath: "/System/Applications/Calculator.app"), "Rows reuse one icon per path")
    for index in 0..<(FileIcons.countLimit + 10) { _ = FileIcons.icon(forPath: "/tmp/macmint-icon-\(index)") }
    XCTAssertEqual(FileIcons.count, FileIcons.countLimit)
    PreviewCaches.release()
    XCTAssertEqual(FileIcons.count, 0)
  }

  func testRowsIgnoreChangesBelowDisplayPrecisionAndAreBuiltOncePerInput() {
    func inputs(cpu: Double, memory: Int64, sort: PerformancePresentation.Sort = .init()) -> PerformancePresentation.RowInputs {
      .init(apps: [.init(id: .init(pid: 7, started: 1), name: "Editor", bundleID: "example.editor", memoryBytes: memory, cpuPercent: cpu),
        .init(id: .init(pid: 8, started: 1), name: "Browser", bundleID: nil, memoryBytes: 1_000_000, cpuPercent: 0)],
        query: "", sort: sort, taming: TamingState(), physicalMemory: 16_000_000_000, logicalCPUCount: 8,
        controllable: [.init(pid: 7, started: 1)])
    }
    let first = PerformancePresentation.rows(inputs(cpu: 12.31, memory: 300_010_000))
    let noise = PerformancePresentation.rows(inputs(cpu: 12.34, memory: 300_020_000))
    XCTAssertEqual(first, noise, "Invisible changes must not re-render a row")
    XCTAssertEqual(first.map(\.cpuText), ["12.3%", "0.0%"])
    XCTAssertEqual(first.first?.control.canControl, true); XCTAssertEqual(first.last?.control.canControl, false)
    XCTAssertNotEqual(first, PerformancePresentation.rows(inputs(cpu: 14, memory: 300_010_000)))
    XCTAssertEqual(PerformancePresentation.quantized(0.123), 0.125)
    let cache = PerformancePresentation.RowCache()
    _ = cache.rows(inputs(cpu: 1, memory: 1)); _ = cache.rows(inputs(cpu: 1, memory: 1))
    XCTAssertEqual(cache.builds, 1)
    _ = cache.rows(inputs(cpu: 1, memory: 1, sort: .init(key: .name, direction: .ascending)))
    XCTAssertEqual(cache.builds, 2)
  }
}
