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
    // MacMint updates itself through Settings → Updates.
    let others = apps.filter { $0.bundleIdentifier != Bundle.main.bundleIdentifier }
    Task {
      updates = await AppUpdateChecker().check(others)
      lastChecked = Date()
      isChecking = false
    }
  }

  var available: [AppUpdate] { updates.filter(\.hasUpdate) }
}

struct AppUpdatesView: View {
  @EnvironmentObject private var model: AppViewModel
  @EnvironmentObject private var store: AppUpdatesStore
  @Environment(\.areaSwatch) private var swatch

  var body: some View {
    VStack(spacing: 14) {
      summary
        .padding(.horizontal, AppTheme.pagePadding)

      if store.updates.isEmpty {
        EmptyState(
          icon: "arrow.down.app", title: store.lastChecked == nil ? "Check your apps for updates" : "No update sources found",
          detail: store.lastChecked == nil
            ? "MacMint looks at App Store apps, apps that update themselves, and Homebrew casks."
            : "None of your apps report a way to check for updates.")
      } else {
        ScrollView {
          LazyVStack(spacing: 0) {
            ForEach(store.updates) { update in
              row(update)
                .overlay(alignment: .top) {
                  if update.id != store.updates.first?.id {
                    Rectangle().fill(AppTheme.divider).frame(height: 1).padding(.leading, 60)
                  }
                }
            }
          }
          .padding(.vertical, 4)
          .cardBackground()
          .padding(.horizontal, AppTheme.pagePadding)
          .padding(.top, 2)
          .padding(.bottom, 24)
        }
      }
    }
  }

  private var summaryTitle: String {
    store.available.isEmpty ? "App updates" : "\(store.available.count) update\(store.available.count == 1 ? "" : "s") available"
  }

  private var summary: some View {
    HStack(alignment: .center, spacing: 14) {
      SwatchBadge(symbol: "arrow.down.app", swatch: swatch, size: 36)
      VStack(alignment: .leading, spacing: 3) {
        Text(summaryTitle)
          .font(.system(size: 15, weight: .bold)).tracking(-0.2).foregroundStyle(AppTheme.ink)
          .accessibilityAddTraits(.isHeader)
        Text(
          "Checks the App Store, each app's own update feed, and Homebrew. Only app identifiers and feed addresses are sent — MacMint never downloads or installs other apps' updates."
        )
        .font(.system(size: 12))
        .foregroundStyle(AppTheme.ink2)
        .fixedSize(horizontal: false, vertical: true)
      }
      Spacer(minLength: 8)
      Button {
        store.check(model.apps)
      } label: {
        if store.isChecking { ProgressView().controlSize(.small) } else { Label("Check for Updates", systemImage: "arrow.triangle.2.circlepath") }
      }
      .buttonStyle(MintButtonStyle(.area))
      .disabled(store.isChecking || model.apps.isEmpty)
    }
    .padding(16)
    .cardBackground()
  }

  private func row(_ update: AppUpdate) -> some View {
    HStack(spacing: 12) {
      Image(nsImage: FileIcons.icon(forPath: update.appURL.path))
        .resizable().interpolation(.high).frame(width: 32, height: 32)
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 3) {
        Text(update.appName).font(.system(size: 13, weight: .semibold)).foregroundStyle(AppTheme.ink).lineLimit(1)
        HStack(spacing: 5) {
          Text("Installed \(update.installedVersion)")
          if let available = update.availableVersion, update.hasUpdate {
            Image(systemName: "arrow.right").font(.system(size: 9, weight: .bold))
            Text(available).foregroundStyle(AppTheme.accentText).fontWeight(.semibold)
          }
          if let minOS = update.minimumSystem, update.hasUpdate { Text("· needs macOS \(minOS)") }
        }
        .font(.system(size: 11.5))
        .foregroundStyle(AppTheme.ink2)
        .lineLimit(1)
      }
      Spacer(minLength: 8)
      status(update)
      Chip(title: update.source.label, symbol: icon(update.source), swatch: .slate)
      action(update)
    }
    .padding(.horizontal, 16).padding(.vertical, 8)
    .frame(minHeight: 50)
    .opacity(update.hasUpdate || update.availableVersion == nil ? 1 : 0.6)
  }

  @ViewBuilder
  private func status(_ update: AppUpdate) -> some View {
    if update.hasUpdate {
      Chip(title: update.statusLabel, symbol: "arrow.down.circle.fill", swatch: .mint)
    } else if update.checkState == .failed {
      Chip(title: update.statusLabel, symbol: "exclamationmark.triangle.fill", swatch: .amber)
    } else {
      Text(update.statusLabel).font(.system(size: 11.5)).foregroundStyle(AppTheme.ink3).lineLimit(1)
    }
  }

  private func buttonKind(_ update: AppUpdate) -> MintButtonStyle.Kind {
    update.hasUpdate ? MintButtonStyle.Kind.area : MintButtonStyle.Kind.secondary
  }

  @ViewBuilder
  private func action(_ update: AppUpdate) -> some View {
    switch update.source {
    case .appStore(let pageURL):
      Button(update.hasUpdate ? "Update in App Store" : "App Store") {
        NSWorkspace.shared.open(
          update.hasUpdate ? URL(string: "macappstore://showUpdatesPage")! : (pageURL ?? URL(string: "macappstore://")!))
      }
      .buttonStyle(MintButtonStyle(buttonKind(update)))
      .controlSize(.small)
    case .sparkle:
      Button(update.hasUpdate ? "Open to Update" : "Open") {
        NSWorkspace.shared.openApplication(at: update.appURL, configuration: NSWorkspace.OpenConfiguration())
      }
      .buttonStyle(MintButtonStyle(buttonKind(update)))
      .controlSize(.small)
      .help("This app updates itself — use “Check for Updates…” in its app menu.")
    case .unsupported:
      EmptyView()
    case .homebrew(let token):
      Button("Copy Command") { model.copyCommand("brew upgrade --cask \(ShellArgument.quote(token))") }
        .buttonStyle(MintButtonStyle(.secondary))
        .controlSize(.small)
    }
  }

  private func icon(_ source: UpdateSource) -> String {
    switch source {
    case .appStore: return "bag"
    case .sparkle: return "sparkles"
    case .homebrew: return "mug"
    case .unsupported: return "questionmark.circle"
    }
  }
}
