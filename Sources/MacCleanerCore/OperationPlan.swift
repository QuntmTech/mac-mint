import Foundation

/// What a planned item is, which decides the safety rule it must pass at execution time.
public enum PlanItemKind: Codable, Hashable, Sendable {
  case cleanupTarget(category: CleanupCategory, risk: CleanupRisk)
  case appBundle
  case appLeftover
  case duplicateCopy
  case reviewedFile
  case developerArtifact

  public var label: String {
    switch self {
    case .cleanupTarget(let category, _): return category.rawValue
    case .appBundle: return "Application"
    case .appLeftover: return "App data"
    case .duplicateCopy: return "Duplicate copy"
    case .reviewedFile: return "Large file"
    case .developerArtifact: return "Developer data"
    }
  }
}

/// Size and modification time of a file when it was scanned; a mismatch means it was edited.
public struct FileSnapshot: Codable, Hashable, Sendable {
  /// Logical size in bytes; nil when only the modification time was recorded.
  public let size: Int64?
  public let modified: Date?

  public init(size: Int64?, modified: Date?) {
    self.size = size
    self.modified = modified
  }

  /// Snapshot of a regular file right now (logical size), or nil for folders.
  public static func current(_ url: URL) -> FileSnapshot? {
    guard let meta = FileSystem.logicalFileMetadata(at: url) else { return nil }
    return FileSnapshot(size: meta.size, modified: meta.modified)
  }

  func matches(_ other: FileSnapshot) -> Bool {
    if let size, let otherSize = other.size, size != otherSize { return false }
    guard let modified, let otherModified = other.modified else { return true }
    return abs(modified.timeIntervalSince(otherModified)) < 0.001
  }
}

/// The copy that stays when a duplicate is removed. It must still exist, unchanged, and must
/// not be removed by the same plan.
public struct KeeperSnapshot: Codable, Hashable, Sendable {
  public let path: String
  public let identity: String?
  public let snapshot: FileSnapshot?

  public init(path: String, identity: String?, snapshot: FileSnapshot?) {
    self.path = path
    self.identity = identity
    self.snapshot = snapshot
  }
}

/// One item the user has chosen to move to Trash, with the evidence used to re-check it later.
public struct PlanItem: Identifiable, Codable, Hashable, Sendable {
  public let id: UUID
  public let url: URL
  public let displayName: String
  public let kind: PlanItemKind
  public let expectedBytes: Int64
  public let reason: String
  /// Screen or flow the item came from ("Cleaner", "Duplicates", "Uninstall Slack"…).
  public let source: String
  /// Personal content or review-risk data the user should look at deliberately.
  public let needsAttention: Bool
  /// The item is only acted on if this other item was moved first (app data after its app).
  public let dependsOn: UUID?
  /// "device:inode" observed when the plan was made. A different file at the same path is skipped.
  public let identity: String?
  /// App whose data this is; the item is skipped while that app is running.
  public let ownerBundleID: String?
  /// For files: size + modification time at scan time.
  public let snapshot: FileSnapshot?
  /// For duplicate copies: the copy that must survive.
  public let keeper: KeeperSnapshot?

  public init(
    id: UUID = UUID(), url: URL, displayName: String, kind: PlanItemKind, expectedBytes: Int64,
    reason: String, source: String, needsAttention: Bool = false, dependsOn: UUID? = nil,
    identity: String? = nil, ownerBundleID: String? = nil, snapshot: FileSnapshot? = nil,
    keeper: KeeperSnapshot? = nil
  ) {
    self.ownerBundleID = ownerBundleID
    self.snapshot = snapshot
    self.keeper = keeper
    self.id = id
    self.url = url
    self.displayName = displayName
    self.kind = kind
    self.expectedBytes = expectedBytes
    self.reason = reason
    self.source = source
    self.needsAttention = needsAttention
    self.dependsOn = dependsOn
    self.identity = identity
  }

  public static func cleanup(_ target: CleanupTarget, source: String = "Cleaner") -> PlanItem {
    PlanItem(
      url: target.url, displayName: target.displayName,
      kind: .cleanupTarget(category: target.category, risk: target.risk),
      expectedBytes: target.size, reason: target.reason, source: source,
      needsAttention: target.risk != .safe,
      identity: target.identity, ownerBundleID: target.ownerBundleID)
  }

  /// `keeper` is the copy that stays; its scan-time state is recorded so the executor can
  /// refuse to remove this copy if the keeper is gone, changed, or also being removed.
  public static func duplicate(_ file: LargeFile, keeper: LargeFile?) -> PlanItem {
    PlanItem(
      url: file.url, displayName: file.url.lastPathComponent, kind: .duplicateCopy,
      expectedBytes: file.size,
      reason: keeper.map { "Identical to \($0.url.lastPathComponent), which is kept." }
        ?? "Exact duplicate; another copy is kept.",
      source: "Duplicates", needsAttention: true, identity: file.identity,
      snapshot: FileSnapshot(size: file.size, modified: file.modifiedAt),
      keeper: keeper.map {
        KeeperSnapshot(
          path: $0.url.standardizedFileURL.path, identity: $0.identity,
          snapshot: FileSnapshot(size: $0.size, modified: $0.modifiedAt))
      })
  }

  public static func developer(_ item: DevStorageItem) -> PlanItem? {
    guard let url = item.url, item.canTrash else { return nil }
    return PlanItem(
      url: url, displayName: "\(item.tool): \(item.title)", kind: .developerArtifact,
      expectedBytes: item.bytes, reason: item.rebuild.explanation, source: item.group.rawValue,
      needsAttention: item.rebuild == .review || item.isActive,
      identity: item.identity, ownerBundleID: item.ownerBundleID)
  }

  /// A folder-based image (never a Photos library asset). For similar shots, the suggested
  /// keeper is recorded so the plan refuses to remove both, and the executor checks it survives.
  public static func photo(
    _ photo: PhotoFingerprint, keeper: PhotoFingerprint?, reason: String, source: String = "Photos"
  ) -> PlanItem? {
    guard !photo.isLibraryAsset, !PhotoAnalysis.isInsideLibraryPackage(photo.url) else { return nil }
    return PlanItem(
      url: photo.url, displayName: photo.url.lastPathComponent, kind: .reviewedFile,
      expectedBytes: photo.bytes, reason: reason, source: source, needsAttention: true,
      identity: photo.identity,
      snapshot: FileSnapshot(size: photo.bytes, modified: photo.modified),
      keeper: keeper.flatMap { kept in
        kept.isLibraryAsset
          ? nil
          : KeeperSnapshot(
            path: kept.url.standardizedFileURL.path, identity: kept.identity,
            snapshot: FileSnapshot(size: kept.bytes, modified: kept.modified))
      })
  }

  /// Library data from an app that is no longer installed. Always needs attention.
  public static func orphan(_ item: OrphanedItem) -> PlanItem {
    PlanItem(
      url: item.url, displayName: item.url.lastPathComponent, kind: .appLeftover,
      expectedBytes: item.bytes, reason: item.reason, source: "Removed apps", needsAttention: true,
      identity: item.identity)
  }

  public static func largeFile(_ file: LargeFile) -> PlanItem {
    PlanItem(
      url: file.url, displayName: file.url.lastPathComponent, kind: .reviewedFile,
      expectedBytes: file.size, reason: "Large file you chose to remove.", source: "Large Files",
      needsAttention: true, identity: file.identity,
      // Large-file sizes are allocated bytes, so only the modification time is compared.
      snapshot: FileSnapshot(size: nil, modified: file.modifiedAt))
  }
}

public struct KeeperConstraint: Hashable, Sendable {
  public let source: URL
  public let keeper: KeeperSnapshot
  public init(source: URL, keeper: KeeperSnapshot) { self.source = source; self.keeper = keeper }
}

public struct OperationPlan: Identifiable, Sendable {
  public let id: UUID
  public let title: String
  public let items: [PlanItem]
  /// Items dropped because a selected parent folder already includes them.
  public let covered: [PlanItem]
  /// Selected items that cannot be part of this plan, with the reason.
  public let excluded: [OperationFailure]
  /// Constraints survive collapsing a selected file into a selected ancestor.
  public let keeperConstraints: [KeeperConstraint]
  public let validationItems: [PlanItem]

  public init(
    id: UUID = UUID(), title: String, items: [PlanItem], covered: [PlanItem] = [],
    excluded: [OperationFailure] = [], protecting: [KeeperConstraint] = [], validationItems: [PlanItem] = []
  ) {
    self.id = id
    self.title = title
    self.items = items
    self.covered = covered
    self.excluded = excluded
    self.validationItems = validationItems
    self.keeperConstraints = protecting + (items + covered).compactMap { item in
      item.keeper.map { KeeperConstraint(source: item.url, keeper: $0) }
    }
  }

  public var totalBytes: Int64 { items.reduce(0) { $0 + $1.expectedBytes } }
  public var attentionItems: [PlanItem] { items.filter(\.needsAttention) }
  public var attentionBytes: Int64 { attentionItems.reduce(0) { $0 + $1.expectedBytes } }
  public var isEmpty: Bool { items.isEmpty }

  public var sources: [String] {
    var seen: Set<String> = []
    return items.map(\.source).filter { seen.insert($0).inserted }
  }
}

public enum OperationPlanner {
  /// Builds a plan: drops exact duplicates and items already inside another selected folder,
  /// and moves anything currently excluded into `excluded` so it is never acted on.
  public static func plan(
    title: String, items: [PlanItem], ignoredPaths: Set<String> = [],
    excluded: [OperationFailure] = [], protecting: [KeeperConstraint] = [], validationItems: [PlanItem] = []
  ) -> OperationPlan {
    var rejected = excluded
    var eligible: [PlanItem] = []
    for item in items {
      if protecting.contains(where: { FileSystem.path(URL(fileURLWithPath: $0.keeper.path), isInsideOrEqual: item.url) }) {
        rejected.append(OperationFailure(url: item.url, message: "This selection includes a copy you are keeping in Duplicates or Photos. Choose another keeper or select smaller items."))
      } else if case .cleanupTarget(_, .safe) = item.kind, validationItems.contains(where: { child in
        guard case .developerArtifact = child.kind else { return false }
        return child.needsAttention && FileSystem.path(child.url, isInsideOrEqual: item.url)
      }) {
        rejected.append(OperationFailure(url: item.url, message: "This broad target includes recent or hard-to-recreate developer data. Review individual items in Developer."))
      } else if FileSystem.isIgnored(item.url, ignoredPaths: ignoredPaths) {
        rejected.append(OperationFailure(url: item.url, message: "Item is on your exclusion list."))
      } else if FileSystem.containsIgnoredDescendant(item.url, ignoredPaths: ignoredPaths) {
        rejected.append(
          OperationFailure(
            url: item.url, message: "Folder contains an excluded item. Rescan to clean around it."))
      } else {
        eligible.append(item)
      }
    }

    // Reject the ancestor, rather than merely hiding the duplicate it covers. Otherwise
    // selecting one folder can discard the last-copy protection along with its child row.
    let constraints = eligible.compactMap { item in
      item.keeper.map { KeeperConstraint(source: item.url, keeper: $0) }
    }
    eligible.removeAll { item in
      let threatensBoth = constraints.contains {
        FileSystem.path($0.source, isInsideOrEqual: item.url)
          && FileSystem.path(URL(fileURLWithPath: $0.keeper.path), isInsideOrEqual: item.url)
      }
      if threatensBoth {
        rejected.append(OperationFailure(url: item.url,
          message: "This selection contains both a selected copy and the copy being kept. Choose smaller selections."))
      }
      return threatensBoth
    }

    // Parents first, so a child whose ancestor is already planned is recognised as covered.
    let ordered = eligible.enumerated().sorted { lhs, rhs in
      let l = lhs.element.url.standardizedFileURL.path.count
      let r = rhs.element.url.standardizedFileURL.path.count
      return l == r ? lhs.offset < rhs.offset : l < r
    }
    var keptPaths: [String] = []
    var keptIDs: Set<UUID> = []
    var covered: [PlanItem] = []
    for (_, item) in ordered {
      let path = FileSystem.comparisonPath(item.url)
      if keptPaths.contains(where: { path == $0 || path.hasPrefix($0 + "/") }) {
        covered.append(item)
      } else {
        keptPaths.append(path)
        keptIDs.insert(item.id)
      }
    }
    // Keep the caller's order (it reflects dependencies such as app before its data).
    var kept = eligible.filter { keptIDs.contains($0.id) }

    // A duplicate may only go if the copy being kept is not removed by this same plan
    // (selected directly, or inside a selected folder, from any screen).
    kept.removeAll { item in
      guard let keeper = item.keeper?.path else { return false }
      let key = FileSystem.comparisonPath(URL(fileURLWithPath: keeper))
      let threatened = keptPaths.contains { key == $0 || key.hasPrefix($0 + "/") }
      if threatened {
        rejected.append(
          OperationFailure(
            url: item.url,
            message: "The copy you're keeping (\(URL(fileURLWithPath: keeper).lastPathComponent)) is also selected for removal."))
      }
      return threatened
    }
    return OperationPlan(title: title, items: kept, covered: covered, excluded: rejected, protecting: protecting, validationItems: validationItems)
  }
}
