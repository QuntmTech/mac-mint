import AppKit
import MacCleanerCore
import SwiftUI

/// Holds update-check results across navigation.
@MainActor
final class AppUpdatesStore: ObservableObject {
  @Published private(set) var updates: [AppUpdate] = []
  @Published private(set) var isChecking = false
  @Published private(set) var lastChecked: Date?

  func check(_ apps: [AppRecord]) {
    guard !isChecking else { return }
    isChecking = true
    Task {
      updates = await AppUpdateChecker().check(apps)
      lastChecked = Date()
      isChecking = false
    }
  }

  var available: [AppUpdate] { updates.filter(\.hasUpdate) }
}

struct AppUpdatesView: View {
  @EnvironmentObject private var model: AppViewModel
  @EnvironmentObject private var store: AppUpdatesStore

  var body: some View {
    VStack(spacing: 0) {
      HStack(alignment: .top) {
        VStack(alignment: .leading, spacing: 4) {
          Text(store.available.isEmpty ? "App updates" : "\(store.available.count) update\(store.available.count == 1 ? "" : "s") available")
            .font(.title2.bold())
          Text(
            "Checks the App Store, each app's own update feed, and Homebrew. Only app identifiers and feed addresses are sent — MacMint never downloads or installs anything itself."
          )
          .font(.callout)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
        }
        Spacer()
        Button {
          store.check(model.apps)
        } label: {
          if store.isChecking { ProgressView().controlSize(.small) } else { Label("Check for Updates", systemImage: "arrow.triangle.2.circlepath") }
        }
        .buttonStyle(.borderedProminent)
        .disabled(store.isChecking || model.apps.isEmpty)
      }
      .padding(AppTheme.pagePadding)
      Divider()

      if store.updates.isEmpty {
        EmptyState(
          icon: "arrow.down.app", title: store.lastChecked == nil ? "Check your apps for updates" : "No update sources found",
          detail: store.lastChecked == nil
            ? "MacMint looks at App Store apps, apps that update themselves, and Homebrew casks."
            : "None of your apps report a way to check for updates.")
      } else {
        List(store.updates) { update in
          HStack(spacing: 12) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: update.appURL.path))
              .resizable().frame(width: 34, height: 34)
            VStack(alignment: .leading, spacing: 3) {
              Text(update.appName).fontWeight(.medium)
              HStack(spacing: 6) {
                Text("Installed \(update.installedVersion)")
                if let available = update.availableVersion, update.hasUpdate {
                  Image(systemName: "arrow.right")
                  Text(available).foregroundStyle(AppTheme.accentText).fontWeight(.semibold)
                }
                if let minOS = update.minimumSystem, update.hasUpdate { Text("• needs macOS \(minOS)") }
              }
              .font(.caption)
              .foregroundStyle(.secondary)
            }
            Spacer()
            StatusPill(title: update.source.label, icon: icon(update.source), tint: .secondary)
            action(update)
          }
          .padding(.vertical, 4)
          .opacity(update.hasUpdate || update.availableVersion == nil ? 1 : 0.6)
        }
        .listStyle(.inset)
      }
    }
  }

  @ViewBuilder
  private func action(_ update: AppUpdate) -> some View {
    switch update.source {
    case .appStore(let pageURL):
      Button(update.hasUpdate ? "Update in App Store" : "App Store") {
        NSWorkspace.shared.open(
          update.hasUpdate ? URL(string: "macappstore://showUpdatesPage")! : (pageURL ?? URL(string: "macappstore://")!))
      }
      .controlSize(.small)
    case .sparkle:
      Button(update.hasUpdate ? "Open to Update" : "Open") {
        NSWorkspace.shared.openApplication(at: update.appURL, configuration: NSWorkspace.OpenConfiguration())
      }
      .controlSize(.small)
      .help("This app updates itself — use “Check for Updates…” in its app menu.")
    case .homebrew(let token):
      Button("Copy Command") { model.copyCommand("brew upgrade --cask \(token)") }
        .controlSize(.small)
    }
  }

  private func icon(_ source: UpdateSource) -> String {
    switch source {
    case .appStore: return "bag"
    case .sparkle: return "sparkles"
    case .homebrew: return "mug"
    }
  }
}
