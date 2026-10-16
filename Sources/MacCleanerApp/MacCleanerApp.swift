import MacCleanerCore
import SwiftUI

@main
struct MacCleanerDesktopApp: App {
  @StateObject private var model = AppViewModel()
  @StateObject private var account = AccountStore(supportDirectory: AppPaths.supportDirectory)

  var body: some Scene {
    WindowGroup("MacMint") {
      AccountGateView()
        .environmentObject(model)
        .environmentObject(account)
        .tint(AppTheme.accent)
        .frame(minWidth: 1040, minHeight: 700)
        .task { await account.start() }
    }
    .windowStyle(.automatic)
    .commands {
      CommandMenu("Scan") {
        Button("Smart Scan") { model.runSmartScan() }
          .keyboardShortcut("r", modifiers: [.command])
          .disabled(!account.isUnlocked)
        Button("Choose Folder for Large Files") { model.chooseLargeFileFolder() }
          .disabled(!account.isUnlocked)
        Button("Choose Folder for Duplicates") { model.chooseDuplicateFolder() }
          .disabled(!account.isUnlocked)
      }
    }
  }
}
