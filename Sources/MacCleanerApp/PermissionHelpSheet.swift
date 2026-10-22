import AppKit
import SwiftUI

struct PermissionHelpSheet: View {
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    VStack(spacing: 0) {
      SheetHeader(symbol: "lock.shield.fill", swatch: .sky, eyebrow: "Access help", title: "Access & setup",
        subtitle: "Permissions can affect coverage. Missing files, exclusions, cloud-only items and other errors can also explain a scan issue. Check its details before changing access, then rescan when you are ready.")
      Rectangle().fill(AppTheme.divider).frame(height: 1)
      ScrollView {
        VStack(alignment: .leading, spacing: 16) {
          stepsCard
          PermissionsSettingsCard()
        }
        .padding(20)
      }
      SheetFooter {
        Label("Changing access does not remove any files.", systemImage: "checkmark.shield.fill")
          .font(.system(size: 11.5))
          .foregroundStyle(AppTheme.ink2)
        Spacer()
        Button("Done") { dismiss() }
          .buttonStyle(MintButtonStyle(.commit))
          .keyboardShortcut(.defaultAction)
      }
    }
    .frame(width: 680, height: 620)
    .background(AppTheme.canvas)
    .onExitCommand { dismiss() }
  }

  // MARK: Steps

  private var stepsCard: some View {
    VStack(alignment: .leading, spacing: 14) {
      Text("Turn on Full Disk Access")
        .font(.system(size: 15, weight: .bold))
        .tracking(-0.2)
        .foregroundStyle(AppTheme.ink)
        .accessibilityAddTraits(.isHeader)
      step(1, title: "Open System Settings",
        detail: "Go to Privacy & Security, then Full Disk Access. The button below opens it for you.")
      VStack(alignment: .leading, spacing: 10) {
        step(2, title: "Turn on MacMint",
          detail: "Use the copy in Applications. If it is missing, click + and choose it.")
        mockSettingsRow.padding(.leading, 36)
      }
      step(3, title: "Reopen and scan again",
        detail: "Quit and reopen MacMint if macOS asks. Then run your scan again.")
    }
    .padding(18)
    .frame(maxWidth: .infinity, alignment: .leading)
    .cardBackground()
  }

  private func step(_ number: Int, title: String, detail: String) -> some View {
    HStack(alignment: .top, spacing: 12) {
      Text("\(number)")
        .font(AppTheme.number(13, weight: .bold))
        .foregroundStyle(.white)
        .frame(width: 24, height: 24)
        .background(AppTheme.Swatch.sky.gradient, in: Circle())
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 2) {
        Text(title)
          .font(.system(size: 13, weight: .semibold))
          .foregroundStyle(AppTheme.ink)
        Text(detail)
          .font(.system(size: 12))
          .foregroundStyle(AppTheme.ink2)
          .fixedSize(horizontal: false, vertical: true)
      }
      .padding(.top, 2)
    }
    .accessibilityElement(children: .combine)
    .accessibilityLabel("Step \(number). \(title). \(detail)")
  }

  /// A picture of the System Settings row people look for. It is not a real control.
  private var mockSettingsRow: some View {
    VStack(alignment: .leading, spacing: 0) {
      Text("Full Disk Access")
        .font(.system(size: 11, weight: .semibold))
        .foregroundStyle(AppTheme.ink2)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
      Rectangle().fill(AppTheme.divider).frame(height: 1)
      HStack(spacing: 10) {
        Image(nsImage: NSApplication.shared.applicationIconImage)
          .resizable()
          .interpolation(.high)
          .frame(width: 22, height: 22)
        Text("MacMint")
          .font(.system(size: 13))
          .foregroundStyle(AppTheme.ink)
        Spacer(minLength: 12)
        Capsule()
          .fill(AppTheme.accent)
          .frame(width: 34, height: 20)
          .overlay(alignment: .trailing) {
            Circle()
              .fill(Color.white)
              .frame(width: 16, height: 16)
              .shadow(color: .black.opacity(0.25), radius: 1, y: 1)
              .padding(2)
          }
      }
      .padding(.horizontal, 12)
      .padding(.vertical, 8)
    }
    .frame(maxWidth: 380, alignment: .leading)
    .background(AppTheme.panel, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(AppTheme.border))
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("Example: MacMint switched on in the Full Disk Access list")
  }
}
