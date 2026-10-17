import AppKit
import Foundation
import MacCleanerCore

/// Checks the published release feed. Only informs — downloads happen in the browser
/// so Gatekeeper verifies the signed, notarized download.
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
    let url = release?.downloadUrl.flatMap(URL.init(string:)) ?? URL(string: "https://macmint.co/account")!
    NSWorkspace.shared.open(url)
  }
}
