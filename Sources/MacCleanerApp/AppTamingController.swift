import AppKit
import Darwin
import MacCleanerCore

@MainActor
protocol TamingBackend {
  func status(_ identity: TamingIdentity) -> TamingTargetStatus
  func setBackground(_ background: Bool, for identity: TamingIdentity) throws
}

enum TamingTargetStatus: Equatable { case current, goneOrChanged, unavailable }

/// Same-user Darwin background policy, reversible without root. Never uses nice, STOP or RAM limits.
@MainActor
struct DarwinTamingBackend: TamingBackend {
  /// Fixed for the life of the process; read once rather than per app per sample.
  static let boot: String = {
    var value = timeval(); var size = MemoryLayout<timeval>.size
    guard sysctlbyname("kern.boottime", &value, &size, nil, 0) == 0 else { return "" }
    return "\(value.tv_sec):\(value.tv_usec)"
  }()
  func status(_ identity: TamingIdentity) -> TamingTargetStatus {
    let boot = Self.boot
    guard !boot.isEmpty else { return .unavailable }
    guard identity.boot == boot, ProcessControlPolicy.allows(pid: identity.pid, bundleID: identity.bundleID) else { return .goneOrChanged }
    guard let usage = ResourceSampler.usage(identity.pid) else {
      errno = 0
      return kill(identity.pid, 0) == -1 && errno == ESRCH ? .goneOrChanged : .unavailable
    }
    guard usage.ri_proc_start_abstime == identity.started else { return .goneOrChanged }
    guard let app = NSRunningApplication(processIdentifier: identity.pid) else { return .unavailable }
    guard !app.isTerminated else { return .goneOrChanged }
    // A still-live birth identity with changed metadata/ownership is uncertain, not gone.
    guard app.bundleIdentifier == identity.bundleID,
      app.bundleURL?.resolvingSymlinksInPath().path == identity.path else { return .unavailable }
    var info = proc_bsdinfo()
    let size = MemoryLayout<proc_bsdinfo>.stride
    guard proc_pidinfo(identity.pid, PROC_PIDTBSDINFO, 0, &info, Int32(size)) == Int32(size) else { return .unavailable }
    return info.pbi_uid == geteuid() ? .current : .unavailable
  }
  func setBackground(_ background: Bool, for identity: TamingIdentity) throws {
    guard status(identity) == .current else { throw CocoaError(.executableNotLoadable) }
    if background, NSRunningApplication(processIdentifier: identity.pid)?.activationPolicy != .regular {
      throw CocoaError(.executableNotLoadable)
    }
    guard setpriority(PRIO_DARWIN_PROCESS, id_t(identity.pid), background ? PRIO_DARWIN_BG : 0) == 0 else {
      throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
    }
  }
}

@MainActor
final class AppTamingController {
  private(set) var state = TamingState()
  private(set) var autoEnabled = false // Explicitly opt in each MacMint session.
  private(set) var message: String?
  private var policy = AutoTamingPolicy()
  private let backend: any TamingBackend
  private let store: TamingStore
  private var ready = false
  private var activated = false
  private var failed: Set<TamingIdentity> = []
  private var suppressed: Set<TamingIdentity> = []
  private var lockDescriptor: Int32 = -1

  init(store: TamingStore, backend: any TamingBackend = DarwinTamingBackend()) {
    self.store = store; self.backend = backend
    do { state = try store.load(); ready = true }
    catch { message = "Slowdown is unavailable because its recovery record could not be read. The record has been preserved." }
  }
  func activate() {
    guard !activated else { return }
    if backend is DarwinTamingBackend, ready {
      do {
        try FileManager.default.createDirectory(at: store.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let descriptor = open(store.url.path + ".lock", O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw CocoaError(.fileWriteNoPermission) }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
          close(descriptor); throw CocoaError(.fileLocking)
        }
        lockDescriptor = descriptor
        // Reload only after owning the lock; another instance may just have exited.
        state = try store.load()
      } catch {
        ready = false; message = "Slowdown is unavailable: another MacMint instance owns the controls, or recovery storage is unavailable."
        return
      }
    }
    activated = true
    // A previous run may have ended between intent, syscall and acknowledgment.
    for receipt in state.receipts { restore(receipt.identity) }
  }
  deinit { if lockDescriptor >= 0 { close(lockDescriptor) } }
  var needsMonitoring: Bool { activated && (autoEnabled || !state.receipts.isEmpty) }
  func receipt(pid: Int32, started: UInt64) -> TamingReceipt? {
    state.receipts.first { $0.identity.pid == pid && $0.identity.started == started }
  }
  func isExcepted(_ bundleID: String?) -> Bool { bundleID.map { state.exceptions[$0.lowercased()] != nil } ?? true }
  func setAutomatic(_ enabled: Bool) {
    guard activated, ready else { return }
    autoEnabled = enabled; policy.reset(); failed = []; suppressed = []
    if !enabled { for item in state.receipts where item.automatic { restore(item.identity) } }
  }
  func setException(bundleID: String, name: String, protected: Bool) {
    guard ready, !bundleID.isEmpty else { return }
    let key = bundleID.lowercased()
    if protected {
      // Restore even if saving the preference subsequently fails.
      for item in state.receipts where item.identity.bundleID.lowercased() == key { restore(item.identity) }
    }
    var next = state; next.exceptions[key] = protected ? name : nil
    commit(next)
  }
  func slow(_ identity: TamingIdentity, name: String, now: Date, automatic: Bool = false, duration: TimeInterval = 900) {
    guard activated, ready, state.receipts.count < 64, !isExcepted(identity.bundleID),
      !failed.contains(identity),
      !state.receipts.contains(where: { $0.identity == identity }) else { return }
    guard backend.status(identity) == .current else {
      message = "Could not verify \(name)'s current process or permissions. Refresh before trying slowdown."
      return
    }
    let receipt = TamingReceipt(identity: identity, name: name, automatic: automatic,
      expires: now.addingTimeInterval(automatic ? 300 : min(3600, max(60, duration))))
    var next = state; next.receipts.append(receipt)
    guard commit(next) else { return } // Durable intent precedes the first OS mutation.
    do { try backend.setBackground(true, for: identity); message = "Slowed \(name). Switch to the app or choose Restore to return its priority." }
    catch {
      failed.insert(identity)
      // Keep the intent if rollback cannot be proved: recovery may still be needed.
      restore(identity)
      message = "macOS could not slow \(name): \(error.localizedDescription)"
    }
  }
  func restore(_ identity: TamingIdentity, now: Date = Date(), suppress: Bool = false) {
    guard activated, ready, let item = state.receipts.first(where: { $0.identity == identity }) else { return }
    if suppress { suppressed.insert(identity) }
    do {
      switch backend.status(identity) {
      case .current: try backend.setBackground(false, for: identity)
      case .goneOrChanged: break
      case .unavailable: throw CocoaError(.fileReadNoPermission)
      }
      var next = state; next.receipts.removeAll { $0.identity == identity }
      if commit(next) { policy.restored(identity, now: now); message = "Restored \(item.name)" }
    } catch { message = "Could not restore \(item.name). Its recovery record is kept; try Restore again. \(error.localizedDescription)" }
  }
  func restoreAll() {
    guard activated, ready else { return }
    autoEnabled = false; policy.reset()
    for item in state.receipts { restore(item.identity) }
  }
  func foregroundChanged(_ bundleID: String?) {
    guard let bundleID else { return }
    for item in state.receipts where item.identity.bundleID == bundleID { restore(item.identity) }
    policy.reset()
  }
  func tick(apps: [SystemMonitor.AppUsage], systemCPU: Double?, foreground: String?, now: Date) {
    // Off with nothing slowed: no identities to resolve, nothing to restore or evaluate.
    guard needsMonitoring else { return }
    let identities = apps.compactMap { usage -> (TamingIdentity, SystemMonitor.AppUsage)? in
      guard let id = Self.identity(usage) else { return nil }; return (id, usage)
    }
    let live = Set(identities.map(\.0))
    failed.formIntersection(live); suppressed.formIntersection(live)
    let candidates = identities.map { identity, usage in
      let existing = state.receipts.first { $0.identity == identity }
      return AutoTamingPolicy.Candidate(identity: identity, cpu: usage.cpuPercent,
        eligible: usage.canControl && usage.bundleID != foreground && !isExcepted(usage.bundleID)
          && !failed.contains(identity) && !suppressed.contains(identity)
          && (existing?.automatic == false || Self.allowsAutomatic(identity.bundleID)))
    }
    let actions = policy.evaluate(candidates: candidates, active: state.receipts,
      systemCPU: systemCPU, now: now, enabled: autoEnabled)
    for identity in actions.restore { restore(identity, now: now) }
    for identity in actions.slow {
      if let usage = identities.first(where: { $0.0 == identity })?.1 {
        slow(identity, name: usage.name, now: now, automatic: true)
      }
    }
  }
  static func identity(_ usage: SystemMonitor.AppUsage) -> TamingIdentity? {
    guard let bundleID = usage.bundleID, let url = usage.application.bundleURL, usage.started > 0 else { return nil }
    let boot = DarwinTamingBackend.boot
    guard !boot.isEmpty else { return nil }
    return TamingIdentity(pid: usage.id, started: usage.started, boot: boot,
      bundleID: bundleID, path: url.resolvingSymlinksInPath().path)
  }
  static func allowsAutomatic(_ bundleID: String) -> Bool {
    let id = bundleID.lowercased()
    // Avoid system and common real-time calling/audio apps by default.
    return !["com.apple.", "us.zoom.", "com.microsoft.teams", "com.hnc.discord", "com.spotify.", "com.cisco.", "com.tinyspeck.slackmacgap"].contains { id.hasPrefix($0) }
  }
  @discardableResult private func commit(_ next: TamingState) -> Bool {
    guard ready else { return false }
    do { try store.save(next); state = next; return true }
    catch { message = "Could not save slowdown recovery data. No new slowdown was applied; existing recovery records are kept."; return false }
  }
}
