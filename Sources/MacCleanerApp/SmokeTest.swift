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
    var rendered = 0
    // Exercise real app selection coordination without moving or reading user files.
    let a = LargeFile(url: support.appendingPathComponent("keep.bin"), size: 4096, modifiedAt: nil, accessedAt: nil)
    let b = LargeFile(url: support.appendingPathComponent("copy.bin"), size: 4096, modifiedAt: nil, accessedAt: nil)
    let download = DownloadItem(url: b.url, kind: .document, bytes: 4096, usage: .unknown,
      modified: nil, logicalSize: nil, identity: nil, idleDays: 100)
    model.largeFiles = [b]; model.downloadItems = [download]
    model.setFileSelection(b.url, selected: true)
    if !model.selectedLargeFileIDs.contains(b.id) || !model.selectedDownloadIDs.contains(download.id) {
      failures.append("Cross-module queue selection")
    }
    model.setFileSelection(b.url, selected: false)
    if !model.selectedLargeFileIDs.isEmpty || !model.selectedDownloadIDs.isEmpty { failures.append("Cross-module keep") }
    model.duplicateGroups = [DuplicateGroup(fingerprint: "fixture", files: [a, b])]
    model.setFileSelection(b.url, selected: true)
    model.setFileSelection(a.url, selected: true)
    if model.selectedDuplicateIDs != [b.id] { failures.append("Cross-module last-copy protection") }
    model.clearQueue(); model.largeFiles = []; model.downloadItems = []; model.duplicateGroups = []

    func render<V: View>(_ name: String, _ view: V, width: CGFloat = 1200, height: CGFloat = 800) {
      rendered += 1
      let content = view
        .environmentObject(model)
        .environmentObject(account)
        .environmentObject(monitor)
        .environmentObject(care)
        .environmentObject(updates)
        .environmentObject(appUpdates)
        .tint(AppTheme.accent)
        .frame(width: width, height: height)
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
    model.selectedSection = .dashboard
    render("Dark overview", RootView().environment(\.colorScheme, .dark))
    render("Compact overview", RootView(), width: 980, height: 660)
    render("Help", HelpView())
    render("Account access", AccountAccessSheet())
    render("Empty final review", PlanReviewSheet(plan: OperationPlan(title: "Review", items: [])))
    render("Menu bar", MenuBarView())
    render("Onboarding", OnboardingView())
    render("Command palette", CommandPalette())

    let seconds = Date().timeIntervalSince(started)
    print(
      failures.isEmpty
        ? "Smoke test passed: \(rendered) screens in \(String(format: "%.1f", seconds))s"
        : "Smoke test FAILED: \(failures.joined(separator: ", "))")
    try? FileManager.default.removeItem(at: support)
    exit(failures.isEmpty ? 0 : 1)
  }
}
