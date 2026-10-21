// External regression probe for the real packaged application lifecycle.
// This launches the full SwiftUI App (including MenuBarExtra), never --smoke-test.
// Intended for the disposable graphical macOS CI runner; it never resets app data.
//
// MACMINT_RESOURCE_SCENARIOS=1 adds realistic resource scenarios with budgets:
//   (a) Overview idle, (b) live Performance view, (c) the same app hidden in the background,
//   (d) a heavy session that maps ~80k generated files and scans 300 generated photos.
// Those launches pass `--resource-probe <temporary folder>`, so the app keeps its support
// data there; the heavy session only reads the generated fixtures.
// MACMINT_RESOURCE_BUDGETS=report prints the budgets without enforcing them.
// MACMINT_PROBE_PROFILE=1 adds best-effort sample/heap/footprint diagnostics.
import AppKit
import CoreGraphics
import Darwin
import Foundation
import ImageIO
import UniformTypeIdentifiers

private struct ProbeFailure: Error, CustomStringConvertible {
  let description: String
}

// NSWorkspace may call its completion off the main thread. Only this locked mailbox
// crosses that boundary; AppKit properties are inspected on the main actor below.
private final class LaunchMailbox: @unchecked Sendable {
  private let lock = NSLock()
  private var app: NSRunningApplication?
  private var error: Error?
  private var completed = false

  func complete(app: NSRunningApplication?, error: Error?) {
    lock.lock()
    defer { lock.unlock() }
    self.app = app
    self.error = error
    completed = true
  }

  func snapshot() -> (app: NSRunningApplication?, error: Error?, completed: Bool) {
    lock.lock()
    defer { lock.unlock() }
    return (app, error, completed)
  }
}

private struct Target {
  let appURL: URL
  let identifier: String
}

private struct LaunchOptions {
  var label: String
  var menuBarInserted = false
  var onboardingDone = true
  var activates = true
  var extraArguments: [String] = []
  /// Resource scenarios start from the default window, not one restored from a previous run,
  /// and reopen the instance if a launch finishes without one.
  var ignoresSavedState = false
}

private struct CPUWindow {
  /// Cores (1.0 = one whole core), from cumulative CPU counter deltas.
  let average: Double
  /// The busiest one-second interval inside the window.
  let peak: Double
  let seconds: Double
  /// Each one-second interval in order (report-only trace), and the system uptime at the start.
  var perSecond: [Double] = []
  var startedAt: TimeInterval = 0
}

/// The app's timed memory releases (`trace-<event>.json`), for report-only attribution.
private struct ReleaseTrace: Decodable {
  struct Release: Decodable {
    let reason: String
    let at: TimeInterval
    let purgeMS: Double
    let compactMS: Double
    let relieveMS: Double
    let freed: Bool
  }
  let uptime: TimeInterval
  let releases: [Release]
}

private struct Footprint {
  let currentMiB: Double
  let lifetimePeakMiB: Double
}

@main
private struct NativeStartupTest {
  // Ordinary hidden launches (onboarding showing, menu bar off/on): eight seconds of
  // settling precede a ten-second cumulative CPU measurement. They measured 0.1-0.5% of a
  // core; 2% leaves room for the end of launch work while still catching a busy loop.
  // The resource scenarios below carry the detailed budgets.
  private static let settleSeconds: TimeInterval = 8
  private static let sampleSeconds: TimeInterval = 10
  private static let maximumAverageCores = 0.02

  @MainActor
  static func main() {
    _ = NSApplication.shared
    NSApplication.shared.setActivationPolicy(.prohibited)
    // Keep an event source alive while pumping the main run loop. NSWorkspace's
    // launch completion / running-application state updates need it serviced.
    let tick = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in }
    defer { tick.invalidate() }
    do {
      guard CommandLine.arguments.count == 2 else {
        throw ProbeFailure(description: "Usage: native-startup-test /path/to/MacMint.app")
      }
      let appURL = URL(fileURLWithPath: CommandLine.arguments[1]).resolvingSymlinksInPath().standardizedFileURL
      guard let bundle = Bundle(url: appURL), let identifier = bundle.bundleIdentifier,
        let executable = bundle.executableURL,
        FileManager.default.isExecutableFile(atPath: executable.path)
      else { throw ProbeFailure(description: "The input must be a packaged executable MacMint.app.") }
      // Refuse any existing instance, including another copy with shared preferences.
      // No already-running application is ever terminated by this probe.
      guard !NSWorkspace.shared.runningApplications.contains(where: { $0.bundleIdentifier == identifier }) else {
        throw ProbeFailure(description: "An instance of \(identifier) is already running; refusing to interfere.")
      }
      guard CGWindowListCopyWindowInfo(.optionAll, kCGNullWindowID) != nil else {
        throw ProbeFailure(description: "A graphical WindowServer session is required for the native startup probe.")
      }
      log("Operating system: \(ProcessInfo.processInfo.operatingSystemVersionString)")
      let target = Target(appURL: appURL, identifier: identifier)
      for inserted in [false, true] {
        try check(target, menuBarInserted: inserted)
      }
      if ProcessInfo.processInfo.environment["MACMINT_RESOURCE_SCENARIOS"] == "1" {
        try runResourceScenarios(target)
      } else {
        try check(target, menuBarInserted: false, performance: true)
      }
      log("PASS: ordinary launches with menu bar off/on finished, created a main window, stayed within their CPU limits, and quit normally.")
    } catch {
      FileHandle.standardError.write(Data("FAIL: \(error)\n".utf8))
      exit(EXIT_FAILURE)
    }
  }

  @MainActor
  private static func check(_ target: Target, menuBarInserted: Bool, performance: Bool = false) throws {
    let label = performance ? "live Performance view" : "menu bar \(menuBarInserted ? "on" : "off")"
    let options = LaunchOptions(label: label, menuBarInserted: menuBarInserted, onboardingDone: performance,
      activates: performance, extraArguments: performance ? ["--performance"] : [])
    try withLaunchedApp(target, options) { app in
      try settle(app, label: label, seconds: settleSeconds)
      let cpu = try measureCPU(app, label: label, seconds: sampleSeconds)
      let memory = try footprint(app.processIdentifier)
      log(String(format: "%@: settled physical footprint %.1f MiB", label, memory.currentMiB))
      log(String(format: "%@: idle CPU %.2f%% of one core over %.1fs (limit %.1f%%)", label, cpu.average * 100,
        cpu.seconds, maximumAverageCores * 100))
      guard cpu.average <= maximumAverageCores else {
        throw ProbeFailure(description: "\(label): idle CPU after launch is above budget (a feedback loop or polling).")
      }
    }
  }

  /// Launches one new, marker-verified instance, runs `body`, then requires a normal Quit.
  /// Cleanup only ever terminates the exact process carrying this launch's marker.
  @MainActor
  private static func withLaunchedApp(_ target: Target, _ options: LaunchOptions,
    _ body: (NSRunningApplication) throws -> Void) throws {
    let label = options.label
    let appURL = target.appURL
    let marker = UUID().uuidString
    let mailbox = LaunchMailbox()
    var ownedApp: NSRunningApplication?
    // A startup feedback loop may prevent NSWorkspace's completion from arriving.
    // The inert UUID argument lets cleanup identify only this exact new process.
    defer {
      let candidate = ownedApp ?? findOwnedApp(appURL: appURL, marker: marker)
      if let candidate, !candidate.isTerminated, hasMarker(candidate.processIdentifier, marker: marker) {
        _ = candidate.terminate()
        if !waitUntil(seconds: 3, { candidate.isTerminated }) {
          log("Cleanup: force-terminating only probe PID \(candidate.processIdentifier) after its Quit timeout.")
          _ = candidate.forceTerminate()
          _ = waitUntil(seconds: 5, { candidate.isTerminated })
        }
      }
    }
    let configuration = NSWorkspace.OpenConfiguration()
    configuration.activates = options.activates
    configuration.hides = !options.activates
    configuration.hidesOthers = false
    configuration.addsToRecentItems = false
    configuration.createsNewApplicationInstance = true
    configuration.allowsRunningApplicationSubstitution = false
    configuration.promptsUserIfNeeded = false
    // NSArgumentDomain overrides only this process's defaults. No `defaults write`,
    // HOME substitution or user-data cleanup is used. Resource scenarios also pass
    // `--resource-probe`, which keeps the app's support files in a temporary folder.
    configuration.arguments = (options.ignoresSavedState ? ["-ApplePersistenceIgnoreState", "YES"] : []) + [
      "-care.showMenuBar", options.menuBarInserted ? "YES" : "NO",
      "-care.onboardingDone", options.onboardingDone ? "YES" : "NO",
      "-care.lowSpaceAlerts", "NO",
      "-care.scanReminders", "NO",
      "-MacMintNativeStartupProbeID", marker,
    ] + options.extraArguments
    log("Launching ordinary app: \(label)")
    // AppKit calls this completion on its own queue. An unannotated closure in
    // this MainActor method can inherit actor isolation and trap before it reaches
    // the mailbox. This callback must only hand off the result through the lock.
    let completion: @Sendable (NSRunningApplication?, Error?) -> Void = { app, error in
      mailbox.complete(app: app, error: error)
    }
    NSWorkspace.shared.openApplication(at: appURL, configuration: configuration, completionHandler: completion)
    let discovered = waitUntil(seconds: 30) {
      let result = mailbox.snapshot()
      if result.error != nil { return true }
      if let app = result.app, matches(app, appURL: appURL), hasMarker(app.processIdentifier, marker: marker) {
        ownedApp = app
      } else if ownedApp == nil {
        ownedApp = findOwnedApp(appURL: appURL, marker: marker)
      }
      return ownedApp != nil
    }
    if let error = mailbox.snapshot().error {
      throw ProbeFailure(description: "\(label): NSWorkspace launch failed: \(error.localizedDescription)")
    }
    guard discovered, let app = ownedApp, app.bundleIdentifier == target.identifier else {
      throw ProbeFailure(description: "\(label): launch did not yield its own application process within 30 seconds.")
    }
    let pid = app.processIdentifier
    try recordOwnedApp(pid: pid, appURL: appURL, marker: marker)
    guard waitUntil(seconds: 30, { app.isFinishedLaunching || app.isTerminated }), !app.isTerminated,
      app.isFinishedLaunching
    else { throw ProbeFailure(description: "\(label): PID \(pid) did not finish ordinary AppKit launch.") }
    log("\(label): PID \(pid) finished launching")
    if options.ignoresSavedState, !waitUntil(seconds: 8, { app.isTerminated || hasMainWindow(pid) }), !app.isTerminated {
      // Some consecutive activated launches on CI runners finish without a workspace window.
      // Reopen the same instance, as clicking its Dock icon does, and say so in the log.
      logWindows(pid, label: label)
      log("\(label): no workspace window after 8 s; sending a Dock-style reopen to PID \(pid)")
      let reopen = NSWorkspace.OpenConfiguration()
      reopen.activates = true
      reopen.addsToRecentItems = false
      reopen.createsNewApplicationInstance = false
      reopen.promptsUserIfNeeded = false
      let ignore: @Sendable (NSRunningApplication?, Error?) -> Void = { _, _ in }
      NSWorkspace.shared.openApplication(at: appURL, configuration: reopen, completionHandler: ignore)
    }
    guard waitUntil(seconds: 20, { app.isTerminated || hasMainWindow(pid) }), !app.isTerminated,
      hasMainWindow(pid)
    else {
      if app.isTerminated {
        throw ProbeFailure(description: "\(label): PID \(pid) exited before its normal main window appeared.")
      }
      logWindows(pid, label: label)
      if ProcessInfo.processInfo.environment["MACMINT_PROBE_PROFILE"] == "1" { profileCPU(app, name: "no-window") }
      throw ProbeFailure(description: "\(label): no normal main-window bounds appeared for PID \(pid).")
    }
    log("\(label): normal-layer main window exists (no title, AX, or pixel capture required)")
    try body(app)
    guard !app.isTerminated, app.terminate() else {
      throw ProbeFailure(description: "\(label): normal Quit request was not accepted.")
    }
    guard waitUntil(seconds: 12, { app.isTerminated }) else {
      throw ProbeFailure(description: "\(label): PID \(pid) did not exit within 12 seconds of normal Quit.")
    }
    log("\(label): normal Quit completed")
    // Let activation pass to another app before the next launch asks for it.
    _ = waitUntil(seconds: 2) { false }
  }

  @MainActor
  private static func settle(_ app: NSRunningApplication, label: String, seconds: TimeInterval) throws {
    guard !waitUntil(seconds: seconds, { app.isTerminated }) else {
      throw ProbeFailure(description: "\(label): process exited while settling.")
    }
  }

  /// Cumulative CPU over the whole window, plus the busiest one-second interval.
  @MainActor
  private static func measureCPU(_ app: NSRunningApplication, label: String, seconds: TimeInterval) throws -> CPUWindow {
    let pid = app.processIdentifier
    let firstCPU = try cpuTicks(pid), firstTime = mach_absolute_time()
    var lastCPU = firstCPU, lastTime = firstTime, peak = 0.0
    var perSecond: [Double] = []
    let start = ProcessInfo.processInfo.systemUptime
    while ProcessInfo.processInfo.systemUptime - start < seconds {
      guard !waitUntil(seconds: 1, { app.isTerminated }) else {
        throw ProbeFailure(description: "\(label): process exited during the CPU sample.")
      }
      let cpu = try cpuTicks(pid), time = mach_absolute_time()
      guard cpu >= lastCPU, time > lastTime else { throw ProbeFailure(description: "\(label): invalid cumulative CPU sample.") }
      // XNU rusage CPU counters use Mach absolute ticks, not nanoseconds on ARM.
      // Compare deltas in the same timebase, as the production sampler does.
      let interval = Double(cpu - lastCPU) / Double(time - lastTime)
      peak = max(peak, interval); perSecond.append(interval)
      lastCPU = cpu; lastTime = time
    }
    return CPUWindow(average: Double(lastCPU - firstCPU) / Double(lastTime - firstTime), peak: peak,
      seconds: ProcessInfo.processInfo.systemUptime - start, perSecond: perSecond, startedAt: start)
  }

  /// Record only an app whose exact bundle and inert launch marker were verified
  /// above. The failure collector uses PID + executable path to reject other apps.
  private static func recordOwnedApp(pid: pid_t, appURL: URL, marker: String) throws {
    guard let folder = ProcessInfo.processInfo.environment["MACMINT_NATIVE_STARTUP_DIAGNOSTICS"] else { return }
    let url = URL(fileURLWithPath: folder).appendingPathComponent("native-startup-test-owned-apps.jsonl")
    let record: [String: Any] = ["pid": Int(pid), "marker": marker,
      "executablePath": appURL.appendingPathComponent("Contents/MacOS/MacMint").path]
    var data = (try? Data(contentsOf: url)) ?? Data()
    data.append(try JSONSerialization.data(withJSONObject: record))
    data.append(0x0a)
    try data.write(to: url, options: .atomic)
  }

  @MainActor
  private static func waitUntil(seconds: TimeInterval, _ condition: () -> Bool) -> Bool {
    let deadline = ProcessInfo.processInfo.systemUptime + seconds
    repeat {
      if condition() { return true }
      _ = RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.1))
    } while ProcessInfo.processInfo.systemUptime < deadline
    return condition()
  }

  @MainActor
  private static func matches(_ app: NSRunningApplication, appURL: URL) -> Bool {
    guard app.processIdentifier != getpid(), let bundleURL = app.bundleURL else { return false }
    return bundleURL.resolvingSymlinksInPath().standardizedFileURL == appURL
  }

  @MainActor
  private static func findOwnedApp(appURL: URL, marker: String) -> NSRunningApplication? {
    NSWorkspace.shared.runningApplications.first {
      matches($0, appURL: appURL) && hasMarker($0.processIdentifier, marker: marker)
    }
  }

  private static func hasMarker(_ pid: pid_t, marker: String) -> Bool {
    let command = Process()
    let output = Pipe()
    command.executableURL = URL(fileURLWithPath: "/bin/ps")
    command.arguments = ["-ww", "-p", String(pid), "-o", "command="]
    command.standardOutput = output
    command.standardError = FileHandle.nullDevice
    do { try command.run() } catch { return false }
    let bytes = output.fileHandleForReading.readDataToEndOfFile()
    command.waitUntilExit()
    return command.terminationStatus == 0 && String(decoding: bytes, as: UTF8.self).contains(marker)
  }

  private static func logWindows(_ pid: pid_t, label: String) {
    let windows = (CGWindowListCopyWindowInfo(.optionAll, kCGNullWindowID) as? [[String: Any]]) ?? []
    let owned = windows.filter { ($0[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid }
    log("\(label): \(owned.count) window(s) for PID \(pid); active=\(NSRunningApplication(processIdentifier: pid)?.isActive ?? false)")
    for window in owned {
      log("\(label):   layer=\(window[kCGWindowLayer as String] ?? "?") onscreen=\(window[kCGWindowIsOnscreen as String] ?? "?") bounds=\(window[kCGWindowBounds as String] ?? "?")")
    }
  }

  private static func hasMainWindow(_ pid: pid_t) -> Bool {
    // Hidden launches can have offscreen windows. Required bounds/PID/layer metadata
    // remains useful even when macOS redacts another process's window title.
    guard let windows = CGWindowListCopyWindowInfo(.optionAll, kCGNullWindowID) as? [[String: Any]] else { return false }
    return windows.contains { window in
      guard let owner = window[kCGWindowOwnerPID as String] as? NSNumber, owner.int32Value == pid,
        let layer = window[kCGWindowLayer as String] as? NSNumber, layer.intValue == 0,
        let bounds = window[kCGWindowBounds as String] as? [String: Any],
        let width = bounds["Width"] as? NSNumber, let height = bounds["Height"] as? NSNumber
      else { return false }
      return width.doubleValue >= 600 && height.doubleValue >= 400
    }
  }

  private static func rusage(_ pid: pid_t) throws -> rusage_info_v4 {
    var usage = rusage_info_v4()
    let result = withUnsafeMutablePointer(to: &usage) { pointer in
      pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
        proc_pid_rusage(pid, RUSAGE_INFO_V4, $0)
      }
    }
    guard result == 0 else { throw ProbeFailure(description: "Could not read resource usage for probe PID \(pid).") }
    return usage
  }

  private static func cpuTicks(_ pid: pid_t) throws -> UInt64 {
    let usage = try rusage(pid)
    let (total, overflow) = usage.ri_user_time.addingReportingOverflow(usage.ri_system_time)
    guard !overflow else { throw ProbeFailure(description: "Cumulative CPU counter overflowed for probe PID \(pid).") }
    return total
  }

  /// `ri_phys_footprint` is the kernel's task_vm_info phys_footprint (Activity Monitor's Memory).
  private static func footprint(_ pid: pid_t) throws -> Footprint {
    let usage = try rusage(pid)
    return Footprint(currentMiB: Double(usage.ri_phys_footprint) / 1_048_576,
      lifetimePeakMiB: Double(usage.ri_lifetime_max_phys_footprint) / 1_048_576)
  }

  private static func log(_ message: String) {
    FileHandle.standardOutput.write(Data((message + "\n").utf8))
  }
}

// MARK: - Resource scenarios

/// Calibrated from macOS 15 and 26 CI runs after the efficiency work (see docs/PERFORMANCE_UX.md).
private struct ResourceBudgets {
  // Percent of one core, averaged over the measured window. Measured: Overview 0.01-0.05%,
  // live Performance 0.59-0.92%, hidden 0.03-0.13%.
  static let overviewIdleCPU = 0.5
  static let performanceCPU = 2.0
  static let backgroundCPU = 0.2
  // MiB of phys_footprint. Measured 53-66 MiB settled (150-158 MiB before) and +17 to +28 MiB
  // over a fresh launch once hidden: the rest is framework state from the screens used and
  // allocator pages macOS keeps (xzone malloc on macOS 26), not MacMint caches.
  static let heavySettledFootprint: Double? = 85
  static let backgroundReleaseOverFresh: Double? = 35
  /// A live Performance view must actually sample (about every 4 s); hidden apps must not.
  static let minimumLiveSamples = 5.0
}

private struct ResourceReport {
  struct Row: Codable {
    let scenario: String
    let metric: String
    let value: Double
    let unit: String
    let limit: Double?
    var minimum: Double? = nil
    var exceeded: Bool { (limit.map { value > $0 } ?? false) || (minimum.map { value < $0 } ?? false) }
    var budget: String? {
      if let limit { return "≤ " + ResourceReport.format(limit, unit) }
      return minimum.map { "≥ " + ResourceReport.format($0, unit) }
    }
  }
  private(set) var rows: [Row] = []

  mutating func cpu(_ scenario: String, _ window: CPUWindow, limit: Double?) {
    rows.append(Row(scenario: scenario, metric: String(format: "CPU average (%.0f s)", window.seconds),
      value: window.average * 100, unit: "%", limit: limit))
    rows.append(Row(scenario: scenario, metric: "CPU busiest 1 s", value: window.peak * 100, unit: "%", limit: nil))
  }

  mutating func system(_ scenario: String, _ observed: [(name: String, percent: Double)]) {
    for item in observed where item.percent >= 0.05 || item.name == "Finder" {
      rows.append(Row(scenario: scenario, metric: "system: \(item.name) CPU", value: item.percent, unit: "%", limit: nil))
    }
  }

  mutating func memory(_ scenario: String, _ metric: String, _ value: Double, limit: Double? = nil) {
    rows.append(Row(scenario: scenario, metric: metric, value: value, unit: "MiB", limit: limit))
  }

  static func format(_ value: Double, _ unit: String) -> String {
    switch unit {
    case "%": return String(format: "%.2f%%", value)
    case "MiB": return String(format: "%.1f MiB", value)
    default: return String(format: "%.0f", value)
    }
  }

  /// Sample counts the app records at hide and quit (`samples-*.json`), when it reports them.
  mutating func samples(_ scenario: String, _ metric: String, _ value: Int?, limit: Double? = nil, minimum: Double? = nil) {
    guard let value else {
      // A gated count the app didn't report fails rather than passing silently.
      if limit != nil || minimum != nil {
        rows.append(Row(scenario: scenario, metric: metric + " (not reported)", value: -1, unit: "count", limit: nil, minimum: 0))
      }
      return
    }
    rows.append(Row(scenario: scenario, metric: metric, value: Double(value), unit: "count", limit: limit, minimum: minimum))
  }

  var lines: [String] {
    let header = "RESOURCE " + "scenario".padding(toLength: 30, withPad: " ", startingAt: 0)
      + "metric".padding(toLength: 34, withPad: " ", startingAt: 0) + "value".padding(toLength: 13, withPad: " ", startingAt: 0) + "budget"
    return [header] + rows.map { row in
      "RESOURCE " + row.scenario.padding(toLength: 30, withPad: " ", startingAt: 0)
        + row.metric.padding(toLength: 34, withPad: " ", startingAt: 0)
        + Self.format(row.value, row.unit).padding(toLength: 13, withPad: " ", startingAt: 0)
        + (row.budget.map { $0 + (row.exceeded ? "  EXCEEDED" : "") } ?? "—")
    }
  }

  func markdown(enforced: Bool) -> String {
    var text = "### MacMint resource scenarios (\(ProcessInfo.processInfo.operatingSystemVersionString))\n\n"
    text += "Budgets \(enforced ? "enforced" : "reported only"). CPU is percent of one core.\n\n"
    text += "| Scenario | Metric | Value | Budget |\n|---|---|---:|---|\n"
    for row in rows {
      text += "| \(row.scenario) | \(row.metric) | \(Self.format(row.value, row.unit)) | "
        + (row.budget.map { $0 + (row.exceeded ? " **exceeded**" : "") } ?? "—") + " |\n"
    }
    return text
  }
}

/// CPU used by Finder and per-user system agents while a scenario window runs, to show
/// whether MacMint makes the system do work on its behalf. Root daemons are not readable.
private struct SystemObserver {
  static let names = ["Finder", "iconservicesagent", "com.apple.quicklook.ThumbnailsAgent", "QuickLookUIService",
    "fileproviderd", "cloudd", "bird", "mds_stores", "deleted"]
  private var starts: [(name: String, pid: pid_t, cpu: UInt64)] = []
  private var startTime: UInt64 = 0

  mutating func start() {
    starts = Self.names.flatMap { name in
      Self.pids(named: name).compactMap { pid in Self.ticks(pid).map { (name: name, pid: pid, cpu: $0) } }
    }
    startTime = mach_absolute_time()
  }

  /// Percent of one core per process name over the window.
  func finish() -> [(name: String, percent: Double)] {
    let elapsed = Double(mach_absolute_time() - startTime)
    guard elapsed > 0 else { return [] }
    var totals: [String: UInt64] = [:]
    for entry in starts {
      guard let now = Self.ticks(entry.pid), now >= entry.cpu else { continue }
      totals[entry.name, default: 0] += now - entry.cpu
    }
    return Self.names.compactMap { name in totals[name].map { (name: name, percent: Double($0) / elapsed * 100) } }
  }

  private static func ticks(_ pid: pid_t) -> UInt64? {
    var usage = rusage_info_v4()
    let result = withUnsafeMutablePointer(to: &usage) { pointer in
      pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
    }
    return result == 0 ? usage.ri_user_time &+ usage.ri_system_time : nil
  }

  private static func pids(named name: String) -> [pid_t] {
    let command = Process(), output = Pipe()
    command.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
    command.arguments = ["-x", "-U", String(getuid()), name]
    command.standardOutput = output; command.standardError = FileHandle.nullDevice
    do { try command.run() } catch { return [] }
    let data = output.fileHandleForReading.readDataToEndOfFile()
    command.waitUntilExit()
    return String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline).compactMap { pid_t($0) }
  }
}

/// Deterministic fixture content: SplitMix64.
private struct FixtureRandom {
  var state: UInt64
  mutating func next() -> UInt64 {
    state &+= 0x9E37_79B9_7F4A_7C15
    var z = state
    z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
    z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
    return z ^ (z >> 31)
  }
  mutating func unit() -> CGFloat { CGFloat(next() >> 11) / CGFloat(UInt64(1) << 53) }
}

/// Everything lives in one new temporary folder that is removed afterwards.
private final class ProbeFixture {
  let root: URL
  let storage: URL
  let photos: URL
  private(set) var storageFiles = 0
  private(set) var storageItems = 0
  private(set) var photoCount = 0

  init() throws {
    root = FileManager.default.temporaryDirectory
      .appendingPathComponent("macmint-resource-fixture-\(UUID().uuidString)", isDirectory: true)
    storage = root.appendingPathComponent("storage-map", isDirectory: true)
    photos = root.appendingPathComponent("photo-folder", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
  }

  func remove() { try? FileManager.default.removeItem(at: root) }

  /// A folder the app accepts as `--resource-probe`; its support data stays inside it.
  func launchFolder(_ name: String, manifest: [String: String] = [:]) throws -> URL {
    let folder = root.appendingPathComponent("macmint-resource-probe-\(name)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
    try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys])
      .write(to: folder.appendingPathComponent("manifest.json"))
    return folder
  }

  /// 50 areas × 40 folders × 40 files = 80,000 files. Every eighth file is a sparse
  /// 2 MiB file (no allocated blocks), so the map keeps ~10k file nodes like a real home.
  func makeStorageTree() throws {
    for area in 0..<50 {
      for folder in 0..<40 {
        let directory = storage.appendingPathComponent(String(format: "area-%02d/folder-%02d", area, folder), isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        storageItems += folder == 0 ? 2 : 1
        for index in 0..<40 {
          let path = directory.appendingPathComponent(String(format: "item-%02d.dat", index)).path
          let descriptor = open(path, O_CREAT | O_WRONLY | O_TRUNC, 0o644)
          guard descriptor >= 0 else { throw ProbeFailure(description: "Could not create fixture file \(path).") }
          defer { close(descriptor) }
          if index % 8 == 0 {
            guard ftruncate(descriptor, off_t(2_097_152 + index * 4096)) == 0 else {
              throw ProbeFailure(description: "Could not size fixture file \(path).")
            }
          } else if index % 3 == 0 {
            var byte = UInt8(truncatingIfNeeded: index)
            guard write(descriptor, &byte, 1) == 1 else { throw ProbeFailure(description: "Could not write fixture file \(path).") }
          }
          storageFiles += 1; storageItems += 1
        }
      }
    }
  }

  /// 100 scenes × 3 near-identical variants = 300 JPEGs at 1600×1200, so the scan finds
  /// similar groups and the Similar tab decodes real previews.
  func makePhotos(scenes: Int = 100, variants: Int = 3) throws {
    try FileManager.default.createDirectory(at: photos, withIntermediateDirectories: true)
    let width = 1600, height = 1200
    guard let space = CGColorSpace(name: CGColorSpace.sRGB) else { throw ProbeFailure(description: "No sRGB color space.") }
    for scene in 0..<scenes {
      var random = FixtureRandom(state: UInt64(scene + 1) &* 0x2545_F491_4F6C_DD1D)
      let background = CGColor(srgbRed: random.unit(), green: random.unit(), blue: random.unit(), alpha: 1)
      let shapes = (0..<12).map { _ in
        (CGRect(x: random.unit() * 1400, y: random.unit() * 1000, width: 120 + random.unit() * 600,
          height: 120 + random.unit() * 500),
         CGColor(srgbRed: random.unit(), green: random.unit(), blue: random.unit(), alpha: 1), random.next() % 2 == 0)
      }
      let dots = (0..<600).map { _ in CGRect(x: random.unit() * 1600, y: random.unit() * 1200, width: 3, height: 3) }
      for variant in 0..<variants {
        let url = photos.appendingPathComponent(String(format: "IMG_%04d.jpg", scene * variants + variant))
        try autoreleasepool {
          guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
            throw ProbeFailure(description: "Could not create a photo fixture context.")
          }
          let bounds = CGRect(x: 0, y: 0, width: width, height: height)
          context.setFillColor(background); context.fill(bounds)
          let offset = CGFloat(variant) * 4
          for (rect, color, ellipse) in shapes {
            context.setFillColor(color)
            if ellipse { context.fillEllipse(in: rect.offsetBy(dx: offset, dy: offset)) }
            else { context.fill(rect.offsetBy(dx: offset, dy: offset)) }
          }
          context.setFillColor(CGColor(gray: 0, alpha: 0.6))
          for dot in dots { context.fill(dot.offsetBy(dx: offset, dy: 0)) }
          context.setFillColor(CGColor(gray: 1, alpha: 0.03 * CGFloat(variant))); context.fill(bounds)
          guard let image = context.makeImage(),
            let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)
          else { throw ProbeFailure(description: "Could not encode a photo fixture.") }
          CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.82] as CFDictionary)
          guard CGImageDestinationFinalize(destination) else { throw ProbeFailure(description: "Could not write \(url.path).") }
        }
        photoCount += 1
      }
    }
  }
}

extension NativeStartupTest {
  @MainActor
  fileprivate static func runResourceScenarios(_ target: Target) throws {
    let environment = ProcessInfo.processInfo.environment
    let enforce = environment["MACMINT_RESOURCE_BUDGETS"] != "report"
    let profile = environment["MACMINT_PROBE_PROFILE"] == "1"
    let fixture = try ProbeFixture()
    defer { fixture.remove() }
    let started = ProcessInfo.processInfo.systemUptime
    try fixture.makeStorageTree()
    try fixture.makePhotos()
    log(String(format: "Resource fixture: %d files (%d items) and %d photos generated in %.1fs", fixture.storageFiles,
      fixture.storageItems, fixture.photoCount, ProcessInfo.processInfo.systemUptime - started))
    let companions = launchCompanionApps()
    defer { terminateCompanionApps(companions) }
    let regular = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular && !$0.isTerminated }
    log("Resource scenarios: \(regular.count) regular apps running before MacMint (\(companions.count) disposable companions)")
    var report = ResourceReport()
    // Whatever was measured is published, including when a later scenario fails.
    defer { publish(report, enforced: enforce) }
    var fresh: Footprint?

    let overview = "(a) Overview idle"
    let overviewFolder = try fixture.launchFolder("overview")
    try withLaunchedApp(target, LaunchOptions(label: overview, extraArguments: ["--resource-probe", overviewFolder.path], ignoresSavedState: true)) { app in
      try settle(app, label: overview, seconds: 10)
      logState(app, overview)
      var system = SystemObserver(); system.start()
      let cpu = try measureCPU(app, label: overview, seconds: 30)
      let memory = try footprint(app.processIdentifier)
      fresh = memory
      report.cpu(overview, cpu, limit: ResourceBudgets.overviewIdleCPU)
      report.system(overview, system.finish())
      report.memory(overview, "footprint, fresh launch", memory.currentMiB)
      logState(app, overview)
    }
    report.samples(overview, "monitor samples taken", readSamples(overviewFolder, "quit")?.samples, limit: 0)

    let performance = "(b) live Performance view"
    let background = "(c) hidden in background"
    let performanceFolder = try fixture.launchFolder("performance")
    var hiddenAt: (samples: Int, published: Int)?
    try withLaunchedApp(target, LaunchOptions(label: performance,
      extraArguments: ["--performance", "--resource-probe", performanceFolder.path], ignoresSavedState: true)) { app in
      try settle(app, label: performance, seconds: 8)
      logState(app, performance)
      var system = SystemObserver(); system.start()
      let cpu = try measureCPU(app, label: performance, seconds: 60)
      report.cpu(performance, cpu, limit: ResourceBudgets.performanceCPU)
      report.system(performance, system.finish())
      report.memory(performance, "footprint after 60 s", try footprint(app.processIdentifier).currentMiB)
      logState(app, performance)
      if profile { profileCPU(app, name: "performance") }
      try hide(app, label: background)
      _ = waitUntil(seconds: 1) { false }
      hiddenAt = readSamples(performanceFolder, "hide")
      try settle(app, label: background, seconds: 4)
      system.start()
      let hidden = try measureCPU(app, label: background, seconds: 30)
      report.cpu(background, hidden, limit: ResourceBudgets.backgroundCPU)
      report.system(background, system.finish())
      report.memory(background, "footprint after 35 s hidden", try footprint(app.processIdentifier).currentMiB)
      logState(app, background)
    }
    let quitAt = readSamples(performanceFolder, "quit")
    report.samples(performance, "monitor samples shown", hiddenAt?.published, minimum: ResourceBudgets.minimumLiveSamples)
    report.samples(background, "monitor samples taken hidden",
      hiddenAt.flatMap { hide in quitAt.map { $0.samples - hide.samples } }, limit: 0)
    report.samples(background, "monitor samples shown hidden",
      hiddenAt.flatMap { hide in quitAt.map { $0.published - hide.published } }, limit: 0)

    let heavy = "(d) heavy session"
    let heavyFolder = try fixture.launchFolder("heavy", manifest: ["storage": fixture.storage.path, "photos": fixture.photos.path])
    var heavyHiddenAt: TimeInterval?
    var heavyHidden: CPUWindow?
    try withLaunchedApp(target, LaunchOptions(label: heavy, extraArguments: ["--resource-probe", heavyFolder.path], ignoresSavedState: true)) { app in
      var system = SystemObserver(); system.start()
      let status = try waitForStatus(app, folder: heavyFolder, label: heavy, seconds: 300)
      report.system(heavy + ", scans", system.finish())
      guard (status["storageItems"] ?? 0) >= fixture.storageFiles, status["photos"] == fixture.photoCount else {
        throw ProbeFailure(description: "\(heavy): the fixture was not fully exercised: \(status)")
      }
      log("\(heavy): mapped \(status["storageItems"] ?? 0) items into \(status["storageNodes"] ?? 0) tree nodes; scanned \(status["photos"] ?? 0) photos in \(status["similarGroups"] ?? 0) similar groups; back on Overview")
      try settle(app, label: heavy, seconds: 15)
      logState(app, heavy)
      system.start()
      let cpu = try measureCPU(app, label: heavy + " on Overview", seconds: 30)
      let settled = try footprint(app.processIdentifier)
      report.cpu(heavy + ", Overview", cpu, limit: ResourceBudgets.overviewIdleCPU)
      report.system(heavy + ", Overview", system.finish())
      report.memory(heavy, "footprint peak during session", settled.lifetimePeakMiB)
      report.memory(heavy, "footprint settled on Overview", settled.currentMiB, limit: ResourceBudgets.heavySettledFootprint)
      if profile { profileMemory(app, name: "heavy-settled") }
      try hide(app, label: heavy)
      heavyHiddenAt = ProcessInfo.processInfo.systemUptime
      let hidden = try measureCPU(app, label: heavy + " hidden", seconds: 30)
      heavyHidden = hidden
      let released = try footprint(app.processIdentifier)
      report.cpu(heavy + ", hidden", hidden, limit: ResourceBudgets.backgroundCPU)
      report.memory(heavy, "footprint after 30 s hidden", released.currentMiB,
        limit: ResourceBudgets.backgroundReleaseOverFresh.flatMap { allowance in fresh.map { $0.currentMiB + allowance } })
      if profile { profileMemory(app, name: "heavy-hidden") }
      logState(app, heavy)
    }
    if let hiddenAt = heavyHiddenAt { traceHidden(heavy, folder: heavyFolder, hiddenAt: hiddenAt, window: heavyHidden) }

    let exceeded = report.rows.filter(\.exceeded)
    if enforce, !exceeded.isEmpty {
      throw ProbeFailure(description: "Resource budgets exceeded: " + exceeded.map { "\($0.scenario) \($0.metric)" }.joined(separator: "; "))
    }
  }

  private static func publish(_ report: ResourceReport, enforced: Bool) {
    let environment = ProcessInfo.processInfo.environment
    report.lines.forEach(log)
    let markdown = report.markdown(enforced: enforced)
    if let folder = environment["MACMINT_NATIVE_STARTUP_DIAGNOSTICS"] {
      let base = URL(fileURLWithPath: folder)
      try? markdown.write(to: base.appendingPathComponent("resource-report.md"), atomically: true, encoding: .utf8)
      if let json = try? JSONEncoder().encode(report.rows) { try? json.write(to: base.appendingPathComponent("resource-report.json")) }
    }
    if let summary = environment["GITHUB_STEP_SUMMARY"], let handle = FileHandle(forWritingAtPath: summary) {
      _ = handle.seekToEndOfFile(); handle.write(Data((markdown + "\n").utf8)); try? handle.close()
    }
  }

  private static func readSamples(_ folder: URL, _ event: String) -> (samples: Int, published: Int)? {
    guard let data = try? Data(contentsOf: folder.appendingPathComponent("samples-\(event).json")),
      let counts = try? JSONDecoder().decode([String: Int].self, from: data),
      let samples = counts["samples"], let published = counts["publishedSamples"] else { return nil }
    return (samples, published)
  }

  @MainActor
  private static func logState(_ app: NSRunningApplication, _ label: String) {
    let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "none"
    log("\(label): active=\(app.isActive) hidden=\(app.isHidden) frontmost=\(front)")
  }

  @MainActor
  private static func hide(_ app: NSRunningApplication, label: String) throws {
    _ = app.hide()
    guard waitUntil(seconds: 5, { app.isHidden || app.isTerminated }), !app.isTerminated else {
      throw ProbeFailure(description: "\(label): PID \(app.processIdentifier) could not be hidden.")
    }
    log("\(label): hidden")
  }

  @MainActor
  private static func waitForStatus(_ app: NSRunningApplication, folder: URL, label: String,
    seconds: TimeInterval) throws -> [String: Int] {
    let url = folder.appendingPathComponent("status.json")
    let started = ProcessInfo.processInfo.systemUptime
    var status: [String: Int]?
    _ = waitUntil(seconds: seconds) {
      if app.isTerminated { return true }
      if let data = try? Data(contentsOf: url) { status = try? JSONDecoder().decode([String: Int].self, from: data) }
      return status != nil
    }
    guard !app.isTerminated else { throw ProbeFailure(description: "\(label): process exited during the session.") }
    guard let status else { throw ProbeFailure(description: "\(label): the session did not finish within \(Int(seconds)) seconds.") }
    log(String(format: "%@: session finished in %.1fs", label, ProcessInfo.processInfo.systemUptime - started))
    return status
  }

  /// Disposable system apps so the Performance list resembles a real session (~12 apps).
  /// Only on a disposable CI runner; only the exact instances launched here are quit.
  @MainActor
  private static func launchCompanionApps() -> [NSRunningApplication] {
    let environment = ProcessInfo.processInfo.environment
    guard environment["GITHUB_ACTIONS"] == "true", environment["CI"] == "true" else {
      log("Companion apps: not launched outside a disposable CI runner.")
      return []
    }
    // Apps without document browsers or first-run panels, which could hold activation.
    let paths = ["Calculator", "Stickies", "Font Book", "Dictionary", "Utilities/Audio MIDI Setup",
      "Utilities/ColorSync Utility", "Utilities/Disk Utility", "Utilities/Terminal"].map { "/System/Applications/\($0).app" }
    var mailboxes: [LaunchMailbox] = []
    for path in paths where FileManager.default.fileExists(atPath: path) {
      let configuration = NSWorkspace.OpenConfiguration()
      configuration.activates = false
      configuration.hides = true
      configuration.addsToRecentItems = false
      configuration.createsNewApplicationInstance = true
      configuration.promptsUserIfNeeded = false
      let mailbox = LaunchMailbox()
      let completion: @Sendable (NSRunningApplication?, Error?) -> Void = { app, error in
        mailbox.complete(app: app, error: error)
      }
      NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: path), configuration: configuration, completionHandler: completion)
      mailboxes.append(mailbox)
    }
    _ = waitUntil(seconds: 30) { mailboxes.allSatisfy { $0.snapshot().completed } }
    let apps = mailboxes.compactMap { $0.snapshot().app }
    _ = waitUntil(seconds: 20) { apps.allSatisfy { $0.isFinishedLaunching || $0.isTerminated } }
    for app in apps where !app.isTerminated { _ = app.hide() }
    _ = waitUntil(seconds: 3) { false }
    return apps.filter { !$0.isTerminated }
  }

  @MainActor
  private static func terminateCompanionApps(_ apps: [NSRunningApplication]) {
    guard !apps.isEmpty else { return }
    for app in apps where !app.isTerminated { _ = app.terminate() }
    if !waitUntil(seconds: 8, { apps.allSatisfy(\.isTerminated) }) {
      for app in apps where !app.isTerminated { _ = app.forceTerminate() }
      _ = waitUntil(seconds: 5) { apps.allSatisfy(\.isTerminated) }
    }
    log("Companion apps: quit \(apps.count) disposable instances")
  }

  // MARK: Best-effort diagnostics (never gate)

  /// Report-only: when inside the hidden window the app used CPU, and which of its timed
  /// memory releases ran then. Offsets are seconds after the app was hidden.
  private static func traceHidden(_ label: String, folder: URL, hiddenAt: TimeInterval, window: CPUWindow?) {
    if let window {
      let offset = window.startedAt - hiddenAt
      let series = window.perSecond.enumerated().map { index, cores in
        String(format: "+%.0fs %.2f%%", offset + Double(index + 1), cores * 100)
      }
      log("TRACE \(label), hidden: per-second CPU (end of each second after hiding): " + series.joined(separator: ", "))
    }
    guard let data = try? Data(contentsOf: folder.appendingPathComponent("trace-quit.json")),
      let trace = try? JSONDecoder().decode(ReleaseTrace.self, from: data) else {
      log("TRACE \(label): no memory-release trace was written")
      return
    }
    for release in trace.releases {
      log(String(format: "TRACE %@: memory release (%@) at %+.1fs from hiding: purge %.1f ms, compaction %.1f ms, allocator walk %.1f ms%@",
        label, release.reason, release.at - hiddenAt, release.purgeMS, release.compactMS, release.relieveMS,
        release.freed ? "" : " (nothing to drop, walk skipped)"))
    }
  }

  @MainActor
  private static func profileCPU(_ app: NSRunningApplication, name: String) {
    guard let folder = ProcessInfo.processInfo.environment["MACMINT_NATIVE_STARTUP_DIAGNOSTICS"] else { return }
    let output = URL(fileURLWithPath: folder).appendingPathComponent("resource-sample-\(name).txt")
    let pid = String(app.processIdentifier)
    guard runTool("/usr/bin/sample", [pid, "10", "1", "-mayDie", "-file", output.path], log: nil),
      let text = try? String(contentsOf: output, encoding: .utf8) else {
      log("PROFILE \(name): sample unavailable on this runner")
      return
    }
    printSection(text, from: "Sort by top of stack", lines: 40, prefix: "PROFILE \(name)")
  }

  @MainActor
  private static func profileMemory(_ app: NSRunningApplication, name: String) {
    guard let folder = ProcessInfo.processInfo.environment["MACMINT_NATIVE_STARTUP_DIAGNOSTICS"] else { return }
    let base = URL(fileURLWithPath: folder)
    let pid = String(app.processIdentifier)
    let footprintURL = base.appendingPathComponent("resource-footprint-\(name).txt")
    if runTool("/usr/bin/footprint", [pid], log: footprintURL), let text = try? String(contentsOf: footprintURL, encoding: .utf8) {
      text.split(separator: "\n", omittingEmptySubsequences: true).prefix(45).forEach { log("FOOTPRINT \(name): \($0)") }
    } else { log("FOOTPRINT \(name): unavailable on this runner") }
    let heapURL = base.appendingPathComponent("resource-heap-\(name).txt")
    if runTool("/usr/bin/heap", ["-s", pid], log: heapURL), let text = try? String(contentsOf: heapURL, encoding: .utf8) {
      for line in text.split(separator: "\n") where line.contains("All zones") || line.contains("Physical footprint") {
        log("HEAP \(name): \(line)")
      }
      printSection(text, from: "COUNT", lines: 35, prefix: "HEAP \(name)")
    } else { log("HEAP \(name): unavailable on this runner") }
  }

  private static func printSection(_ text: String, from marker: String, lines count: Int, prefix: String) {
    let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
    guard let start = lines.firstIndex(where: { $0.contains(marker) }) else {
      log("\(prefix): section \"\(marker)\" not found")
      return
    }
    lines[start..<min(lines.count, start + count)].forEach { log("\(prefix): \($0)") }
  }

  /// Runs a read-only inspection tool (as the user, then non-interactive sudo on CI).
  @MainActor
  private static func runTool(_ path: String, _ arguments: [String], log output: URL?) -> Bool {
    guard FileManager.default.isExecutableFile(atPath: path) else { return false }
    for (executable, args) in [(path, arguments), ("/usr/bin/sudo", ["-n", path] + arguments)] {
      let process = Process()
      process.executableURL = URL(fileURLWithPath: executable)
      process.arguments = args
      var handle: FileHandle?
      if let output {
        FileManager.default.createFile(atPath: output.path, contents: nil)
        handle = try? FileHandle(forWritingTo: output)
      }
      process.standardOutput = handle ?? FileHandle.nullDevice
      process.standardError = handle ?? FileHandle.nullDevice
      do { try process.run() } catch { try? handle?.close(); continue }
      let finished = waitUntil(seconds: 90) { !process.isRunning }
      if !finished { process.terminate(); _ = waitUntil(seconds: 3) { !process.isRunning } }
      try? handle?.close()
      if finished, process.terminationStatus == 0 { return true }
    }
    return false
  }
}
