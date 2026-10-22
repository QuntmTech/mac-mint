import AppKit
import SwiftUI

/// How a permission's status dot looks: a glyph on a tinted circle.
struct PermissionLook {
  let symbol: String
  let swatch: AppTheme.Swatch
}

/// A 22 pt status dot: mint when allowed, amber when off or partial, rose when restricted, slate
/// when macOS asks later or MacMint can't check it.
struct PermissionStatusDot: View {
  let look: PermissionLook

  var body: some View {
    Image(systemName: look.symbol)
      .font(.system(size: 10, weight: .bold))
      .foregroundStyle(look.swatch.text)
      .frame(width: 22, height: 22)
      .background(look.swatch.tint, in: Circle())
      .accessibilityHidden(true)
  }
}

extension PhotosPermissionState {
  var look: PermissionLook {
    switch self {
    case .allowed: return PermissionLook(symbol: "checkmark", swatch: .mint)
    case .limited: return PermissionLook(symbol: "circle.lefthalf.filled", swatch: .amber)
    case .denied: return PermissionLook(symbol: "xmark", swatch: .amber)
    case .restricted: return PermissionLook(symbol: "lock.fill", swatch: .rose)
    case .notRequested: return PermissionLook(symbol: "hand.raised.fill", swatch: .slate)
    case .unknown: return PermissionLook(symbol: "questionmark", swatch: .slate)
    }
  }
}

extension NotificationPermissionState {
  var look: PermissionLook {
    switch self {
    case .enabled: return PermissionLook(symbol: "checkmark", swatch: .mint)
    case .quiet: return PermissionLook(symbol: "moon.fill", swatch: .mint)
    case .denied: return PermissionLook(symbol: "xmark", swatch: .amber)
    case .notRequested: return PermissionLook(symbol: "hand.raised.fill", swatch: .slate)
    case .unavailable: return PermissionLook(symbol: "questionmark", swatch: .slate)
    }
  }
}

/// A numbered step: a small mint number and one line of instruction.
struct PermissionStepLine: View {
  let number: Int
  let text: String

  var body: some View {
    HStack(alignment: .top, spacing: 8) {
      Text("\(number)")
        .font(AppTheme.number(10.5, weight: .bold))
        .foregroundStyle(.white)
        .frame(width: 18, height: 18)
        .background(AppTheme.Swatch.mint.gradient, in: Circle())
        .accessibilityHidden(true)
      Text(text)
        .font(.system(size: 12))
        .foregroundStyle(AppTheme.ink)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.top, 1)
    }
    .accessibilityElement(children: .combine)
    .accessibilityLabel("Step \(number). \(text)")
  }
}

struct FullDiskAccessGuide: View {
  @ObservedObject var permissions: PermissionsService

  var body: some View {
    HStack(alignment: .top, spacing: 11) {
      // MacMint can't read this switch, so the dot stays neutral.
      PermissionStatusDot(look: PermissionLook(symbol: "questionmark", swatch: .slate))
      VStack(alignment: .leading, spacing: 8) {
        HStack(spacing: 6) {
          Text("Full Disk Access")
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(AppTheme.ink)
          Chip(title: "Optional", swatch: .slate)
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
        Text("Lets MacMint inspect protected app data for broader scan coverage. Without it, you can still inspect permitted locations; unreadable areas appear in scan issues.")
          .font(.system(size: 12)).foregroundStyle(AppTheme.ink2)
          .fixedSize(horizontal: false, vertical: true)
        Text("Install and open MacMint from Applications before granting this access.")
          .font(.system(size: 12, weight: .medium)).foregroundStyle(AppTheme.ink)
          .fixedSize(horizontal: false, vertical: true)
        HStack(spacing: 8) {
          Button("Open Full Disk Access") { permissions.open(.fullDiskAccess) }
            .buttonStyle(MintButtonStyle(.secondary))
            .controlSize(.small)
          Button("Reveal This App") { permissions.revealThisApp() }
            .buttonStyle(MintButtonStyle(.plain))
            .controlSize(.small)
        }
        VStack(alignment: .leading, spacing: 6) {
          PermissionStepLine(number: 1, text: "Turn on the MacMint copy you are running.")
          PermissionStepLine(number: 2, text: "If it is missing, click + and select the app revealed in Finder.")
          PermissionStepLine(number: 3, text: "Quit and reopen MacMint if macOS asks, then run your scan again.")
        }
        Text("Confirm the switch in System Settings. MacMint cannot grant this access or reliably verify that switch for you.")
          .font(.system(size: 11.5)).foregroundStyle(AppTheme.ink3)
          .fixedSize(horizontal: false, vertical: true)
        Text(PermissionSettingsPane.fullDiskAccess.path)
          .font(.system(size: 11)).foregroundStyle(AppTheme.ink3)
          .textSelection(.enabled)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
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
    SettingsCard(spacing: 0) {
      SettingsCardHeader(symbol: "lock.shield.fill", swatch: .sky, title: "Permissions & setup",
        subtitle: "Optional access. Changing it does not remove any files.") {
        Button("Review Setup") { showingSetup = true }
          .buttonStyle(MintButtonStyle(.secondary))
          .controlSize(.small)
      }
      .padding(.bottom, 12)
      InstallationGuide()
        .padding(.bottom, 12)
      rowDivider
      FullDiskAccessGuide(permissions: permissions)
        .padding(.vertical, 12)
      permissionRow(PermissionLook(symbol: "folder.fill", swatch: .slate), title: "Files & Folders",
        detail: "macOS asks when a scan reaches protected locations such as Desktop, Documents, or Downloads. Allow the locations you want inspected; changing access does not remove any files.",
        pane: .filesAndFolders) {
        Button("Open Files & Folders") { permissions.open(.filesAndFolders) }
          .buttonStyle(MintButtonStyle(.secondary))
          .controlSize(.small)
      }
      permissionRow(PermissionLook(symbol: "app.badge.checkmark", swatch: .slate), title: "App Management",
        detail: "macOS may ask separately when you confirm removing an installed app. Full Disk Access does not replace App Management permission.",
        pane: .appManagement) {
        Button("Open Privacy & Security") { permissions.open(.appManagement) }
          .buttonStyle(MintButtonStyle(.secondary))
          .controlSize(.small)
      }
      permissionRow(permissions.photos.look, title: "Photos", status: permissions.photos.title,
        detail: permissions.photos.detail, pane: .photos) {
        Button("Open Photos Settings") { permissions.open(.photos) }
          .buttonStyle(MintButtonStyle(.secondary))
          .controlSize(.small)
        Button("Go to Photos") { model.selectedSection = .photos }
          .buttonStyle(MintButtonStyle(.plain))
          .controlSize(.small)
      }
      permissionRow(permissions.notifications.look, title: "Notifications", status: permissions.notifications.title,
        detail: "Optional low-space alerts and scan reminders ask for notification access only when you turn them on. Permission alone does not enable reminders.",
        pane: .notifications) {
        Button("Open Notification Settings") { permissions.open(.notifications) }
          .buttonStyle(MintButtonStyle(.secondary))
          .controlSize(.small)
        Spacer(minLength: 0)
        Button("Refresh Status") { Task { await permissions.refresh() } }
          .buttonStyle(MintButtonStyle(.plain))
          .controlSize(.small)
      }
      if let error = permissions.settingsError {
        Label(error, systemImage: "exclamationmark.triangle.fill")
          .font(.system(size: 12))
          .foregroundStyle(AppTheme.warning)
          .fixedSize(horizontal: false, vertical: true)
          .padding(.top, 4)
      }
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

  private var rowDivider: some View {
    Rectangle().fill(AppTheme.divider).frame(height: 1)
  }

  private func permissionRow<Buttons: View>(_ look: PermissionLook, title: String, status: String? = nil,
    detail: String, pane: PermissionSettingsPane, @ViewBuilder buttons: () -> Buttons) -> some View {
    VStack(alignment: .leading, spacing: 0) {
      rowDivider
      HStack(alignment: .top, spacing: 11) {
        PermissionStatusDot(look: look)
        VStack(alignment: .leading, spacing: 6) {
          VStack(alignment: .leading, spacing: 1) {
            Text(title)
              .font(.system(size: 13, weight: .semibold))
              .foregroundStyle(AppTheme.ink)
            if let status {
              Text(status)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(look.swatch.text)
            }
          }
          .accessibilityElement(children: .combine)
          .accessibilityAddTraits(.isHeader)
          Text(detail)
            .font(.system(size: 12))
            .foregroundStyle(AppTheme.ink2)
            .fixedSize(horizontal: false, vertical: true)
          HStack(spacing: 8) { buttons() }
          Text(pane.path)
            .font(.system(size: 11))
            .foregroundStyle(AppTheme.ink3)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
      .padding(.vertical, 12)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}
