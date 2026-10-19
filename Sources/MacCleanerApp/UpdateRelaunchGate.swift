import Foundation

/// Holds an update's relaunch while MacMint moves, restores or organizes files. Sparkle's
/// installer waits for the app to quit, so postponing only delays the swap; nothing is
/// interrupted. Knows nothing about Sparkle, so it is unit tested directly.
@MainActor
final class UpdateRelaunchGate {
  /// Reads `AppViewModel.isWorking`; set when the model is bound.
  var isWorking: () -> Bool = { false }
  /// Set once Sparkle relaunches. The quit guard then waits instead of asking again.
  private(set) var isRelaunching = false
  private var waiting: [() -> Void] = []

  var isHolding: Bool { !waiting.isEmpty }

  /// For Sparkle's `shouldPostponeRelaunchForUpdate`: true when `resume` must wait for work.
  func postponeRelaunch(_ resume: @escaping () -> Void) -> Bool {
    guard isWorking() else { return false }
    waiting.append(resume)
    return true
  }

  func relaunchWillBegin() { isRelaunching = true }

  /// Work that started after the user chose Install and Relaunch finishes first; then quit.
  func terminateWhenIdle(_ terminate: @escaping () -> Void) {
    if isWorking() { waiting.append(terminate) } else { terminate() }
  }

  /// Call after `isWorking` changes. Releases everything held once no work remains.
  func workDidChange() {
    guard !isWorking(), !waiting.isEmpty else { return }
    let ready = waiting
    waiting = []
    ready.forEach { $0() }
  }
}
