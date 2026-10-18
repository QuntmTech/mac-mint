import MacCleanerCore
import SwiftUI

@main
struct MacCleanerDesktopApp: App {
  @StateObject private var model = AppViewModel()
  @StateObject private var account = AccountStore(supportDirectory: AppPaths.supportDirectory)
  @StateObject private var monitor = SystemMonitor()
  @StateObject private var care = CareService()
  @StateObject private var updates = UpdateService()
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
        .environmentObject(appUpdates)
        .tint(AppTheme.accent)
        .preferredColorScheme(appearance.colorScheme)
        .frame(minWidth: 980, minHeight: 620)
        .task {
          monitor.activateControls()
          care.start()
          updates.start()
          await account.start()
          await account.refreshAIStatus()
        }
    }
    .defaultSize(width: 1240, height: 820)
    .windowStyle(.automatic)
    .commands {
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
      CommandMenu("Appearance") {
        Picker("Appearance", selection: $appearance) {
          ForEach(AppAppearance.allCases) { option in Text(option.title).tag(option) }
        }
      }
      CommandMenu("Scan") {
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
        .environmentObject(model)
        .environmentObject(account)
        .environmentObject(monitor)
        .tint(AppTheme.accent)
        .preferredColorScheme(appearance.colorScheme)
    }
    .menuBarExtraStyle(.window)
  }
}
