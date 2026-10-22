import AppKit
import MacCleanerCore
import Sparkle
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
    let updater = UpdaterController(startingUpdater: false)
    let appUpdates = AppUpdatesStore()
    monitor.sample()
    // Normal windows refresh these summaries asynchronously; offscreen renders need them now.
    model.refreshVolumeSummaryNow()

    var failures: [String] = []
    var rendered = 0
    // The packaged updater, without network: Sparkle loads from Contents/Frameworks without
    // XPC services, the public key is set and both channel feeds are trusted.
    if Bundle.main.bundleURL.pathExtension == "app" {
      let frameworks = Bundle.main.bundleURL.appendingPathComponent("Contents/Frameworks").resolvingSymlinksInPath().path + "/"
      let sparkle = Bundle(for: SPUUpdater.self).bundleURL.resolvingSymlinksInPath()
      if !sparkle.path.hasPrefix(frameworks) { failures.append("Embedded Sparkle.framework") }
      if FileManager.default.fileExists(atPath: sparkle.appendingPathComponent("Versions/Current/XPCServices").path) {
        failures.append("Unused Sparkle XPC services")
      }
      let key = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String
      if key.flatMap({ Data(base64Encoded: $0) })?.count != 32 { failures.append("Sparkle public key") }
      if UpdateChannel.allCases.contains(where: { UpdaterController.feedURLString(for: $0) == nil }) {
        failures.append("Update feeds")
      }
      if UpdaterController.current.build == nil || UpdaterController.current.commit == nil {
        failures.append("Stamped build number and commit")
      }
    }
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
    model.refreshQueueSummaryNow()
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
    model.refreshQueueSummaryNow()
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
        .environmentObject(care).environmentObject(updates).environmentObject(updater).environmentObject(appUpdates)
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
          if name.contains("-Performance-") {
            let requiredRows = name.contains("-Compact-") ? 3 : 5
            let viewport = layoutProbe.frames["performance viewport"]
            if viewport == nil { failures.append("Missing performance viewport: " + name) }
            for index in 0..<requiredRows {
              guard let frame = layoutProbe.frames["performance app row \(index)"] else {
                failures.append("Missing visible performance row \(index): " + name)
                continue
              }
              if let viewport, frame.height < 40 || frame.width <= 0 || !viewport.insetBy(dx: -1, dy: -1).contains(frame) {
                failures.append("Performance row \(index) is not fully visible: " + name)
                print("✗ Performance first-fold \(name): row \(index) \(frame), viewport \(viewport)")
              }
            }
          }
          for (element, frame) in layoutProbe.frames {
            // Later table rows may correctly extend below the scroll viewport.
            if element.hasPrefix("performance app row ") { continue }
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
    model.refreshQueueSummaryNow()
    let review = OperationPlan(title: "Selected items", items: model.cleanupTargets.filter(\.isSelected).map { PlanItem.cleanup($0) })
    for appearance in [ColorScheme.light, .dark] {
      scheme = appearance
      let prefix = appearance == .dark ? "Dark" : "Light"
      for section in AppViewModel.Section.primary + [.review, .duplicates, .settings] {
        model.selectedSection = section
        render(prefix + "-Populated-" + section.rawValue, RootView())
        render(prefix + "-Compact-" + section.rawValue, RootView(), width: 980, height: 660)
      }
      for state in PerformanceFixtureState.allCases {
        model.selectedSection = .performance
        let view = RootView().environment(\.performancePreview, performancePreview(state))
        render(prefix + "-Performance-Populated-" + state.rawValue, view)
        render(prefix + "-Performance-Compact-" + state.rawValue, view, width: 980, height: 660)
      }
      model.selectedSection = .dashboard
      model.tourStep = GuidedTour.steps.firstIndex { $0.target == .map }
      render(prefix + "-Tour-map", RootView())
      model.selectedSection = .dashboard
      model.tourStep = GuidedTour.steps.firstIndex { $0.target == .review }
      render(prefix + "-Tour-review", RootView(), width: 980, height: 660)
      model.tourStep = nil
      render(prefix + "-Organizer", OrganizerView(), width: 840, height: 660)
      render(prefix + "-Photo-deck", PhotoReviewDeck(), width: 720, height: 480)
      let reviewSession = model.photoReviewSession
      model.photoReviewSession.cursor = min(1, model.allScannedPhotos.count)
      render(prefix + "-Photo-deck-resumed", PhotoReviewDeck(), width: 720, height: 480)
      model.photoReviewSession.cursor = model.allScannedPhotos.count
      render(prefix + "-Photo-deck-complete", PhotoReviewDeck(), width: 720, height: 480)
      model.photoReviewSession = reviewSession
      let photoSelection = model.selectedPhotoIDs
      model.setPhotoSelection(model.allScannedPhotos, selected: true)
      model.refreshQueueSummaryNow()
      model.selectedSection = .photos
      render(prefix + "-Photos-bulk-selection", RootView(), width: 980, height: 660)
      model.selectedPhotoIDs = photoSelection
      model.refreshQueueSummaryNow()
      render(prefix + "-Final-review", PlanReviewSheet(plan: review), width: 720, height: 640)
      model.selectedSection = .settings
      let update = UpdaterController.Update(version: "0.9.0", build: "1000")
      updater.showPreview(available: update, reminder: update, waitingForWork: false)
      render(prefix + "-Update-available", RootView(), width: 980, height: 660)
      render(prefix + "-Updates-settings", UpdatesSettingsCard().padding(20), width: 720, height: 420)
      updater.showPreview(available: update, reminder: nil, waitingForWork: true)
      render(prefix + "-Update-waiting", RootView(), width: 980, height: 660)
      updater.showPreview(available: nil, reminder: nil, waitingForWork: false)
      render(prefix + "-Menu-bar", MenuBarView(), width: 320, height: 400)
      render(prefix + "-Onboarding", OnboardingView(initialStep: 0), width: 720, height: 660)
      render(prefix + "-Onboarding-access", OnboardingView(initialStep: 1), width: 720, height: 660)
      render(prefix + "-Onboarding-helpers", OnboardingView(initialStep: 2), width: 720, height: 660)
      render(prefix + "-Install-from-image", InstallationGuide(bundleURL: URL(fileURLWithPath: "/Volumes/MacMint/MacMint.app"), location: .readOnlyVolume), width: 640, height: 250)
      render(prefix + "-Install-ready", InstallationGuide(bundleURL: URL(fileURLWithPath: "/Applications/MacMint.app"), location: .installed), width: 640, height: 180)
      render(prefix + "-Access-help", PermissionHelpSheet(), width: 720, height: 660)
      render(prefix + "-Scan-issues", ScanIssueSheet(issues: [ScanIssue(area: "Downloads", message: "Access to this location was denied. Review Files & Folders settings before rescanning.")]), width: 720, height: 540)
    }
    scheme = .light
    render("Help", HelpView())
    render("Account access", AccountAccessSheet(), width: 560, height: 620)
    render("Account paid action", AccountAccessSheet(purpose: .paidAction, hasDeferredPlan: true), width: 560, height: 620)
    render("Account overview", AccountOverviewPanel(details: .init(email: "owner@example.com",
      plan: "Pro • Access until Oct 20, 2027", planActive: true, devices: "2 of 3 in use",
      thisMac: "Example MacBook Pro", offline: false), refresh: {}, manage: {}, signOut: {}).padding(24),
      width: 560, height: 360)
    render("Command palette", CommandPalette())

    let seconds = Date().timeIntervalSince(started)
    print(
      failures.isEmpty
        ? "Smoke test passed: \(rendered) screens in \(String(format: "%.1f", seconds))s"
        : "Smoke test FAILED: \(failures.joined(separator: ", "))")
    try? FileManager.default.removeItem(at: support)
    exit(failures.isEmpty ? 0 : 1)
  }

  private enum PerformanceFixtureState: String, CaseIterable {
    case populated, paused, highPressure = "high-pressure", unknownCPU = "unknown-cpu", tamed
  }

  private static func performancePreview(_ state: PerformanceFixtureState) -> PerformancePreview {
    let gb: Int64 = 1_000_000_000
    var snapshot = SystemMonitor.Snapshot(freeBytes: 165 * gb, totalBytes: 512 * gb,
      cpuUsage: 0.23, memoryUsedBytes: 10 * gb, physicalMemory: 16 * gb,
      swapUsedBytes: 512_000_000, pressure: .normal)
    let rows: [PerformancePresentation.App] = [
      .init(id: .init(pid: 401, started: 1), name: "Code Studio", bundleID: "example.code-studio",
        memoryBytes: 3 * gb, cpuPercent: 185.4, fallbackSymbol: "hammer.fill",
        helpers: ProcessFamilies.Helpers(count: 6, memoryBytes: 2 * gb, cpuPercent: 120.2, largest: [
          .init(pid: 501, name: "Code Studio Helper (Plugin)", memoryBytes: 900_000_000, cpuPercent: 96.3),
          .init(pid: 502, name: "language-server", memoryBytes: 600_000_000, cpuPercent: 20.1),
        ]), ownMemoryBytes: gb, ownCPUPercent: 65.2),
      .init(id: .init(pid: 402, started: 2), name: "Browser", bundleID: "example.browser",
        memoryBytes: 2 * gb, cpuPercent: 32.6, fallbackSymbol: "globe",
        helpers: ProcessFamilies.Helpers(count: 9, memoryBytes: 1_600_000_000, cpuPercent: 28.1, largest: [
          .init(pid: 511, name: "Browser Helper (Renderer)", memoryBytes: 700_000_000, cpuPercent: 18.0),
          .init(pid: 512, name: "Browser Helper (GPU)", memoryBytes: 400_000_000, cpuPercent: 6.4),
        ]), ownMemoryBytes: 400_000_000, ownCPUPercent: 4.5),
      .init(id: .init(pid: 403, started: 3), name: "Design Workspace with a longer application name", bundleID: "example.design-workspace",
        memoryBytes: 1_400_000_000, cpuPercent: 5.7, fallbackSymbol: "paintpalette.fill"),
      .init(id: .init(pid: 404, started: 4), name: "Music", bundleID: "example.music",
        memoryBytes: 290_000_000, cpuPercent: 0, fallbackSymbol: "music.note"),
      .init(id: .init(pid: 405, started: 5), name: "Notes", bundleID: "example.notes",
        memoryBytes: 145_000_000, cpuPercent: nil, fallbackSymbol: "note.text"),
    ]
    if state == .highPressure {
      snapshot.pressure = .critical; snapshot.memoryUsedBytes = 15 * gb
      snapshot.swapUsedBytes = 3 * gb; snapshot.cpuUsage = 0.88
    }
    if state == .unknownCPU { snapshot.cpuUsage = nil }
    let apps = state == .unknownCPU ? rows.enumerated().map { index, app in
      PerformancePresentation.App(id: app.id, name: app.name, bundleID: app.bundleID,
        memoryBytes: app.memoryBytes, cpuPercent: index == 0 ? .nan : nil, fallbackSymbol: app.fallbackSymbol)
    } : rows
    var taming: SystemMonitor.TamingDisplay?
    if state == .tamed {
      var value = TamingState()
      value.receipts = [.init(identity: .init(pid: 401, started: 1, boot: "preview",
        bundleID: "example.code-studio", path: "/preview"), name: "Code Studio", automatic: true,
        expires: Date(timeIntervalSince1970: 1_792_231_500))]
      value.exceptions = ["example.browser": "Browser"]
      taming = .init(state: value, automatic: true, message: "Slowed Code Studio. Switch to the app or choose Restore to return its priority.")
    }
    return PerformancePreview(snapshot: snapshot, apps: apps,
      sampledAt: Date(timeIntervalSince1970: 1_792_231_200), logicalCPUCount: 8, paused: state == .paused, taming: taming)
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
