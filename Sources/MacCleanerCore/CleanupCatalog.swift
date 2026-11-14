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
        // Apps write new logs, but removed logs don't come back: they can be the only record
        // of a crash or problem. Review, never a rebuildable default.
        url: h.appendingPathComponent("Library/Logs"), risk: .review,
        reason: "Past logs. Apps write new ones, but removed logs don't come back, and they can help explain a crash or problem.", expandChildren: true,
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
        reason: "Build artifacts Xcode regenerates; quit Xcode first.", ownerBundleID: "com.apple.dt.Xcode"),
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
        reason: "Simulator cache data is regenerated by CoreSimulator; quit Simulator first.", ownerBundleID: "com.apple.iphonesimulator"),
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
        reason: "Firmware kept for restoring a device (often 10 GB or more). It's downloaded again the next time you update or restore that device.",
        expandChildren: true),
      .init(
        category: .deviceFirmware, name: "iPad software updates",
        url: h.appendingPathComponent("Library/iTunes/iPad Software Updates"), risk: .safe,
        reason: "Firmware kept for restoring a device (often 10 GB or more). It's downloaded again the next time you update or restore that device.",
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
    ] + appCacheRules()
  }

  // MARK: App caches (Electron/Chromium apps that keep caches in Application Support)

  public static let vsCodeBundleID = "com.microsoft.VSCode"
  public static let webCatalogBundleID = "com.webcatalog.jordan"

  /// Chromium's disposable cache folders. Everything else in a profile (Cookies, Local Storage,
  /// IndexedDB, Session Storage, service workers, sign-ins) is someone's data.
  public static let chromiumCacheFolderNames: Set<String> = [
    "Cache", "Code Cache", "GPUCache", "DawnCache", "DawnGraphiteCache", "DawnWebGPUCache", "ShaderCache",
  ]
  /// Folders never searched into for caches: they hold site data and sign-ins.
  static let profileDataFolderNames: Set<String> = [
    "Cookies", "Local Storage", "IndexedDB", "Session Storage", "Service Worker", "databases",
    "Login Data", "Network", "WebStorage", "User", "Extensions", "blob_storage", "File System",
  ]

  func appCacheRules(applicationRoots: [URL]? = nil) -> [CleanupRule] {
    let h = homeDirectory
    var rules: [CleanupRule] = []

    // VS Code: its HTTP and GPU caches, compiled-code caches of versions no longer running (the
    // current version's is kept, as VS Code's own cleaner does), and downloaded extension
    // packages (installed extensions live in ~/.vscode/extensions and aren't touched).
    let code = h.appendingPathComponent("Library/Application Support/Code")
    if FileManager.default.fileExists(atPath: code.path) {
      for name in ["Cache", "Code Cache", "GPUCache"] {
        rules.append(.init(
          category: .appCaches, name: "VS Code \(name.lowercased())", url: code.appendingPathComponent(name), risk: .safe,
          reason: "VS Code recreates this cache. Settings, extensions and open workspaces are kept.",
          ownerBundleID: Self.vsCodeBundleID))
      }
      let commit = Self.vsCodeCommit(applicationRoots: applicationRoots ?? [
        URL(fileURLWithPath: "/Applications"), h.appendingPathComponent("Applications"),
      ])
      rules.append(.init(
        category: .appCaches, name: "VS Code code caches", url: code.appendingPathComponent("CachedData"),
        risk: commit == nil ? .review : .safe,
        reason: commit == nil
          ? "Compiled-code caches. MacMint couldn't tell which one the installed VS Code uses, so review them."
          : "Compiled-code caches from VS Code versions you no longer run. The current version's cache is kept.",
        expandChildren: true, excludedChildNames: commit.map { [$0] } ?? [], ownerBundleID: Self.vsCodeBundleID))
      rules.append(.init(
        category: .appCaches, name: "VS Code extension downloads", url: code.appendingPathComponent("CachedExtensionVSIXs"),
        risk: .safe,
        reason: "Downloaded extension packages. Installed extensions are kept; VS Code downloads a package again if it needs one.",
        ownerBundleID: Self.vsCodeBundleID))
    }

    // WebCatalog: each web app keeps a Chromium profile. Only its named cache folders are
    // offered, and as review: profile layouts differ between WebCatalog versions.
    let webCatalog = h.appendingPathComponent("Library/Application Support/WebCatalog")
    for folder in Self.cacheFolders(in: webCatalog, depth: 7) {
      let profile = folder.deletingLastPathComponent().lastPathComponent
      rules.append(.init(
        category: .appCaches, name: "WebCatalog \(profile) \(folder.lastPathComponent.lowercased())", url: folder, risk: .review,
        reason: "A web app's cache inside WebCatalog. Sign-ins, cookies and site data are kept. Review it because WebCatalog's folder layout varies between versions.",
        ownerBundleID: Self.webCatalogBundleID))
    }
    return rules
  }

  /// Chromium cache folders under `root`, without descending into profile data or into a cache
  /// once found. Symlinks are not followed.
  static func cacheFolders(in root: URL, depth: Int) -> [URL] {
    guard depth > 0,
      let entries = try? FileManager.default.contentsOfDirectory(
        at: root, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: [])
    else { return [] }
    var found: [URL] = []
    for entry in entries {
      let values = try? entry.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
      guard values?.isDirectory == true, values?.isSymbolicLink != true else { continue }
      let name = entry.lastPathComponent
      if chromiumCacheFolderNames.contains(name) { found.append(entry); continue }
      if profileDataFolderNames.contains(name) { continue }
      found += cacheFolders(in: entry, depth: depth - 1)
    }
    return found
  }

  /// The commit of the installed VS Code, whose code cache is the one in use.
  static func vsCodeCommit(applicationRoots: [URL]) -> String? {
    for root in applicationRoots {
      let product = root.appendingPathComponent("Visual Studio Code.app/Contents/Resources/app/product.json")
      guard let data = try? Data(contentsOf: product),
        let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
        let commit = json["commit"] as? String, !commit.isEmpty
      else { continue }
      return commit
    }
    return nil
  }
}
