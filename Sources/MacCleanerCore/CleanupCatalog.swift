import Foundation

public struct CleanupRule: Sendable {
  public let category: CleanupCategory
  public let name: String
  public let url: URL
  public let risk: CleanupRisk
  public let reason: String
  public let expandChildren: Bool
  public let excludedChildNames: Set<String>
  /// App that writes this data. Its data is skipped while it is running.
  public let ownerBundleID: String?

  public init(
    category: CleanupCategory, name: String, url: URL, risk: CleanupRisk, reason: String,
    expandChildren: Bool = false, excludedChildNames: Set<String> = [], ownerBundleID: String? = nil
  ) {
    self.ownerBundleID = ownerBundleID
    self.category = category
    self.name = name
    self.url = url
    self.risk = risk
    self.reason = reason
    self.expandChildren = expandChildren
    self.excludedChildNames = excludedChildNames
  }
}

public struct CleanupCatalog: Sendable {
  public let homeDirectory: URL

  public init(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) {
    self.homeDirectory = homeDirectory
  }

  public func rules() -> [CleanupRule] {
    let h = homeDirectory
    return [
      .init(
        category: .userCaches, name: "Application caches",
        url: h.appendingPathComponent("Library/Caches"), risk: .safe,
        reason: "Regenerable per-user cache data.", expandChildren: true,
        excludedChildNames: [
          "Google", "Firefox", "Microsoft Edge", "com.apple.Safari", "Homebrew",
          "pip", "CocoaPods", "Yarn", "org.swift.swiftpm", "BraveSoftware", "Arc",
          "company.thebrowser.Browser", "Vivaldi", "com.operasoftware.Opera",
        ]),
      .init(
        category: .userLogs, name: "Application logs",
        url: h.appendingPathComponent("Library/Logs"), risk: .safe,
        reason: "Historical per-user logs that apps recreate as needed.", expandChildren: true,
        excludedChildNames: ["DiagnosticReports"]),

      .init(
        category: .diagnostics, name: "Crash reports",
        url: h.appendingPathComponent("Library/Logs/DiagnosticReports"), risk: .review,
        reason: "Old crash reports can be useful when diagnosing app problems."),

      .init(
        category: .browserCaches, name: "Chrome cache",
        url: h.appendingPathComponent("Library/Caches/Google/Chrome"), risk: .safe,
        reason: "Browser cache only; history, bookmarks, passwords, and cookies are not targeted.",
        ownerBundleID: "com.google.Chrome"),
      .init(
        category: .browserCaches, name: "Firefox cache",
        url: h.appendingPathComponent("Library/Caches/Firefox"), risk: .safe,
        reason: "Browser cache only.", ownerBundleID: "org.mozilla.firefox"),
      .init(
        category: .browserCaches, name: "Edge cache",
        url: h.appendingPathComponent("Library/Caches/Microsoft Edge"), risk: .safe,
        reason: "Browser cache only.", ownerBundleID: "com.microsoft.edgemac"),
      .init(
        category: .browserCaches, name: "Brave cache",
        url: h.appendingPathComponent("Library/Caches/BraveSoftware/Brave-Browser"), risk: .safe,
        reason: "Browser cache only; history, passwords, and cookies are not targeted.",
        ownerBundleID: "com.brave.Browser"),
      .init(
        category: .browserCaches, name: "Arc cache",
        url: h.appendingPathComponent("Library/Caches/Arc"), risk: .safe,
        reason: "Browser cache only.", ownerBundleID: "company.thebrowser.Browser"),
      .init(
        category: .browserCaches, name: "Arc cache",
        url: h.appendingPathComponent("Library/Caches/company.thebrowser.Browser"), risk: .safe,
        reason: "Browser cache only.", ownerBundleID: "company.thebrowser.Browser"),
      .init(
        category: .browserCaches, name: "Vivaldi cache",
        url: h.appendingPathComponent("Library/Caches/Vivaldi"), risk: .safe,
        reason: "Browser cache only.", ownerBundleID: "com.vivaldi.Vivaldi"),
      .init(
        category: .browserCaches, name: "Opera cache",
        url: h.appendingPathComponent("Library/Caches/com.operasoftware.Opera"), risk: .safe,
        reason: "Browser cache only.", ownerBundleID: "com.operasoftware.Opera"),
      .init(
        category: .browserCaches, name: "Safari cache",
        url: h.appendingPathComponent("Library/Caches/com.apple.Safari"), risk: .review,
        reason: "Safari cache only; macOS privacy permissions may restrict visibility.",
        ownerBundleID: "com.apple.Safari"),

      .init(
        category: .developerJunk, name: "Xcode DerivedData",
        url: h.appendingPathComponent("Library/Developer/Xcode/DerivedData"), risk: .safe,
        reason: "Build artifacts Xcode regenerates."),
      .init(
        category: .developerJunk, name: "Xcode Archives",
        url: h.appendingPathComponent("Library/Developer/Xcode/Archives"), risk: .review,
        reason: "Archives can be large but may be needed for symbolication or export."),
      .init(
        category: .developerJunk, name: "Xcode DeviceSupport",
        url: h.appendingPathComponent("Library/Developer/Xcode/iOS DeviceSupport"), risk: .review,
        reason:
          "Device support files can be recreated, but keeping recent versions speeds device debugging."
      ),
      .init(
        category: .developerJunk, name: "Simulator caches",
        url: h.appendingPathComponent("Library/Developer/CoreSimulator/Caches"), risk: .safe,
        reason: "Simulator cache data is regenerated by CoreSimulator."),
      .init(
        category: .developerJunk, name: "npm cache", url: h.appendingPathComponent(".npm/_cacache"),
        risk: .safe, reason: "npm content-addressable cache."),
      .init(
        category: .developerJunk, name: "Gradle cache",
        url: h.appendingPathComponent(".gradle/caches"), risk: .review,
        reason: "Gradle can recreate caches, but the next build may be slower."),
      .init(
        category: .developerJunk, name: "Homebrew cache",
        url: h.appendingPathComponent("Library/Caches/Homebrew"), risk: .safe,
        reason: "Downloaded formula and cask artifacts can be re-fetched."),
      .init(
        category: .developerJunk, name: "pip cache",
        url: h.appendingPathComponent("Library/Caches/pip"), risk: .safe,
        reason: "Python package downloads can be re-fetched."),
      .init(
        category: .developerJunk, name: "CocoaPods cache",
        url: h.appendingPathComponent("Library/Caches/CocoaPods"), risk: .safe,
        reason: "Downloaded CocoaPods artifacts can be recreated."),
      .init(
        category: .developerJunk, name: "Yarn cache",
        url: h.appendingPathComponent("Library/Caches/Yarn"), risk: .safe,
        reason: "Yarn cache data can be re-fetched."),
      .init(
        category: .developerJunk, name: "SwiftPM cache",
        url: h.appendingPathComponent("Library/Caches/org.swift.swiftpm"), risk: .safe,
        reason: "Swift Package Manager cache data can be rebuilt."),

      .init(
        category: .mailAttachments, name: "Mail attachments",
        url: h.appendingPathComponent("Library/Containers/com.apple.mail/Data/Library/Mail Downloads"),
        risk: .review,
        reason:
          "Copies of attachments you opened in Mail. IMAP and Exchange accounts can download them again; POP attachments may only exist here.",
        expandChildren: true, ownerBundleID: "com.apple.mail"),
      .init(
        category: .deviceFirmware, name: "iPhone software updates",
        url: h.appendingPathComponent("Library/iTunes/iPhone Software Updates"), risk: .safe,
        reason: "Firmware kept for restoring devices; Finder downloads the current version again when needed.",
        expandChildren: true),
      .init(
        category: .deviceFirmware, name: "iPad software updates",
        url: h.appendingPathComponent("Library/iTunes/iPad Software Updates"), risk: .safe,
        reason: "Firmware kept for restoring devices; Finder downloads the current version again when needed.",
        expandChildren: true),

      .init(
        category: .deviceBackups, name: "iPhone & iPad backups",
        url: h.appendingPathComponent("Library/Application Support/MobileSync/Backup"),
        risk: .review, reason: "Local device backups may be valuable. Review before removal.",
        expandChildren: true),

      .init(
        category: .installers, name: "Downloads installers",
        url: h.appendingPathComponent("Downloads"), risk: .restricted,
        reason:
          "Scanned for old installer/archive files only; the Downloads folder itself is never targeted."
      ),
    ]
  }
}
