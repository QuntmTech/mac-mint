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
    let launchd = await readLaunchd?()
    var items: [StartupItem] = []
    var issues: [ScanIssue] = []

    for (root, scope) in roots {
      if Task.isCancelled {
        return ScanReport(
          value: sort(items), issues: issues, duration: Date().timeIntervalSince(started),
          wasCancelled: true)
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
          let target = Self.resolveTarget(program: program, arguments: arguments) { [fileManager] path in
            fileManager.fileExists(atPath: path)
          }
          // Agents load into the user's session; daemons into the system domain, whose
          // jobs an unprivileged reader can't list.
          let domain = scope.contains("Daemon") ? launchd?.system : launchd?.user
          items.append(
            StartupItem(
              url: url,
              label: label,
              program: program,
              runAtLoad: runAtLoad,
              keepAlive: keepAlive,
              disabled: disabled,
              scope: scope,
              target: target.target,
              targetPath: target.path,
              disabledOverride: domain?.overrides[label],
              live: domain?.jobs.map { StartupLiveState(job: $0[label]) }
            ))
        }
      } catch {
        issues.append(
          ScanIssue(area: "Startup Items", path: root.path, message: error.localizedDescription))
      }
    }

    return ScanReport(
      value: sort(items), issues: issues, duration: Date().timeIntervalSince(started))
  }

  /// Programs that run another file or an inline command. The file they run is what has to exist.
  static let launchers: Set<String> = [
    "/bin/sh", "/bin/bash", "/bin/zsh", "/bin/dash", "/bin/ksh", "/bin/csh", "/bin/tcsh",
    "/usr/bin/env", "/usr/bin/open", "/usr/bin/osascript", "/usr/bin/python3", "/usr/bin/perl",
    "/usr/bin/ruby", "/usr/bin/arch", "/usr/bin/nice",
  ]

  /// Where a declared program points, without running it. `arguments` is ProgramArguments
  /// (argv, including argv[0]). An inline command (`sh -c`, `osascript -e`) or a name looked
  /// up on PATH is reported as unresolved rather than guessed.
  public static func resolveTarget(
    program: String?, arguments: [String], exists: (String) -> Bool
  ) -> (target: StartupTarget, path: String?) {
    guard var path = program, !path.isEmpty else { return (.unresolved, nil) }
    if launchers.contains(path) {
      let rest = arguments.dropFirst()
      if rest.contains("-c") || rest.contains("-e") { return (.unresolved, nil) }
      guard let file = rest.first(where: { $0.hasPrefix("/") }) else { return (.unresolved, nil) }
      path = file
    }
    guard path.hasPrefix("/") else { return (.unresolved, nil) }
    let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
    if [path, resolved].contains(where: { $0.contains("/.Trash/") || $0.contains("/.Trashes/") }) {
      return (.inTrash, path)
    }
    let components = URL(fileURLWithPath: path).standardizedFileURL.pathComponents
    if components.count > 2, components[1] == "Volumes" {
      let volume = "/Volumes/" + components[2]
      guard exists(volume) else { return (.volumeNotMounted, path) }
      return (exists(path) ? .otherVolume : .missing, path)
    }
    return (exists(path) ? .present : .missing, path)
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
