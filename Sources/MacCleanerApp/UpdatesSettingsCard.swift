import MacCleanerCore
import SwiftUI

/// Settings → Updates: this build, Sparkle's check and automatic options, the developer
/// channel, and the server's minimum-version notice.
struct UpdatesSettingsCard: View {
  @EnvironmentObject private var updater: UpdaterController
  @EnvironmentObject private var updates: UpdateService

  var body: some View {
    SurfaceCard {
      VStack(alignment: .leading, spacing: 12) {
        HStack(alignment: .firstTextBaseline) {
          Label("Updates", systemImage: "arrow.triangle.2.circlepath").font(.headline)
          Spacer()
          Button("Check for Updates…") {
            updater.checkForUpdates()
            Task { await updates.check() }
          }
          .disabled(!updater.canCheckForUpdates)
        }
        Text(UpdaterController.current.displayString + " · " + channelName + " channel")
          .font(.callout)
          .foregroundStyle(.secondary)
          .textSelection(.enabled)
        status.font(.callout)
        Divider()
        Toggle("Automatically check for updates", isOn: $updater.automaticallyChecks)
        Toggle("Automatically download and install updates", isOn: $updater.automaticallyInstalls)
          .disabled(!updater.automaticallyChecks || !updater.allowsAutomaticInstalls)
        Toggle("Receive developer builds (may be unstable)", isOn: $updater.receivesDeveloperBuilds)
        Text(channelNote)
          .font(.caption)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
        Text(lastChecked)
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      .toggleStyle(.switch)
    }
  }

  @ViewBuilder
  private var status: some View {
    if let error = updater.startError {
      Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(AppTheme.warning)
    } else if updater.isWaitingForWork {
      Label("The update installs and MacMint restarts when the current operation finishes.",
        systemImage: "clock.arrow.circlepath")
        .foregroundStyle(AppTheme.accentText)
    } else if let update = updater.availableUpdate {
      HStack {
        Label("Version \(update.title) is available", systemImage: "arrow.down.circle.fill")
          .foregroundStyle(AppTheme.accentText)
        Button("Install…") { updater.checkForUpdates() }.controlSize(.small)
      }
    } else if case .required(let release, let minimum) = updates.status {
      HStack {
        Label("Update required (minimum \(minimum))", systemImage: "exclamationmark.triangle.fill")
          .foregroundStyle(AppTheme.warning)
        Button("Download") { updates.openDownload(release) }.controlSize(.small)
      }
    } else if let error = updates.checkError {
      Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(AppTheme.warning)
    } else if let result = updater.lastResult {
      switch result {
      case .newest:
        Label("This is the newest build on the \(channelName) channel.", systemImage: "checkmark.circle.fill")
          .foregroundStyle(AppTheme.accentText)
      case .newerThanChannel:
        Label("This build is newer than anything on the \(channelName) channel.", systemImage: "checkmark.circle")
          .foregroundStyle(.secondary)
      case .needsNewerMacOS:
        Label("A newer version is available but needs a newer version of macOS.", systemImage: "exclamationmark.circle")
          .foregroundStyle(AppTheme.warning)
      case .unsupportedMacOS:
        Label("The newest version on this channel doesn't support this version of macOS yet.", systemImage: "exclamationmark.circle")
          .foregroundStyle(AppTheme.warning)
      case .failed:
        Label(updater.channel == .stable
          ? "Couldn't check the Stable channel: no stable release feed was found, or it couldn't be reached. Developer builds can be turned on below."
          : "Couldn't check the Developer channel: its feed was missing or couldn't be reached. Try again later.",
          systemImage: "exclamationmark.triangle")
          .foregroundStyle(AppTheme.warning).fixedSize(horizontal: false, vertical: true)
      }
    }
  }

  private var channelName: String { updater.channel == .developer ? "Developer" : "Stable" }

  private var channelNote: String {
    switch updater.channel {
    case .stable:
      "Stable releases are signed with MacMint's Developer ID and notarized by Apple. Each update is verified before it installs."
    case .developer:
      "Developer builds come from every change to MacMint's main branch and are not notarized. Turning this off returns to stable releases once one is newer than this build."
    }
  }

  private var lastChecked: String {
    guard let date = updater.lastCheck else { return "Not checked yet" }
    return "Last checked \(date.formatted(.relative(presentation: .named)))"
  }
}
