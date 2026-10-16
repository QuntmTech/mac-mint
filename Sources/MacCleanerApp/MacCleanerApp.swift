import MacCleanerCore
import SwiftUI

@main
struct MacCleanerDesktopApp: App {
  @StateObject private var model = AppViewModel()

  var body: some Scene {
    WindowGroup {
      RootView()
        .environmentObject(model)
        .frame(minWidth: 1040, minHeight: 700)
    }
    .windowStyle(.automatic)
    .commands {
      CommandMenu("Scan") {
        Button("Smart Scan") { model.runSmartScan() }
          .keyboardShortcut("r", modifiers: [.command])
        Button("Choose Folder for Large Files") { model.chooseLargeFileFolder() }
        Button("Choose Folder for Duplicates") { model.chooseDuplicateFolder() }
      }
    }
  }
}
