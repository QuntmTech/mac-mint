import AppKit
import SwiftUI

struct FullDiskAccessGuide: View {
  @ObservedObject var permissions: PermissionsService

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      Label("Full Disk Access · Optional", systemImage: "externaldrive.badge.checkmark")
        .font(.headline)
      Text("Lets MacMint inspect protected app data for broader scan coverage. Without it, you can still inspect permitted locations; unreadable areas appear in scan issues.")
        .font(.callout).foregroundStyle(.secondary)
      HStack {
        Button("Open Full Disk Access") { permissions.open(.fullDiskAccess) }
          .buttonStyle(MintButtonStyle(prominent: false))
        Button("Reveal This App") { permissions.revealThisApp() }
      }
      Text("1. Turn on the MacMint copy you are running.\n2. If it is missing, click + and select the app revealed in Finder.\n3. Quit and reopen MacMint if macOS asks, then run your scan again.")
        .font(.callout).fixedSize(horizontal: false, vertical: true)
      Text("Confirm the switch in System Settings. MacMint cannot grant this access or reliably verify that switch for you.")
        .font(.caption).foregroundStyle(.secondary)
      Text(PermissionSettingsPane.fullDiskAccess.path)
        .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
    }
  }
}

/// The same optional-access explanations are available after first launch.
struct PermissionsSettingsCard: View {
  @EnvironmentObject private var model: AppViewModel
  @EnvironmentObject private var care: CareService
  @StateObject private var permissions = PermissionsService()
  @State private var showingSetup = false
  @State private var scanAfterSetup = false

  var body: some View {
    SurfaceCard {
      VStack(alignment: .leading, spacing: 16) {
        HStack {
          Label("Permissions & setup", systemImage: "lock.shield").font(.headline)
          Spacer()
          Button("Review Setup") { showingSetup = true }
        }
        InstallationGuide()
        FullDiskAccessGuide(permissions: permissions)
        Divider()
        VStack(alignment: .leading, spacing: 8) {
          Label("Files & Folders", systemImage: "folder").font(.headline)
          Text("macOS asks when a scan reaches protected locations such as Desktop, Documents, or Downloads. Allow the locations you want inspected; changing access does not remove any files.")
            .font(.callout).foregroundStyle(.secondary)
          Button("Open Files & Folders") { permissions.open(.filesAndFolders) }
          Text(PermissionSettingsPane.filesAndFolders.path).font(.caption).foregroundStyle(.secondary)
        }
        Divider()
        VStack(alignment: .leading, spacing: 8) {
          Label("App Management", systemImage: "app.badge.checkmark").font(.headline)
          Text("macOS may ask separately when you confirm removing an installed app. Full Disk Access does not replace App Management permission.")
            .font(.callout).foregroundStyle(.secondary)
          Button("Open Privacy & Security") { permissions.open(.appManagement) }
          Text(PermissionSettingsPane.appManagement.path).font(.caption).foregroundStyle(.secondary)
        }
        Divider()
        VStack(alignment: .leading, spacing: 8) {
          Label("Photos · \(permissions.photos.title)", systemImage: "photo.on.rectangle").font(.headline)
          Text(permissions.photos.detail).font(.callout).foregroundStyle(.secondary)
          HStack {
            Button("Open Photos Settings") { permissions.open(.photos) }
            Button("Go to Photos") { model.selectedSection = .photos }
          }
          Text(PermissionSettingsPane.photos.path).font(.caption).foregroundStyle(.secondary)
        }
        Divider()
        VStack(alignment: .leading, spacing: 8) {
          Label("Notifications · \(permissions.notifications.title)", systemImage: "bell").font(.headline)
          Text("Optional low-space alerts and scan reminders ask for notification access only when you turn them on. Permission alone does not enable reminders.")
            .font(.callout).foregroundStyle(.secondary)
          HStack {
            Button("Open Notification Settings") { permissions.open(.notifications) }
            Spacer()
            Button("Refresh Status") { Task { await permissions.refresh() } }
          }
          Text(PermissionSettingsPane.notifications.path).font(.caption).foregroundStyle(.secondary)
        }
        if let error = permissions.settingsError {
          Label(error, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(AppTheme.warning)
        }
      }
      .fixedSize(horizontal: false, vertical: true)
    }
    .sheet(isPresented: $showingSetup, onDismiss: {
      guard scanAfterSetup else { return }
      scanAfterSetup = false
      model.selectedSection = .dashboard
      model.runSmartCare()
    }) { OnboardingView(onFinish: { scanAfterSetup = $0 }) }
    .task { await permissions.refresh() }
    .onChange(of: care.notificationPermission) { _, _ in Task { await permissions.refresh() } }
    .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
      Task { await permissions.refresh() }
    }
  }
}
