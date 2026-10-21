import Foundation

public enum CleanupRisk: String, Codable, Sendable, CaseIterable {
  case safe
  case review
  case restricted
}

public enum CleanupCategory: String, Codable, Sendable, CaseIterable, Identifiable {
  case userCaches = "User Caches"
  case userLogs = "User Logs"
  case browserCaches = "Browser Caches"
  case developerJunk = "Developer Junk"
  case deviceBackups = "Device Backups"
  case diagnostics = "Diagnostics"
  case appLeftovers = "App Leftovers"
  case installers = "Old Installers"
  case mailAttachments = "Mail Attachments"
  case deviceFirmware = "Device Firmware"

  public var id: String { rawValue }
}

public enum ScanIssueSeverity: String, Codable, Sendable, CaseIterable {
  case info
  case warning
  case error
}

public struct ScanIssue: Identifiable, Codable, Hashable, Sendable {
  public let id: UUID
  public let area: String
  public let path: String?
  public let severity: ScanIssueSeverity
  public let message: String

  public init(
    id: UUID = UUID(), area: String, path: String? = nil, severity: ScanIssueSeverity = .warning,
    message: String
  ) {
    self.id = id
    self.area = area
    self.path = path
    self.severity = severity
    self.message = message
  }
}

public struct ScanReport<Value: Sendable>: Sendable {
  public let value: Value
  public let issues: [ScanIssue]
  public let duration: TimeInterval
  public let wasCancelled: Bool

  public init(
    value: Value, issues: [ScanIssue] = [], duration: TimeInterval, wasCancelled: Bool = false
  ) {
    self.value = value
    self.issues = issues
    self.duration = duration
    self.wasCancelled = wasCancelled
  }
}

public struct CleanupTarget: Identifiable, Codable, Hashable, Sendable {
  public let id: UUID
  public let category: CleanupCategory
  public let url: URL
  public let displayName: String
  public let detail: String
  public let size: Int64
  public let risk: CleanupRisk
  public let reason: String
  public var isSelected: Bool
  /// App that writes this data; cleanup is skipped while it is running.
  public let ownerBundleID: String?
  /// "device:inode" observed at scan time.
  public let identity: String?

  public init(
    id: UUID = UUID(),
    category: CleanupCategory,
    url: URL,
    displayName: String,
    detail: String = "",
    size: Int64,
    risk: CleanupRisk,
    reason: String,
    isSelected: Bool = true,
    ownerBundleID: String? = nil,
    identity: String? = nil
  ) {
    self.ownerBundleID = ownerBundleID
    self.identity = identity
    self.id = id
    self.category = category
    self.url = url
    self.displayName = displayName
    self.detail = detail
    self.size = size
    self.risk = risk
    self.reason = reason
    self.isSelected = isSelected
  }
}

public struct LargeFile: Identifiable, Codable, Hashable, Sendable {
  public let id: UUID
  public let url: URL
  public let size: Int64
  public let modifiedAt: Date?
  public let accessedAt: Date?
  /// Physical file identity ("device:inode"). Equal identities are hard links to one file.
  public let identity: String?

  public init(
    id: UUID = UUID(), url: URL, size: Int64, modifiedAt: Date?, accessedAt: Date?,
    identity: String? = nil
  ) {
    self.id = id
    self.url = url
    self.size = size
    self.modifiedAt = modifiedAt
    self.accessedAt = accessedAt
    self.identity = identity
  }
}

public struct DuplicateGroup: Identifiable, Codable, Hashable, Sendable {
  public let id: UUID
  public let fingerprint: String
  public let files: [LargeFile]

  public init(id: UUID = UUID(), fingerprint: String, files: [LargeFile]) {
    self.id = id
    self.fingerprint = fingerprint
    self.files = files
  }

  /// Distinct physical copies. Hard links to the same file count once.
  public var physicalCopyCount: Int {
    var seen: Set<String> = []
    var count = 0
    for file in files {
      if let identity = file.identity {
        if seen.insert(identity).inserted { count += 1 }
      } else {
        count += 1
      }
    }
    return count
  }

  public var reclaimableBytes: Int64 {
    guard let size = files.first?.size, physicalCopyCount > 1 else { return 0 }
    return Int64(physicalCopyCount - 1) * size
  }
}

public enum MatchConfidence: String, Codable, Sendable, CaseIterable {
  case high, medium, low

  var rank: Int {
    switch self {
    case .high: return 0
    case .medium: return 1
    case .low: return 2
    }
  }
}

public struct AppRecord: Identifiable, Codable, Hashable, Sendable {
  public let id: UUID
  public let url: URL
  public let name: String
  public let bundleIdentifier: String?
  public let version: String?
  public let bundleSize: Int64
  public let lastModified: Date?
  public let identity: String?
  /// Spotlight's last-opened date (nil = unknown, never "unused").
  public let lastUsed: Date?

  public init(
    id: UUID = UUID(), url: URL, name: String, bundleIdentifier: String?, version: String?,
    bundleSize: Int64, lastModified: Date?, identity: String? = nil, lastUsed: Date? = nil
  ) {
    self.identity = identity
    self.lastUsed = lastUsed
    self.id = id
    self.url = url
    self.name = name
    self.bundleIdentifier = bundleIdentifier
    self.version = version
    self.bundleSize = bundleSize
    self.lastModified = lastModified
  }
}

public struct AppLeftover: Identifiable, Codable, Hashable, Sendable {
  public let id: UUID
  public let url: URL
  public let size: Int64
  public let confidence: MatchConfidence
  public let reason: String
  /// Shared containers (e.g. app groups) may also be used by other apps from the same developer.
  public let isShared: Bool
  public let identity: String?

  public init(
    id: UUID = UUID(), url: URL, size: Int64, confidence: MatchConfidence, reason: String,
    isShared: Bool = false, identity: String? = nil
  ) {
    self.identity = identity
    self.id = id
    self.url = url
    self.size = size
    self.confidence = confidence
    self.reason = reason
    self.isShared = isShared
  }

  /// Only exact, unshared matches are suggested for selection by default.
  public var isSuggested: Bool { confidence == .high && !isShared }
}

public struct StartupItem: Identifiable, Codable, Hashable, Sendable {
  public let id: UUID
  public let url: URL
  public let label: String
  public let program: String?
  public let runAtLoad: Bool
  public let keepAlive: Bool
  /// The property list's own Disabled key.
  public let disabled: Bool
  public let scope: String
  /// What the declared program points at; nil when it wasn't checked.
  public let target: StartupTarget?
  /// The path that was checked: the program, or the script a shell launcher runs.
  public let targetPath: String?
  /// launchd's enable/disable override, which wins over the Disabled key; nil when none was read.
  public let disabledOverride: Bool?
  /// launchd's view of the job now; nil when it couldn't be read (system daemons, or no answer).
  public let live: StartupLiveState?

  public init(
    id: UUID = UUID(),
    url: URL,
    label: String,
    program: String?,
    runAtLoad: Bool,
    keepAlive: Bool = false,
    disabled: Bool = false,
    scope: String,
    target: StartupTarget? = nil,
    targetPath: String? = nil,
    disabledOverride: Bool? = nil,
    live: StartupLiveState? = nil
  ) {
    self.id = id
    self.url = url
    self.label = label
    self.program = program
    self.runAtLoad = runAtLoad
    self.keepAlive = keepAlive
    self.disabled = disabled
    self.scope = scope
    self.target = target
    self.targetPath = targetPath
    self.disabledOverride = disabledOverride
    self.live = live
  }

  /// Turned off by a launchd override, or by its own Disabled key when there is no override.
  public var isDisabled: Bool { disabledOverride ?? disabled }

  /// The declared program can't run as written (missing, in the Trash, or on a disk that isn't connected).
  public var hasBrokenTarget: Bool { target?.isBroken ?? false }

  /// Something worth a look: a broken target, or a last run that ended with an error.
  public var needsAttention: Bool { hasBrokenTarget || (live?.kind == .failed && !isDisabled) }
}

/// What a startup item's declared program points at, checked without running anything.
public enum StartupTarget: String, Codable, Hashable, Sendable {
  case present
  /// Nothing exists at the path (for example, the app was deleted or moved).
  case missing
  /// The path is inside a Trash folder.
  case inTrash
  /// The path is under /Volumes on a disk that isn't connected, often an installer disk image.
  case volumeNotMounted
  /// The program exists on another connected disk and runs only while that disk is attached.
  case otherVolume
  /// No absolute path could be checked: an inline shell command, a name looked up on PATH, or no program key.
  case unresolved

  public var isBroken: Bool { self == .missing || self == .inTrash || self == .volumeNotMounted }
}

/// launchd's state for a job in the user's session.
public struct StartupLiveState: Codable, Hashable, Sendable {
  public enum Kind: String, Codable, Hashable, Sendable {
    /// A process is running now.
    case running
    /// Loaded and idle: launchd starts it when its trigger fires. Not a problem.
    case waiting
    /// Loaded and idle, and its last run exited with an error code.
    case failed
    /// Not loaded in this session, so it won't start until the next login (or at all).
    case notLoaded
  }
  public let kind: Kind
  public let pid: Int32?
  /// Exit code of the last run; negative values are the signal that ended it.
  public let lastExitStatus: Int32?

  public init(kind: Kind, pid: Int32? = nil, lastExitStatus: Int32? = nil) {
    self.kind = kind
    self.pid = pid
    self.lastExitStatus = lastExitStatus
  }

  /// A missing job is not loaded. An exit by signal (for example when macOS stops an idle
  /// helper) is not counted as a failure; only a positive exit code is.
  public init(job: LaunchdDomain.Job?) {
    guard let job else { self.init(kind: .notLoaded); return }
    if let pid = job.pid { self.init(kind: .running, pid: pid, lastExitStatus: job.lastExitStatus); return }
    let failed = (job.lastExitStatus ?? 0) > 0
    self.init(kind: failed ? .failed : .waiting, lastExitStatus: job.lastExitStatus)
  }
}

/// launchd's jobs and overrides for one domain, parsed from `launchctl` output.
public struct LaunchdDomain: Sendable, Equatable {
  public struct Job: Sendable, Equatable {
    public let pid: Int32?
    public let lastExitStatus: Int32?

    public init(pid: Int32?, lastExitStatus: Int32?) {
      self.pid = pid
      self.lastExitStatus = lastExitStatus
    }
  }

  /// Loaded jobs by label; nil when the job list couldn't be read.
  public var jobs: [String: Job]?
  /// Enable/disable overrides by label (true = disabled).
  public var overrides: [String: Bool]

  public init(jobs: [String: Job]?, overrides: [String: Bool] = [:]) {
    self.jobs = jobs
    self.overrides = overrides
  }

  /// `launchctl list`: tab-separated PID ("-" when not running), last exit status and label.
  public static func parseJobs(_ text: String) -> [String: Job] {
    var jobs: [String: Job] = [:]
    for line in text.split(whereSeparator: \.isNewline) {
      let fields = line.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
      guard fields.count == 3, fields[0] != "PID", !fields[2].isEmpty else { continue }
      let pid = Int32(fields[0]).flatMap { $0 > 0 ? $0 : nil }
      jobs[String(fields[2])] = Job(pid: pid, lastExitStatus: Int32(fields[1]))
    }
    return jobs
  }

  /// The "disabled services" block of `launchctl print-disabled`, in either the
  /// `=> disabled/enabled` or the older `=> true/false` form.
  public static func parseOverrides(_ text: String) -> [String: Bool] {
    var overrides: [String: Bool] = [:]
    var inside = false
    for raw in text.split(whereSeparator: \.isNewline) {
      let line = raw.trimmingCharacters(in: .whitespaces)
      if line.hasPrefix("disabled services") { inside = true; continue }
      if line.hasPrefix("}") { inside = false; continue }
      guard inside, line.hasPrefix("\""), let arrow = line.range(of: "\" => ") else { continue }
      let label = String(line[line.index(after: line.startIndex)..<arrow.lowerBound])
      switch line[arrow.upperBound...] {
      case "disabled", "true": overrides[label] = true
      case "enabled", "false": overrides[label] = false
      default: continue
      }
    }
    return overrides
  }
}

/// The user's session domain and the system domain, as far as an unprivileged reader can see.
public struct LaunchdSnapshot: Sendable, Equatable {
  public var user: LaunchdDomain?
  public var system: LaunchdDomain?

  public init(user: LaunchdDomain?, system: LaunchdDomain?) {
    self.user = user
    self.system = system
  }
}

public struct ScanSummary: Sendable {
  public let cleanupTargets: [CleanupTarget]
  public let reclaimableBytes: Int64
  public let reviewBytes: Int64
  public let apps: [AppRecord]
  public let startupItems: [StartupItem]
  public let issues: [ScanIssue]
  public let scannedAt: Date
  public let duration: TimeInterval
  public let wasCancelled: Bool

  public init(
    cleanupTargets: [CleanupTarget],
    reclaimableBytes: Int64,
    reviewBytes: Int64 = 0,
    apps: [AppRecord],
    startupItems: [StartupItem],
    issues: [ScanIssue] = [],
    scannedAt: Date = Date(),
    duration: TimeInterval = 0,
    wasCancelled: Bool = false
  ) {
    self.cleanupTargets = cleanupTargets
    self.reclaimableBytes = reclaimableBytes
    self.reviewBytes = reviewBytes
    self.apps = apps
    self.startupItems = startupItems
    self.issues = issues
    self.scannedAt = scannedAt
    self.duration = duration
    self.wasCancelled = wasCancelled
  }
}

public struct OperationFailure: Codable, Hashable, Sendable {
  public let url: URL
  public let message: String

  public init(url: URL, message: String) {
    self.url = url
    self.message = message
  }
}

/// Where an item went when it was moved to Trash, so it can be restored later.
public struct TrashReceipt: Codable, Hashable, Sendable {
  public let originalPath: String
  public let trashPath: String?
  public let bytes: Int64
  public let movedAt: Date
  /// "device:inode" of the moved item; a move to the Trash keeps it, so restore can verify
  /// that what's in the Trash now is the same item.
  public let identity: String?

  public init(
    originalPath: String, trashPath: String?, bytes: Int64, movedAt: Date = Date(),
    identity: String? = nil
  ) {
    self.originalPath = originalPath
    self.trashPath = trashPath
    self.bytes = bytes
    self.movedAt = movedAt
    self.identity = identity
  }
}

public struct CleanupResult: Sendable {
  public let movedToTrash: [URL]
  public let failed: [OperationFailure]
  public let bytesAttempted: Int64
  public let bytesMoved: Int64
  public let receipts: [TrashReceipt]
  public let wasCancelled: Bool

  public init(
    movedToTrash: [URL], failed: [OperationFailure], bytesAttempted: Int64, bytesMoved: Int64,
    receipts: [TrashReceipt] = [], wasCancelled: Bool = false
  ) {
    self.movedToTrash = movedToTrash
    self.failed = failed
    self.bytesAttempted = bytesAttempted
    self.bytesMoved = bytesMoved
    self.receipts = receipts
    self.wasCancelled = wasCancelled
  }
}

/// Limits progress callbacks, and the main-actor hops behind them, to a steady rate.
/// The first call always reports so short operations still show progress.
public struct ProgressThrottle: Sendable {
  private let interval: TimeInterval
  private let now: @Sendable () -> TimeInterval
  private var last: TimeInterval?

  public init(interval: TimeInterval = 0.2, now: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
    self.interval = interval
    self.now = now
  }

  public mutating func shouldReport() -> Bool {
    let current = now()
    if let last, current - last < interval { return false }
    last = current
    return true
  }
}
