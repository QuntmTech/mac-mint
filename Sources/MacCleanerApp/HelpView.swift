import AppKit
import MacCleanerCore
import SwiftUI

struct HelpView: View {
  @EnvironmentObject private var model: AppViewModel
  @EnvironmentObject private var account: AccountStore
  @Environment(\.dismiss) private var dismiss
  @State private var showDiagnostics = false
  private var diagnostics: String {
    """
    MacMint \(UpdateService.currentVersion)
    macOS \(ProcessInfo.processInfo.operatingSystemVersionString)
    Scan completed: \(model.lastScanDate?.formatted() ?? "Not run")
    Completed categories: \(model.scanCompletedAreas.count)
    Scan issues: \(model.scanIssues.count)
    Recovery warnings: \(model.recoveryWarnings.count)
    Exclusions: \(model.ignoredPaths.count)
    History operations: \(model.history.count)
    Access: \(account.isUnlocked ? "Pro" : "Local inspection")
    AI consent: \(model.aiEnabled ? "Enabled" : "Disabled")
    AI available: \(account.aiAvailable)
    No account identifiers, names, paths, questions, or file contents are included.
    """
  }
  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 18) {
        Text("Help & recovery").font(.title.bold())
        Text("Scans and previews work locally before sign-in. An active plan is needed to start a removal. History and Restore remain available.")
        topic("Why didn't my free space increase?", "Moving files to Trash does not free their space. Review Trash in Finder when you no longer need recovery. APFS snapshots, shared file blocks and other activity can affect the observed change.")
        topic("An area could not be read", "Check the scan issues. Full Disk Access can improve coverage; choose System Settings → Privacy & Security → Full Disk Access. Continue without it to inspect permitted locations.")
        topic("How do I restore?", "Open History and expand an operation. Restore never overwrites another item. For conflicts, choose another folder. Photos assets are recovered through Photos, while available in Recently Deleted. iCloud Photos deletion also affects synced devices.")
        topic("What is included in Quick Scan?", "Known cache locations, installed apps, startup metadata, Downloads, removed-app data and home Trash. Whole-folder storage maps, duplicate comparisons, photo analysis and deep project scans start only when you choose them.")
        topic("How does AI use my data?", "AI is optional and cannot select or remove items. Automatic context uses storage categories and known tool identifiers. Your typed question and recent conversation are sent as written. Preview the context before enabling AI.")
        HStack {
          Button("Open Privacy Settings") { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!) }
          Button("Contact Support") { NSWorkspace.shared.open(URL(string: "mailto:support@macmint.co")!) }
        }
        Toggle("Preview diagnostic summary", isOn: $showDiagnostics)
        if showDiagnostics {
          Text(diagnostics).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
          Button("Export this summary…") {
            let panel = NSSavePanel()
            panel.nameFieldStringValue = "MacMint-diagnostics.txt"
            if panel.runModal() == .OK, let url = panel.url {
              do { try diagnostics.write(to: url, atomically: true, encoding: .utf8) }
              catch { model.statusMessage = "Could not export diagnostics: \(error.localizedDescription)" }
            }
          }
        }
        HStack { Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.defaultAction) }
      }.padding(24)
    }.frame(width: 620, height: 620)
  }
  private func topic(_ title: String, _ text: String) -> some View {
    VStack(alignment: .leading, spacing: 5) {
      Text(title).font(.headline)
      Text(text).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }
  }
}
