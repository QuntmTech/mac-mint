import AppKit

/// Whether a MacMint workspace window is in front of the person: the app is active and
/// unhidden, and a normal window is on screen (not minimized, closed or fully covered).
/// Window-bound sampling and refreshes pause whenever this is false.
@MainActor
final class AppActivity {
  static let shared = AppActivity()

  private(set) var isForeground: Bool
  private let evaluate: @MainActor () -> Bool
  private var handlers: [UUID: @MainActor (Bool) -> Void] = [:]
  private var observers: [NSObjectProtocol] = []

  init(center: NotificationCenter = .default, evaluate: @escaping @MainActor () -> Bool = AppActivity.workspaceInFront) {
    self.evaluate = evaluate
    isForeground = evaluate()
    let names: [Notification.Name] = [
      NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification,
      NSApplication.didHideNotification, NSApplication.didUnhideNotification,
      NSWindow.didChangeOcclusionStateNotification, NSWindow.didMiniaturizeNotification,
      NSWindow.didDeminiaturizeNotification, NSWindow.didBecomeMainNotification, NSWindow.willCloseNotification,
    ]
    for name in names {
      observers.append(center.addObserver(forName: name, object: nil, queue: .main) { @Sendable [weak self] note in
        let closing = note.name == NSWindow.willCloseNotification
        MainActor.assumeIsolated {
          // A closing window is still visible during its own notification.
          if closing { Task { @MainActor [weak self] in self?.refresh() } } else { self?.refresh() }
        }
      })
    }
  }

  /// Re-reads the window and app state, notifying observers only on a change.
  func refresh() {
    let next = evaluate()
    guard next != isForeground else { return }
    isForeground = next
    for handler in handlers.values { handler(next) }
  }

  @discardableResult
  func observe(_ handler: @escaping @MainActor (Bool) -> Void) -> UUID {
    let id = UUID()
    handlers[id] = handler
    return id
  }

  func removeObserver(_ id: UUID) { handlers[id] = nil }

  static func workspaceInFront() -> Bool {
    let app = NSApplication.shared
    guard app.isActive, !app.isHidden else { return false }
    return app.windows.contains { window in
      window.isVisible && !window.isMiniaturized && window.occlusionState.contains(.visible)
        && window.level == .normal && !(window is NSPanel) && window.canBecomeMain
    }
  }
}
