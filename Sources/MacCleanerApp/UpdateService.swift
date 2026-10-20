import AppKit
import Foundation
import MacCleanerCore

/// Checks the published release feed and the server's minimum supported version. Sparkle
/// (`UpdaterController`) installs updates; this keeps the "required" gate and, when Sparkle
/// has nothing to install, a fallback download that opens in the browser from an allowlisted
/// first-party HTTPS location (otherwise the account page). Builds can still be ad-hoc signed
/// prereleases that Gatekeeper does not vouch for, so the release's published SHA-256
/// (`ReleaseInfo.expectedSHA256`) is the integrity reference for that download.
@MainActor
final class UpdateService: ObservableObject {
  @Published private(set) var status: UpdateStatus = .current
  @Published private(set) var lastChecked: Date?
  @Published private(set) var checkError: String?
  @Published var dismissedVersion: String?

  static var currentVersion: String {
    Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
  }

  private let checker = ReleaseChecker()
  private var started = false

  /// Checks once at launch. Later checks follow Sparkle's daily schedule
  /// (`UpdaterController.onCycleFinished`) and Check for Updates.
  func start() {
    guard !started else { return }
    started = true
    Task { await check() }
  }

  func check() async {
    do {
      status = try await checker.check(currentVersion: Self.currentVersion)
      lastChecked = Date()
      checkError = nil
    } catch { checkError = "Check failed. The available version could not be verified." }
  }

  var bannerRelease: ReleaseInfo? {
    switch status {
    case .available(let release): return release.version == dismissedVersion ? nil : release
    case .required(let release, _): return release
    case .current: return nil
    }
  }

  var isRequired: Bool {
    if case .required = status { return true }
    return false
  }

  func openDownload(_ release: ReleaseInfo?) {
    NSWorkspace.shared.open(ReleaseChecker.trustedDownloadURL(release?.downloadUrl) ?? ReleaseChecker.fallbackDownloadURL)
  }
}
