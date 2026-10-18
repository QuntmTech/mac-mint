import AppKit
import Darwin
import Foundation
import MacCleanerCore

/// Views own idempotent leases; a serial utility sampler performs kernel/filesystem work.
@MainActor
final class SystemMonitor: ObservableObject {
  enum Pressure: String, Sendable { case normal = "Normal", warning = "Elevated", critical = "High", unknown = "Unavailable" }
  struct Snapshot: Equatable, Sendable {
    var freeBytes: Int64 = 0
    var totalBytes: Int64 = 0
    var cpuUsage: Double?
    var memoryUsedBytes: Int64?
    var physicalMemory: Int64 = Int64(ProcessInfo.processInfo.physicalMemory)
    var swapUsedBytes: Int64?
    var pressure: Pressure = .unknown
    var diskUsedFraction: Double { totalBytes > 0 ? min(1, max(0, Double(totalBytes - freeBytes) / Double(totalBytes))) : 0 }
  }
  struct AppUsage: Identifiable, Equatable {
    let id: pid_t
    let name: String
    let bundleID: String?
    let memoryBytes: Int64
    let cpuPercent: Double?
    let started: UInt64
    let application: NSRunningApplication
    var canControl: Bool { ProcessControlPolicy.allows(pid: id, bundleID: bundleID) }
  }
  @Published private(set) var snapshot = Snapshot()
  @Published private(set) var apps: [AppUsage] = []
  @Published private(set) var sampledAt: Date?
  struct TamingDisplay: Equatable, Sendable {
    var state = TamingState()
    var automatic = false
    var message: String?
  }
  @Published private(set) var taming = TamingDisplay()
  private let tamingController: AppTamingController
  private let tamingLease = UUID()
  private var controlObservers: [NSObjectProtocol] = []
  private var controlsActivated = false
  init(tamingController: AppTamingController? = nil) {
    self.tamingController = tamingController ?? AppTamingController(store: TamingStore(
      url: AppPaths.supportDirectory.appendingPathComponent("process-slowdown.json")))
    publishTaming()
  }

  func activateControls() {
    guard !controlsActivated else { return }
    controlsActivated = true
    tamingController.activate(); publishTaming()
    controlObservers.append(NSWorkspace.shared.notificationCenter.addObserver(
      forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
    ) { @Sendable [weak self] _ in
      MainActor.assumeIsolated {
        guard let self else { return }
        self.tamingController.foregroundChanged(NSWorkspace.shared.frontmostApplication?.bundleIdentifier)
        self.publishTaming()
      }
    })
    controlObservers.append(NotificationCenter.default.addObserver(
      forName: NSApplication.willTerminateNotification, object: nil, queue: .main
    ) { @Sendable [weak self] _ in MainActor.assumeIsolated { self?.restoreAllApps() } })
    controlObservers.append(NSWorkspace.shared.notificationCenter.addObserver(
      forName: NSWorkspace.willSleepNotification, object: nil, queue: .main
    ) { @Sendable [weak self] _ in MainActor.assumeIsolated { self?.restoreAllApps() } })
  }
  func setAutomaticTaming(_ enabled: Bool) {
    tamingController.setAutomatic(enabled); publishTaming()
  }
  func slowApp(_ usage: AppUsage, duration: TimeInterval) {
    guard usage.canControl, let identity = AppTamingController.identity(usage),
      usage.bundleID != NSWorkspace.shared.frontmostApplication?.bundleIdentifier else { return }
    tamingController.slow(identity, name: usage.name, now: Date(), duration: duration); publishTaming()
  }
  func restoreApp(_ usage: AppUsage) {
    if let item = tamingController.receipt(pid: usage.id, started: usage.started) {
      tamingController.restore(item.identity, suppress: true); publishTaming()
    }
  }
  func setNeverSlow(bundleID: String, name: String, protected: Bool) {
    tamingController.setException(bundleID: bundleID, name: name, protected: protected); publishTaming()
  }
  func restoreAllApps() { tamingController.restoreAll(); publishTaming() }
  private func publishTaming() {
    let display = TamingDisplay(state: tamingController.state, automatic: tamingController.autoEnabled,
      message: tamingController.message)
    if taming != display { taming = display }
    if tamingController.needsMonitoring { start(lease: tamingLease, interval: 8) }
    else { stop(lease: tamingLease) }
  }
  var topApps: [AppUsage] { Array(apps.sorted { $0.memoryBytes > $1.memoryBytes }.prefix(8)) }
  private var timer: Timer?
  private var leases: [UUID: TimeInterval] = [:]
  private(set) var samplingInterval: TimeInterval?
  private var samplingTask: Task<Void, Never>?
  private var generation = UUID()
  private let sampler = ResourceSampler()
  private(set) var activeLeaseCount = 0

  func start(lease: UUID, interval: TimeInterval = 4) {
    leases[lease] = max(3, interval); activeLeaseCount = leases.count
    configureTimer()
  }
  func stop(lease: UUID) {
    leases.removeValue(forKey: lease); activeLeaseCount = leases.count
    configureTimer()
  }
  private func configureTimer() {
    let requested = leases.values.min()
    let floor: TimeInterval = ProcessInfo.processInfo.thermalState == .serious || ProcessInfo.processInfo.thermalState == .critical ? 12 : ProcessInfo.processInfo.isLowPowerModeEnabled ? 8 : 3
    let interval = requested.map { max(floor, $0) }
    guard interval != samplingInterval else { return }
    timer?.invalidate(); timer = nil; samplingInterval = interval
    guard let interval else {
      generation = UUID(); samplingTask?.cancel(); samplingTask = nil
      Task { await sampler.reset() }
      return
    }
    sample()
    timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
      Task { @MainActor in
        guard let self else { return }
        self.configureTimer(); self.sample()
      }
    }
    timer?.tolerance = interval * 0.25
  }
  func sample() {
    guard samplingTask == nil else { return }
    let applications = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular && !$0.isTerminated }
    let pids = applications.map(\.processIdentifier)
    let token = generation
    let sampler = sampler
    samplingTask = Task { [weak self] in
      let work = Task.detached(priority: .utility) { await sampler.read(pids: pids) }
      let result = await withTaskCancellationHandler { await work.value } onCancel: { work.cancel() }
      guard let self, !Task.isCancelled, generation == token else { return }
      defer { samplingTask = nil }
      snapshot = result.snapshot
      apps = applications.compactMap { app in
        guard !app.isTerminated, let reading = result.apps[app.processIdentifier] else { return nil }
        return AppUsage(id: app.processIdentifier, name: app.localizedName ?? "App", bundleID: app.bundleIdentifier,
          memoryBytes: reading.memoryBytes, cpuPercent: reading.cpuPercent, started: reading.started, application: app)
      }
      sampledAt = Date()
      tamingController.tick(apps: apps, systemCPU: snapshot.cpuUsage,
        foreground: NSWorkspace.shared.frontmostApplication?.bundleIdentifier, now: Date())
      publishTaming()
    }
  }

  /// Validates both the LaunchServices object and kernel birth identity immediately before action.
  func requestQuit(_ usage: AppUsage, force: Bool = false) -> Bool {
    guard usage.canControl, !usage.application.isTerminated,
      let current = NSRunningApplication(processIdentifier: usage.id), current.isEqual(usage.application),
      current.bundleIdentifier == usage.bundleID,
      let info = ResourceSampler.usage(usage.id), info.ri_proc_start_abstime == usage.started,
      Self.isOwnedByCurrentUser(usage.id) else { return false }
    return force ? usage.application.forceTerminate() : usage.application.terminate()
  }
  private static func isOwnedByCurrentUser(_ pid: pid_t) -> Bool {
    var info = proc_bsdinfo()
    let size = MemoryLayout<proc_bsdinfo>.stride
    return proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(size)) == Int32(size) && info.pbi_uid == geteuid()
  }
}

enum ProcessControlPolicy {
  static func allows(pid: pid_t, bundleID: String?) -> Bool {
    guard pid > 1, pid != ProcessInfo.processInfo.processIdentifier, let bundleID,
      bundleID != Bundle.main.bundleIdentifier else { return false }
    return !["com.apple.finder", "com.apple.dock", "com.apple.loginwindow", "com.apple.systemuiserver", "com.apple.controlcenter"].contains(bundleID.lowercased())
  }
}

actor ResourceSampler {
  struct AppReading: Sendable { let started: UInt64; let memoryBytes: Int64; let cpuPercent: Double? }
  struct Result: Sendable { let snapshot: SystemMonitor.Snapshot; let apps: [pid_t: AppReading] }
  private struct Baseline { let started: UInt64; let cpu: UInt64; let time: UInt64 }
  private var baselines: [pid_t: Baseline] = [:]
  private var previousTicks: (busy: UInt64, total: UInt64)?
  func reset() { baselines = [:]; previousTicks = nil }

  func read(pids: [pid_t]) -> Result {
    var next = SystemMonitor.Snapshot()
    if let values = try? FileManager.default.homeDirectoryForCurrentUser.resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey]) {
      next.totalBytes = Int64(values.volumeTotalCapacity ?? 0); next.freeBytes = values.volumeAvailableCapacityForImportantUsage ?? 0
    }
    next.cpuUsage = cpuUsage(); next.memoryUsedBytes = memoryUsed(); next.swapUsedBytes = swapUsed(); next.pressure = pressure()
    var readings: [pid_t: AppReading] = [:], updated: [pid_t: Baseline] = [:]
    for pid in pids {
      guard !Task.isCancelled, let info = Self.usage(pid) else { continue }
      // XNU rusage CPU counters and mach_absolute_time share the Mach absolute timebase.
      // Dividing deltas avoids assuming nanoseconds on Apple silicon.
      let time = mach_absolute_time(), cpu = info.ri_user_time &+ info.ri_system_time
      let old = baselines[pid]
      let percent = old.flatMap { old in
        Self.cpuPercent(previousCPU: old.cpu, currentCPU: cpu, previousTime: old.time, currentTime: time,
          sameProcess: old.started == info.ri_proc_start_abstime)
      }
      updated[pid] = Baseline(started: info.ri_proc_start_abstime, cpu: cpu, time: time)
      readings[pid] = AppReading(started: info.ri_proc_start_abstime, memoryBytes: Int64(clamping: info.ri_phys_footprint), cpuPercent: percent)
    }
    baselines = updated
    return Result(snapshot: next, apps: readings)
  }
  nonisolated static func cpuPercent(previousCPU: UInt64, currentCPU: UInt64, previousTime: UInt64, currentTime: UInt64, sameProcess: Bool) -> Double? {
    guard sameProcess, currentTime > previousTime, currentCPU >= previousCPU else { return nil }
    return 100 * Double(currentCPU - previousCPU) / Double(currentTime - previousTime)
  }
  nonisolated static func usage(_ pid: pid_t) -> rusage_info_v4? {
    var info = rusage_info_v4()
    let result = withUnsafeMutablePointer(to: &info) { pointer in
      pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
    }
    return result == 0 ? info : nil
  }
  private func cpuUsage() -> Double? {
    var size = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.stride / MemoryLayout<integer_t>.stride)
    var info = host_cpu_load_info_data_t()
    let host = mach_host_self()
    defer { _ = mach_port_deallocate(mach_task_self_, host) }
    let result = withUnsafeMutablePointer(to: &info) { pointer in
      pointer.withMemoryRebound(to: integer_t.self, capacity: Int(size)) { host_statistics(host, HOST_CPU_LOAD_INFO, $0, &size) }
    }
    guard result == KERN_SUCCESS else { return nil }
    let busy = UInt64(info.cpu_ticks.0) + UInt64(info.cpu_ticks.1) + UInt64(info.cpu_ticks.3)
    let total = busy + UInt64(info.cpu_ticks.2)
    defer { previousTicks = (busy, total) }
    guard let previous = previousTicks, total > previous.total, busy >= previous.busy else { return nil }
    return min(1, Double(busy - previous.busy) / Double(total - previous.total))
  }
  private func memoryUsed() -> Int64? {
    var size = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride)
    var stats = vm_statistics64_data_t()
    let host = mach_host_self()
    defer { _ = mach_port_deallocate(mach_task_self_, host) }
    let result = withUnsafeMutablePointer(to: &stats) { pointer in
      pointer.withMemoryRebound(to: integer_t.self, capacity: Int(size)) { host_statistics64(host, HOST_VM_INFO64, $0, &size) }
    }
    guard result == KERN_SUCCESS else { return nil }
    let pages = Int64(stats.internal_page_count) - Int64(stats.purgeable_count) + Int64(stats.wire_count) + Int64(stats.compressor_page_count)
    return max(0, pages) * Int64(getpagesize())
  }
  private func swapUsed() -> Int64? {
    var usage = xsw_usage(); var size = MemoryLayout<xsw_usage>.size
    return sysctlbyname("vm.swapusage", &usage, &size, nil, 0) == 0 ? Int64(clamping: usage.xsu_used) : nil
  }
  private func pressure() -> SystemMonitor.Pressure {
    var level: Int32 = 0; var size = MemoryLayout<Int32>.size
    guard sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0) == 0 else { return .unknown }
    switch level { case 1: return .normal; case 2: return .warning; case 4: return .critical; default: return .unknown }
  }
}
