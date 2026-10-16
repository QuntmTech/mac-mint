import Foundation

public actor StartupItemScanner {
  private let fileManager: FileManager
  private let homeDirectory: URL

  public init(fileManager: FileManager = .default, homeDirectory: URL? = nil) {
    self.fileManager = fileManager
    self.homeDirectory = homeDirectory ?? fileManager.homeDirectoryForCurrentUser
  }

  public func scan() async -> [StartupItem] {
    await scanReport().value
  }

  public func scanReport() async -> ScanReport<[StartupItem]> {
    let started = Date()
    let roots: [(URL, String)] = [
      (homeDirectory.appendingPathComponent("Library/LaunchAgents"), "User LaunchAgent"),
      (URL(fileURLWithPath: "/Library/LaunchAgents"), "System LaunchAgent"),
      (URL(fileURLWithPath: "/Library/LaunchDaemons"), "System LaunchDaemon"),
    ]
    var items: [StartupItem] = []
    var issues: [ScanIssue] = []

    for (root, scope) in roots {
      if Task.isCancelled {
        return ScanReport(
          value: sort(items), issues: issues, duration: Date().timeIntervalSince(started),
          wasCancelled: true)
      }
      guard fileManager.fileExists(atPath: root.path) else { continue }
      do {
        let entries = try fileManager.contentsOfDirectory(
          at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
        for url in entries where url.pathExtension.lowercased() == "plist" {
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
          let program =
            (plist["Program"] as? String) ?? (plist["ProgramArguments"] as? [String])?.first
          let runAtLoad = (plist["RunAtLoad"] as? Bool) ?? false
          let keepAlive = parseBooleanish(plist["KeepAlive"])
          let disabled = (plist["Disabled"] as? Bool) ?? false
          items.append(
            StartupItem(
              url: url,
              label: label,
              program: program,
              runAtLoad: runAtLoad,
              keepAlive: keepAlive,
              disabled: disabled,
              scope: scope
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

  private func parseBooleanish(_ value: Any?) -> Bool {
    if let bool = value as? Bool { return bool }
    if let dict = value as? [String: Any] { return !dict.isEmpty }
    return false
  }

  private func sort(_ items: [StartupItem]) -> [StartupItem] {
    items.sorted { $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending }
  }
}
