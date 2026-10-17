import AppKit
import Foundation
import MacCleanerCore

/// Checks the published release feed. Only informs: the download opens in the browser, and
/// only from an allowlisted first-party HTTPS location (otherwise the account page). Builds
/// can still be ad-hoc signed prereleases that Gatekeeper does not vouch for, so the
/// release's published SHA-256 (`ReleaseInfo.expectedSHA256`) is the integrity reference.
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
  private var timer: Timer?

  func start() {
    guard timer == nil else { return }
    Task { await check() }
    timer = Timer.scheduledTimer(withTimeInterval: 24 * 3600, repeats: true) { [weak self] _ in
      Task { @MainActor in await self?.check() }
    }
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
