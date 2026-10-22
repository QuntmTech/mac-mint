import AppKit
import MacCleanerCore
import SwiftUI

/// Explain optional access before the user chooses a scan. Reading status never
/// requests permission; Photos and notifications ask when their features are used.
struct OnboardingView: View {
  @EnvironmentObject private var care: CareService
  @EnvironmentObject private var account: AccountStore
  @Environment(\.dismiss) private var dismiss
  @AppStorage(CareService.Keys.showMenuBar) private var showMenuBar = false
  @AppStorage(CareService.Keys.lowSpaceAlerts) private var lowSpaceAlerts = false
  @AppStorage(CareService.Keys.scanOnLaunch) private var scanOnLaunch = true
  @StateObject private var permissions = PermissionsService()
  @State private var step: Int
  @State private var showingAccount = false
  private let progress: SetupProgressStore
  private let onFinish: (Bool) -> Void

  init(initialStep: Int? = nil, defaults: UserDefaults = .standard, onFinish: @escaping (Bool) -> Void = { _ in }) {
    let progress = SetupProgressStore(defaults: defaults)
    self.progress = progress
    self.onFinish = onFinish
    // Intentional one-time seed; navigation owns its state for this presentation.
    _step = State(initialValue: min(max(initialStep ?? progress.initialStep, 0), 2))
  }

  var body: some View {
    VStack(spacing: 0) {
      ScrollView {
        Group {
          switch step {
          case 0: welcome
          case 1: access
          default: helpers
          }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .padding(28)
      }
      .id(step)
      Divider()
      HStack(spacing: 12) {
        Text("\(["Welcome", "Access", "Ready"][step]) · Step \(step + 1) of 3").font(.caption).foregroundStyle(.secondary)
        Spacer()
        if step > 0 { Button("Back") { step -= 1 } }
        Button(step == 2 ? "Open Workspace" : "Set Up Later") { finish(startScan: false) }
        Button(step == 2 ? "Run Quick Scan" : "Continue") {
          if step < 2 { step += 1 } else { finish(startScan: true) }
        }
        .buttonStyle(MintButtonStyle())
        .keyboardShortcut(.defaultAction)
      }
      .padding(16)
    }
    .frame(width: 640, height: 600)
    .background(AppTheme.canvas)
    .onExitCommand { finish(startScan: false) }
    .onChange(of: step) { _, next in
      guard !SmokeTest.isRequested else { return }
      progress.record(step: next)
    }
    .sheet(isPresented: $showingAccount) { AccountAccessSheet() }
    .task {
      await permissions.refresh()
      await care.refreshAuthorization()
    }
    .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
      Task {
        await permissions.refresh()
        await care.refreshAuthorization()
      }
    }
  }

  private var welcome: some View {
    VStack(alignment: .leading, spacing: 20) {
      BrandMark(size: 54)
      Text("Welcome to MacMint").font(.system(size: 27, weight: .semibold))
      Text("Understand your storage, review what can go, and keep recovery close.")
        .font(.title3).foregroundStyle(.secondary)
      InstallationGuide()
      point("magnifyingglass", "Start with a local scan", "Inspect results before signing in. Quick Scan only reads, and inspection and History work without an account.")
      point("checklist", "Review before removal", "Personal files need your decision. Nothing is removed when you grant permission or run a scan.")
      point("arrow.uturn.backward.circle.fill", "Know your recovery path", "File removals use Trash receipts. Restore while items remain there; Photos manages its own Recently Deleted recovery.")
      Text("Optional AI needs separate consent. You can preview what would be sent before enabling it.")
        .font(.caption).foregroundStyle(.secondary)
    }
  }

  private var access: some View {
    VStack(alignment: .leading, spacing: 18) {
      Text("Choose what MacMint can inspect").font(.title2.bold())
      Text("Access improves coverage. You can continue with your current permissions and return to this guide in Settings.")
        .foregroundStyle(.secondary)
      FullDiskAccessGuide(permissions: permissions)
      Divider()
      point("folder", "Folders ask as needed", "A scan may ask to read Desktop, Documents, Downloads, or another protected location. Allow the locations you want included.")
      Button("Open Files & Folders") { permissions.open(.filesAndFolders) }
      point("photo.on.rectangle", "Photos asks when you scan your library", "Library access is optional. Choosing a photo folder works without Photos-library permission.")
      if let error = permissions.settingsError {
        Text(error).font(.callout).foregroundStyle(AppTheme.warning)
      }
    }
  }

  private var helpers: some View {
    VStack(alignment: .leading, spacing: 18) {
      Text("Ready for your first scan").font(.title2.bold())
      Text("Scanning does not remove files. Review the results and keep anything you need.").foregroundStyle(.secondary)
      VStack(alignment: .leading, spacing: 9) {
        Label(account.isUnlocked ? "This Mac is activated" : "Already purchased MacMint?",
          systemImage: account.isUnlocked ? "checkmark.seal.fill" : "person.crop.circle")
          .font(.headline)
        if account.isUnlocked {
          Text("Your account is connected. You still review and confirm each removal.")
            .font(.callout).foregroundStyle(.secondary)
        } else {
          Text("Use the same account as your website purchase. Connect now or when you review a paid operation. Local scans and recovery work without signing in.")
            .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
          Button("Connect My Account") { showingAccount = true }
            .buttonStyle(MintButtonStyle(prominent: false))
        }
      }
      Divider()
      Text("Optional helpers").font(.headline)
      Text("Change these any time in Settings.").font(.callout).foregroundStyle(.secondary)
      Toggle(isOn: $scanOnLaunch) {
        VStack(alignment: .leading, spacing: 3) {
          Text("Run Quick Scan when MacMint opens")
          Text("Overview, Cleanup and Apps are ready when you look. It only reads; nothing is removed.")
            .font(.caption).foregroundStyle(.secondary)
        }
      }
      Toggle(isOn: $showMenuBar) {
        VStack(alignment: .leading, spacing: 3) {
          Text("Show MacMint in the menu bar")
          Text("Free space, memory pressure, and CPU at a glance.").font(.caption).foregroundStyle(.secondary)
        }
      }
      Toggle(isOn: $lowSpaceAlerts) {
        VStack(alignment: .leading, spacing: 3) {
          Text("Alert me when space runs low")
          Text("Asks for notification access when enabled. At most once a day, never between 10 pm and 8 am.")
            .font(.caption).foregroundStyle(.secondary)
        }
      }
      .onChange(of: lowSpaceAlerts) { _, enabled in if enabled { Task { await care.requestAuthorization() } } }
      if care.notificationsDenied {
        Text("Notifications are off. Turn them on in System Settings if you want alerts.")
          .font(.callout).foregroundStyle(AppTheme.warning)
        Button("Open Notification Settings") { permissions.open(.notifications) }
      }
      if let error = care.notificationError {
        Text(error).font(.callout).foregroundStyle(AppTheme.warning)
      }
      if let error = permissions.settingsError {
        Text(error).font(.callout).foregroundStyle(AppTheme.warning)
      }
      Divider()
      point("magnifyingglass", "Ready when you are", "Quick Scan inspects known cleanup areas and inventories apps. Storage mapping, duplicate checks, photo analysis, and deep developer scans start separately when you choose them.")
      Text("Open Workspace to explore first, or Run Quick Scan to start inspecting now.")
        .font(.callout).foregroundStyle(.secondary)
    }
    .toggleStyle(.switch)
  }

  private func point(_ icon: String, _ title: String, _ detail: String) -> some View {
    HStack(alignment: .top, spacing: 12) {
      Image(systemName: icon).font(.title3).foregroundStyle(AppTheme.accentText).frame(width: 26)
      VStack(alignment: .leading, spacing: 3) {
        Text(title).font(.headline)
        Text(detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
      }
    }
  }

  private func finish(startScan: Bool) {
    progress.complete()
    onFinish(startScan)
    dismiss()
  }
}
