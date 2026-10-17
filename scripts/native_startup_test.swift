// External regression probe for the real packaged application lifecycle.
// This launches the full SwiftUI App (including MenuBarExtra), never --smoke-test.
// Intended for the disposable graphical macOS CI runner; it never resets app data.
import AppKit
import CoreGraphics
import Darwin
import Foundation

private struct ProbeFailure: Error, CustomStringConvertible {
  let description: String
}

// NSWorkspace may call its completion off the main thread. Only this locked mailbox
// crosses that boundary; AppKit properties are inspected on the main actor below.
private final class LaunchMailbox: @unchecked Sendable {
  private let lock = NSLock()
  private var app: NSRunningApplication?
  private var error: Error?

  func complete(app: NSRunningApplication?, error: Error?) {
    lock.lock()
    defer { lock.unlock() }
    self.app = app
    self.error = error
  }

  func snapshot() -> (app: NSRunningApplication?, error: Error?) {
    lock.lock()
    defer { lock.unlock() }
    return (app, error)
  }
}

@main
private struct NativeStartupTest {
  // This is a broad feedback-loop detector, not a performance benchmark. Eight
  // seconds of settling precede a ten-second cumulative CPU measurement. Ordinary
  // launch work is allowed; sustained consumption near one whole core is not.
  private static let settleSeconds: TimeInterval = 8
  private static let sampleSeconds: TimeInterval = 10
  private static let maximumAverageCores = 0.85

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
      for inserted in [false, true] {
        try check(appURL: appURL, identifier: identifier, menuBarInserted: inserted)
      }
      log("PASS: ordinary launches with menu bar off/on finished, created a main window, stayed below the CPU-loop limit, and quit normally.")
    } catch {
      FileHandle.standardError.write(Data("FAIL: \(error)\n".utf8))
      exit(EXIT_FAILURE)
    }
  }

  @MainActor
  private static func check(appURL: URL, identifier: String, menuBarInserted: Bool) throws {
    let label = "menu bar \(menuBarInserted ? "on" : "off")"
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
    configuration.activates = false
    configuration.hides = true
    configuration.hidesOthers = false
    configuration.addsToRecentItems = false
    configuration.createsNewApplicationInstance = true
    configuration.allowsRunningApplicationSubstitution = false
    configuration.promptsUserIfNeeded = false
    // NSArgumentDomain overrides only this process's defaults. No `defaults write`,
    // HOME substitution, test-only app entry point, or user-data cleanup is used.
    configuration.arguments = [
      "-care.showMenuBar", menuBarInserted ? "YES" : "NO",
      "-care.onboardingDone", "NO",
      "-care.lowSpaceAlerts", "NO",
      "-care.scanReminders", "NO",
      "-MacMintNativeStartupProbeID", marker,
    ]
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
    guard discovered, let app = ownedApp, app.bundleIdentifier == identifier else {
      throw ProbeFailure(description: "\(label): launch did not yield its own application process within 30 seconds.")
    }
    let pid = app.processIdentifier
    guard waitUntil(seconds: 30, { app.isFinishedLaunching || app.isTerminated }), !app.isTerminated,
      app.isFinishedLaunching
    else { throw ProbeFailure(description: "\(label): PID \(pid) did not finish ordinary AppKit launch.") }
    log("\(label): PID \(pid) finished launching")
    guard waitUntil(seconds: 20, { app.isTerminated || hasMainWindow(pid) }), !app.isTerminated,
      hasMainWindow(pid)
    else { throw ProbeFailure(description: "\(label): no normal main-window bounds appeared for PID \(pid).") }
    log("\(label): normal-layer main window exists (no title, AX, or pixel capture required)")
    guard !waitUntil(seconds: settleSeconds, { app.isTerminated }) else {
      throw ProbeFailure(description: "\(label): process exited while settling.")
    }
    let initialCPU = try cpuTicks(pid)
    let initialTime = mach_absolute_time()
    let start = ProcessInfo.processInfo.systemUptime
    guard !waitUntil(seconds: sampleSeconds, { app.isTerminated }) else {
      throw ProbeFailure(description: "\(label): process exited during the idle CPU sample.")
    }
    let finalCPU = try cpuTicks(pid)
    let finalTime = mach_absolute_time()
    let wallSeconds = ProcessInfo.processInfo.systemUptime - start
    guard finalCPU >= initialCPU, finalTime > initialTime, wallSeconds > 0 else {
      throw ProbeFailure(description: "\(label): invalid cumulative CPU sample.")
    }
    // XNU rusage CPU counters use Mach absolute ticks, not nanoseconds on ARM.
    // Compare deltas in the same timebase, as the production sampler does.
    let averageCores = Double(finalCPU - initialCPU) / Double(finalTime - initialTime)
    log(String(format: "%@: idle CPU %.1f%% of one core over %.1fs (limit %.0f%%)", label, averageCores * 100, wallSeconds, maximumAverageCores * 100))
    guard averageCores <= maximumAverageCores else {
      throw ProbeFailure(description: "\(label): sustained idle CPU suggests a launch/scene feedback loop.")
    }
    guard !app.isTerminated, app.terminate() else {
      throw ProbeFailure(description: "\(label): normal Quit request was not accepted.")
    }
    guard waitUntil(seconds: 12, { app.isTerminated }) else {
      throw ProbeFailure(description: "\(label): PID \(pid) did not exit within 12 seconds of normal Quit.")
    }
    log("\(label): normal Quit completed")
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

  private static func cpuTicks(_ pid: pid_t) throws -> UInt64 {
    var usage = rusage_info_v4()
    let result = withUnsafeMutablePointer(to: &usage) { pointer in
      pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
        proc_pid_rusage(pid, RUSAGE_INFO_V4, $0)
      }
    }
    guard result == 0 else { throw ProbeFailure(description: "Could not read cumulative CPU for probe PID \(pid).") }
    let (total, overflow) = usage.ri_user_time.addingReportingOverflow(usage.ri_system_time)
    guard !overflow else { throw ProbeFailure(description: "Cumulative CPU counter overflowed for probe PID \(pid).") }
    return total
  }

  private static func log(_ message: String) {
    FileHandle.standardOutput.write(Data((message + "\n").utf8))
  }
}
