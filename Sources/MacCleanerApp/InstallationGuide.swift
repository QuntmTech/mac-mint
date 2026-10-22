import AppKit
import MacCleanerCore
import SwiftUI

/// Reads only bundle/volume metadata; no protected-directory probe or polling.
struct InstallationGuide: View {
  private let bundleURL: URL
  private let location: InstallationLocation
  @State private var errorMessage: String?

  init(bundleURL: URL = Bundle.main.bundleURL, location: InstallationLocation? = nil) {
    self.bundleURL = bundleURL
    self.location = location ?? .evaluate(bundleURL: bundleURL,
      homeDirectory: FileManager.default.homeDirectoryForCurrentUser,
      volumeIsReadOnly: (try? bundleURL.resourceValues(forKeys: [.volumeIsReadOnlyKey]))?.volumeIsReadOnly == true)
  }

  var body: some View {
    HStack(alignment: .top, spacing: 12) {
      SwatchBadge(symbol: symbol, swatch: swatch, size: 30)
      VStack(alignment: .leading, spacing: 10) {
        VStack(alignment: .leading, spacing: 3) {
          HStack(spacing: 8) {
            Text(title).font(.system(size: 13.5, weight: .semibold)).foregroundStyle(AppTheme.ink)
              .accessibilityAddTraits(.isHeader)
            if location == .installed { Chip(title: "Ready", symbol: "checkmark.circle.fill", swatch: .mint) }
            if location.suggestsInstallation { Chip(title: "One more step", symbol: "arrow.down.circle.fill", swatch: .amber) }
          }
          Text(detail).font(.system(size: 12)).foregroundStyle(AppTheme.ink2)
            .fixedSize(horizontal: false, vertical: true)
        }
        if location.suggestsInstallation {
          HStack(spacing: 8) {
            Button("Open Applications") { open(URL(fileURLWithPath: "/Applications")) }
              .buttonStyle(MintButtonStyle(.secondary))
            if location == .translocated {
              Button("Open Downloads") {
                open(FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads"))
              }
              .buttonStyle(MintButtonStyle(.plain))
            } else {
              Button("Show This Copy") { NSWorkspace.shared.activateFileViewerSelecting([bundleURL]) }
                .buttonStyle(MintButtonStyle(.plain))
            }
          }
          .controlSize(.small)
          Text("After copying, quit this copy and open MacMint from Applications. Keep any existing copy until you choose whether to replace it.")
            .font(.system(size: 11.5)).foregroundStyle(AppTheme.ink3).fixedSize(horizontal: false, vertical: true)
        }
        if let errorMessage {
          Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
            .font(.system(size: 12)).foregroundStyle(AppTheme.warning)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
      Spacer(minLength: 0)
    }
    .padding(14)
    .frame(maxWidth: .infinity, alignment: .leading)
    .cardBackground(radius: 14)
  }

  private var symbol: String {
    switch location {
    case .installed: return "checkmark.circle"
    case .development: return "hammer"
    case .readOnlyVolume, .translocated, .downloads, .elsewhere: return "app.badge.checkmark"
    }
  }

  private var swatch: AppTheme.Swatch {
    switch location {
    case .installed: return .mint
    case .development: return .slate
    case .readOnlyVolume, .translocated, .downloads, .elsewhere: return .amber
    }
  }

  private var title: String {
    switch location {
    case .installed: return "Installed in Applications"
    case .development: return "Running a development build"
    case .readOnlyVolume, .translocated: return "Finish installing MacMint"
    case .downloads, .elsewhere: return "Keep MacMint in Applications"
    }
  }

  private var detail: String {
    switch location {
    case .installed: return "You’re running the installed copy. Grant any optional access to this same copy."
    case .development: return "For normal installation and permission setup, use the packaged MacMint.app. Local inspection still works here."
    case .readOnlyVolume: return "You’re running from a read-only location, such as the installer disk image. Drag MacMint.app to the Applications shortcut first."
    case .translocated: return "macOS is running an isolated downloaded copy. Drag the original MacMint.app from the download or disk image to Applications first."
    case .downloads, .elsewhere: return "Move MacMint.app to Applications before granting Full Disk Access, so you don’t grant access to a temporary or duplicate copy. You can still explore locally."
    }
  }

  private func open(_ url: URL) {
    errorMessage = NSWorkspace.shared.open(url) ? nil : "Finder could not open this folder. Open it from Finder’s Go menu instead."
  }
}
