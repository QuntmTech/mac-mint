import Foundation

/// The write gate for every removal. Paths are compared in canonical form: parent symlinks are
/// resolved (so a symlinked folder can't smuggle a protected location in) and comparisons ignore
/// case, matching APFS's default case-insensitive behaviour.
public struct SafetyPolicy: Sendable {
  public let homeDirectory: URL
  private let home: String

  public init(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) {
    self.homeDirectory = homeDirectory.standardizedFileURL
    self.home = Self.canonicalPath(of: homeDirectory.standardizedFileURL.resolvingSymlinksInPath())
  }

  // MARK: Canonical paths

  /// Standardized path with every parent symlink resolved (the item itself is not followed),
  /// lowercased for case-insensitive comparison.
  static func canonicalPath(of url: URL) -> String {
    let standardized = url.standardizedFileURL
    let parent = standardized.deletingLastPathComponent().resolvingSymlinksInPath()
    let path = standardized.path == "/" ? "/" : parent.appendingPathComponent(standardized.lastPathComponent).path
    return path.lowercased()
  }

  private func canonical(_ url: URL) -> String { Self.canonicalPath(of: url) }

  private func homePath(_ relative: String) -> String {
    (home + "/" + relative).lowercased()
  }

  private func inside(_ path: String, _ root: String, strict: Bool = false) -> Bool {
    (!strict && path == root) || path.hasPrefix(root + "/")
  }

  private func inside(_ path: String, roots: [String], strict: Bool = false) -> Bool {
    roots.contains { inside(path, $0, strict: strict) }
  }

  private var isUnderHomeCheck: (String) -> Bool { { [home] in $0.hasPrefix(home + "/") } }

  // MARK: Decisions

  /// Baseline automatic-cleanup policy: only user-owned paths below the home directory,
  /// never system-owned paths, personal content roots, the Trash, or symbolic links.
  public func deletionDecision(for url: URL) -> (allowed: Bool, reason: String) {
    let path = canonical(url)
    if isSystemOwned(path) { return (false, "System-owned location is protected by the app.") }
    if inside(path, roots: personalRoots()) {
      return (false, "Personal-content folders are never automatic-cleanup targets.")
    }
    guard isUnderHomeCheck(path) else {
      return (false, "Automatic cleanup is limited to user-owned paths below the home folder.")
    }
    if isTrash(path) { return (false, "Items already in the Trash are left alone.") }
    if isSymlink(url) { return (false, "Symbolic links are not automatic-cleanup targets.") }
    return (true, "User-owned path passes the baseline automatic-cleanup policy.")
  }

  /// A target must pass the baseline policy AND sit in a location appropriate for its category.
  public func cleanupTargetDecision(for target: CleanupTarget) -> (allowed: Bool, reason: String) {
    cleanupDecision(for: target.url, category: target.category)
  }

  public func cleanupDecision(for url: URL, category: CleanupCategory) -> (
    allowed: Bool, reason: String
  ) {
    let baseline = deletionDecision(for: url)
    guard baseline.allowed else { return baseline }
    let path = canonical(url)
    let allowed: Bool

    switch category {
    case .userCaches, .browserCaches:
      // Items inside Caches, never the Caches folder itself.
      allowed = inside(path, homePath("Library/Caches"), strict: true)
    case .userLogs:
      allowed = inside(path, homePath("Library/Logs"), strict: true)
    case .developerJunk:
      allowed = inside(path, roots: catalogDeveloperRoots())
    case .deviceBackups:
      allowed = inside(path, homePath("Library/Application Support/MobileSync/Backup"), strict: true)
    case .diagnostics:
      allowed = inside(path, homePath("Library/Logs/DiagnosticReports"))
    case .appLeftovers:
      allowed = inside(path, roots: appLeftoverRoots(), strict: true) && !isAppleData(url)
    case .installers:
      allowed = isReviewedInstaller(url, path: path)
    }

    return allowed
      ? (true, "Target is inside an allowlisted location for \(category.rawValue).")
      : (false, "Target is outside the allowlisted location for \(category.rawValue).")
  }

  /// Developer and AI storage: known tool caches, or a build-output folder that sits next to
  /// its tool's marker file (projects may live under Documents, so that block doesn't apply).
  public func developerArtifactDecision(for url: URL, extraRoots: [URL] = []) -> (
    allowed: Bool, reason: String
  ) {
    let path = canonical(url)
    if isSystemOwned(path) { return (false, "System-owned location is protected by the app.") }
    guard isUnderHomeCheck(path) else {
      return (false, "Developer cleanup is limited to your home folder.")
    }
    if isTrash(path) { return (false, "Items already in the Trash are left alone.") }
    if isSymlink(url) { return (false, "Symbolic links are not removed.") }
    let extra = DeveloperStorageScanner.validatedRoots(extraRoots, home: homeDirectory).map(canonical)
    if inside(path, roots: developerRoots() + extra) {
      return (true, "Inside a known developer or AI cache.")
    }
    let parent = (path as NSString).deletingLastPathComponent
    if !inside(path, homePath("Library")), parent != home,
      DeveloperStorageScanner.isProjectArtifact(url)
    {
      return (true, "Build output folder next to its project file.")
    }
    return (false, "Not a recognised developer cache or a build folder inside a project.")
  }

  /// Applications may be uninstalled from /Applications or ~/Applications, never /System.
  public func appBundleDecision(for url: URL) -> (allowed: Bool, reason: String) {
    let path = canonical(url)
    guard url.pathExtension.lowercased() == "app" else {
      return (false, "Only application bundles can be uninstalled.")
    }
    guard inside(path, "/applications", strict: true) || inside(path, homePath("Applications"), strict: true)
    else {
      return (false, "This application path is not eligible for uninstall.")
    }
    if isSymlink(url) { return (false, "Symbolic links are not uninstalled.") }
    return (true, "Application bundle is in an Applications folder.")
  }

  /// Explicit-review policy used by Large Files, Duplicates, and Storage. It permits personal
  /// files, but still blocks system/support data, the Trash, and symlinks.
  public func reviewedFileDecision(for url: URL) -> (allowed: Bool, reason: String) {
    let path = canonical(url)
    if isSystemOwned(path) {
      return (false, "System-owned locations cannot be removed from review tools.")
    }
    if inside(path, homePath("Library")) {
      return (
        false,
        "~/Library is managed by dedicated cleanup and uninstaller modules, not generic file removal."
      )
    }
    guard isUnderHomeCheck(path) else {
      return (false, "Reviewed file removal is limited to files inside your home folder.")
    }
    if isTrash(path) { return (false, "Items already in the Trash are left alone.") }
    if isSymlink(url) { return (false, "Symbolic links are not removed by the review tools.") }
    return (true, "Explicitly reviewed user file passes the safety policy.")
  }

  public func appLeftoverDecision(for url: URL) -> (allowed: Bool, reason: String) {
    let baseline = deletionDecision(for: url)
    guard baseline.allowed else { return baseline }
    guard inside(canonical(url), roots: appLeftoverRoots(), strict: true) else {
      return (false, "App leftovers are limited to items inside known user Library locations.")
    }
    if isAppleData(url) { return (false, "macOS's own data is never removed as app leftovers.") }
    return (true, "Related app data is inside an allowlisted user Library location.")
  }

  public func isKnownSafeCleanupPath(_ url: URL) -> Bool {
    inside(
      canonical(url),
      roots: [
        "Library/Caches", "Library/Logs", "Library/Developer/Xcode/DerivedData",
        "Library/Developer/CoreSimulator/Caches", ".npm/_cacache", "Library/Caches/Homebrew",
      ].map(homePath))
  }

  // MARK: Rules

  private func personalRoots() -> [String] {
    ["Desktop", "Documents", "Pictures", "Movies", "Music"].map(homePath)
  }

  private func catalogDeveloperRoots() -> [String] {
    [
      "Library/Developer/Xcode/DerivedData", "Library/Developer/Xcode/Archives",
      "Library/Developer/Xcode/iOS DeviceSupport", "Library/Developer/CoreSimulator/Caches",
      ".npm/_cacache", ".gradle/caches", "Library/Caches/Homebrew", "Library/Caches/pip",
      "Library/Caches/CocoaPods", "Library/Caches/Yarn", "Library/Caches/org.swift.swiftpm",
    ].map(homePath)
  }

  private func developerRoots() -> [String] {
    [
      "Library/Developer/Xcode/DerivedData", "Library/Developer/Xcode/Archives",
      "Library/Developer/Xcode/iOS DeviceSupport", "Library/Developer/Xcode/watchOS DeviceSupport",
      "Library/Developer/Xcode/tvOS DeviceSupport", "Library/Developer/Xcode/visionOS DeviceSupport",
      "Library/Developer/CoreSimulator/Caches", ".npm/_cacache", "Library/pnpm/store",
      "Library/Caches/Yarn", "Library/Caches/Homebrew", "Library/Caches/pip",
      "Library/Caches/CocoaPods", "Library/Caches/org.swift.swiftpm", ".bun/install/cache",
      ".gradle/caches", ".m2/repository", ".cargo/registry/cache", ".lmstudio/models",
      ".cache/lm-studio/models", ".cache/huggingface/hub",
    ].map(homePath)
  }

  private func appLeftoverRoots() -> [String] {
    [
      "Library/Application Support", "Library/Application Scripts", "Library/Caches",
      "Library/Preferences", "Library/Logs", "Library/Saved Application State", "Library/WebKit",
      "Library/Containers", "Library/Group Containers", "Library/HTTPStorages", "Library/Cookies",
      "Library/LaunchAgents",
    ].map(homePath)
  }

  /// Apple's own per-app data (com.apple.*, group.com.apple.*, <TEAM>.com.apple.*).
  private func isAppleData(_ url: URL) -> Bool {
    let name = url.lastPathComponent.lowercased()
    return name.hasPrefix("com.apple.") || name.hasPrefix("group.com.apple.")
      || name.range(of: #"^[a-z0-9]{10}\.com\.apple\."#, options: .regularExpression) != nil
  }

  private func isReviewedInstaller(_ url: URL, path: String) -> Bool {
    guard inside(path, homePath("Downloads"), strict: true) else { return false }
    return ["dmg", "pkg", "iso", "zip", "xip"].contains(url.pathExtension.lowercased())
  }

  private func isTrash(_ path: String) -> Bool {
    inside(path, homePath(".Trash")) || path.contains("/.trashes/")
  }

  /// System locations are blocked even when reached through a symlink. The home folder is
  /// exempt so a home that itself lives under /private/var (test fixtures) still works.
  private func isSystemOwned(_ path: String) -> Bool {
    if path == home || path.hasPrefix(home + "/") { return false }
    let blocked = [
      "/system", "/bin", "/sbin", "/usr", "/private", "/library", "/etc", "/var", "/tmp", "/opt",
      "/cores", "/dev",
    ]
    return blocked.contains { inside(path, $0) } || path == "/"
  }

  private func isSymlink(_ url: URL) -> Bool {
    (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true
  }
}
