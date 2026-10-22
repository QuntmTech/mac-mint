import AppKit
import MacCleanerCore
import SwiftUI

@main
struct MacCleanerDesktopApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
  @StateObject private var model = AppViewModel()
  @StateObject private var account = AccountStore(supportDirectory: AppPaths.supportDirectory)
  @StateObject private var monitor = SystemMonitor()
  @StateObject private var care = CareService()
  @StateObject private var updates = UpdateService()
  @StateObject private var updater = UpdaterController()
  @StateObject private var appUpdates = AppUpdatesStore()
  @AppStorage(AppAppearance.storageKey) private var appearance: AppAppearance = .system
  @AppStorage(CareService.Keys.showMenuBar) private var showMenuBar = false

  init() {
    if SmokeTest.isRequested { SmokeTest.run() }
  }

  var body: some Scene {
    WindowGroup("MacMint", id: "main") {
      AccountGateView()
        .environmentObject(model)
        .environmentObject(account)
        .environmentObject(monitor)
        .environmentObject(care)
        .environmentObject(updates)
        .environmentObject(updater)
        .environmentObject(appUpdates)
        .tint(AppTheme.accent)
        .preferredColorScheme(appearance.colorScheme)
        .frame(minWidth: 980, minHeight: 620)
        .background(MainWindowReader())
        .onAppear {
          appDelegate.model = model
          appDelegate.updater = updater
          updater.bind(to: model)
        }
        .onChange(of: updates.status) { _, status in
          // A newer or required version on the server: let Sparkle find it so the banner installs it.
          if status != .current { updater.probeForUpdate() }
        }
        .task {
          PreviewCaches.startMemoryPressureHandling()
          monitor.activateControls()
          care.start()
          updater.onCycleFinished = { [weak updates] in Task { await updates?.check() } }
          updates.start()
          await account.start()
          await account.refreshAIStatus()
        }
    }
    .defaultSize(width: 1240, height: 820)
    .windowStyle(.automatic)
    .commands {
      // One workspace window: every window would share the model's sheets and onboarding.
      CommandGroup(replacing: .newItem) {}
      CommandGroup(after: .appInfo) {
        Button("Check for Updates…") { updater.checkForUpdates() }
          .disabled(!updater.canCheckForUpdates)
      }
      CommandGroup(replacing: .appSettings) {
        Button("Settings…") { model.selectedSection = .settings }
          .keyboardShortcut(",", modifiers: [.command])

      }
      CommandGroup(after: .sidebar) {
        Button("Go To…") { model.showingCommandPalette = true }
          .keyboardShortcut("k", modifiers: [.command])

        Divider()
        ForEach(Array(([.dashboard, .cleaner, .storage, .applications, .photos, .developer, .history, .performance, .review] as [AppViewModel.Section]).enumerated()), id: \.element) { index, section in
          Button(section.rawValue) { model.selectedSection = section }
            .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: [.command])

        }
      }
      CommandGroup(before: .help) {
        Button("Quick Tour of MacMint") { model.startTour() }
      }
      CommandMenu("Appearance") {
        Picker("Appearance", selection: $appearance) {
          ForEach(AppAppearance.allCases) { option in Text(option.title).tag(option) }
        }
      }
      CommandMenu("Scan") {
        Group {
          Button("Quick Scan") {
            model.selectedSection = .dashboard
            model.runSmartCare()
          }
            .keyboardShortcut("r", modifiers: [.command])

          Button("Map Storage") {
            model.selectedSection = .storage
            model.scanStorage()
          }
          .keyboardShortcut("m", modifiers: [.command, .shift])
          Button("Choose Folder for Large Files") { model.chooseLargeFileFolder() }

          Button("Choose Folder for Duplicates") { model.chooseDuplicateFolder() }
        }
        // These would navigate and then silently skip the scan while other work is active.
        .disabled(model.isScanning || model.isWorking || model.isPreparingPlan || model.pendingPlan != nil)
      }
    }

    MenuBarExtra("MacMint", systemImage: "leaf.fill", isInserted: Binding(
      get: { showMenuBar },
      set: { inserted in
        // Scene updates can report the existing state. Republishing it through
        // AppStorage can continuously invalidate the application's scene graph.
        guard showMenuBar != inserted else { return }
        showMenuBar = inserted
      }
    )) {
      MenuBarView()
        .onAppear { appDelegate.model = model }
        .environmentObject(model)
        .environmentObject(account)
        .environmentObject(monitor)
        .tint(AppTheme.accent)
        .preferredColorScheme(appearance.colorScheme)
    }
    .menuBarExtraStyle(.window)
  }
}

/// Quitting during a move, restore or organization asks first. Work stops at the next item
/// boundary; anything left unfinished is reconciled from its journal on the next launch.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
  weak var model: AppViewModel?
  weak var updater: UpdaterController?

  func applicationWillFinishLaunching(_ notification: Notification) {
    // Window tabs would offer "+" to create another copy of the single workspace.
    NSWindow.allowsAutomaticWindowTabbing = false
  }

  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    guard let model, model.isWorking else { return .terminateNow }
    if let gate = updater?.relaunchGate, gate.isRelaunching {
      // Install and Relaunch was already chosen and waited for earlier work. Work started
      // since then finishes first; MacMint then quits for the installer without asking again.
      gate.terminateWhenIdle { NSApp.terminate(nil) }
      return .terminateCancel
    }
    let alert = NSAlert()
    alert.alertStyle = .warning
    alert.messageText = "Quit while MacMint is working?"
    alert.informativeText = "\(model.operationTitle ?? "An operation") is in progress. MacMint will stop after the current item and record what finished. Anything interrupted is checked again the next time MacMint opens."
    alert.addButton(withTitle: "Keep Working")
    alert.addButton(withTitle: "Stop and Quit")
    guard alert.runModal() == .alertSecondButtonReturn else { return .terminateCancel }
    model.cancelCurrentOperation()
    Task { @MainActor in
      // Let the current item finish and History record it, but never hold Quit indefinitely.
      let deadline = Date().addingTimeInterval(15)
      while model.isWorking, Date() < deadline { try? await Task.sleep(for: .milliseconds(100)) }
      NSApp.reply(toApplicationShouldTerminate: true)
    }
    return .terminateLater
  }
}

/// Records the workspace window so the menu bar can bring it forward instead of opening another.
@MainActor
enum MainWindow {
  private static weak var window: NSWindow?

  static func register(_ window: NSWindow?) { if let window { self.window = window } }

  /// False when the window was closed and must be opened again.
  static func focusExisting() -> Bool {
    if NSApp.isHidden { NSApp.unhide(nil) }
    guard let window, window.isVisible || window.isMiniaturized else { return false }
    if window.isMiniaturized { window.deminiaturize(nil) }
    window.makeKeyAndOrderFront(nil)
    return true
  }
}

private struct MainWindowReader: NSViewRepresentable {
  func makeNSView(context: Context) -> NSView { Reader() }
  func updateNSView(_ nsView: NSView, context: Context) {}

  final class Reader: NSView {
    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      MainWindow.register(window)
    }
  }
}
