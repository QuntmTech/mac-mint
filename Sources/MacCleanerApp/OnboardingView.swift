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
  @State private var showingSteps = false
  private let progress: SetupProgressStore
  private let onFinish: (Bool) -> Void

  init(initialStep: Int? = nil, defaults: UserDefaults = .standard, onFinish: @escaping (Bool) -> Void = { _ in }) {
    let progress = SetupProgressStore(defaults: defaults)
    self.progress = progress
    self.onFinish = onFinish
    // Intentional one-time seed; navigation owns its state for this presentation.
    _step = State(initialValue: min(max(initialStep ?? progress.initialStep, 0), 2))
  }

  private struct SetupStep {
    let title: String
    let detail: String
  }

  private let steps: [SetupStep] = [
    SetupStep(title: "Welcome", detail: "What MacMint does"),
    SetupStep(title: "Access", detail: "Optional permissions"),
    SetupStep(title: "Ready", detail: "Pick how to start"),
  ]

  var body: some View {
    HStack(spacing: 0) {
      sidePanel.frame(width: 210)
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
          .padding(.horizontal, 26).padding(.top, 24).padding(.bottom, 22)
        }
        .id(step)
        footer
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .background(AppTheme.canvas)
    }
    // The design is 780×580; 720 keeps every step inside the smallest window that shows it.
    .frame(width: 720, height: 580)
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

  // MARK: Brand panel

  private var sidePanel: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack(spacing: 10) {
        BrandMark(size: 34).frame(width: 34, height: 34)
        VStack(alignment: .leading, spacing: 1) {
          Text("MacMint").font(.system(size: 15, weight: .bold)).tracking(-0.3)
          Text("Setup").font(.system(size: 11)).foregroundStyle(Color.white.opacity(0.78))
        }
      }
      .accessibilityElement(children: .combine)
      .padding(.bottom, 26)

      Eyebrow("Three steps", color: Color.white.opacity(0.78))
        .padding(.horizontal, 10).padding(.bottom, 8)
      VStack(alignment: .leading, spacing: 4) {
        ForEach(steps.indices, id: \.self) { index in
          stepRow(index)
        }
      }

      Spacer(minLength: 16)

      VStack(alignment: .leading, spacing: 8) {
        sidePromise("eye.fill", "We look")
        sidePromise("hand.tap.fill", "You decide")
        sidePromise("arrow.uturn.backward", "You can undo")
      }
      .padding(12)
      .background(Color.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
      .accessibilityElement(children: .combine)
      .accessibilityLabel(TrustLine.promise)
    }
    .foregroundStyle(.white)
    .padding(.horizontal, 16).padding(.top, 22).padding(.bottom, 18)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .background { sidePanelBackground }
  }

  private var sidePanelBackground: some View {
    ZStack {
      AppTheme.heroGradient
      Image(systemName: "leaf.fill").font(.system(size: 170)).foregroundStyle(Color.white.opacity(0.06))
        .rotationEffect(.degrees(-18)).offset(x: 60, y: 30)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
    }
    .clipped()
    .accessibilityHidden(true)
  }

  private func stepRow(_ index: Int) -> some View {
    let item = steps[index]
    let current = index == step
    let done = index < step
    return HStack(spacing: 10) {
      ZStack {
        Circle().fill(current ? Color.white : Color.white.opacity(done ? 0.24 : 0.08))
        Circle().strokeBorder(Color.white.opacity(current || done ? 0 : 0.4), lineWidth: 1)
        if done {
          Image(systemName: "checkmark").font(.system(size: 10, weight: .heavy))
        } else {
          Text("\(index + 1)").font(AppTheme.number(11.5)).monospacedDigit()
        }
      }
      .foregroundStyle(current ? AppTheme.hex(0x04583F) : Color.white)
      .frame(width: 24, height: 24)
      VStack(alignment: .leading, spacing: 1) {
        Text(item.title).font(.system(size: 13, weight: current ? .bold : .medium))
        Text(item.detail).font(.system(size: 11)).foregroundStyle(Color.white.opacity(current ? 0.88 : 0.7))
          .lineLimit(1)
      }
      Spacer(minLength: 0)
    }
    .padding(.horizontal, 10).padding(.vertical, 8)
    .background(current ? Color.white.opacity(0.16) : Color.clear,
      in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    .accessibilityElement(children: .combine)
    .accessibilityAddTraits(current ? .isSelected : [])
  }

  private func sidePromise(_ symbol: String, _ title: String) -> some View {
    HStack(spacing: 8) {
      Image(systemName: symbol).font(.system(size: 11, weight: .semibold)).frame(width: 16)
      Text(title).font(.system(size: 12, weight: .semibold))
    }
  }

  // MARK: Footer

  private var footer: some View {
    SheetFooter {
      Text("Step \(step + 1) of 3").font(AppTheme.number(12, weight: .medium)).monospacedDigit()
        .foregroundStyle(AppTheme.ink2)
        .accessibilityLabel("\(steps[step].title), step \(step + 1) of 3")
      Spacer()
      if step < 2 {
        Button("Set Up Later") { finish(startScan: false) }.buttonStyle(MintButtonStyle(.plain))
      }
      if step > 0 {
        Button("Back") { step -= 1 }.buttonStyle(MintButtonStyle(.secondary))
      }
      if step < 2 {
        Button("Continue") { step += 1 }
          .buttonStyle(MintButtonStyle(.commit))
          .keyboardShortcut(.defaultAction)
      }
    }
  }

  // MARK: Welcome

  private var areas: [AppViewModel.Section] { AppViewModel.Section.primary + [.review] }

  private var welcome: some View {
    VStack(alignment: .leading, spacing: 18) {
      heading("Welcome", "Welcome to MacMint",
        "Understand your storage, review what can go, and keep recovery close.")
      HStack(alignment: .top, spacing: 10) {
        promise("magnifyingglass", .mint, "We look",
          "Quick Scan only reads. Scans and History work without an account.")
        promise("checklist", .sky, "You decide",
          "Nothing is removed by a scan. Personal files need your choice.")
        promise("arrow.uturn.backward", .indigo, "You can undo",
          "Removals go to the Trash with a receipt. Restore while they're there.")
      }
      .fixedSize(horizontal: false, vertical: true)

      VStack(alignment: .leading, spacing: 10) {
        Text("Where everything lives").font(.system(size: 15, weight: .bold)).tracking(-0.2)
          .foregroundStyle(AppTheme.ink).accessibilityAddTraits(.isHeader)
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 12, alignment: .leading),
          GridItem(.flexible(), spacing: 12, alignment: .leading)], alignment: .leading, spacing: 10) {
          ForEach(areas) { section in
            areaRow(section)
          }
        }
        .padding(12)
        .cardBackground(radius: 14)
      }

      InstallationGuide()

      Label("Photos keeps its own Recently Deleted. Optional AI needs separate consent, and you can preview what would be sent first.",
        systemImage: "info.circle")
        .font(.system(size: 11.5)).foregroundStyle(AppTheme.ink3)
        .fixedSize(horizontal: false, vertical: true)
    }
  }

  private func promise(_ symbol: String, _ swatch: AppTheme.Swatch, _ title: String, _ detail: String) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      SwatchBadge(symbol: symbol, swatch: swatch, size: 30)
      Text(title).font(.system(size: 13.5, weight: .bold)).tracking(-0.2).foregroundStyle(AppTheme.ink)
      Text(detail).font(.system(size: 11.5)).foregroundStyle(AppTheme.ink2)
        .fixedSize(horizontal: false, vertical: true)
    }
    .padding(12)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .cardBackground(radius: 14)
    .accessibilityElement(children: .combine)
  }

  private func areaRow(_ section: AppViewModel.Section) -> some View {
    HStack(spacing: 10) {
      SwatchBadge(symbol: section.icon, swatch: section.swatch, size: 26)
      VStack(alignment: .leading, spacing: 1) {
        Text(section.rawValue).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(AppTheme.ink)
        Text(areaDetail(section)).font(.system(size: 11.5)).foregroundStyle(AppTheme.ink2)
      }
      .lineLimit(1)
      Spacer(minLength: 0)
    }
    .accessibilityElement(children: .combine)
  }

  private func areaDetail(_ section: AppViewModel.Section) -> String {
    switch section {
    case .dashboard: return "Your Mac's health"
    case .cleaner: return "Caches and leftovers"
    case .storage: return "What fills space"
    case .applications: return "Apps and uninstalls"
    case .photos: return "Similar shots, screenshots"
    case .developer: return "Rebuildable build files"
    case .history: return "Undo past cleanups"
    case .review: return "Check before Trash"
    default: return ""
    }
  }

  // MARK: Access

  private var access: some View {
    VStack(alignment: .leading, spacing: 16) {
      heading("Access · Optional", "Choose what MacMint can inspect",
        "Access improves coverage. You can continue with your current permissions and return to this guide in Settings.")
      fullDiskAccessCard
      VStack(alignment: .leading, spacing: 0) {
        accessRow("folder", .indigo, "Folders ask as needed",
          "A scan may ask to read Desktop, Documents, Downloads, or another protected location. Allow the locations you want included.") {
          Button("Open Files & Folders") { permissions.open(.filesAndFolders) }
            .buttonStyle(MintButtonStyle(.secondary)).controlSize(.small)
        }
        Rectangle().fill(AppTheme.divider).frame(height: 1).padding(.leading, 54)
        accessRow("photo.on.rectangle", .pink, "Photos asks when you scan your library",
          "Library access is optional. Choosing a photo folder works without Photos-library permission.") {
          EmptyView()
        }
      }
      .cardBackground()
      if let error = permissions.settingsError { warningLine(error) }
    }
  }

  private var fullDiskAccessCard: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack(alignment: .top, spacing: 12) {
        SwatchBadge(symbol: "externaldrive.badge.checkmark", swatch: .mint, size: 36, glow: true)
        VStack(alignment: .leading, spacing: 4) {
          HStack(spacing: 8) {
            Text("Full Disk Access").font(.system(size: 15, weight: .bold)).tracking(-0.2)
              .foregroundStyle(AppTheme.ink)
            Chip(title: "Optional", symbol: "info.circle.fill", swatch: .slate)
          }
          Text("Lets MacMint inspect protected app data for broader scan coverage. Without it, you can still inspect permitted locations; unreadable areas appear in scan issues.")
            .font(.system(size: 12)).foregroundStyle(AppTheme.ink2).fixedSize(horizontal: false, vertical: true)
        }
      }
      HStack(alignment: .top, spacing: 8) {
        Image(systemName: "questionmark.circle.fill").font(.system(size: 12)).foregroundStyle(AppTheme.ink2)
        Text("Status: confirm the switch in System Settings. MacMint cannot grant this access or reliably verify that switch for you.")
          .font(.system(size: 11.5)).foregroundStyle(AppTheme.ink2).fixedSize(horizontal: false, vertical: true)
      }
      .padding(.horizontal, 10).padding(.vertical, 8)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(AppTheme.panel, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
      .accessibilityElement(children: .combine)
      Label("Install and open MacMint from Applications before granting this access.", systemImage: "app.badge.checkmark")
        .font(.system(size: 12)).foregroundStyle(AppTheme.ink)
        .fixedSize(horizontal: false, vertical: true)
      HStack(spacing: 8) {
        Button("Open System Settings") { permissions.open(.fullDiskAccess) }
          .buttonStyle(MintButtonStyle(.area))
          .environment(\.areaSwatch, .mint)
          .help(PermissionSettingsPane.fullDiskAccess.path)
        Button(showingSteps ? "Hide Steps" : "Show Me How") { showingSteps.toggle() }
          .buttonStyle(MintButtonStyle(.secondary))
        Button("Reveal This App") { permissions.revealThisApp() }
          .buttonStyle(MintButtonStyle(.plain))
      }
      if showingSteps {
        VStack(alignment: .leading, spacing: 8) {
          numberedStep(1, "Turn on the MacMint copy you are running.")
          numberedStep(2, "If it is missing, click + and select the app revealed in Finder.")
          numberedStep(3, "Quit and reopen MacMint if macOS asks, then run your scan again.")
          Text(PermissionSettingsPane.fullDiskAccess.path)
            .font(.system(size: 11.5, design: .monospaced)).foregroundStyle(AppTheme.ink2)
            .textSelection(.enabled)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppTheme.panel, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
      }
    }
    .padding(16)
    .cardBackground()
  }

  private func numberedStep(_ number: Int, _ text: String) -> some View {
    HStack(alignment: .top, spacing: 8) {
      Text("\(number)").font(AppTheme.number(11)).monospacedDigit().foregroundStyle(.white)
        .frame(width: 18, height: 18)
        .background(AppTheme.accent, in: Circle())
      Text(text).font(.system(size: 12)).foregroundStyle(AppTheme.ink)
        .fixedSize(horizontal: false, vertical: true)
    }
    .accessibilityElement(children: .combine)
  }

  private func accessRow<Action: View>(_ symbol: String, _ swatch: AppTheme.Swatch, _ title: String, _ detail: String,
    @ViewBuilder action: () -> Action) -> some View {
    HStack(alignment: .top, spacing: 12) {
      SwatchBadge(symbol: symbol, swatch: swatch, size: 28)
      VStack(alignment: .leading, spacing: 6) {
        VStack(alignment: .leading, spacing: 2) {
          Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(AppTheme.ink)
          Text(detail).font(.system(size: 12)).foregroundStyle(AppTheme.ink2)
            .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
        action()
      }
      Spacer(minLength: 0)
    }
    .padding(14)
  }

  // MARK: Ready

  private var helpers: some View {
    VStack(alignment: .leading, spacing: 16) {
      heading("Ready", "Ready for your first scan",
        "Scanning does not remove files. Review the results and keep anything you need.")
      HStack(alignment: .top, spacing: 10) {
        // Both end setup the same way as before; the workspace offers the tour on its own.
        choice(symbol: "map.fill", swatch: .iris, title: "Show me around",
          detail: "Open MacMint and see where things are. Scan when you're ready.", primary: false) {
          finish(startScan: false)
        }
        choice(symbol: "dot.radiowaves.left.and.right", swatch: .mint, title: "Jump right in",
          detail: "Run Quick Scan now. It only reads; nothing is removed.", primary: true) {
          finish(startScan: true)
        }
        .keyboardShortcut(.defaultAction)
      }
      .fixedSize(horizontal: false, vertical: true)

      helperToggles
      accountCard

      Label("Quick Scan inspects known cleanup areas and inventories apps. Storage mapping, duplicate checks, photo analysis, and deep developer scans start separately when you choose them.",
        systemImage: "magnifyingglass")
        .font(.system(size: 11.5)).foregroundStyle(AppTheme.ink3)
        .fixedSize(horizontal: false, vertical: true)
    }
  }

  private func choice(symbol: String, swatch: AppTheme.Swatch, title: String, detail: String, primary: Bool,
    action: @escaping () -> Void) -> some View {
    let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
    return Button(action: action) {
      VStack(alignment: .leading, spacing: 8) {
        HStack(alignment: .top) {
          SwatchBadge(symbol: symbol, swatch: swatch, size: 34, glow: primary)
          Spacer(minLength: 8)
          Image(systemName: "arrow.right").font(.system(size: 12, weight: .bold))
            .foregroundStyle(primary ? AppTheme.accentText : AppTheme.ink3)
        }
        Text(title).font(.system(size: 15, weight: .bold)).tracking(-0.2).foregroundStyle(AppTheme.ink)
        Text(detail).font(.system(size: 12)).foregroundStyle(AppTheme.ink2)
          .multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
      }
      .padding(14)
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
      .cardBackground(primary ? AppTheme.Swatch.mint.tint : AppTheme.surface, radius: 14)
      .overlay(shape.strokeBorder(primary ? AppTheme.brand.opacity(0.55) : Color.clear, lineWidth: 1.5))
      .contentShape(shape)
    }
    .buttonStyle(CardButtonStyle())
  }

  private var helperToggles: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack(alignment: .firstTextBaseline) {
        Text("Optional helpers").font(.system(size: 13.5, weight: .semibold)).foregroundStyle(AppTheme.ink)
          .accessibilityAddTraits(.isHeader)
        Spacer(minLength: 8)
        Text("Change these any time in Settings.").font(.system(size: 11.5)).foregroundStyle(AppTheme.ink3)
      }
      .padding(.bottom, 4)
      helperToggle($scanOnLaunch, "Run Quick Scan when MacMint opens",
        "Overview, Cleanup and Apps are ready when you look. It only reads; nothing is removed.")
      Rectangle().fill(AppTheme.divider).frame(height: 1)
      helperToggle($showMenuBar, "Show MacMint in the menu bar",
        "Free space, memory pressure, and CPU at a glance.")
      Rectangle().fill(AppTheme.divider).frame(height: 1)
      helperToggle($lowSpaceAlerts, "Alert me when space runs low",
        "Asks for notification access when enabled. At most once a day, never between 10 pm and 8 am.")
        .onChange(of: lowSpaceAlerts) { _, enabled in if enabled { Task { await care.requestAuthorization() } } }
      if care.notificationsDenied {
        VStack(alignment: .leading, spacing: 6) {
          warningLine("Notifications are off. Turn them on in System Settings if you want alerts.")
          Button("Open Notification Settings") { permissions.open(.notifications) }
            .buttonStyle(MintButtonStyle(.secondary)).controlSize(.small)
        }
        .padding(.top, 6)
      }
      if let error = care.notificationError { warningLine(error).padding(.top, 6) }
      if let error = permissions.settingsError { warningLine(error).padding(.top, 6) }
    }
    .padding(.horizontal, 14).padding(.vertical, 12)
    .cardBackground()
  }

  private func helperToggle(_ isOn: Binding<Bool>, _ title: String, _ detail: String) -> some View {
    Toggle(isOn: isOn) {
      VStack(alignment: .leading, spacing: 2) {
        Text(title).font(.system(size: 13, weight: .medium)).foregroundStyle(AppTheme.ink)
        Text(detail).font(.system(size: 11.5)).foregroundStyle(AppTheme.ink2)
          .fixedSize(horizontal: false, vertical: true)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .toggleStyle(.switch)
    .controlSize(.small)
    .padding(.vertical, 8)
  }

  private var accountCard: some View {
    HStack(alignment: .top, spacing: 12) {
      SwatchBadge(symbol: account.isUnlocked ? "checkmark.seal.fill" : "person.crop.circle.fill",
        swatch: account.isUnlocked ? .mint : .violet, size: 30)
      VStack(alignment: .leading, spacing: 3) {
        HStack(spacing: 6) {
          Text(account.isUnlocked ? "This Mac is activated" : "Already purchased MacMint?")
            .font(.system(size: 13.5, weight: .semibold)).foregroundStyle(AppTheme.ink)
          if !account.isUnlocked { Chip(title: "Optional", swatch: .slate) }
        }
        if account.isUnlocked {
          Text("Your account is connected. You still review and confirm each removal.")
            .font(.system(size: 12)).foregroundStyle(AppTheme.ink2).fixedSize(horizontal: false, vertical: true)
        } else {
          Text("Use the same account as your website purchase. Connect now or when you review a paid operation. Local scans and recovery work without signing in.")
            .font(.system(size: 12)).foregroundStyle(AppTheme.ink2).fixedSize(horizontal: false, vertical: true)
        }
      }
      Spacer(minLength: 8)
      if !account.isUnlocked {
        Button("Connect My Account") { showingAccount = true }
          .buttonStyle(MintButtonStyle(.secondary)).controlSize(.small)
      }
    }
    .padding(14)
    .cardBackground()
  }

  // MARK: Shared pieces

  private func heading(_ eyebrow: String, _ title: String, _ subtitle: String) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      Eyebrow(eyebrow, color: AppTheme.Swatch.mint.text)
      Text(title).font(.system(size: 22, weight: .bold)).tracking(-0.5).foregroundStyle(AppTheme.ink)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityAddTraits(.isHeader)
      Text(subtitle).font(.system(size: 13)).foregroundStyle(AppTheme.ink2)
        .fixedSize(horizontal: false, vertical: true)
    }
  }

  private func warningLine(_ text: String) -> some View {
    Label(text, systemImage: "exclamationmark.triangle.fill")
      .font(.system(size: 12)).foregroundStyle(AppTheme.warning)
      .fixedSize(horizontal: false, vertical: true)
  }

  private func finish(startScan: Bool) {
    progress.complete()
    onFinish(startScan)
    dismiss()
  }
}
