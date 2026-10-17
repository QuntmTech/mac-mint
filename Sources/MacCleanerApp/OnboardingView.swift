import AppKit
import SwiftUI

/// First-run welcome: what MacMint does, Full Disk Access, and optional helpers.
struct OnboardingView: View {
  @EnvironmentObject private var model: AppViewModel
  @EnvironmentObject private var care: CareService
  @Environment(\.dismiss) private var dismiss
  @AppStorage(CareService.Keys.showMenuBar) private var showMenuBar = false
  @AppStorage(CareService.Keys.lowSpaceAlerts) private var lowSpaceAlerts = false
  @AppStorage(CareService.Keys.onboardingDone) private var onboardingDone = false
  @State private var step = 0
  @State private var hasFullDiskAccess = OnboardingView.checkFullDiskAccess()

  var body: some View {
    VStack(spacing: 0) {
      Group {
        switch step {
        case 0: welcome
        case 1: access
        default: helpers
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
      .padding(28)

      Divider()
      HStack {
        HStack(spacing: 6) {
          ForEach(0..<3) { index in
            Circle()
              .fill(index == step ? AppTheme.accent : Color.secondary.opacity(0.3))
              .frame(width: 7, height: 7)
          }
        }
        Spacer()
        if step > 0 {
          Button("Back") { step -= 1 }
        }
        Button(step == 2 ? "Run My First Scan" : "Continue") {
          if step < 2 {
            step += 1
          } else {
            finish()
          }
        }
        .buttonStyle(MintButtonStyle())
        .keyboardShortcut(.defaultAction)
      }
      .padding(16)
    }
    .frame(width: 600, height: 480)
    .background(AppTheme.canvas)
    .onExitCommand {
      onboardingDone = true
      dismiss()
    }
    .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
      hasFullDiskAccess = Self.checkFullDiskAccess()
    }
  }

  private var welcome: some View {
    VStack(alignment: .leading, spacing: 16) {
      BrandMark(size: 54)
      Text("Welcome to MacMint").font(.system(size: 27, weight: .semibold))
      point("checkmark.shield.fill", "Safe by design", "Only rebuildable caches are preselected. Personal files always need your review.")
      point("arrow.uturn.backward.circle.fill", "Review and restore", "File removals use Trash receipts. Restore while items remain there; Photos manages its own recovery.")
      point("lock.fill", "Private", "Scans run on your Mac. Optional AI sends category summaries and your typed questions after consent; preview the request first.")
    }
  }

  private var access: some View {
    VStack(alignment: .leading, spacing: 16) {
      Image(systemName: hasFullDiskAccess ? "checkmark.seal.fill" : "lock.open.fill")
        .font(.system(size: 40))
        .foregroundStyle(hasFullDiskAccess ? AppTheme.accentText : .orange)
      Text(hasFullDiskAccess ? "Full Disk Access is on" : "Allow Full Disk Access (recommended)")
        .font(.title2.bold())
      Text(
        "macOS protects some folders, such as Mail, Safari, and app containers. With Full Disk Access, MacMint can measure them accurately. Without it, those folders are listed as \"couldn't be read\" — nothing is skipped silently."
      )
      .foregroundStyle(.secondary)
      .fixedSize(horizontal: false, vertical: true)
      if !hasFullDiskAccess {
        Button {
          NSWorkspace.shared.open(
            URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!)
        } label: {
          Label("Open Privacy & Security", systemImage: "gear")
        }
        Text("Turn on MacMint in the list, then come back here.")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
  }

  private var helpers: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text("Optional helpers").font(.title2.bold())
      Toggle(isOn: $showMenuBar) {
        VStack(alignment: .leading, spacing: 2) {
          Text("Show MacMint in the menu bar")
          Text("Free space, memory pressure, and CPU at a glance.").font(.caption).foregroundStyle(.secondary)
        }
      }
      Toggle(isOn: $lowSpaceAlerts) {
        VStack(alignment: .leading, spacing: 2) {
          Text("Alert me when space runs low")
          Text("At most once a day, never at night.").font(.caption).foregroundStyle(.secondary)
        }
      }
      .onChange(of: lowSpaceAlerts) { _, enabled in
        if enabled { care.requestAuthorization() }
      }
      Text("You can change these any time in Settings.").font(.caption).foregroundStyle(.secondary)
    }
    .toggleStyle(.switch)
  }

  private func point(_ icon: String, _ title: String, _ detail: String) -> some View {
    HStack(alignment: .top, spacing: 12) {
      Image(systemName: icon).font(.title3).foregroundStyle(AppTheme.accentText).frame(width: 26)
      VStack(alignment: .leading, spacing: 2) {
        Text(title).font(.headline)
        Text(detail).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
      }
    }
  }

  private func finish() {
    onboardingDone = true
    dismiss()
    model.selectedSection = .dashboard
    model.runSmartScan()
  }

  /// A protected folder is readable only with Full Disk Access.
  static func checkFullDiskAccess() -> Bool {
    let probe = FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent("Library/Containers/com.apple.stocks")
    let safari = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Safari")
    return [probe, safari].contains { url in
      FileManager.default.fileExists(atPath: url.path)
        && (try? FileManager.default.contentsOfDirectory(atPath: url.path)) != nil
    }
  }
}
