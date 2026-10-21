import Foundation

public actor StartupItemScanner {
  public typealias LaunchdReader = @Sendable () async -> LaunchdSnapshot?
  private let fileManager: FileManager
  private let homeDirectory: URL
  private let roots: [(URL, String)]?
  private let readLaunchd: LaunchdReader?

  /// `launchd` supplies live job state and overrides; without it, items report only what their
  /// property lists declare and whether their programs exist.
  public init(
    fileManager: FileManager = .default, homeDirectory: URL? = nil, roots: [(URL, String)]? = nil,
    launchd: LaunchdReader? = nil
  ) {
    self.fileManager = fileManager
    self.homeDirectory = homeDirectory ?? fileManager.homeDirectoryForCurrentUser
    self.roots = roots
    self.readLaunchd = launchd
  }

  public func scan() async -> [StartupItem] {
    await scanReport().value
  }

  public func scanReport(ignoredPaths: Set<String> = []) async -> ScanReport<[StartupItem]> {
    let started = Date()
    let roots: [(URL, String)] = self.roots ?? [
      (homeDirectory.appendingPathComponent("Library/LaunchAgents"), "User LaunchAgent"),
      (URL(fileURLWithPath: "/Library/LaunchAgents"), "System LaunchAgent"),
      (URL(fileURLWithPath: "/Library/LaunchDaemons"), "System LaunchDaemon"),
    ]
    // launchd is asked while the property lists are read, not before.
    let reader = readLaunchd
    async let launchdState: LaunchdSnapshot? = reader?()
    let volumes = Self.volumes(fileManager)
    let protectedFolders = Self.protectedFolders(home: homeDirectory)
    var parsed: [Parsed] = []
    var items: [StartupItem] = []
    var issues: [ScanIssue] = []

    for (root, scope) in roots {
      if Task.isCancelled {
        return ScanReport(
          value: sort(parsed.map { $0.item(launchd: nil) }), issues: issues,
          duration: Date().timeIntervalSince(started), wasCancelled: true)
      }
      guard !FileSystem.isIgnored(root, ignoredPaths: ignoredPaths), fileManager.fileExists(atPath: root.path) else { continue }
      do {
        let entries = try fileManager.contentsOfDirectory(
          at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
        for url in entries where url.pathExtension.lowercased() == "plist" {
          if FileSystem.isIgnored(url, ignoredPaths: ignoredPaths) { continue }
          guard let data = try? Data(contentsOf: url),
            let object = try? PropertyListSerialization.propertyList(
              from: data, options: [], format: nil),
            let plist = object as? [String: Any]
          else {
            issues.append(
              ScanIssue(
                area: "Startup Items", path: url.path, severity: .info,
                message: "Could not parse launch item property list."))
            continue
          }
          let label = (plist["Label"] as? String) ?? url.deletingPathExtension().lastPathComponent
          let arguments = (plist["ProgramArguments"] as? [String]) ?? []
          let program = (plist["Program"] as? String) ?? arguments.first
          let runAtLoad = (plist["RunAtLoad"] as? Bool) ?? false
          let keepAlive = parseBooleanish(plist["KeepAlive"])
          let disabled = (plist["Disabled"] as? Bool) ?? false
          let target = Self.resolveTarget(program: program, arguments: arguments, volumes: volumes,
            protectedFolders: protectedFolders, exists: Self.fileExists)
          parsed.append(Parsed(url: url, label: label, program: program, runAtLoad: runAtLoad,
            keepAlive: keepAlive, disabled: disabled, scope: scope, target: target))
        }
      } catch {
        issues.append(
          ScanIssue(area: "Startup Items", path: root.path, message: error.localizedDescription))
      }
    }

    let launchd = await launchdState
    items = parsed.map { $0.item(launchd: launchd) }
    return ScanReport(
      value: sort(items), issues: issues, duration: Date().timeIntervalSince(started))
  }

  /// A property list read during the scan, joined with launchd's state afterwards.
  private struct Parsed {
    let url: URL
    let label: String
    let program: String?
    let runAtLoad: Bool
    let keepAlive: Bool
    let disabled: Bool
    let scope: String
    let target: (target: StartupTarget, path: String?)

    func item(launchd: LaunchdSnapshot?) -> StartupItem {
      // Agents load into the user's session; daemons into the system domain, whose
      // jobs an unprivileged reader can't list.
      let domain = scope.contains("Daemon") ? launchd?.system : launchd?.user
      return StartupItem(
        url: url, label: label, program: program, runAtLoad: runAtLoad, keepAlive: keepAlive,
        disabled: disabled, scope: scope, target: target.target, targetPath: target.path,
        disabledOverride: domain?.overrides[label],
        live: domain?.jobs.map { StartupLiveState(job: $0[label]) })
    }
  }

  /// Connected volumes, and names in /Volumes that point back at the startup disk.
  public struct Volumes: Sendable {
    public var mounted: Set<String>
    public var startupAliases: Set<String>

    public init(mounted: Set<String> = [], startupAliases: Set<String> = []) {
      self.mounted = mounted
      self.startupAliases = startupAliases
    }
  }

  /// Read from the mount table and /Volumes itself, never from inside another disk.
  static func volumes(_ fileManager: FileManager) -> Volumes {
    let mounted = (fileManager.mountedVolumeURLs(includingResourceValuesForKeys: nil, options: []) ?? [])
      .map { $0.standardizedFileURL.path }
    let aliases = ((try? fileManager.contentsOfDirectory(atPath: "/Volumes")) ?? []).map { "/Volumes/" + $0 }
      .filter { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path == "/" }
    return Volumes(mounted: Set(mounted), startupAliases: Set(aliases))
  }

  /// Privacy-protected folders. Checking a file there could ask the person for access in the
  /// middle of a scan, so programs there are left unresolved instead.
  static func protectedFolders(home: URL) -> [String] {
    ["Desktop", "Documents", "Downloads", "Pictures", "Movies", "Music", "Library/Mobile Documents",
      "Library/CloudStorage"].map { home.appendingPathComponent($0).standardizedFileURL.path }
  }

  /// True or false when the file system answers; nil when it refuses (for example, no access).
  static func fileExists(_ path: String) -> Bool? {
    var info = stat()
    if stat(path, &info) == 0 { return true }
    return errno == ENOENT || errno == ENOTDIR ? false : nil
  }

  /// Programs that run another file or an inline command, with the option letters that make
  /// them run an inline command (`zsh -lc "…"`, `osascript -e "…"`). The file they run is
  /// what has to exist.
  static let launchers: [String: Set<Character>] = [
    "/bin/sh": ["c"], "/bin/bash": ["c"], "/bin/zsh": ["c"], "/bin/dash": ["c"], "/bin/ksh": ["c"],
    "/bin/csh": ["c"], "/bin/tcsh": ["c"], "/usr/bin/python3": ["c"], "/usr/bin/perl": ["e", "E"],
    "/usr/bin/ruby": ["e"], "/usr/bin/osascript": ["e"], "/usr/bin/env": ["S"],
    "/usr/bin/open": [], "/usr/bin/arch": [], "/usr/bin/nice": [],
  ]

  /// Where a declared program points, without running it. `arguments` is ProgramArguments
  /// (argv, including argv[0]). An inline command, a name looked up on PATH, a file in a
  /// privacy-protected folder or a file the system won't describe is reported as unresolved
  /// rather than guessed. Files on other disks are never opened.
  public static func resolveTarget(
    program: String?, arguments: [String], volumes: Volumes = Volumes(), protectedFolders: [String] = [],
    exists: (String) -> Bool?
  ) -> (target: StartupTarget, path: String?) {
    guard var path = program, !path.isEmpty else { return (.unresolved, nil) }
    if let inline = launchers[path] {
      var file: String?
      for argument in arguments.dropFirst() {
        if argument.count > 1, argument.hasPrefix("-") {
          if !argument.hasPrefix("--"), argument.dropFirst().contains(where: inline.contains) { return (.unresolved, nil) }
          continue
        }
        file = argument
        break
      }
      guard let file else { return (.unresolved, nil) }
      path = file
    }
    guard path.hasPrefix("/") else { return (.unresolved, nil) }
    func inTrash(_ value: String) -> Bool { value.contains("/.Trash/") || value.contains("/.Trashes/") }
    if inTrash(path) { return (.inTrash, path) }
    // Nothing below touches another disk or a privacy-protected folder.
    var components = URL(fileURLWithPath: path).standardizedFileURL.pathComponents
    if components.count > 2, components[1] == "Volumes" {
      let volume = "/Volumes/" + components[2]
      if volumes.startupAliases.contains(volume) {
        components = ["/"] + components.dropFirst(3)  // "/Volumes/Macintosh HD/…" is the startup disk.
      } else {
        return (volumes.mounted.contains(volume) ? .otherVolume : .volumeNotMounted, path)
      }
    }
    let local = components.count > 1 ? "/" + components.dropFirst().joined(separator: "/") : "/"
    if protectedFolders.contains(where: { local == $0 || local.hasPrefix($0 + "/") }) { return (.unresolved, path) }
    if inTrash(URL(fileURLWithPath: local).resolvingSymlinksInPath().path) { return (.inTrash, path) }
    switch exists(local) {
    case true?: return (.present, path)
    case false?: return (.missing, path)
    case nil: return (.unresolved, path)
    }
  }

  private func parseBooleanish(_ value: Any?) -> Bool {
    if let bool = value as? Bool { return bool }
    if let dict = value as? [String: Any] { return !dict.isEmpty }
    return false
  }

  private func sort(_ items: [StartupItem]) -> [StartupItem] {
    items.sorted { $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending }
  }
}
