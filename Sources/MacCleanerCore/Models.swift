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
  public let disabled: Bool
  public let scope: String

  public init(
    id: UUID = UUID(),
    url: URL,
    label: String,
    program: String?,
    runAtLoad: Bool,
    keepAlive: Bool = false,
    disabled: Bool = false,
    scope: String
  ) {
    self.id = id
    self.url = url
    self.label = label
    self.program = program
    self.runAtLoad = runAtLoad
    self.keepAlive = keepAlive
    self.disabled = disabled
    self.scope = scope
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
