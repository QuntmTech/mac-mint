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
    let model = AppViewModel(supportDirectory: support.appendingPathComponent("model"))
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
    if model.queuedCount != 1 || model.queuedBytes != 4096 { failures.append("Deduplicated queue totals") }
    model.setFileSelection(b.url, selected: false)
    if !model.selectedLargeFileIDs.isEmpty || !model.selectedDownloadIDs.isEmpty { failures.append("Cross-module keep") }
    model.duplicateGroups = [DuplicateGroup(fingerprint: "fixture", files: [a, b])]
    model.setFileSelection(b.url, selected: true)
    model.setFileSelection(a.url, selected: true)
    if model.selectedDuplicateIDs != [b.id] { failures.append("Cross-module last-copy protection") }
    let selectedBeforeAction = model.selectedDuplicateIDs
    model.openAIDestination("shortcuts://run-shortcut?name=remove-files")
    if model.selectedSection != .dashboard || model.selectedDuplicateIDs != selectedBeforeAction { failures.append("AI navigation boundary") }
    let prose = AssistantView.rendered("[run](shortcuts://run-shortcut?name=remove-files)")
    if prose.runs.contains(where: { $0.link != nil }) { failures.append("AI prose links must stay inert") }
    model.assistantDraft = "Keep this question while scanning"
    model.isScanning = true
    model.ask(model.assistantDraft, account: account)
    if model.assistantDraft.isEmpty || !model.assistantTurns.isEmpty { failures.append("Pending question retention") }
    model.isScanning = false
    model.assistantDraft = ""
    model.clearQueue(); model.largeFiles = []; model.downloadItems = []; model.duplicateGroups = []
    model.statusMessage = "Ready when you are · Local inspection"

    let screenshotDirectory = ProcessInfo.processInfo.environment["MACMINT_SCREENSHOT_DIR"].map { URL(fileURLWithPath: $0) }
    if let screenshotDirectory { try? FileManager.default.createDirectory(at: screenshotDirectory, withIntermediateDirectories: true) }
    var scheme: ColorScheme = .light
    let layoutProbe = WorkspaceLayoutProbe()

    func render<V: View>(_ name: String, _ view: V, width: CGFloat = 1200, height: CGFloat = 800) {
      rendered += 1
      layoutProbe.frames = [:]
      let content = view
        .onPreferenceChange(WorkspaceLayoutFrames.self) { frames in
          MainActor.assumeIsolated { layoutProbe.frames = frames }
        }
        .environmentObject(model).environmentObject(account).environmentObject(monitor)
        .environmentObject(care).environmentObject(updates).environmentObject(appUpdates)
        .environment(\.colorScheme, scheme).tint(AppTheme.accent)
        .frame(width: width, height: height).background(AppTheme.canvas)
      autoreleasepool {
        if let screenshotDirectory {
          // Capture actual AppKit-backed controls as well as SwiftUI. Release each
          // hosting tree before changing shared models for the next screen.
          let hosting = NSHostingView(rootView: content)
          hosting.sizingOptions = []
          let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height),
            styleMask: [.borderless], backing: .buffered, defer: false)
          // A content-only capture must not let SwiftUI install a titlebar toolbar
          // and change the host's content size after layout starts.
          window.isReleasedWhenClosed = false
          window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
          window.contentView = hosting
          window.setContentSize(NSSize(width: width, height: height))
          window.orderFront(nil)
          RunLoop.current.run(until: Date().addingTimeInterval(0.12))
          hosting.frame = NSRect(x: 0, y: 0, width: width, height: height)
          hosting.layoutSubtreeIfNeeded()
          if (name.contains("-Empty-") || name.contains("-Populated-") || name.contains("-Compact-")), !Set(layoutProbe.frames.keys).isSuperset(of: ["brand", "workspace controls"]) {
            failures.append("Missing workspace layout evidence: " + name)
          }
          for (element, frame) in layoutProbe.frames {
            if frame.minY < -1 || frame.maxY > height + 1 || frame.minX < -1 || frame.maxX > width + 1 {
              failures.append("Offscreen " + element + ": " + name)
              print("✗ Layout \(name): \(element) \(frame), bounds \(hosting.bounds)")
            }
          }
          if abs(hosting.bounds.width - width) > 1 || abs(hosting.bounds.height - height) > 1 {
            failures.append("Window exceeded requested size: " + name)
            print("✗ Host \(name): \(hosting.bounds), expected \(width) × \(height)")
          }
          if let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) {
            hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
            if let png = bitmap.representation(using: .png, properties: [:]) {
              let filename = name.replacingOccurrences(of: " ", with: "-").replacingOccurrences(of: "/", with: "-")
              do { try png.write(to: screenshotDirectory.appendingPathComponent(filename + ".png")) }
              catch { failures.append("Screenshot write: " + name) }
            } else { failures.append("Screenshot encoding: " + name) }
          } else { failures.append("Screenshot layout: " + name) }
          window.orderOut(nil)
          window.contentView = nil
          window.close()
        } else if ImageRenderer(content: content).nsImage == nil {
          failures.append(name)
        }
      }
      print("✓ \(name)")
    }

    for appearance in [ColorScheme.light, .dark] {
      scheme = appearance
      let prefix = appearance == .dark ? "Dark" : "Light"
      for section in AppViewModel.Section.allCases {
        model.selectedSection = section
        render(prefix + "-Empty-" + section.rawValue, RootView())
      }
    }
    seedDesignFixtures(model, root: support.appendingPathComponent("Fixtures"))
    let review = OperationPlan(title: "Selected items", items: model.cleanupTargets.filter(\.isSelected).map { PlanItem.cleanup($0) })
    for appearance in [ColorScheme.light, .dark] {
      scheme = appearance
      let prefix = appearance == .dark ? "Dark" : "Light"
      for section in AppViewModel.Section.primary + [.review, .duplicates, .settings] {
        model.selectedSection = section
        render(prefix + "-Populated-" + section.rawValue, RootView())
        render(prefix + "-Compact-" + section.rawValue, RootView(), width: 980, height: 660)
      }
      render(prefix + "-Photo-deck", PhotoReviewDeck(photos: model.allScannedPhotos), width: 720, height: 480)
      render(prefix + "-Final-review", PlanReviewSheet(plan: review), width: 720, height: 640)
      render(prefix + "-Menu-bar", MenuBarView(), width: 320, height: 400)
      render(prefix + "-Onboarding", OnboardingView(), width: 720, height: 540)
    }
    scheme = .light
    render("Help", HelpView())
    render("Account access", AccountAccessSheet())
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


/// Only the smoke harness reads these preferences; normal windows do not collect them.
struct WorkspaceLayoutFrames: PreferenceKey {
  static let defaultValue: [String: CGRect] = [:]
  static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
    value.merge(nextValue(), uniquingKeysWith: { _, next in next })
  }
}

@MainActor
private final class WorkspaceLayoutProbe {
  var frames: [String: CGRect] = [:]
}
