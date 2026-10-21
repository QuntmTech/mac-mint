import Darwin
import Foundation
import MacCleanerCore

/// Reads launchd's job list and enable/disable overrides with `launchctl`, read-only and off the
/// main thread. Nothing is loaded, unloaded, enabled or disabled.
enum LaunchdStateReader {
  static func snapshot() async -> LaunchdSnapshot? {
    await Task.detached(priority: .utility) { () -> LaunchdSnapshot? in
      let uid = getuid()
      let jobs = run(["list"]).map(LaunchdDomain.parseJobs)
      let userOverrides = run(["print-disabled", "gui/\(uid)"]).map(LaunchdDomain.parseOverrides)
      let systemOverrides = run(["print-disabled", "system"]).map(LaunchdDomain.parseOverrides)
      guard jobs != nil || userOverrides != nil || systemOverrides != nil else { return nil }
      return LaunchdSnapshot(
        user: LaunchdDomain(jobs: jobs, overrides: userOverrides ?? [:]),
        // System daemons' jobs aren't listable without administrator rights; only overrides are.
        system: systemOverrides.map { LaunchdDomain(jobs: nil, overrides: $0) })
    }.value
  }

  /// Runs launchctl with a 5-second limit. Output goes to a temporary file so a long job list
  /// can't fill a pipe and stall the tool; nil on failure or timeout.
  private static func run(_ arguments: [String]) -> String? {
    let output = FileManager.default.temporaryDirectory
      .appendingPathComponent("macmint-launchctl-\(UUID().uuidString).txt")
    guard FileManager.default.createFile(atPath: output.path, contents: nil),
      let handle = try? FileHandle(forWritingTo: output) else { return nil }
    defer {
      try? handle.close()
      try? FileManager.default.removeItem(at: output)
    }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
    process.arguments = arguments
    process.standardOutput = handle
    process.standardError = FileHandle.nullDevice
    do { try process.run() } catch { return nil }
    let deadline = Date().addingTimeInterval(5)
    while process.isRunning, Date() < deadline { usleep(20_000) }
    if process.isRunning {
      process.terminate()
      return nil
    }
    guard process.terminationStatus == 0, let data = try? Data(contentsOf: output) else { return nil }
    return String(decoding: data, as: UTF8.self)
  }
}
