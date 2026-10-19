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
  private var compactions: [UUID: @MainActor () -> Void] = [:]
  private var closeObserver: NSObjectProtocol?
  private let purge: @MainActor () -> Void
  private let relieve: @MainActor () -> Void
  private let delay: TimeInterval
  private(set) var releases = 0

  init(delay: TimeInterval = MemoryRelief.backgroundDelay,
    purge: @escaping @MainActor () -> Void = { PreviewCaches.release() },
    relieve: @escaping @MainActor () -> Void = { _ = malloc_zone_pressure_relief(nil, 0) }) {
    self.delay = delay; self.purge = purge; self.relieve = relieve
  }

  /// Idempotent. Call once the app has launched.
  func start(activity: AppActivity = .shared) {
    guard pressureSource == nil else { return }
    let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
    source.setEventHandler { @Sendable [weak self] in MainActor.assumeIsolated { self?.release() } }
    source.resume(); pressureSource = source
    activity.observe { [weak self] foreground in self?.foregroundChanged(foreground) }
    closeObserver = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: nil,
      queue: .main) { @Sendable [weak self] note in
      let normal = MainActor.assumeIsolated { (note.object as? NSWindow).map { $0.level == .normal && !($0 is NSPanel) } ?? false }
      guard normal else { return }
      // Release after the window and its views have actually gone away.
      Task { @MainActor [weak self] in self?.release() }
    }
  }

  /// Registers work that drops recomputable state; returns a token for `unregister`.
  @discardableResult
  func register(_ compaction: @escaping @MainActor () -> Void) -> UUID {
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
      self?.release()
    }
  }

  /// After a large scan finishes, its temporaries are freed but malloc keeps the pages;
  /// hand them back shortly afterwards.
  func relieveSoon(after seconds: TimeInterval = 2) {
    Task { [weak self] in
      try? await Task.sleep(for: .seconds(seconds))
      self?.relieve()
    }
  }

  func release() {
    pending?.cancel(); pending = nil
    purge()
    for compaction in compactions.values { compaction() }
    releases += 1
    relieve()
  }
}
