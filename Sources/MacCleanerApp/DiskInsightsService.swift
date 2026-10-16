import Foundation
import MacCleanerCore

/// Gathers DiskInsights with short, read-only system tool calls off the main thread.
enum DiskInsightsService {
  static func load() async -> DiskInsights {
    await Task.detached(priority: .utility) {
      var insights = DiskInsights()
      let values = try? FileManager.default.homeDirectoryForCurrentUser.resourceValues(forKeys: [
        .volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey,
      ])
      insights.purgeableBytes = DiskInsights.purgeable(
        important: values?.volumeAvailableCapacityForImportantUsage,
        available: values?.volumeAvailableCapacity.map(Int64.init))
      if let data = run("/usr/sbin/diskutil", ["info", "-plist", "/"]) {
        let info = DiskInsights.volumeInfo(fromDiskutilPlist: data)
        insights.fileSystem = info.fileSystem
        insights.health = info.health
      }
      if let data = run("/usr/bin/tmutil", ["listlocalsnapshots", "/"]),
        let text = String(data: data, encoding: .utf8)
      {
        insights.localSnapshots = DiskInsights.snapshotDates(fromTmutil: text)
        insights.snapshotsReadable = true
      }
      return insights
    }.value
  }

  /// Runs a system tool with a 5-second limit; nil on failure or timeout.
  private static func run(_ path: String, _ arguments: [String]) -> Data? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: path)
    process.arguments = arguments
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    do { try process.run() } catch { return nil }
    let deadline = Date().addingTimeInterval(5)
    while process.isRunning, Date() < deadline { usleep(50_000) }
    if process.isRunning {
      process.terminate()
      return nil
    }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    return process.terminationStatus == 0 ? data : nil
  }
}
