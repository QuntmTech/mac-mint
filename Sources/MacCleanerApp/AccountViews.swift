import AppKit
import MacCleanerCore
import SwiftUI

/// Local inspection and recovery stay available independently of paid access.
struct AccountGateView: View {
  @EnvironmentObject private var account: AccountStore
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    RootView()

    .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: account.phase)
  }
}

struct BrandMark: View {
  var size: CGFloat = 38

  /// The bundled app icon, when running as MacMint.app (not via `swift run`).
  @MainActor private static let appIcon: NSImage? =
    Bundle.main.bundleURL.pathExtension == "app" ? NSApplication.shared.applicationIconImage : nil

  var body: some View {
    if let icon = Self.appIcon {
      Image(nsImage: icon)
        .resizable()
        .interpolation(.high)
        .frame(width: size * 1.24, height: size * 1.24)
        .padding(-size * 0.12)
        .accessibilityHidden(true)
    } else {
      drawnMark
    }
  }

  private var drawnMark: some View {
    ZStack {
      RoundedRectangle(cornerRadius: size * 0.29, style: .continuous)
        .fill(
          LinearGradient(
            colors: [AppTheme.brand, AppTheme.accent],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
          )
        )
        .frame(width: size, height: size)
      Image(systemName: "leaf.fill")
        .font(.system(size: size * 0.45, weight: .bold))
        .foregroundStyle(.white)
    }
    .accessibilityHidden(true)
  }
}

/// The form side of the split account sheet: the panel, then any account message.
private struct GateScaffold<Content: View>: View {
  @ViewBuilder let content: Content

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 16) {
        content
        GateMessages()
      }
      .padding(.horizontal, 24).padding(.top, 20).padding(.bottom, 24)
      .frame(maxWidth: .infinity, alignment: .topLeading)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}

/// The brand side of the split account sheet: what Pro adds, and what always stays free.
private struct AccountBrandPanel: View {
  let purpose: AccountSheetPurpose

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack(spacing: 10) {
        BrandMark(size: 32).frame(width: 32, height: 32)
        VStack(alignment: .leading, spacing: 1) {
          Text("MacMint").font(.system(size: 15, weight: .bold)).tracking(-0.3)
          Text("Pro").font(.system(size: 11, weight: .semibold)).foregroundStyle(Color.white.opacity(0.8))
        }
      }
      .accessibilityElement(children: .combine)
      .padding(.bottom, 22)

      Text(purpose == .paidAction ? "This step needs Pro" : "What Pro unlocks")
        .font(.system(size: 17, weight: .bold)).tracking(-0.3)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.bottom, 12)
      VStack(alignment: .leading, spacing: 10) {
        perk("trash.fill", "Move reviewed items to the Trash")
        perk("square.grid.2x2.fill", "Uninstall apps with their leftovers")
        perk("folder.fill", "Sort your Downloads into folders")
      }

      Spacer(minLength: 16)

      VStack(alignment: .leading, spacing: 8) {
        Eyebrow("Always free", color: Color.white.opacity(0.8))
        perk("magnifyingglass", "Scanning and exploring")
        perk("clock.arrow.circlepath", "History and Restore")
      }
      .padding(12)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(Color.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
      .accessibilityElement(children: .combine)
    }
    .foregroundStyle(.white)
    .padding(.horizontal, 18).padding(.top, 22).padding(.bottom, 18)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .background { panelBackground }
  }

  private var panelBackground: some View {
    ZStack {
      AppTheme.heroGradient
      Image(systemName: "leaf.fill").font(.system(size: 150)).foregroundStyle(Color.white.opacity(0.06))
        .rotationEffect(.degrees(-18)).offset(x: 54, y: 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
    }
    .clipped()
    .accessibilityHidden(true)
  }

  private func perk(_ symbol: String, _ title: String) -> some View {
    HStack(alignment: .top, spacing: 9) {
      Image(systemName: symbol).font(.system(size: 10.5, weight: .semibold))
        .frame(width: 22, height: 22)
        .background(Color.white.opacity(0.18), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .accessibilityHidden(true)
      Text(title).font(.system(size: 12.5, weight: .medium))
        .fixedSize(horizontal: false, vertical: true)
        .padding(.top, 3)
    }
  }
}

/// A form panel's title: a small badge and a bold line.
private struct PanelHeading: View {
  let symbol: String
  var swatch: AppTheme.Swatch = .violet
  let title: String

  var body: some View {
    HStack(alignment: .center, spacing: 10) {
      SwatchBadge(symbol: symbol, swatch: swatch, size: 30)
      Text(title).font(.system(size: 17, weight: .bold)).tracking(-0.3).foregroundStyle(AppTheme.ink)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityAddTraits(.isHeader)
    }
  }
}

/// Text fields on the account forms: surface fill, hairline border, mint ring while focused.
private struct FieldChrome: ViewModifier {
  let active: Bool
  @Environment(\.colorSchemeContrast) private var contrast

  func body(content: Content) -> some View {
    let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
    return content
      .textFieldStyle(.plain)
      .font(.system(size: 13))
      .padding(.horizontal, 10)
      .frame(height: 32)
      .background(AppTheme.surface, in: shape)
      .overlay(shape.strokeBorder(borderColor, lineWidth: active ? 2 : 1))
  }

  private var borderColor: Color {
    if active { return AppTheme.accentText }
    return contrast == .increased ? AppTheme.ink.opacity(0.6) : AppTheme.borderStrong
  }
}

private struct GateMessages: View {
  @EnvironmentObject private var account: AccountStore

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      if let error = account.errorMessage {
        message(error, symbol: "exclamationmark.triangle.fill", color: AppTheme.warning, tint: AppTheme.warningTint)
      }
      if let info = account.infoMessage {
        message(info, symbol: "checkmark.circle.fill", color: AppTheme.accentText, tint: AppTheme.successTint)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private func message(_ text: String, symbol: String, color: Color, tint: Color) -> some View {
    Label(text, systemImage: symbol)
      .font(.system(size: 12.5))
      .foregroundStyle(color)
      .fixedSize(horizontal: false, vertical: true)
      .padding(.horizontal, 12).padding(.vertical, 10)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(tint, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
  }
}

private struct AuthForm: View {
  @EnvironmentObject private var account: AccountStore
  @State private var isCreating = false
  @State private var name = ""
  @State private var email = ""
  @State private var password = ""
  @FocusState private var focused: Field?

  enum Field { case name, email, password }

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      VStack(alignment: .leading, spacing: 4) {
        Text(isCreating ? "Create your account" : "Sign in")
          .font(.system(size: 19, weight: .bold)).tracking(-0.3).foregroundStyle(AppTheme.ink)
          .accessibilityAddTraits(.isHeader)
        Text(
          isCreating
            ? "Create an account to connect a purchase or redeem a code. Local inspection stays available."
            : "Sign in with the same account you use on the MacMint website."
        )
        .font(.system(size: 12.5))
        .foregroundStyle(AppTheme.ink2)
        .fixedSize(horizontal: false, vertical: true)
      }

      VStack(alignment: .leading, spacing: 10) {
        if isCreating {
          TextField("Name", text: $name)
            .textContentType(.name)
            .focused($focused, equals: .name)
            .modifier(FieldChrome(active: focused == .name))
        }
        TextField("Email", text: $email)
          .textContentType(.username)
          .focused($focused, equals: .email)
          .modifier(FieldChrome(active: focused == .email))
        SecureField("Password", text: $password)
          .textContentType(isCreating ? .newPassword : .password)
          .focused($focused, equals: .password)
          .onSubmit(submit)
          .modifier(FieldChrome(active: focused == .password))
      }

      Button(action: submit) {
        HStack {
          if account.isBusy { ProgressView().controlSize(.small) }
          Text(isCreating ? "Create Account" : "Sign In").frame(maxWidth: .infinity)
        }
      }
      .buttonStyle(MintButtonStyle(.commit))
      .keyboardShortcut(.defaultAction)
      .disabled(account.isBusy || email.isEmpty || password.isEmpty)

      HStack {
        Button(isCreating ? "I already have an account" : "Create an account") {
          isCreating.toggle()
          account.errorMessage = nil
        }
        Spacer()
        if !isCreating {
          Button("Forgot password?") {
            Task { await account.requestPasswordReset(email: email) }
          }
          .disabled(account.isBusy)
        }
      }
      .buttonStyle(MintButtonStyle(.plain))
      .padding(.horizontal, -6)
    }
    .onAppear { focused = .email }
  }

  private func submit() {
    guard !account.isBusy, !email.isEmpty, !password.isEmpty else { return }
    Task {
      if isCreating {
        await account.signUp(name: name, email: email, password: password)
      } else {
        await account.signIn(email: email, password: password)
      }
    }
  }
}

private struct RedeemForm: View {
  @EnvironmentObject private var account: AccountStore
  @State private var code = ""

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      VStack(alignment: .leading, spacing: 4) {
        Text("Unlock MacMint").font(.system(size: 19, weight: .bold)).tracking(-0.3).foregroundStyle(AppTheme.ink)
          .accessibilityAddTraits(.isHeader)
        if let email = account.snapshot?.user.email {
          Text("Signed in as \(email)").font(.system(size: 12.5)).foregroundStyle(AppTheme.ink2)
            .lineLimit(1).truncationMode(.middle)
        }
      }
      Text("Bought MacMint on the website? Check your purchase to activate this Mac, or enter a redemption code below.")
        .font(.system(size: 12.5)).foregroundStyle(AppTheme.ink)
        .fixedSize(horizontal: false, vertical: true)
      Button {
        Task { await account.checkPurchase() }
      } label: {
        Label("Check My Purchase", systemImage: "arrow.clockwise")
          .frame(maxWidth: .infinity)
      }
      .buttonStyle(MintButtonStyle(.commit))
      .disabled(account.isBusy)

      HStack(spacing: 8) {
        Rectangle().fill(AppTheme.divider).frame(height: 1)
        Text("or use a code").font(.system(size: 11)).foregroundStyle(AppTheme.ink3).fixedSize()
        Rectangle().fill(AppTheme.divider).frame(height: 1)
      }
      .accessibilityHidden(true)

      TextField("MINT-XXXX-XXXX-XXXX-XXXX", text: $code)
        .font(.system(size: 13, design: .monospaced))
        .onSubmit(submit)
        .modifier(FieldChrome(active: false))

      Button(action: submit) {
        HStack {
          if account.isBusy { ProgressView().controlSize(.small) }
          Text("Redeem Code").frame(maxWidth: .infinity)
        }
      }
      .buttonStyle(MintButtonStyle(.secondary))
      .keyboardShortcut(.defaultAction)
      .disabled(account.isBusy || code.isEmpty)

      Rectangle().fill(AppTheme.divider).frame(height: 1)
      HStack {
        Button("Buy MacMint") { account.openPurchasePage() }
        Spacer()
        Button("Sign Out") { Task { await account.signOut() } }
      }
      .buttonStyle(MintButtonStyle(.plain))
      .padding(.horizontal, -6)
    }
  }

  private func submit() {
    guard !account.isBusy, !code.isEmpty else { return }
    Task { await account.redeem(code: code) }
  }
}

private struct DeviceLimitPanel: View {
  @EnvironmentObject private var account: AccountStore
  let message: String
  let devices: [RegisteredDevice]

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      PanelHeading(symbol: "laptopcomputer", swatch: .amber, title: "Device limit reached")
      Text(message).font(.system(size: 12.5)).foregroundStyle(AppTheme.ink2)
        .fixedSize(horizontal: false, vertical: true)

      VStack(spacing: 0) {
        ForEach(devices) { device in
          HStack(spacing: 10) {
            SwatchBadge(symbol: "laptopcomputer", swatch: .slate, size: 26)
            VStack(alignment: .leading, spacing: 2) {
              Text(device.name).font(.system(size: 13, weight: .semibold)).foregroundStyle(AppTheme.ink)
                .lineLimit(1)
              Text(detail(for: device)).font(.system(size: 11.5)).foregroundStyle(AppTheme.ink2)
                .lineLimit(1)
            }
            .accessibilityElement(children: .combine)
            Spacer(minLength: 8)
            Button("Remove") { Task { await account.removeDevice(device) } }
              .buttonStyle(MintButtonStyle(.secondary))
              .controlSize(.small)
              .disabled(account.isBusy)
          }
          .padding(.horizontal, 12)
          .frame(minHeight: 48)
          if device.id != devices.last?.id {
            Rectangle().fill(AppTheme.divider).frame(height: 1).padding(.leading, 48)
          }
        }
      }
      .cardBackground(radius: 12)

      HStack {
        Button("Try Again") { Task { await account.retry() } }
          .buttonStyle(MintButtonStyle(.secondary))
        Spacer()
        Button("Sign Out") { Task { await account.signOut() } }
          .buttonStyle(MintButtonStyle(.plain))
      }
    }
  }

  private func detail(for device: RegisteredDevice) -> String {
    var parts: [String] = []
    if let model = device.model, !model.isEmpty { parts.append(model) }
    if let seen = device.lastSeenDate {
      parts.append("last used " + seen.formatted(.relative(presentation: .named)))
    }
    return parts.joined(separator: " • ")
  }
}

private struct DeviceRemovedPanel: View {
  @EnvironmentObject private var account: AccountStore

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      PanelHeading(symbol: "laptopcomputer.slash", swatch: .amber, title: "This Mac was removed from your account")
      Text("MacMint won’t add it back on its own. Activate this Mac to use your plan here again; it takes one of your device slots.")
        .font(.system(size: 12.5)).foregroundStyle(AppTheme.ink2).fixedSize(horizontal: false, vertical: true)
      Button {
        Task { await account.activateThisMac() }
      } label: {
        HStack {
          if account.isBusy { ProgressView().controlSize(.small) }
          Text("Activate this Mac").frame(maxWidth: .infinity)
        }
      }
      .buttonStyle(MintButtonStyle(.commit))
      .disabled(account.isBusy)
      HStack {
        Button("Manage Devices…") { account.openAccountPage() }
        Spacer()
        Button("Sign Out") { Task { await account.signOut() } }
      }
      .buttonStyle(MintButtonStyle(.plain))
      .padding(.horizontal, -6)
    }
  }
}

private struct AccessLapsedPanel: View {
  @EnvironmentObject private var account: AccountStore

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      PanelHeading(symbol: "clock.badge.exclamationmark", swatch: .amber, title: "MacMint Pro needs to be checked again")
      Text(account.isOffline
        ? "This Mac has been offline longer than MacMint Pro allows without a check, or your access period ended. Connect to the internet and check again."
        : "Your access period may have ended. Check again to confirm your plan for this Mac.")
        .font(.system(size: 12.5)).foregroundStyle(AppTheme.ink2).fixedSize(horizontal: false, vertical: true)
      Button {
        Task { await account.retry() }
      } label: {
        HStack {
          if account.isBusy || account.phase == .checking { ProgressView().controlSize(.small) }
          Text("Check Again").frame(maxWidth: .infinity)
        }
      }
      .buttonStyle(MintButtonStyle(.commit))
      .disabled(account.isBusy)
      HStack {
        Button("Buy MacMint") { account.openPurchasePage() }
        Spacer()
        Button("Sign Out") { Task { await account.signOut() } }
      }
      .buttonStyle(MintButtonStyle(.plain))
      .padding(.horizontal, -6)
    }
  }
}

private struct FailurePanel: View {
  @EnvironmentObject private var account: AccountStore
  let message: String

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      PanelHeading(symbol: "wifi.exclamationmark", swatch: .amber, title: "Couldn't verify your account")
      Text(message).font(.system(size: 12.5)).foregroundStyle(AppTheme.ink2)
        .fixedSize(horizontal: false, vertical: true)
      HStack {
        Button("Try Again") { Task { await account.retry() } }
          .buttonStyle(MintButtonStyle(.commit))
          .disabled(account.isBusy)
        Spacer()
        Button("Sign Out") { Task { await account.signOut() } }
          .buttonStyle(MintButtonStyle(.plain))
      }
    }
  }
}

/// Compact account summary used in Settings.
struct AccountSettingsCard: View {
  @EnvironmentObject private var account: AccountStore
  @EnvironmentObject private var model: AppViewModel
  @State private var confirmSignOut = false

  var body: some View {
    SurfaceCard {
      VStack(alignment: .leading, spacing: 12) {
        HStack(spacing: 10) {
          SwatchBadge(symbol: "person.crop.circle.fill", swatch: .violet, size: 26)
          Text("Account").font(.system(size: 15, weight: .bold)).tracking(-0.2).foregroundStyle(AppTheme.ink)
            .accessibilityAddTraits(.isHeader)
          Spacer()
          if account.isOffline {
            StatusPill(title: "Offline", icon: "wifi.slash", tint: AppTheme.warning)
          }
        }
        if let snapshot = account.snapshot {
          VStack(spacing: 8) {
            row("Email", snapshot.user.email)
            row("Access", account.isUnlocked ? snapshot.entitlement.planDescription : "Verification required")
            row(
              "Devices",
              "\(snapshot.devices.count) of \(max(snapshot.entitlement.maxDevices, 1)) in use")
            row("This Mac", account.deviceInfo.name)
          }
        }
        if account.snapshot == nil {
          Text("You’re inspecting locally. Scan, explore, and use History without signing in. Connect your account when you’re ready to start a paid operation.")
            .font(.system(size: 12.5)).foregroundStyle(AppTheme.ink2).fixedSize(horizontal: false, vertical: true)
        }
        Rectangle().fill(AppTheme.divider).frame(height: 1)
        HStack {
          if account.snapshot != nil {
            Button("Manage Account…") { account.openAccountPage() }.buttonStyle(MintButtonStyle(.secondary))
            Spacer()
            Button(role: .destructive) { confirmSignOut = true } label: {
              Text("Sign Out").foregroundStyle(AppTheme.danger)
            }
            .buttonStyle(MintButtonStyle(.plain))
          } else {
            Label("Local inspection", systemImage: "desktopcomputer").font(.system(size: 11.5)).foregroundStyle(AppTheme.ink3)
            Spacer()
            Button("Connect account") { model.openAccount() }.buttonStyle(MintButtonStyle(prominent: false))
          }
        }
      }
    }
    .alert("Sign out of MacMint?", isPresented: $confirmSignOut) {
      Button("Cancel", role: .cancel) {}
      Button("Sign Out", role: .destructive) { Task { await account.signOut() } }
    } message: {
      Text("Sign out on this Mac. Your cleanup history and exclusions stay available here.")
    }
  }

  private func row(_ title: String, _ value: String) -> some View {
    HStack {
      Text(title).foregroundStyle(AppTheme.ink)
      Spacer()
      Text(value).foregroundStyle(AppTheme.ink2).textSelection(.enabled)
    }
    .font(.system(size: 12.5))
  }

}

extension Entitlement {
  /// The plan as people read it: trial end, access end, lifetime or no active plan.
  var planDescription: String {
    guard active else { return "No active plan" }
    if let expiry = expiryDate {
      if source == "subscription_trial" { return "Trial ends \(expiry.formatted(date: .abbreviated, time: .omitted))" }
      return "Pro • Access until \(expiry.formatted(date: .abbreviated, time: .omitted))"
    }
    return isLifetime ? "Pro • Lifetime" : "Refresh account to verify expiry"
  }
}

/// Why the account sheet is open. The profile button and "Connect account" show the
/// account itself; a paid action that needs access shows the gate and, once access is
/// confirmed, can return to its review. Opening or closing the account never resumes one.
enum AccountSheetPurpose: Equatable, Sendable { case account, paidAction }

/// The signed-in account: plan, devices and this Mac, with the actions MacMint supports.
/// Takes display values only, so fixtures can render it without an account.
struct AccountOverviewPanel: View {
  struct Details: Equatable {
    var email: String
    var plan: String
    var planActive: Bool
    var devices: String
    var thisMac: String
    var offline: Bool
  }
  let details: Details
  var busy = false
  let refresh: () -> Void
  let manage: () -> Void
  let signOut: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      HStack(spacing: 14) {
        SwatchBadge(symbol: "person.crop.circle.fill", swatch: .violet, size: 44, glow: true)
        VStack(alignment: .leading, spacing: 5) {
          Text(details.email).font(.system(size: 17, weight: .bold)).tracking(-0.3).foregroundStyle(AppTheme.ink)
            .lineLimit(1).truncationMode(.middle)
            .textSelection(.enabled)
          Chip(title: details.plan,
            symbol: details.planActive ? "checkmark.seal.fill" : "exclamationmark.circle.fill",
            swatch: details.planActive ? .mint : .amber)
        }
        Spacer(minLength: 0)
      }
      VStack(spacing: 0) {
        row("laptopcomputer.and.iphone", "Devices", details.devices)
        Rectangle().fill(AppTheme.divider).frame(height: 1).padding(.leading, 42)
        row("laptopcomputer", "This Mac", details.thisMac)
        Rectangle().fill(AppTheme.divider).frame(height: 1).padding(.leading, 42)
        row(details.offline ? "wifi.slash" : "wifi", "Connection", details.offline ? "Offline · using saved access" : "Online")
      }
      .cardBackground(radius: 14)
      Text("Billing, receipts and the devices on your plan are managed on your account page.")
        .font(.system(size: 11.5)).foregroundStyle(AppTheme.ink3).fixedSize(horizontal: false, vertical: true)
      HStack(spacing: 8) {
        Button("Manage Account…", action: manage).buttonStyle(MintButtonStyle(.secondary))
        Button("Refresh", action: refresh).buttonStyle(MintButtonStyle(.secondary)).disabled(busy)
        Spacer()
        Button(role: .destructive, action: signOut) {
          Text("Sign Out").foregroundStyle(AppTheme.danger)
        }
        .buttonStyle(MintButtonStyle(.plain))
      }
    }
  }

  private func row(_ symbol: String, _ title: String, _ value: String) -> some View {
    HStack(spacing: 10) {
      Image(systemName: symbol).font(.system(size: 12, weight: .semibold)).foregroundStyle(AppTheme.ink3)
        .frame(width: 18)
        .accessibilityHidden(true)
      Text(title).font(.system(size: 13)).foregroundStyle(AppTheme.ink)
      Spacer(minLength: 12)
      Text(value).font(.system(size: 13, weight: .medium)).monospacedDigit().foregroundStyle(AppTheme.ink2)
        .lineLimit(1).truncationMode(.middle)
        .textSelection(.enabled)
    }
    .padding(.horizontal, 14)
    .frame(minHeight: 40)
    .accessibilityElement(children: .combine)
  }
}

/// Account access is a recoverable sheet, never a gate around local scans or History.
struct AccountAccessSheet: View {
  var purpose: AccountSheetPurpose = .account
  /// A paid action is waiting for access; RootView resumes its review when the sheet closes.
  var hasDeferredPlan = false
  @EnvironmentObject private var account: AccountStore
  @Environment(\.dismiss) private var dismiss
  @State private var confirmSignOut = false

  var body: some View {
    HStack(spacing: 0) {
      // Sign-in and plan panels are a split sheet: what Pro unlocks beside the form.
      if usesScaffold { AccountBrandPanel(purpose: purpose).frame(width: 206) }
      VStack(spacing: 0) {
        header
        Rectangle().fill(AppTheme.divider).frame(height: 1)
        content
        SheetFooter {
          Spacer(minLength: 8)
          Button(closeTitle) { dismiss() }
            .buttonStyle(MintButtonStyle(.secondary))
            .keyboardShortcut(.cancelAction)
        }
      }
      .frame(maxWidth: .infinity)
    }
    .frame(width: 560, height: usesScaffold ? 560 : nil)
    .background(AppTheme.elevated)
    // A waiting action continues once access is confirmed; the account itself stays open.
    .onChange(of: account.isUnlocked) { _, unlocked in if unlocked, purpose == .paidAction { dismiss() } }
    .onExitCommand { dismiss() }
    .alert("Sign out of MacMint?", isPresented: $confirmSignOut) {
      Button("Cancel", role: .cancel) {}
      Button("Sign Out", role: .destructive) { Task { await account.signOut() } }
    } message: {
      Text("Sign out on this Mac. Your cleanup history and exclusions stay available here.")
    }
  }

  private var header: some View {
    HStack(alignment: .center, spacing: 12) {
      if !usesScaffold {
        SwatchBadge(symbol: headerSymbol, swatch: headerSwatch, size: 36, glow: true)
      }
      VStack(alignment: .leading, spacing: 2) {
        Eyebrow(purpose == .paidAction ? "MacMint Pro" : "Account", color: headerSwatch.text)
        Text(title).font(.system(size: 17, weight: .bold)).tracking(-0.3).foregroundStyle(AppTheme.ink)
          .fixedSize(horizontal: false, vertical: true)
          .accessibilityAddTraits(.isHeader)
      }
      Spacer(minLength: 0)
    }
    .padding(.horizontal, 22).padding(.top, 18).padding(.bottom, 14)
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  @ViewBuilder private var content: some View {
    switch account.phase {
    case .active where account.accessLapsed: GateScaffold { AccessLapsedPanel() }
    case .active:
      if purpose == .paidAction { accessConfirmed } else { overview }
    case .checking:
      ProgressView("Checking account…").padding(50).frame(maxWidth: .infinity)
    case .signedOut: GateScaffold { AuthForm() }
    case .needsPlan: GateScaffold { RedeemForm() }
    case .deviceLimit(let message, let devices): GateScaffold { DeviceLimitPanel(message: message, devices: devices) }
    case .deviceRemoved: GateScaffold { DeviceRemovedPanel() }
    case .failed(let message): GateScaffold { FailurePanel(message: message) }
    }
  }

  private var overview: some View {
    VStack(alignment: .leading, spacing: 14) {
      AccountOverviewPanel(details: details, busy: account.isBusy,
        refresh: { Task { await account.refreshAccess(force: true) } },
        manage: { account.openAccountPage() },
        signOut: { confirmSignOut = true })
      GateMessages()
    }
    .padding(24)
  }

  private var accessConfirmed: some View {
    VStack(alignment: .leading, spacing: 14) {
      HStack(spacing: 12) {
        SwatchBadge(symbol: "checkmark.seal.fill", swatch: .mint, size: 32)
        Text("Your MacMint Pro access is confirmed.")
          .font(.system(size: 14, weight: .semibold)).foregroundStyle(AppTheme.accentText)
          .fixedSize(horizontal: false, vertical: true)
      }
      .accessibilityElement(children: .combine)
      Text(hasDeferredPlan
        ? "Continue to review the items you selected. Nothing moves until you confirm there."
        : "Choose the action again to continue.")
        .font(.system(size: 12.5)).foregroundStyle(AppTheme.ink2).fixedSize(horizontal: false, vertical: true)
      if hasDeferredPlan {
        HStack { Spacer(); Button("Continue to Review") { dismiss() }.buttonStyle(MintButtonStyle()) }
      }
    }
    .padding(24)
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private var details: AccountOverviewPanel.Details {
    let snapshot = account.snapshot
    return AccountOverviewPanel.Details(
      email: snapshot?.user.email ?? "Signed in",
      plan: account.isUnlocked ? snapshot?.entitlement.planDescription ?? "Pro" : "Verification required",
      planActive: account.isUnlocked,
      devices: snapshot.map { "\($0.devices.count) of \(max($0.entitlement.maxDevices, 1)) in use" } ?? "—",
      thisMac: account.deviceInfo.name,
      offline: account.isOffline)
  }

  /// Sign-in and plan panels need the taller scaffold; the account and progress fit their content.
  private var usesScaffold: Bool {
    switch account.phase {
    case .active: return account.accessLapsed
    case .checking: return false
    default: return true
    }
  }

  private var headerSymbol: String {
    if case .active = account.phase, purpose == .paidAction { return "checkmark.seal.fill" }
    return "person.crop.circle.fill"
  }

  private var headerSwatch: AppTheme.Swatch {
    if case .active = account.phase, purpose == .paidAction { return .mint }
    return .violet
  }

  private var title: String {
    switch account.phase {
    case .active where !account.accessLapsed: return purpose == .paidAction ? "MacMint Pro is active" : "Account"
    case .signedOut: return purpose == .paidAction ? "Sign in to continue" : "Connect your MacMint account"
    default: return purpose == .paidAction ? "MacMint Pro is needed for this step" : "Account"
    }
  }

  private var closeTitle: String {
    guard purpose == .paidAction else { return "Done" }
    return account.isUnlocked ? "Not Now" : "Continue inspecting locally"
  }
}
