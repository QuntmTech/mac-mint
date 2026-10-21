import XCTest

@testable import MacCleanerCore

final class StartupItemStatusTests: XCTestCase {
  private let fm = FileManager.default

  private func resolve(_ program: String?, _ arguments: [String] = [], existing: Set<String> = [],
    mounted: Set<String> = [], aliases: Set<String> = [], unreadable: Set<String> = [],
    protected: [String] = []) -> (target: StartupTarget, path: String?) {
    StartupItemScanner.resolveTarget(program: program, arguments: arguments,
      volumes: .init(mounted: mounted, startupAliases: aliases), protectedFolders: protected) { path in
      unreadable.contains(path) ? nil : existing.contains(path)
    }
  }

  func testDeletedAppsTrashAndEjectedInstallerDisksAreBrokenTargets() {
    // A removed app (the Notion Calendar / One Switch / SideNotes style of entry).
    XCTAssertEqual(resolve("/Applications/SideNotes.app/Contents/MacOS/SideNotes").target, .missing)
    XCTAssertEqual(resolve("/Users/me/.Trash/Willow.app/Contents/MacOS/Willow",
      existing: ["/Users/me/.Trash/Willow.app/Contents/MacOS/Willow"]).target, .inTrash)
    // An agent registered from an installer disk image that was later ejected.
    let installer = resolve("/Volumes/Miller Installer/Miller.app/Contents/MacOS/Miller")
    XCTAssertEqual(installer.target, .volumeNotMounted)
    XCTAssertEqual(installer.path, "/Volumes/Miller Installer/Miller.app/Contents/MacOS/Miller")
    XCTAssertEqual(resolve("/Volumes/Work/Tool", mounted: ["/Volumes/Work"]).target, .otherVolume,
      "Another disk is never opened, so its files are not called missing")
    XCTAssertEqual(resolve("/Volumes/Work/Tool", existing: ["/Volumes/Work"]).target, .volumeNotMounted,
      "An empty mount-point folder left behind is not a connected disk")
    XCTAssertEqual(resolve("/Volumes/Macintosh HD/Applications/Gone.app/Contents/MacOS/Gone", aliases: ["/Volumes/Macintosh HD"]).target,
      .missing, "The startup disk's /Volumes name is the startup disk")
    XCTAssertEqual(resolve("/Volumes/Macintosh HD/usr/local/bin/agent", existing: ["/usr/local/bin/agent"],
      aliases: ["/Volumes/Macintosh HD"]).target, .present)
    XCTAssertEqual(resolve("/usr/local/bin/agent", existing: ["/usr/local/bin/agent"]).target, .present)
    XCTAssertTrue(StartupTarget.volumeNotMounted.isBroken)
    XCTAssertFalse(StartupTarget.otherVolume.isBroken)
    XCTAssertFalse(StartupTarget.unresolved.isBroken)
  }

  func testShellLaunchersCheckTheScriptAndNeverGuessInlineCommands() {
    let script = resolve("/bin/bash", ["/bin/bash", "-l", "/Users/me/bin/sync.sh"])
    XCTAssertEqual(script.target, .missing)
    XCTAssertEqual(script.path, "/Users/me/bin/sync.sh")
    XCTAssertEqual(resolve("/bin/sh", ["/bin/sh", "/opt/run.sh"], existing: ["/opt/run.sh"]).target, .present)
    XCTAssertEqual(resolve("/bin/sh", ["/bin/sh", "-c", "/Applications/Gone.app/run --flag"]).target, .unresolved)
    XCTAssertEqual(resolve("/bin/zsh", ["/bin/zsh", "-lc", "/Users/me/bin/sync.sh --quiet"]).target, .unresolved,
      "Combined shell options that include c run an inline command")
    XCTAssertEqual(resolve("/bin/bash", ["/bin/bash", "-e", "/opt/run.sh"], existing: ["/opt/run.sh"]).target, .present,
      "bash -e is errexit, not an inline command")
    XCTAssertEqual(resolve("/usr/bin/env", ["/usr/bin/env", "-S", "node server.js"]).target, .unresolved)
    XCTAssertEqual(resolve("/usr/bin/osascript", ["/usr/bin/osascript", "-e", "tell app \"X\""]).target, .unresolved)
    XCTAssertEqual(resolve("/usr/bin/env", ["/usr/bin/env", "node", "server.js"]).target, .unresolved)
    XCTAssertEqual(resolve("relative-tool").target, .unresolved)
    XCTAssertEqual(resolve("/Users/me/Documents/backup.sh", protected: ["/Users/me/Documents"]).target, .unresolved,
      "Privacy-protected folders are not checked during a scan")
    XCTAssertEqual(resolve("/opt/agent", unreadable: ["/opt/agent"]).target, .unresolved,
      "A file the system won't describe is not called missing")
    XCTAssertEqual(resolve(nil).target, .unresolved)
    XCTAssertEqual(resolve("").target, .unresolved)
  }

  func testLaunchctlListAndOverridesParse() {
    let list = "PID\tStatus\tLabel\n812\t0\tcom.logi.optionsplus.agent\n-\t78\tcom.epson.EventManager\n-\t0\tcom.paste.helper\n-\t-9\tcom.example.stopped\n"
    let jobs = LaunchdDomain.parseJobs(list)
    XCTAssertEqual(jobs.count, 4)
    XCTAssertEqual(jobs["com.logi.optionsplus.agent"], LaunchdDomain.Job(pid: 812, lastExitStatus: 0))
    XCTAssertEqual(StartupLiveState(job: jobs["com.logi.optionsplus.agent"]).kind, .running)
    XCTAssertEqual(StartupLiveState(job: jobs["com.epson.EventManager"]).kind, .failed)
    XCTAssertEqual(StartupLiveState(job: jobs["com.paste.helper"]).kind, .waiting, "An idle on-demand helper is not broken")
    XCTAssertEqual(StartupLiveState(job: jobs["com.example.stopped"]).kind, .waiting, "A signal stop is not an error exit")
    XCTAssertEqual(StartupLiveState(job: nil).kind, .notLoaded)

    let modern = """
      disabled services = {
      \t"com.epson.EventManager" => disabled
      \t"com.wispr.flow.helper" => enabled
      }

      login item associations = {
      \t"com.example.associated" => disabled
      }
      """
    XCTAssertEqual(LaunchdDomain.parseOverrides(modern), ["com.epson.EventManager": true, "com.wispr.flow.helper": false])
    let legacy = "disabled services = {\n\t\"com.example.old\" => true\n\t\"com.example.on\" => false\n}\n"
    XCTAssertEqual(LaunchdDomain.parseOverrides(legacy), ["com.example.old": true, "com.example.on": false])
  }

  func testScannerCombinesPlistTargetsAndLaunchdState() async throws {
    let folder = fm.temporaryDirectory.appendingPathComponent("startup-\(UUID().uuidString)")
    let agents = folder.appendingPathComponent("LaunchAgents")
    let daemons = folder.appendingPathComponent("LaunchDaemons")
    try fm.createDirectory(at: agents, withIntermediateDirectories: true)
    try fm.createDirectory(at: daemons, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: folder) }
    let tool = folder.appendingPathComponent("tool")
    try Data("#!/bin/sh\n".utf8).write(to: tool)

    func plist(_ folder: URL, _ label: String, _ values: [String: Any]) throws {
      var values = values
      values["Label"] = label
      let data = try PropertyListSerialization.data(fromPropertyList: values, format: .xml, options: 0)
      try data.write(to: folder.appendingPathComponent(label + ".plist"))
    }
    try plist(agents, "com.epson.EventManager", ["ProgramArguments": [tool.path], "RunAtLoad": true])
    try plist(agents, "com.sidenotes.helper", ["Program": "/Applications/SideNotes-\(UUID().uuidString).app/Contents/MacOS/Helper"])
    try plist(agents, "com.logi.agent", ["ProgramArguments": [tool.path], "KeepAlive": true])
    try plist(agents, "com.example.off", ["ProgramArguments": [tool.path], "Disabled": false])
    try plist(daemons, "com.example.daemon", ["ProgramArguments": [tool.path]])

    let snapshot = LaunchdSnapshot(
      user: LaunchdDomain(jobs: [
        "com.epson.EventManager": .init(pid: nil, lastExitStatus: 78),
        "com.logi.agent": .init(pid: 4242, lastExitStatus: 0),
      ], overrides: ["com.example.off": true]),
      system: LaunchdDomain(jobs: nil, overrides: [:]))
    let scanner = StartupItemScanner(
      homeDirectory: folder, roots: [(agents, "User LaunchAgent"), (daemons, "System LaunchDaemon")],
      launchd: { snapshot })
    let items = await scanner.scanReport().value
    let byLabel = Dictionary(uniqueKeysWithValues: items.map { ($0.label, $0) })

    let epson = try XCTUnwrap(byLabel["com.epson.EventManager"])
    XCTAssertEqual(epson.target, .present)
    XCTAssertEqual(epson.live?.kind, .failed)
    XCTAssertTrue(epson.needsAttention)

    let sidenotes = try XCTUnwrap(byLabel["com.sidenotes.helper"])
    XCTAssertEqual(sidenotes.target, .missing)
    XCTAssertEqual(sidenotes.live?.kind, .notLoaded)
    XCTAssertTrue(sidenotes.needsAttention)

    let logi = try XCTUnwrap(byLabel["com.logi.agent"])
    XCTAssertEqual(logi.live, StartupLiveState(kind: .running, pid: 4242, lastExitStatus: 0))
    XCTAssertFalse(logi.needsAttention)

    let off = try XCTUnwrap(byLabel["com.example.off"])
    XCTAssertTrue(off.isDisabled, "launchd's override wins over the plist's Disabled key")

    let daemon = try XCTUnwrap(byLabel["com.example.daemon"])
    XCTAssertNil(daemon.live, "System daemons' state is unknown to an unprivileged reader")
    XCTAssertFalse(daemon.needsAttention)

    let unread = await StartupItemScanner(homeDirectory: folder, roots: [(agents, "User LaunchAgent")])
      .scanReport().value
    XCTAssertTrue(unread.allSatisfy { $0.live == nil && $0.disabledOverride == nil }, "No reader, no claimed state")
  }
}
