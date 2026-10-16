import Foundation

public struct SafetyPolicy: Sendable {
  public let homeDirectory: URL

  public init(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) {
    self.homeDirectory = homeDirectory.standardizedFileURL
  }

  /// Baseline automatic-cleanup policy: only user-owned paths below the home directory,
  /// never system-owned paths, personal content roots, or symbolic links.
  public func deletionDecision(for url: URL) -> (allowed: Bool, reason: String) {
    let candidate = url.standardizedFileURL
    let path = candidate.path
    let home = homeDirectory.path

    if isSystemOwned(candidate) {
      return (false, "System-owned location is protected by the app.")
    }

    let personal = ["Desktop", "Documents", "Pictures", "Movies", "Music"]
      .map { homeDirectory.appendingPathComponent($0).standardizedFileURL.path }
    if personal.contains(where: { path == $0 || path.hasPrefix($0 + "/") }) {
      return (false, "Personal-content folders are never automatic-cleanup targets.")
    }

    guard path != home, path.hasPrefix(home + "/") else {
      return (false, "Automatic cleanup is limited to user-owned paths below the home folder.")
    }

    if isSymlink(candidate) {
      return (false, "Symbolic links are not automatic-cleanup targets.")
    }

    return (true, "User-owned path passes the baseline automatic-cleanup policy.")
  }

  /// Stronger policy used by CleanupEngine. A target must pass the baseline policy AND
  /// belong to an allowlisted location appropriate for its cleanup category.
  public func cleanupTargetDecision(for target: CleanupTarget) -> (allowed: Bool, reason: String) {
    cleanupDecision(for: target.url, category: target.category)
  }

  public func cleanupDecision(for url: URL, category: CleanupCategory) -> (
    allowed: Bool, reason: String
  ) {
    let baseline = deletionDecision(for: url)
    guard baseline.allowed else { return baseline }

    let candidate = url.standardizedFileURL
    let allowed: Bool

    switch category {
    case .userCaches:
      allowed = isInside(candidate, roots: [homeDirectory.appendingPathComponent("Library/Caches")])

    case .userLogs:
      allowed = isInside(candidate, roots: [homeDirectory.appendingPathComponent("Library/Logs")])

    case .browserCaches:
      allowed = isInside(candidate, roots: [homeDirectory.appendingPathComponent("Library/Caches")])

    case .developerJunk:
      allowed = isInside(
        candidate,
        roots: [
          homeDirectory.appendingPathComponent("Library/Developer/Xcode/DerivedData"),
          homeDirectory.appendingPathComponent("Library/Developer/Xcode/Archives"),
          homeDirectory.appendingPathComponent("Library/Developer/Xcode/iOS DeviceSupport"),
          homeDirectory.appendingPathComponent("Library/Developer/CoreSimulator/Caches"),
          homeDirectory.appendingPathComponent(".npm/_cacache"),
          homeDirectory.appendingPathComponent(".gradle/caches"),
          homeDirectory.appendingPathComponent("Library/Caches/Homebrew"),
          homeDirectory.appendingPathComponent("Library/Caches/pip"),
          homeDirectory.appendingPathComponent("Library/Caches/CocoaPods"),
          homeDirectory.appendingPathComponent("Library/Caches/Yarn"),
          homeDirectory.appendingPathComponent("Library/Caches/org.swift.swiftpm"),
        ])

    case .deviceBackups:
      allowed = isInside(
        candidate,
        roots: [
          homeDirectory.appendingPathComponent("Library/Application Support/MobileSync/Backup")
        ])

    case .diagnostics:
      allowed = isInside(
        candidate,
        roots: [
          homeDirectory.appendingPathComponent("Library/Logs/DiagnosticReports")
        ])

    case .appLeftovers:
      allowed = isInside(candidate, roots: appLeftoverRoots())

    case .installers:
      allowed = isReviewedInstaller(candidate)
    }

    return allowed
      ? (true, "Target is inside an allowlisted location for \(category.rawValue).")
      : (false, "Target is outside the allowlisted location for \(category.rawValue).")
  }

  /// Developer and AI storage: known tool caches, or build-output folders inside projects
  /// (projects may live under Documents, so the personal-folder block does not apply here).
  public func developerArtifactDecision(for url: URL, extraRoots: [URL] = []) -> (
    allowed: Bool, reason: String
  ) {
    let candidate = url.standardizedFileURL
    let path = candidate.path
    let home = homeDirectory.path
    if isSystemOwned(candidate) { return (false, "System-owned location is protected by the app.") }
    guard path != home, path.hasPrefix(home + "/") else {
      return (false, "Developer cleanup is limited to your home folder.")
    }
    if isSymlink(candidate) { return (false, "Symbolic links are not removed.") }
    if isInside(candidate, roots: developerRoots() + extraRoots) {
      return (true, "Inside a known developer or AI cache.")
    }
    let library = homeDirectory.appendingPathComponent("Library").standardizedFileURL.path
    let parent = candidate.deletingLastPathComponent().path
    if !path.hasPrefix(library + "/"), parent != home,
      DeveloperStorageScanner.projectArtifactNames.contains(candidate.lastPathComponent)
    {
      return (true, "Build output folder inside a project.")
    }
    return (false, "Not a recognised developer cache or build folder.")
  }

  private func developerRoots() -> [URL] {
    [
      "Library/Developer/Xcode/DerivedData", "Library/Developer/Xcode/Archives",
      "Library/Developer/Xcode/iOS DeviceSupport", "Library/Developer/Xcode/watchOS DeviceSupport",
      "Library/Developer/Xcode/tvOS DeviceSupport", "Library/Developer/Xcode/visionOS DeviceSupport",
      "Library/Developer/CoreSimulator/Caches", ".npm/_cacache", "Library/pnpm/store",
      "Library/Caches/Yarn", "Library/Caches/Homebrew", "Library/Caches/pip",
      "Library/Caches/CocoaPods", "Library/Caches/org.swift.swiftpm", ".bun/install/cache",
      ".gradle/caches", ".m2/repository", ".cargo/registry/cache", ".lmstudio/models",
      ".cache/lm-studio/models", ".cache/huggingface/hub",
    ].map { homeDirectory.appendingPathComponent($0) }
  }

  /// Applications may be uninstalled from /Applications or ~/Applications, never /System.
  public func appBundleDecision(for url: URL) -> (allowed: Bool, reason: String) {
    let candidate = url.standardizedFileURL
    let path = candidate.path
    let homeApps = homeDirectory.appendingPathComponent("Applications").standardizedFileURL.path
    guard candidate.pathExtension.lowercased() == "app" else {
      return (false, "Only application bundles can be uninstalled.")
    }
    guard path.hasPrefix("/Applications/") || path.hasPrefix(homeApps + "/") else {
      return (false, "This application path is not eligible for uninstall.")
    }
    if isSymlink(candidate) { return (false, "Symbolic links are not uninstalled.") }
    return (true, "Application bundle is in an Applications folder.")
  }

  /// Explicit-review policy used by Large Files and Duplicates. It permits personal files,
  /// but still blocks system/support data and symlinks.
  public func reviewedFileDecision(for url: URL) -> (allowed: Bool, reason: String) {
    let candidate = url.standardizedFileURL
    let path = candidate.path
    let home = homeDirectory.path

    if isSystemOwned(candidate) {
      return (false, "System-owned locations cannot be removed from review tools.")
    }

    let userLibrary = homeDirectory.appendingPathComponent("Library").standardizedFileURL.path
    if path == userLibrary || path.hasPrefix(userLibrary + "/") {
      return (
        false,
        "~/Library is managed by dedicated cleanup and uninstaller modules, not generic file removal."
      )
    }

    guard path != home, path.hasPrefix(home + "/") else {
      return (false, "Reviewed file removal is limited to files inside your home folder.")
    }

    if isSymlink(candidate) {
      return (false, "Symbolic links are not removed by the review tools.")
    }

    return (true, "Explicitly reviewed user file passes the safety policy.")
  }

  public func appLeftoverDecision(for url: URL) -> (allowed: Bool, reason: String) {
    let baseline = deletionDecision(for: url)
    guard baseline.allowed else { return baseline }
    guard isInside(url.standardizedFileURL, roots: appLeftoverRoots()) else {
      return (false, "App leftovers are limited to known user Library support locations.")
    }
    return (true, "Related app data is inside an allowlisted user Library location.")
  }

  public func isKnownSafeCleanupPath(_ url: URL) -> Bool {
    let roots = [
      homeDirectory.appendingPathComponent("Library/Caches"),
      homeDirectory.appendingPathComponent("Library/Logs"),
      homeDirectory.appendingPathComponent("Library/Developer/Xcode/DerivedData"),
      homeDirectory.appendingPathComponent("Library/Developer/CoreSimulator/Caches"),
      homeDirectory.appendingPathComponent(".npm/_cacache"),
      homeDirectory.appendingPathComponent("Library/Caches/Homebrew"),
    ]
    return isInside(url.standardizedFileURL, roots: roots)
  }

  private func appLeftoverRoots() -> [URL] {
    [
      "Library/Application Support",
      "Library/Application Scripts",
      "Library/Caches",
      "Library/Preferences",
      "Library/Logs",
      "Library/Saved Application State",
      "Library/WebKit",
      "Library/Containers",
      "Library/Group Containers",
      "Library/HTTPStorages",
      "Library/Cookies",
      "Library/LaunchAgents",
    ].map { homeDirectory.appendingPathComponent($0) }
  }

  private func isReviewedInstaller(_ url: URL) -> Bool {
    let downloads = homeDirectory.appendingPathComponent("Downloads")
    guard FileSystem.path(url, isInsideOrEqual: downloads),
      url.standardizedFileURL != downloads.standardizedFileURL
    else {
      return false
    }
    return ["dmg", "pkg", "iso", "zip", "xip"].contains(url.pathExtension.lowercased())
  }

  private func isInside(_ candidate: URL, roots: [URL]) -> Bool {
    roots.contains { root in FileSystem.path(candidate, isInsideOrEqual: root.standardizedFileURL) }
  }

  private func isSystemOwned(_ url: URL) -> Bool {
    let path = url.path
    let hardBlocked = ["/System", "/bin", "/sbin", "/usr", "/private", "/Library"]
    return hardBlocked.contains(where: { path == $0 || path.hasPrefix($0 + "/") })
  }

  private func isSymlink(_ url: URL) -> Bool {
    (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true
  }
}
