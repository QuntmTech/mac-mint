import SwiftUI

struct SettingsView: View {
  @EnvironmentObject private var model: AppViewModel
  @State private var confirmClear = false

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 18) {
        PageHeader("Settings", subtitle: "Your workspace, your preferences. Safety and privacy stay in your control.")
        AppearanceSettingsCard()

        AccountSettingsCard()

        AISettingsCard()

        HelpersSettingsCard()

        AboutSettingsCard()

        SurfaceCard {
          VStack(alignment: .leading, spacing: 12) {
            Label("Safety model", systemImage: "checkmark.shield.fill")
              .font(.headline)
              .foregroundStyle(.green)
            settingRow("Deletion mode", value: "Trash-first")
            settingRow("Automatic personal-file cleanup", value: "Blocked")
            settingRow("System-owned cleanup", value: "Read-only")
            Divider()
            Text(
              "Automatic cleanup never targets Documents, Desktop, Pictures, Movies, or Music. Generic Large Files and Duplicates review also excludes ~/Library and system-owned paths."
            )
            .font(.callout)
            .foregroundStyle(.secondary)
          }
        }

        SurfaceCard {
          VStack(alignment: .leading, spacing: 12) {
            HStack {
              Label("Scan exclusions", systemImage: "hand.raised.fill")
                .font(.headline)
              Spacer()
              if !model.ignoredPaths.isEmpty || model.exclusionLoadError != nil {
                Button("Clear all", role: .destructive) { confirmClear = true }
                  .controlSize(.small)
              }
            }
            Text(
              "Excluded folders are skipped by cleanup, storage, developer, photo, large-file, duplicate, and app-leftover scans."
            )
            .font(.caption)
            .foregroundStyle(.secondary)

            if let error = model.exclusionLoadError {
              Text(error).foregroundStyle(AppTheme.warning)
              Button("Show Exclusion Files") { model.reveal(AppPaths.supportDirectory) }
            } else if model.ignoredPaths.isEmpty {
              Text("No exclusions saved.")
                .foregroundStyle(.secondary)
                .padding(.vertical, 8)
            } else {
              ForEach(model.ignoredPaths.sorted(), id: \.self) { path in
                HStack(spacing: 10) {
                  Image(systemName: "folder.badge.minus")
                    .foregroundStyle(AppTheme.accentText)
                  Text(path)
                    .font(.caption)
                    .lineLimit(1)
                    .textSelection(.enabled)
                  Spacer()
                  Button {
                    model.removeIgnore(path: path)
                  } label: {
                    Image(systemName: "xmark.circle.fill")
                      .accessibilityLabel("Remove exclusion")
                  }
                  .buttonStyle(.plain)
                  .foregroundStyle(.secondary)
                }
                if path != model.ignoredPaths.sorted().last { Divider() }
              }
            }
          }
        }

        SurfaceCard {
          VStack(alignment: .leading, spacing: 12) {
            Label("Permissions", systemImage: "lock.shield")
              .font(.headline)
            Text(
              "macOS may deny access to protected Library locations. The scanner records access problems and continues; it never tries to bypass system privacy controls."
            )
            .font(.callout)
            .foregroundStyle(.secondary)
            Button("Open System Settings") { model.openSystemSettings() }
          }
        }

        SurfaceCard {
          VStack(alignment: .leading, spacing: 12) {
            Label("Privacy", systemImage: "hand.raised.square")
              .font(.headline)
            settingRow("Telemetry", value: "None")
            settingRow("Network calls", value: model.aiEnabled ? "Account, releases, optional app updates & AI" : "Account, release and optional app-update checks")
            settingRow("File contents uploaded", value: "Never")
            settingRow("AI summaries", value: model.aiEnabled ? "Categories, only when requested" : "Off")
            settingRow("Cleanup history", value: "Local JSON")
            settingRow("Exclusions", value: "Local JSON")
          }
        }
      }
      .padding(AppTheme.pagePadding)
      .frame(maxWidth: 900, alignment: .leading)
    }
    .alert("Clear all scan exclusions?", isPresented: $confirmClear) {
      Button("Cancel", role: .cancel) {}
      Button("Clear Exclusions", role: .destructive) { model.clearIgnores() }
    }
  }

  private func settingRow(_ title: String, value: String) -> some View {
    HStack {
      Text(title)
      Spacer()
      Text(value).foregroundStyle(.secondary)
    }
    .font(.callout)
  }
}

struct HelpersSettingsCard: View {
  @EnvironmentObject private var care: CareService
  @AppStorage(CareService.Keys.showMenuBar) private var showMenuBar = false
  @AppStorage(CareService.Keys.lowSpaceAlerts) private var lowSpaceAlerts = false
  @AppStorage(CareService.Keys.lowSpaceThresholdGB) private var thresholdGB = 20
  @AppStorage(CareService.Keys.scanReminders) private var scanReminders = false
  @State private var launchAtLogin = false

  var body: some View {
    SurfaceCard {
      VStack(alignment: .leading, spacing: 12) {
        Label("Helpers & reminders", systemImage: "bell.badge").font(.headline)
        Toggle("Show MacMint in the menu bar", isOn: $showMenuBar)
        Toggle("Open MacMint at login", isOn: $launchAtLogin)
          .onChange(of: launchAtLogin) { _, enabled in
            if enabled != care.launchesAtLogin { care.setLaunchAtLogin(enabled) }
          }
        if let error = care.launchAtLoginError {
          Text(error).font(.caption).foregroundStyle(AppTheme.warning)
        }
        Divider()
        HStack {
          Toggle("Alert me when free space drops below", isOn: $lowSpaceAlerts)
          Picker("", selection: $thresholdGB) {
            ForEach([10, 20, 50, 100], id: \.self) { Text("\($0) GB").tag($0) }
          }
          .labelsHidden()
          .frame(width: 90)
          .disabled(!lowSpaceAlerts)
        }
        Toggle("Remind me to scan if a week goes by", isOn: $scanReminders)
        Text(
          "Alerts are checked while MacMint or its menu bar item is running, at most once a day, and never between 10 pm and 8 am. Removal always needs your confirmation."
        )
        .font(.caption)
        .foregroundStyle(.secondary)
        if care.notificationsDenied {
          Text("Notifications are turned off for MacMint in System Settings → Notifications.")
            .font(.caption)
            .foregroundStyle(AppTheme.warning)
        }
      }
      .toggleStyle(.switch)
    }
    .onAppear { launchAtLogin = care.launchesAtLogin }
    .onChange(of: lowSpaceAlerts) { _, enabled in if enabled { care.requestAuthorization() } }
    .onChange(of: scanReminders) { _, enabled in if enabled { care.requestAuthorization() } }
  }
}

struct AboutSettingsCard: View {
  @EnvironmentObject private var updates: UpdateService
  @State private var checking = false

  var body: some View {
    SurfaceCard {
      VStack(alignment: .leading, spacing: 10) {
        HStack {
          Label("About MacMint", systemImage: "info.circle").font(.headline)
          Spacer()
          Text("Version \(UpdateService.currentVersion)").foregroundStyle(.secondary)
        }
        HStack {
          if let error = updates.checkError {
            Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(AppTheme.warning)
          } else if updates.lastChecked == nil {
            Text("Not checked").foregroundStyle(.secondary)
          } else { switch updates.status {
          case .current:
            Label("You're up to date", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
          case .available(let release):
            Label("Version \(release.version) is available", systemImage: "arrow.down.circle.fill")
              .foregroundStyle(AppTheme.accentText)
            Button("Download") { updates.openDownload(release) }.controlSize(.small)
          case .required(let release, let minimum):
            Label("Update required (minimum \(minimum))", systemImage: "exclamationmark.triangle.fill")
              .foregroundStyle(AppTheme.warning)
            Button("Download") { updates.openDownload(release) }.controlSize(.small)
          }
          }
          Spacer()
          Button(checking ? "Checking…" : "Check Now") {
            checking = true
            Task {
              await updates.check()
              checking = false
            }
          }
          .disabled(checking)
        }
        .font(.callout)
        if let date = updates.lastChecked {
          Text("Last checked \(date.formatted(.relative(presentation: .named)))")
            .font(.caption)
            .foregroundStyle(.tertiary)
        }
      }
    }
  }
}
