import AppKit
import Darwin

/// Returns disposable memory to macOS: decoded previews and icons, plus registered
/// compaction (such as the deep levels of a storage map). It runs when the workspace
/// window closes, after the app has been hidden or in the background for a short while,
/// after large scans, and on system memory-pressure warnings. Selections, the review
/// queue, History and recovery records are never part of a release.
@MainActor
final class MemoryRelief {
  static let shared = MemoryRelief()
  static let backgroundDelay: TimeInterval = 10

  private var pressureSource: DispatchSourceMemoryPressure?
  private var pending: Task<Void, Never>?
  private var compactions: [UUID: @MainActor () -> Bool] = [:]
  private var closeObserver: NSObjectProtocol?
  private let purge: @MainActor () -> Bool
  private let relieve: @MainActor () -> Void
  private let delay: TimeInterval
  private(set) var releases = 0

  /// One timed release. The last 20 are kept so the resource probe can attribute
  /// background CPU to them; recording costs a few clock reads.
  struct Record: Codable, Sendable {
    let reason: String
    /// System uptime when the release started.
    let at: TimeInterval
    let purgeMS: Double
    let compactMS: Double
    /// The allocator walk; zero when nothing was dropped and the walk was skipped.
    let relieveMS: Double
    let freed: Bool
  }
  private(set) var records: [Record] = []

  init(delay: TimeInterval = MemoryRelief.backgroundDelay,
    purge: @escaping @MainActor () -> Bool = { PreviewCaches.release() },
    relieve: @escaping @MainActor () -> Void = { _ = malloc_zone_pressure_relief(nil, 0) }) {
    self.delay = delay; self.purge = purge; self.relieve = relieve
  }

  /// Idempotent. Call once the app has launched.
  func start(activity: AppActivity = .shared) {
    guard pressureSource == nil else { return }
    let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
    source.setEventHandler { @Sendable [weak self] in MainActor.assumeIsolated { self?.release(reason: "memory pressure") } }
    source.resume(); pressureSource = source
    activity.observe { [weak self] foreground in self?.foregroundChanged(foreground) }
    closeObserver = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: nil,
      queue: .main) { @Sendable [weak self] _ in
      // Checked after the window and its views have actually gone away; sheets and the
      // menu bar popover closing don't count while a workspace window remains.
      Task { @MainActor [weak self] in
        let open = NSApplication.shared.windows.contains {
          $0.isVisible && $0.level == .normal && !($0 is NSPanel) && $0.canBecomeMain
        }
        if !open { self?.release(reason: "window closed") }
      }
    }
  }

  /// Registers work that drops recomputable state and reports whether it dropped anything;
  /// returns a token for `unregister`.
  @discardableResult
  func register(_ compaction: @escaping @MainActor () -> Bool) -> UUID {
    let id = UUID()
    compactions[id] = compaction
    return id
  }

  func unregister(_ id: UUID) { compactions[id] = nil }

  func foregroundChanged(_ foreground: Bool) {
    pending?.cancel(); pending = nil
    guard !foreground else { return }
    let delay = delay
    pending = Task { [weak self] in
      try? await Task.sleep(for: .seconds(delay))
      guard !Task.isCancelled else { return }
      self?.release(reason: "in background")
    }
  }

  /// After a large scan finishes, its temporaries are freed but malloc keeps the pages;
  /// hand them back shortly afterwards.
  func relieveSoon(after seconds: TimeInterval = 2) {
    Task { [weak self] in
      try? await Task.sleep(for: .seconds(seconds))
      guard let self else { return }
      let start = ProcessInfo.processInfo.systemUptime
      relieve()
      note(Record(reason: "after a scan or screen change", at: start, purgeMS: 0, compactMS: 0,
        relieveMS: (ProcessInfo.processInfo.systemUptime - start) * 1000, freed: true))
    }
  }

  func release(reason: String = "requested") {
    pending?.cancel(); pending = nil
    let start = ProcessInfo.processInfo.systemUptime
    var freed = purge()
    let purged = ProcessInfo.processInfo.systemUptime
    for compaction in compactions.values where compaction() { freed = true }
    let compacted = ProcessInfo.processInfo.systemUptime
    releases += 1
    // Scans and screen changes already hand pages back; a release with nothing to drop
    // skips the allocator walk, which is itself measurable CPU in the background.
    if freed { relieve() }
    note(Record(reason: reason, at: start, purgeMS: (purged - start) * 1000, compactMS: (compacted - purged) * 1000,
      relieveMS: freed ? (ProcessInfo.processInfo.systemUptime - compacted) * 1000 : 0, freed: freed))
  }

  private func note(_ record: Record) {
    records.append(record)
    if records.count > 20 { records.removeFirst(records.count - 20) }
  }
}
