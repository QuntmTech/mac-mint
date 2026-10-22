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

private struct GateScaffold<Content: View>: View {
  @ViewBuilder let content: Content

  var body: some View {
    ZStack {
      LinearGradient(
        colors: [AppTheme.panel, AppTheme.canvas],
        startPoint: .top,
        endPoint: .bottom
      )
      .ignoresSafeArea()

      GeometryReader { geometry in
        ScrollView {
          VStack(spacing: 22) {
            VStack(spacing: 10) {
              BrandMark(size: 56)
              Text("MacMint").font(.system(size: 27, weight: .semibold))
            }
            SurfaceCard { content }
              .frame(width: 420)
            GateMessages()
          }
          .padding(40)
          .frame(maxWidth: .infinity, minHeight: geometry.size.height)
        }
      }
    }
  }
}

private struct GateMessages: View {
  @EnvironmentObject private var account: AccountStore

  var body: some View {
    VStack(spacing: 8) {
      if let error = account.errorMessage {
        Label(error, systemImage: "exclamationmark.triangle.fill")
          .foregroundStyle(AppTheme.warning)
      }
      if let info = account.infoMessage {
        Label(info, systemImage: "checkmark.circle.fill")
          .foregroundStyle(AppTheme.accentText)
      }
    }
    .font(.callout)
    .multilineTextAlignment(.center)
    .frame(width: 420)
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
        Text(isCreating ? "Create your account" : "Sign in").font(.title2.bold())
        Text(
          isCreating
            ? "Create an account to connect a purchase or redeem a code. Local inspection stays available."
            : "Sign in with the same account you use on the MacMint website."
        )
        .font(.callout)
        .foregroundStyle(.secondary)
      }

      if isCreating {
        TextField("Name", text: $name)
          .textContentType(.name)
          .focused($focused, equals: .name)
      }
      TextField("Email", text: $email)
        .textContentType(.username)
        .focused($focused, equals: .email)
      SecureField("Password", text: $password)
        .textContentType(isCreating ? .newPassword : .password)
        .focused($focused, equals: .password)
        .onSubmit(submit)

      Button(action: submit) {
        HStack {
          if account.isBusy { ProgressView().controlSize(.small) }
          Text(isCreating ? "Create Account" : "Sign In").frame(maxWidth: .infinity)
        }
      }
      .buttonStyle(.borderedProminent)
      .controlSize(.large)
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
      .buttonStyle(.link)
        .tint(AppTheme.accentText)
      .font(.callout)
    }
    .textFieldStyle(.roundedBorder)
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
        Text("Unlock MacMint").font(.title2.bold())
        if let email = account.snapshot?.user.email {
          Text("Signed in as \(email)").font(.callout).foregroundStyle(.secondary)
        }
      }
      Text("Bought MacMint on the website? Check your purchase to activate this Mac, or enter a redemption code below.")
        .font(.callout)
        .fixedSize(horizontal: false, vertical: true)
      Button {
        Task { await account.checkPurchase() }
      } label: {
        Label("Check My Purchase", systemImage: "arrow.clockwise")
          .frame(maxWidth: .infinity)
      }
      .buttonStyle(.borderedProminent)
      .controlSize(.large)
      .disabled(account.isBusy)

      TextField("MINT-XXXX-XXXX-XXXX-XXXX", text: $code)
        .textFieldStyle(.roundedBorder)
        .font(.body.monospaced())
        .onSubmit(submit)

      Button(action: submit) {
        HStack {
          if account.isBusy { ProgressView().controlSize(.small) }
          Text("Redeem Code").frame(maxWidth: .infinity)
        }
      }
      .buttonStyle(.bordered)
      .controlSize(.large)
      .keyboardShortcut(.defaultAction)
      .disabled(account.isBusy || code.isEmpty)

      Divider()
      HStack {
        Button("Buy MacMint") { account.openPurchasePage() }
        Spacer()
        Button("Sign Out") { Task { await account.signOut() } }
      }
      .buttonStyle(.link)
        .tint(AppTheme.accentText)
      .font(.callout)
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
      Text("Device limit reached").font(.title2.bold())
      Text(message).font(.callout).foregroundStyle(.secondary)

      VStack(spacing: 0) {
        ForEach(devices) { device in
          HStack(spacing: 10) {
            Image(systemName: "laptopcomputer").foregroundStyle(AppTheme.accentText)
            VStack(alignment: .leading, spacing: 2) {
              Text(device.name).fontWeight(.medium)
              Text(detail(for: device)).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Remove") { Task { await account.removeDevice(device) } }
              .disabled(account.isBusy)
          }
          .padding(.vertical, 8)
          if device.id != devices.last?.id { Divider() }
        }
      }

      HStack {
        Button("Try Again") { Task { await account.retry() } }
        Spacer()
        Button("Sign Out") { Task { await account.signOut() } }
          .buttonStyle(.link)
        .tint(AppTheme.accentText)
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
      Label("This Mac was removed from your account", systemImage: "laptopcomputer.slash")
        .font(.title3.bold())
      Text("MacMint won’t add it back on its own. Activate this Mac to use your plan here again; it takes one of your device slots.")
        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
      Button {
        Task { await account.activateThisMac() }
      } label: {
        HStack {
          if account.isBusy { ProgressView().controlSize(.small) }
          Text("Activate this Mac").frame(maxWidth: .infinity)
        }
      }
      .buttonStyle(.borderedProminent)
      .controlSize(.large)
      .disabled(account.isBusy)
      HStack {
        Button("Manage Devices…") { account.openAccountPage() }
        Spacer()
        Button("Sign Out") { Task { await account.signOut() } }
      }
      .buttonStyle(.link)
      .tint(AppTheme.accentText)
      .font(.callout)
    }
  }
}

private struct AccessLapsedPanel: View {
  @EnvironmentObject private var account: AccountStore

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      Label("MacMint Pro needs to be checked again", systemImage: "clock.badge.exclamationmark")
        .font(.title3.bold())
      Text(account.isOffline
        ? "This Mac has been offline longer than MacMint Pro allows without a check, or your access period ended. Connect to the internet and check again."
        : "Your access period may have ended. Check again to confirm your plan for this Mac.")
        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
      Button {
        Task { await account.retry() }
      } label: {
        HStack {
          if account.isBusy || account.phase == .checking { ProgressView().controlSize(.small) }
          Text("Check Again").frame(maxWidth: .infinity)
        }
      }
      .buttonStyle(.borderedProminent)
      .controlSize(.large)
      .disabled(account.isBusy)
      HStack {
        Button("Buy MacMint") { account.openPurchasePage() }
        Spacer()
        Button("Sign Out") { Task { await account.signOut() } }
      }
      .buttonStyle(.link)
      .tint(AppTheme.accentText)
      .font(.callout)
    }
  }
}

private struct FailurePanel: View {
  @EnvironmentObject private var account: AccountStore
  let message: String

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      Label("Couldn't verify your account", systemImage: "wifi.exclamationmark")
        .font(.title3.bold())
      Text(message).font(.callout).foregroundStyle(.secondary)
      HStack {
        Button("Try Again") { Task { await account.retry() } }
          .buttonStyle(.borderedProminent)
          .disabled(account.isBusy)
        Spacer()
        Button("Sign Out") { Task { await account.signOut() } }
          .buttonStyle(.link)
        .tint(AppTheme.accentText)
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
        HStack {
          Label("Account", systemImage: "person.crop.circle.fill").font(.headline)
          Spacer()
          if account.isOffline {
            StatusPill(title: "Offline", icon: "wifi.slash", tint: AppTheme.warning)
          }
        }
        if let snapshot = account.snapshot {
          row("Email", snapshot.user.email)
          row("Access", account.isUnlocked ? snapshot.entitlement.planDescription : "Verification required")
          row(
            "Devices",
            "\(snapshot.devices.count) of \(max(snapshot.entitlement.maxDevices, 1)) in use")
          row("This Mac", account.deviceInfo.name)
        }
        if account.snapshot == nil {
          Text("You’re inspecting locally. Scan, explore, and use History without signing in. Connect your account when you’re ready to start a paid operation.")
            .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        Divider()
        HStack {
          if account.snapshot != nil {
            Button("Manage Account…") { account.openAccountPage() }
            Spacer()
            Button("Sign Out", role: .destructive) { confirmSignOut = true }
          } else {
            Label("Local inspection", systemImage: "desktopcomputer").font(.caption).foregroundStyle(.secondary)
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
      Text(title)
      Spacer()
      Text(value).foregroundStyle(.secondary).textSelection(.enabled)
    }
    .font(.callout)
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
      HStack(spacing: 12) {
        SwatchBadge(symbol: "person.crop.circle.fill", swatch: .mint, size: 40)
        VStack(alignment: .leading, spacing: 4) {
          Text(details.email).font(.title3.weight(.semibold)).lineLimit(1).truncationMode(.middle)
            .textSelection(.enabled)
          StatusPill(title: details.plan, icon: details.planActive ? "checkmark.seal.fill" : "exclamationmark.circle",
            tint: details.planActive ? AppTheme.accentText : AppTheme.warning)
        }
        Spacer(minLength: 0)
      }
      SurfaceCard {
        VStack(spacing: 10) {
          row("Devices", details.devices)
          row("This Mac", details.thisMac)
          row("Connection", details.offline ? "Offline · using saved access" : "Online")
        }
      }
      Text("Billing, receipts and the devices on your plan are managed on your account page.")
        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
      HStack(spacing: 10) {
        Button("Manage Account…", action: manage)
        Button("Refresh", action: refresh).disabled(busy)
        Spacer()
        Button("Sign Out", role: .destructive, action: signOut)
      }
    }
  }

  private func row(_ title: String, _ value: String) -> some View {
    HStack {
      Text(title)
      Spacer()
      Text(value).foregroundStyle(.secondary).textSelection(.enabled)
    }
    .font(.callout)
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
    VStack(spacing: 0) {
      HStack(spacing: 12) {
        Text(title).font(.headline).accessibilityAddTraits(.isHeader)
        Spacer()
        Button(closeTitle) { dismiss() }.keyboardShortcut(.cancelAction)
      }
      .padding(.horizontal, 20).padding(.vertical, 14)
      Divider()
      content
    }
    .frame(width: 560, height: usesScaffold ? 560 : nil)
    .background(AppTheme.canvas)
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

  @ViewBuilder private var content: some View {
    switch account.phase {
    case .active where account.accessLapsed: GateScaffold { AccessLapsedPanel() }
    case .active:
      if purpose == .paidAction { accessConfirmed } else { overview }
    case .checking: ProgressView("Checking account…").padding(50)
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
    VStack(alignment: .leading, spacing: 16) {
      Label("Your MacMint Pro access is confirmed.", systemImage: "checkmark.seal.fill")
        .font(.callout.weight(.medium)).foregroundStyle(AppTheme.accentText)
      Text(hasDeferredPlan
        ? "Continue to review the items you selected. Nothing moves until you confirm there."
        : "Choose the action again to continue.")
        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
      if hasDeferredPlan {
        HStack { Spacer(); Button("Continue to Review") { dismiss() }.buttonStyle(MintButtonStyle()) }
      }
    }
    .padding(24)
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
