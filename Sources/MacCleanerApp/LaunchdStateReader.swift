import Darwin
import Foundation
import MacCleanerCore

/// Reads launchd's job list and enable/disable overrides with `launchctl`, read-only. Nothing
/// is loaded, unloaded, enabled or disabled. The three reads run at once, wait without holding
/// a thread, stop after five seconds, and stop when the scan is cancelled.
enum LaunchdStateReader {
  static func snapshot() async -> LaunchdSnapshot? {
    let uid = getuid()
    async let list = run(["list"])
    async let user = run(["print-disabled", "gui/\(uid)"])
    async let system = run(["print-disabled", "system"])
    let jobs = await list.map(LaunchdDomain.parseJobs)
    let userOverrides = await user.map(LaunchdDomain.parseOverrides)
    let systemOverrides = await system.map(LaunchdDomain.parseOverrides)
    guard jobs != nil || userOverrides != nil || systemOverrides != nil else { return nil }
    return LaunchdSnapshot(
      user: LaunchdDomain(jobs: jobs, overrides: userOverrides ?? [:]),
      // System daemons' jobs aren't listable without administrator rights; only overrides are.
      system: systemOverrides.map { LaunchdDomain(jobs: nil, overrides: $0) })
  }

  /// One launchctl run, shared with its termination, timeout and cancellation handlers.
  private final class Run: @unchecked Sendable {
    let process = Process()
    let output: URL
    init(output: URL) { self.output = output }
  }

  /// Output goes to a temporary file so a long job list can't fill a pipe and stall the tool;
  /// nil on failure, timeout or cancellation.
  private static func run(_ arguments: [String]) async -> String? {
    let output = FileManager.default.temporaryDirectory
      .appendingPathComponent("macmint-launchctl-\(UUID().uuidString).txt")
    guard FileManager.default.createFile(atPath: output.path, contents: nil),
      let handle = try? FileHandle(forWritingTo: output) else { return nil }
    defer {
      try? handle.close()
      try? FileManager.default.removeItem(at: output)
    }
    let job = Run(output: output)
    job.process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
    job.process.arguments = arguments
    job.process.standardOutput = handle
    job.process.standardError = FileHandle.nullDevice
    return await withTaskCancellationHandler {
      await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
        job.process.terminationHandler = { process in
          let finished = process.terminationReason == .exit && process.terminationStatus == 0
          continuation.resume(returning: finished
            ? (try? Data(contentsOf: job.output)).map { String(decoding: $0, as: UTF8.self) } : nil)
        }
        guard !Task.isCancelled else {
          job.process.terminationHandler = nil
          continuation.resume(returning: nil)
          return
        }
        do { try job.process.run() } catch {
          job.process.terminationHandler = nil
          continuation.resume(returning: nil)
          return
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 5) {
          if job.process.isRunning { job.process.terminate() }
        }
      }
    } onCancel: {
      if job.process.isRunning { job.process.terminate() }
    }
  }
}
