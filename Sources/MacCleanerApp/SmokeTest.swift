import AppKit
import MacCleanerCore
import SwiftUI

/// `MacMint --smoke-test`: builds the real view models and renders every screen offscreen,
/// then exits 0 (or 1 when a screen fails to render). Used by CI to prove the packaged app
/// launches and lays out without crashing. No sign-in or network is involved.
@MainActor
enum SmokeTest {
  static var isRequested: Bool { CommandLine.arguments.contains("--smoke-test") }

  static func run() -> Never {
    // Runs from App.init, before SwiftUI creates the application object.
    _ = NSApplication.shared
    setvbuf(stdout, nil, _IONBF, 0)
    let started = Date()
    let support = FileManager.default.temporaryDirectory
      .appendingPathComponent("macmint-smoke-\(ProcessInfo.processInfo.processIdentifier)")
    let model = AppViewModel()
    let account = AccountStore(supportDirectory: support)
    let monitor = SystemMonitor()
    let care = CareService()
    let updates = UpdateService()
    let appUpdates = AppUpdatesStore()
    monitor.sample()

    var failures: [String] = []
    func render<V: View>(_ name: String, _ view: V) {
      let content = view
        .environmentObject(model)
        .environmentObject(account)
        .environmentObject(monitor)
        .environmentObject(care)
        .environmentObject(updates)
        .environmentObject(appUpdates)
        .tint(AppTheme.accent)
        .frame(width: 1200, height: 800)
      let renderer = ImageRenderer(content: content)
      if renderer.nsImage == nil {
        failures.append(name)
        print("✗ \(name)")
      } else {
        print("✓ \(name)")
      }
    }

    render("Account gate", AccountGateView())
    for section in AppViewModel.Section.allCases {
      model.selectedSection = section
      render(section.rawValue, RootView())
    }
    render("Menu bar", MenuBarView())
    render("Onboarding", OnboardingView())
    render("Command palette", CommandPalette())

    let seconds = Date().timeIntervalSince(started)
    print(
      failures.isEmpty
        ? "Smoke test passed: \(AppViewModel.Section.allCases.count + 4) screens in \(String(format: "%.1f", seconds))s"
        : "Smoke test FAILED: \(failures.joined(separator: ", "))")
    try? FileManager.default.removeItem(at: support)
    exit(failures.isEmpty ? 0 : 1)
  }
}
