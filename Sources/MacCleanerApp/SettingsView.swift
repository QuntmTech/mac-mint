import AppKit
import SwiftUI

struct SettingsView: View {
  @EnvironmentObject private var model: AppViewModel
  @State private var confirmClear = false

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 16) {
        PageHeader("Settings", subtitle: "Appearance, access, helpers, updates, account and AI. Safety and privacy stay in your control.")
        // Two columns of cards when there is room; one column at compact widths.
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 360), spacing: 14, alignment: .top)], alignment: .leading, spacing: 14) {
          VStack(alignment: .leading, spacing: 14) {
            AppearanceSettingsCard()
            HelpersSettingsCard()
            exclusionsCard
            AISettingsCard()
            privacyCard
            safetyCard
          }
          VStack(alignment: .leading, spacing: 14) {
            PermissionsSettingsCard()
            UpdatesSettingsCard()
            AccountSettingsCard()
          }
        }
      }
      .frame(maxWidth: 1040, alignment: .leading)
      .padding(.horizontal, AppTheme.pagePadding)
      .padding(.top, AppTheme.pageTopPadding)
      .padding(.bottom, 28)
      .frame(maxWidth: .infinity)
    }
    .alert("Clear all scan exclusions?", isPresented: $confirmClear) {
      Button("Cancel", role: .cancel) {}
      Button("Clear Exclusions", role: .destructive) { model.clearIgnores() }
    }
  }

  // MARK: Cards

  private var exclusionsCard: some View {
    SettingsCard {
      SettingsCardHeader(symbol: "hand.raised.fill", swatch: .slate, title: "Exclusions") {
        if !model.ignoredPaths.isEmpty || model.exclusionLoadError != nil {
          Button("Clear all", role: .destructive) { confirmClear = true }
            .buttonStyle(MintButtonStyle(.secondary))
            .controlSize(.small)
        }
      }
      Text(
        "Excluded folders are skipped by cleanup, storage, developer, photo, large-file, duplicate, and app-leftover scans."
      )
      .font(.system(size: 11.5))
      .foregroundStyle(AppTheme.ink3)
      .fixedSize(horizontal: false, vertical: true)

      if let error = model.exclusionLoadError {
        Label(error, systemImage: "exclamationmark.triangle.fill")
          .font(.system(size: 12))
          .foregroundStyle(AppTheme.warning)
          .fixedSize(horizontal: false, vertical: true)
        Button("Show Exclusion Files") { model.reveal(AppPaths.supportDirectory) }
          .buttonStyle(MintButtonStyle(.secondary))
          .controlSize(.small)
      } else if model.ignoredPaths.isEmpty {
        Text("No exclusions saved.")
          .font(.system(size: 12.5))
          .foregroundStyle(AppTheme.ink2)
          .padding(.horizontal, 10)
          .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
          .background(AppTheme.panel, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
      } else {
        VStack(alignment: .leading, spacing: 6) {
          ForEach(model.ignoredPaths.sorted(), id: \.self) { path in
            exclusionRow(path)
          }
        }
      }
    }
  }

  private func exclusionRow(_ path: String) -> some View {
    HStack(spacing: 8) {
      Image(systemName: "folder.fill")
        .font(.system(size: 12))
        .foregroundStyle(AppTheme.ink3)
        .accessibilityHidden(true)
      Text(path)
        .font(.system(size: 11.5, design: .monospaced))
        .foregroundStyle(AppTheme.ink)
        .lineLimit(1)
        .truncationMode(.middle)
        .textSelection(.enabled)
      Spacer(minLength: 6)
      Button {
        model.removeIgnore(path: path)
      } label: {
        Image(systemName: "xmark.circle.fill")
          .accessibilityLabel("Remove exclusion")
      }
      .buttonStyle(.plain)
      .foregroundStyle(AppTheme.ink3)
      .help("Remove exclusion")
    }
    .padding(.horizontal, 10)
    .frame(minHeight: 32)
    .background(AppTheme.panel, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
  }

  private var safetyCard: some View {
    SettingsCard(spacing: 0) {
      SettingsCardHeader(symbol: "checkmark.shield.fill", swatch: .mint, title: "Safety model")
        .padding(.bottom, 10)
      settingRow("Deletion mode", value: "Trash-first")
      settingRow("Automatic personal-file cleanup", value: "Blocked")
      settingRow("System-owned cleanup", value: "Read-only")
      Rectangle().fill(AppTheme.divider).frame(height: 1)
      Text(
        "Automatic cleanup never targets Documents, Desktop, Pictures, Movies, or Music. Generic Large Files and Duplicates review also excludes ~/Library and system-owned paths."
      )
      .font(.system(size: 11.5))
      .foregroundStyle(AppTheme.ink2)
      .fixedSize(horizontal: false, vertical: true)
      .padding(.top, 10)
    }
  }

  private var privacyCard: some View {
    SettingsCard(spacing: 0) {
      SettingsCardHeader(symbol: "hand.raised.square.fill", swatch: .graphite, title: "Privacy")
        .padding(.bottom, 10)
      settingRow("Telemetry", value: "None")
      settingRow("Network calls", value: model.aiEnabled ? "Account, releases, optional app updates & AI" : "Account, release and optional app-update checks")
      settingRow("File contents uploaded", value: "Never")
      settingRow("AI summaries", value: model.aiEnabled ? "Categories, only when requested" : "Off")
      settingRow("Cleanup history", value: "Local JSON")
      settingRow("Exclusions", value: "Local JSON")
    }
  }

  private func settingRow(_ title: String, value: String) -> some View {
    VStack(alignment: .leading, spacing: 0) {
      Rectangle().fill(AppTheme.divider).frame(height: 1)
      HStack(alignment: .firstTextBaseline, spacing: 12) {
        Text(title)
          .font(.system(size: 12.5))
          .foregroundStyle(AppTheme.ink)
        Spacer(minLength: 8)
        Text(value)
          .font(.system(size: 12.5, weight: .medium))
          .foregroundStyle(AppTheme.ink2)
          .multilineTextAlignment(.trailing)
          .fixedSize(horizontal: false, vertical: true)
      }
      .padding(.vertical, 8)
    }
    .accessibilityElement(children: .combine)
  }
}

// MARK: - Shared settings pieces

/// A settings card: surface, 16 pt radius, card shadow, 16–18 pt padding, full column width.
struct SettingsCard<Content: View>: View {
  var spacing: CGFloat = 12
  @ViewBuilder var content: () -> Content

  var body: some View {
    VStack(alignment: .leading, spacing: spacing) { content() }
      .padding(.horizontal, 18)
      .padding(.vertical, 16)
      .frame(maxWidth: .infinity, alignment: .leading)
      .cardBackground()
  }
}

/// A settings card's title row: a 26 pt gradient badge, a 14 pt bold title and optional controls.
struct SettingsCardHeader<Trailing: View>: View {
  let symbol: String
  let swatch: AppTheme.Swatch
  let title: String
  var subtitle: String? = nil
  @ViewBuilder var trailing: () -> Trailing

  var body: some View {
    HStack(alignment: .center, spacing: 10) {
      SwatchBadge(symbol: symbol, swatch: swatch, size: 26)
      VStack(alignment: .leading, spacing: 1) {
        Text(title)
          .font(.system(size: 14, weight: .bold))
          .tracking(-0.2)
          .foregroundStyle(AppTheme.ink)
          .accessibilityAddTraits(.isHeader)
        if let subtitle {
          Text(subtitle)
            .font(.system(size: 11.5))
            .foregroundStyle(AppTheme.ink3)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
      Spacer(minLength: 8)
      trailing()
    }
  }
}

extension SettingsCardHeader where Trailing == EmptyView {
  init(symbol: String, swatch: AppTheme.Swatch, title: String, subtitle: String? = nil) {
    self.symbol = symbol
    self.swatch = swatch
    self.title = title
    self.subtitle = subtitle
    self.trailing = { EmptyView() }
  }
}

/// A settings switch row: title and optional explanation on the left, a small switch on the right,
/// with a divider above. The switch keeps the title as its accessibility label.
struct SettingsToggleRow: View {
  let title: String
  var detail: String? = nil
  @Binding var isOn: Bool
  var divider = true
  @Environment(\.isEnabled) private var isEnabled

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      if divider { Rectangle().fill(AppTheme.divider).frame(height: 1) }
      HStack(alignment: .center, spacing: 12) {
        VStack(alignment: .leading, spacing: 2) {
          Text(title)
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(AppTheme.ink)
            .fixedSize(horizontal: false, vertical: true)
          if let detail {
            Text(detail)
              .font(.system(size: 11.5))
              .foregroundStyle(AppTheme.ink3)
              .fixedSize(horizontal: false, vertical: true)
          }
        }
        .opacity(isEnabled ? 1 : 0.5)
        .accessibilityHidden(true)
        Spacer(minLength: 8)
        Toggle(title, isOn: $isOn)
          .labelsHidden()
          .toggleStyle(.switch)
          .controlSize(.small)
          .accessibilityHint(detail ?? "")
      }
      .padding(.vertical, 9)
    }
  }
}

struct HelpersSettingsCard: View {
  @EnvironmentObject private var care: CareService
  @AppStorage(CareService.Keys.showMenuBar) private var showMenuBar = false
  @AppStorage(CareService.Keys.lowSpaceAlerts) private var lowSpaceAlerts = false
  @AppStorage(CareService.Keys.lowSpaceThresholdGB) private var thresholdGB = 20
  @AppStorage(CareService.Keys.scanReminders) private var scanReminders = false
  @AppStorage(CareService.Keys.scanOnLaunch) private var scanOnLaunch = true
  @State private var launchAtLogin = false
  @StateObject private var permissions = PermissionsService()

  var body: some View {
    SettingsCard(spacing: 0) {
      SettingsCardHeader(symbol: "bell.badge", swatch: .mint, title: "Helpers & reminders")
        .padding(.bottom, 8)
      SettingsToggleRow(
        title: "Run Quick Scan when MacMint opens",
        detail: "Overview, Cleanup, Apps and the other Quick Scan pages are ready when you look. It only reads; nothing is removed.",
        isOn: $scanOnLaunch)
      SettingsToggleRow(title: "Show MacMint in the menu bar", isOn: $showMenuBar)
      SettingsToggleRow(title: "Open MacMint at login", isOn: $launchAtLogin)
        .onChange(of: launchAtLogin) { _, enabled in
          if enabled != care.launchAtLoginRequested {
            care.setLaunchAtLogin(enabled)
            launchAtLogin = care.launchAtLoginRequested
          }
        }
      Group {
        if care.launchAtLoginNeedsApproval {
          VStack(alignment: .leading, spacing: 6) {
            warning("Login launch is waiting for your approval. Enable MacMint under Login Items in System Settings.")
            Button("Open Login Items") { care.openLoginItemsSettings() }
              .buttonStyle(MintButtonStyle(.secondary))
              .controlSize(.small)
          }
          .padding(.bottom, 10)
        }
        if let error = care.launchAtLoginError {
          warning(error).padding(.bottom, 10)
        }
      }
      lowSpaceRow
      SettingsToggleRow(title: "Remind me to scan if a week goes by", isOn: $scanReminders)
      VStack(alignment: .leading, spacing: 0) {
        Rectangle().fill(AppTheme.divider).frame(height: 1)
        Text(
          "Alerts are checked while MacMint or its menu bar item is running, at most once a day, and never between 10 pm and 8 am. Removal always needs your confirmation."
        )
        .font(.system(size: 11.5))
        .foregroundStyle(AppTheme.ink3)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.top, 10)
      }
      Group {
        if care.notificationsDenied {
          VStack(alignment: .leading, spacing: 6) {
            warning("Notifications are turned off for MacMint in System Settings → Notifications.")
            Button("Open Notification Settings") { permissions.open(.notifications) }
              .buttonStyle(MintButtonStyle(.secondary))
              .controlSize(.small)
          }
          .padding(.top, 10)
        }
        if let error = care.notificationError ?? permissions.settingsError {
          warning(error).padding(.top, 8)
        }
      }
    }
    .task { await care.refreshAuthorization(); launchAtLogin = care.launchAtLoginRequested }
    .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
      Task { await care.refreshAuthorization(); launchAtLogin = care.launchAtLoginRequested }
    }
    .onChange(of: lowSpaceAlerts) { _, enabled in if enabled { Task { await care.requestAuthorization() } } }
    .onChange(of: scanReminders) { _, enabled in if enabled { Task { await care.requestAuthorization() } } }
  }

  private var lowSpaceRow: some View {
    VStack(alignment: .leading, spacing: 0) {
      Rectangle().fill(AppTheme.divider).frame(height: 1)
      HStack(alignment: .center, spacing: 10) {
        Text("Alert me when free space drops below")
          .font(.system(size: 13, weight: .medium))
          .foregroundStyle(AppTheme.ink)
          .fixedSize(horizontal: false, vertical: true)
          .accessibilityHidden(true)
        Spacer(minLength: 8)
        Picker("Free space threshold", selection: $thresholdGB) {
          ForEach([10, 20, 50, 100], id: \.self) { Text("\($0) GB").tag($0) }
        }
        .labelsHidden()
        .frame(width: 90)
        .disabled(!lowSpaceAlerts)
        Toggle("Alert me when free space drops below", isOn: $lowSpaceAlerts)
          .labelsHidden()
          .toggleStyle(.switch)
          .controlSize(.small)
      }
      .padding(.vertical, 9)
    }
  }

  private func warning(_ text: String) -> some View {
    Label(text, systemImage: "exclamationmark.triangle.fill")
      .font(.system(size: 11.5))
      .foregroundStyle(AppTheme.warning)
      .fixedSize(horizontal: false, vertical: true)
  }
}
