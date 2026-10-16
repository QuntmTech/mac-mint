import MacCleanerCore
import SwiftUI

@main
struct MacCleanerDesktopApp: App {
  @StateObject private var model = AppViewModel()
  @StateObject private var account = AccountStore(supportDirectory: AppPaths.supportDirectory)
  @StateObject private var monitor = SystemMonitor()
  @StateObject private var care = CareService()
  @StateObject private var updates = UpdateService()
  @AppStorage(CareService.Keys.showMenuBar) private var showMenuBar = false

  var body: some Scene {
    WindowGroup("MacMint", id: "main") {
      AccountGateView()
        .environmentObject(model)
        .environmentObject(account)
        .environmentObject(monitor)
        .environmentObject(care)
        .environmentObject(updates)
        .tint(AppTheme.accent)
        .frame(minWidth: 1040, minHeight: 700)
        .task {
          care.start()
          updates.start()
          await account.start()
        }
    }
    .windowStyle(.automatic)
    .commands {
      CommandMenu("Scan") {
        Button("Smart Scan") { model.runSmartScan() }
          .keyboardShortcut("r", modifiers: [.command])
          .disabled(!account.isUnlocked)
        Button("Map Storage") {
          model.selectedSection = .storage
          model.scanStorage()
        }
        .keyboardShortcut("m", modifiers: [.command, .shift])
        .disabled(!account.isUnlocked)
        Button("Choose Folder for Large Files") { model.chooseLargeFileFolder() }
          .disabled(!account.isUnlocked)
        Button("Choose Folder for Duplicates") { model.chooseDuplicateFolder() }
          .disabled(!account.isUnlocked)
      }
    }

    MenuBarExtra("MacMint", systemImage: "leaf.fill", isInserted: $showMenuBar) {
      MenuBarView()
        .environmentObject(model)
        .environmentObject(account)
        .environmentObject(monitor)
        .tint(AppTheme.accent)
    }
    .menuBarExtraStyle(.window)
  }
}
