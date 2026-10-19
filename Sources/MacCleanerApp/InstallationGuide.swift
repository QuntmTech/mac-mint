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
    VStack(alignment: .leading, spacing: 10) {
      Label(title, systemImage: location == .installed ? "checkmark.circle.fill" : "app.badge.checkmark")
        .font(.headline).foregroundStyle(location.suggestsInstallation ? AppTheme.ink : AppTheme.accentText)
      Text(detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
      if location.suggestsInstallation {
        HStack(spacing: 12) {
          Button("Open Applications") { open(URL(fileURLWithPath: "/Applications")) }
            .buttonStyle(MintButtonStyle(prominent: false))
          if location == .translocated {
            Button("Open Downloads") {
              open(FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads"))
            }
          } else {
            Button("Show This Copy") { NSWorkspace.shared.activateFileViewerSelecting([bundleURL]) }
          }
        }
        Text("After copying, quit this copy and open MacMint from Applications. Keep any existing copy until you choose whether to replace it.")
          .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
      }
      if let errorMessage { Text(errorMessage).font(.callout).foregroundStyle(AppTheme.warning) }
    }
    .padding(16)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(AppTheme.surface, in: RoundedRectangle(cornerRadius: 12))
    .overlay(RoundedRectangle(cornerRadius: 12).stroke(AppTheme.border))
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
