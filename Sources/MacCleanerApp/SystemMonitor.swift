import AppKit
import Darwin
import Foundation
import MacCleanerCore

/// Views own idempotent leases; a serial utility sampler performs kernel/filesystem work.
/// Window leases pause while the workspace isn't in front (hidden, inactive, minimized or
/// covered); the menu bar popover and Auto Tame keep theirs. Per-sample readings live in
/// `live`, so only views that display them re-render when a sample arrives.
@MainActor
final class SystemMonitor: ObservableObject {
  enum Pressure: String, Sendable { case normal = "Normal", warning = "Elevated", critical = "High", unknown = "Unavailable" }
  struct Snapshot: Equatable, Sendable {
    var freeBytes: Int64 = 0
    var totalBytes: Int64 = 0
    /// The latest disk read failed; the capacity shown is the last good reading.
    var diskStale = false
    var cpuUsage: Double?
    var memoryUsedBytes: Int64?
    var physicalMemory: Int64 = Int64(ProcessInfo.processInfo.physicalMemory)
    var swapUsedBytes: Int64?
    var pressure: Pressure = .unknown
    /// False until macOS has reported a capacity. Zero free bytes is then unknown, not a full disk.
    var hasDiskReading: Bool { totalBytes > 0 }
    var diskUsedFraction: Double? {
      hasDiskReading ? min(1, max(0, Double(totalBytes - freeBytes) / Double(totalBytes))) : nil
    }
  }
  struct AppUsage: Identifiable, Equatable {
    let id: pid_t
    let name: String
    let bundleID: String?
    /// The app's own process. Auto Tame and the process controls act on this process only.
    let memoryBytes: Int64
    let cpuPercent: Double?
    let started: UInt64
    let application: NSRunningApplication
    /// Processes the app started (renderers, extension hosts and their tools); nil when not sampled.
    var helpers: ProcessFamilies.Helpers? = nil
    var canControl: Bool { ProcessControlPolicy.allows(pid: id, bundleID: bundleID) }
    /// The app and its helpers together, for display only.
    var totalMemoryBytes: Int64 { ProcessFamilies.add(memoryBytes, helpers?.memoryBytes ?? 0) }
    /// Unknown until at least one helper has two samples, rather than the app's CPU alone.
    var totalCPUPercent: Double? {
      guard let own = cpuPercent else { return nil }
      guard let helpers, helpers.count > 0 else { return own }
      return helpers.cpuMeasured > 0 ? own + helpers.cpuPercent : nil
    }
  }
  struct Reading: Equatable {
    var snapshot = Snapshot()
    var apps: [AppUsage] = []
    var sampledAt: Date?
  }
  /// One publication per sample, observed only by views that show readings.
  @MainActor final class LiveReadings: ObservableObject {
    @Published fileprivate(set) var reading = Reading()
  }
  enum LeaseKind: Sendable {
    /// A workspace screen: sampled only while the workspace window is in front.
    case window
    /// The menu bar popover while it is open.
    case popover
    /// Auto Tame / slowdown expiry: samples without publishing readings to views.
    case control
  }
  let live = LiveReadings()
  var snapshot: Snapshot { live.reading.snapshot }
  var apps: [AppUsage] { live.reading.apps }
  var sampledAt: Date? { live.reading.sampledAt }
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
  private let activity: AppActivity
  private(set) var isForeground: Bool
  init(tamingController: AppTamingController? = nil, activity: AppActivity? = nil) {
    self.tamingController = tamingController ?? AppTamingController(store: TamingStore(
      url: AppPaths.supportDirectory.appendingPathComponent("process-slowdown.json")))
    let activity = activity ?? .shared
    self.activity = activity
    isForeground = activity.isForeground
    activity.observe { [weak self] foreground in self?.foregroundChanged(foreground) }
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
        guard let self, self.tamingController.needsMonitoring else { return }
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
    // Auto Tame shares this sampler; it never runs a second loop, and none while it is off.
    if tamingController.needsMonitoring { start(lease: tamingLease, interval: 8, kind: .control) }
    else { stop(lease: tamingLease) }
  }
  private var timer: Timer?
  private struct Lease { var interval: TimeInterval; var kind: LeaseKind }
  private var leases: [UUID: Lease] = [:]
  private(set) var samplingInterval: TimeInterval?
  private var samplingTask: Task<Void, Never>?
  private var generation = UUID()
  private let sampler = ResourceSampler()
  private(set) var activeLeaseCount = 0
  /// Process-wide counts, reported by `--resource-probe` launches.
  private(set) static var samples = 0
  private(set) static var publishedSamples = 0

  func start(lease: UUID, interval: TimeInterval = 4, kind: LeaseKind = .window) {
    if kind == .window { activity.refresh() }
    let next = Lease(interval: max(3, interval), kind: kind)
    if let current = leases[lease], current.interval == next.interval, current.kind == next.kind { return }
    leases[lease] = next; activeLeaseCount = leases.count
    configureTimer()
  }
  func stop(lease: UUID) {
    guard leases.removeValue(forKey: lease) != nil else { return }
    activeLeaseCount = leases.count
    configureTimer()
  }
  /// Readings reach views only while something visible consumes them.
  var publishesReadings: Bool {
    leases.isEmpty || leases.values.contains { $0.kind == .popover || ($0.kind == .window && isForeground) }
  }
  /// Helper processes are listed whenever readings reach an open Performance list, which shows
  /// per-app totals (also while the popover keeps sampling with the workspace in the back).
  /// The popover alone and Auto Tame don't need them.
  var listsHelpers: Bool { publishesReadings && leases.values.contains { $0.kind == .window } }
  private func foregroundChanged(_ foreground: Bool) {
    guard foreground != isForeground else { return }
    let wasPublishing = publishesReadings
    isForeground = foreground
    let before = samplingInterval
    configureTimer()
    // Returning to the front refreshes immediately instead of showing a stale reading.
    if !wasPublishing, publishesReadings, samplingInterval != nil, samplingInterval == before { sample() }
  }
  private func configureTimer() {
    let requested = leases.values.filter { $0.kind != .window || isForeground }.map(\.interval).min()
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
    let families = listsHelpers
    samplingTask = Task { [weak self] in
      let work = Task.detached(priority: .utility) { await sampler.read(pids: pids, families: families) }
      let result = await withTaskCancellationHandler { await work.value } onCancel: { work.cancel() }
      guard let self, !Task.isCancelled, generation == token else { return }
      defer { samplingTask = nil }
      Self.samples += 1
      let usages = applications.compactMap { app -> AppUsage? in
        guard !app.isTerminated, let reading = result.apps[app.processIdentifier] else { return nil }
        return AppUsage(id: app.processIdentifier, name: app.localizedName ?? "App", bundleID: app.bundleIdentifier,
          memoryBytes: reading.memoryBytes, cpuPercent: reading.cpuPercent, started: reading.started, application: app,
          helpers: reading.helpers)
      }
      if publishesReadings {
        live.reading = Reading(snapshot: result.snapshot, apps: usages, sampledAt: Date())
        Self.publishedSamples += 1
      }
      guard tamingController.needsMonitoring else { return }
      tamingController.tick(apps: usages, systemCPU: result.snapshot.cpuUsage,
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
  struct AppReading: Sendable {
    let started: UInt64; let memoryBytes: Int64; let cpuPercent: Double?
    var helpers: ProcessFamilies.Helpers? = nil
  }
  struct Result: Sendable { let snapshot: SystemMonitor.Snapshot; let apps: [pid_t: AppReading] }
  typealias DiskReader = @Sendable () -> (free: Int64, total: Int64)?
  /// Important-usage capacity can make macOS compute purgeable space, so it is read at
  /// most this often and reused by the samples in between.
  static let diskInterval: TimeInterval = 60
  private struct Baseline { let started: UInt64; let cpu: UInt64; let time: UInt64 }
  private var baselines: [pid_t: Baseline] = [:]
  /// Full executable names of displayed helpers, reused while the same process lives.
  private var helperNames: [pid_t: (started: UInt64, name: String)] = [:]
  private var previousTicks: (busy: UInt64, total: UInt64)?
  /// The last good capacity; a failed read keeps it (marked stale) instead of reporting zero.
  private var disk: (free: Int64, total: Int64)?
  private var diskCheckedAt: TimeInterval?
  private var diskStale = false
  private let readDisk: DiskReader
  private let clock: @Sendable () -> TimeInterval
  private(set) var diskReads = 0

  init(readDisk: @escaping DiskReader = ResourceSampler.startupDisk,
    clock: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
    self.readDisk = readDisk; self.clock = clock
  }

  func reset() { baselines = [:]; previousTicks = nil; helperNames = [:] }

  func read(pids: [pid_t], families: Bool = false) -> Result {
    var next = SystemMonitor.Snapshot()
    if let capacity = diskCapacity() {
      next.totalBytes = capacity.total; next.freeBytes = capacity.free; next.diskStale = diskStale
    }
    next.cpuUsage = cpuUsage(); next.memoryUsedBytes = Self.memoryUsed(); next.swapUsedBytes = Self.swapUsed(); next.pressure = Self.pressure()
    var readings: [pid_t: AppReading] = [:], updated: [pid_t: Baseline] = [:]
    let listing = families ? Self.listProcesses() : []
    let members = families ? ProcessFamilies.members(of: Set(pids), in: listing) : [:]
    let records = families ? Dictionary(listing.map { ($0.pid, $0) }, uniquingKeysWith: { first, _ in first }) : [:]
    var names: [pid_t: (started: UInt64, name: String)] = [:]
    for pid in pids {
      guard !Task.isCancelled, let own = measure(pid, into: &updated) else { continue }
      var reading = AppReading(started: own.started, memoryBytes: own.memoryBytes, cpuPercent: own.cpuPercent)
      if families {
        var started: [pid_t: UInt64] = [:]
        let usages = (members[pid] ?? []).compactMap { helper -> ProcessFamilies.Usage? in
          guard !Task.isCancelled, let measured = measure(helper, into: &updated) else { return nil }
          started[helper] = measured.started
          return ProcessFamilies.Usage(pid: helper, name: records[helper]?.name ?? "Helper",
            memoryBytes: measured.memoryBytes, cpuPercent: measured.cpuPercent)
        }
        var helpers = ProcessFamilies.Helpers(usages)
        for index in helpers.largest.indices {
          let helper = helpers.largest[index], birth = started[helper.pid] ?? 0
          let name = helperNames[helper.pid].flatMap { $0.started == birth ? $0.name : nil }
            ?? Self.executableName(helper.pid) ?? helper.name
          names[helper.pid] = (birth, name); helpers.largest[index].name = name
        }
        reading.helpers = helpers
      }
      readings[pid] = reading
    }
    baselines = updated
    if families { helperNames = names }
    return Result(snapshot: next, apps: readings)
  }

  /// One process's footprint and CPU since its previous reading, recording the next baseline.
  private func measure(_ pid: pid_t, into updated: inout [pid_t: Baseline])
    -> (started: UInt64, memoryBytes: Int64, cpuPercent: Double?)? {
    guard let info = Self.usage(pid) else { return nil }
    // XNU rusage CPU counters and mach_absolute_time share the Mach absolute timebase.
    // Dividing deltas avoids assuming nanoseconds on Apple silicon.
    let time = mach_absolute_time(), cpu = info.ri_user_time &+ info.ri_system_time
    let percent = baselines[pid].flatMap { old in
      Self.cpuPercent(previousCPU: old.cpu, currentCPU: cpu, previousTime: old.time, currentTime: time,
        sameProcess: old.started == info.ri_proc_start_abstime)
    }
    updated[pid] = Baseline(started: info.ri_proc_start_abstime, cpu: cpu, time: time)
    return (info.ri_proc_start_abstime, Int64(clamping: info.ri_phys_footprint), percent)
  }

  /// Parent, start time and short name of every process this user may inspect: one listing
  /// plus one BSD-info call per process. Processes that exit or refuse access are skipped.
  nonisolated static func listProcesses() -> [ProcessRecord] {
    let estimate = proc_listallpids(nil, 0)
    guard estimate > 0 else { return [] }
    var pids = [pid_t](repeating: 0, count: Int(estimate) + 64)
    let count = pids.withUnsafeMutableBytes { proc_listallpids($0.baseAddress, Int32(clamping: $0.count)) }
    guard count > 0 else { return [] }
    let size = Int32(MemoryLayout<proc_bsdinfo>.stride)
    return pids.prefix(min(Int(count), pids.count)).compactMap { pid -> ProcessRecord? in
      guard pid > 0 else { return nil }
      var info = proc_bsdinfo()
      guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
      let started = info.pbi_start_tvsec &* 1_000_000 &+ info.pbi_start_tvusec
      return ProcessRecord(pid: pid, parent: Int32(bitPattern: info.pbi_ppid), started: started, name: shortName(info))
    }
  }

  private nonisolated static func shortName(_ info: proc_bsdinfo) -> String {
    let name = withUnsafeBytes(of: info.pbi_name) { bytes in String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self) }
    guard name.isEmpty else { return name }
    return withUnsafeBytes(of: info.pbi_comm) { bytes in String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self) }
  }

  /// The executable's file name, which isn't truncated like the kernel's short name.
  nonisolated static func executableName(_ pid: pid_t) -> String? {
    var buffer = [UInt8](repeating: 0, count: 4 * Int(MAXPATHLEN))
    let length = buffer.withUnsafeMutableBytes { proc_pidpath(pid, $0.baseAddress, UInt32($0.count)) }
    guard length > 0 else { return nil }
    let name = URL(fileURLWithPath: String(decoding: buffer.prefix(Int(length)), as: UTF8.self)).lastPathComponent
    return name.isEmpty ? nil : name
  }

  private func diskCapacity() -> (free: Int64, total: Int64)? {
    let now = clock()
    if let checked = diskCheckedAt, now >= checked, now - checked < Self.diskInterval { return disk }
    diskReads += 1; diskCheckedAt = now
    if let value = readDisk(), value.total > 0, value.free >= 0 {
      disk = value; diskStale = false
    } else {
      diskStale = disk != nil
    }
    return disk
  }

  /// Nil when either capacity is missing: a missing value is not a measured zero.
  nonisolated static func startupDisk() -> (free: Int64, total: Int64)? {
    let reading = VolumeSummary.capacity()
    guard let free = reading.free, let total = reading.total, total > 0 else { return nil }
    return (free: free, total: total)
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
  /// App memory + wired + compressed: what Activity Monitor calls Memory Used.
  nonisolated static func memoryUsed() -> Int64? {
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
  nonisolated static func swapUsed() -> Int64? {
    var usage = xsw_usage(); var size = MemoryLayout<xsw_usage>.size
    return sysctlbyname("vm.swapusage", &usage, &size, nil, 0) == 0 ? Int64(clamping: usage.xsu_used) : nil
  }
  nonisolated static func pressure() -> SystemMonitor.Pressure {
    var level: Int32 = 0; var size = MemoryLayout<Int32>.size
    guard sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0) == 0 else { return .unknown }
    switch level { case 1: return .normal; case 2: return .warning; case 4: return .critical; default: return .unknown }
  }
}
