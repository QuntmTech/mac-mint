import AppKit
import Darwin
import Foundation
import MacCleanerCore

/// Lightweight system readings for the menu bar and Performance screen.
/// Polls only while a view that shows it is visible (callers balance start/stop).
@MainActor
final class SystemMonitor: ObservableObject {
  enum Pressure: String {
    case normal = "Normal"
    case warning = "Elevated"
    case critical = "High"
    case unknown = "Unavailable"
  }

  struct Snapshot: Equatable {
    var freeBytes: Int64 = 0
    var totalBytes: Int64 = 0
    var cpuUsage: Double?
    var memoryUsedBytes: Int64?
    var physicalMemory: Int64 = Int64(ProcessInfo.processInfo.physicalMemory)
    var swapUsedBytes: Int64?
    var pressure: Pressure = .unknown

    var diskUsedFraction: Double {
      totalBytes > 0 ? Double(totalBytes - freeBytes) / Double(totalBytes) : 0
    }
  }

  struct AppUsage: Identifiable, Equatable {
    let id: pid_t
    let name: String
    let bundleID: String?
    let memoryBytes: Int64
    let icon: NSImage?
  }

  @Published private(set) var snapshot = Snapshot()
  @Published private(set) var topApps: [AppUsage] = []

  private var timer: Timer?
  private var watchers = 0
  private var previousTicks: (busy: UInt64, total: UInt64)?

  func start(interval: TimeInterval = 4) {
    watchers += 1
    guard timer == nil else { return }
    sample()
    timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
      Task { @MainActor in self?.sample() }
    }
  }

  func stop() {
    watchers = max(0, watchers - 1)
    guard watchers == 0 else { return }
    timer?.invalidate()
    timer = nil
    previousTicks = nil
  }

  func sample() {
    var next = Snapshot()
    if let values = try? FileManager.default.homeDirectoryForCurrentUser.resourceValues(forKeys: [
      .volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey,
    ]) {
      next.totalBytes = Int64(values.volumeTotalCapacity ?? 0)
      next.freeBytes = values.volumeAvailableCapacityForImportantUsage ?? 0
    }
    next.cpuUsage = cpuUsage()
    next.memoryUsedBytes = memoryUsed()
    next.swapUsedBytes = swapUsed()
    next.pressure = pressure()
    snapshot = next
    topApps = Self.topApps(limit: 8)
  }

  // MARK: Readings

  private func cpuUsage() -> Double? {
    var size = mach_msg_type_number_t(
      MemoryLayout<host_cpu_load_info_data_t>.stride / MemoryLayout<integer_t>.stride)
    var info = host_cpu_load_info_data_t()
    let result = withUnsafeMutablePointer(to: &info) { pointer in
      pointer.withMemoryRebound(to: integer_t.self, capacity: Int(size)) {
        host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &size)
      }
    }
    guard result == KERN_SUCCESS else { return nil }
    let user = UInt64(info.cpu_ticks.0)
    let system = UInt64(info.cpu_ticks.1)
    let idle = UInt64(info.cpu_ticks.2)
    let nice = UInt64(info.cpu_ticks.3)
    let busy = user + system + nice
    let total = busy + idle
    defer { previousTicks = (busy, total) }
    guard let previous = previousTicks, total > previous.total else { return nil }
    return Double(busy - previous.busy) / Double(total - previous.total)
  }

  /// Matches Activity Monitor's "Memory Used": app memory + wired + compressed.
  private func memoryUsed() -> Int64? {
    var size = mach_msg_type_number_t(
      MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride)
    var stats = vm_statistics64_data_t()
    let result = withUnsafeMutablePointer(to: &stats) { pointer in
      pointer.withMemoryRebound(to: integer_t.self, capacity: Int(size)) {
        host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &size)
      }
    }
    guard result == KERN_SUCCESS else { return nil }
    let page = Int64(getpagesize())
    let appPages = Int64(stats.internal_page_count) - Int64(stats.purgeable_count)
    let pages = appPages + Int64(stats.wire_count) + Int64(stats.compressor_page_count)
    return max(0, pages) * page
  }

  private func swapUsed() -> Int64? {
    var usage = xsw_usage()
    var size = MemoryLayout<xsw_usage>.size
    guard sysctlbyname("vm.swapusage", &usage, &size, nil, 0) == 0 else { return nil }
    return Int64(usage.xsu_used)
  }

  private func pressure() -> Pressure {
    var level: Int32 = 0
    var size = MemoryLayout<Int32>.size
    guard sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0) == 0 else {
      return .unknown
    }
    switch level {
    case 1: return .normal
    case 2: return .warning
    case 4: return .critical
    default: return .unknown
    }
  }

  private static func topApps(limit: Int) -> [AppUsage] {
    NSWorkspace.shared.runningApplications
      .filter { $0.activationPolicy == .regular }
      .compactMap { app -> AppUsage? in
        var info = rusage_info_v4()
        let result = withUnsafeMutablePointer(to: &info) { pointer in
          pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
            proc_pid_rusage(app.processIdentifier, RUSAGE_INFO_V4, $0)
          }
        }
        guard result == 0 else { return nil }
        return AppUsage(
          id: app.processIdentifier, name: app.localizedName ?? "App",
          bundleID: app.bundleIdentifier, memoryBytes: Int64(info.ri_phys_footprint),
          icon: app.icon)
      }
      .sorted { $0.memoryBytes > $1.memoryBytes }
      .prefix(limit)
      .map { $0 }
  }

  /// Asks an app to quit normally, so it can prompt to save work. Never force-quits.
  func requestQuit(_ usage: AppUsage) -> Bool {
    NSRunningApplication(processIdentifier: usage.id)?.terminate() ?? false
  }
}
