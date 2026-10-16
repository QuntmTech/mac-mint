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

  public init(
    id: UUID = UUID(), url: URL, displayName: String, kind: PlanItemKind, expectedBytes: Int64,
    reason: String, source: String, needsAttention: Bool = false, dependsOn: UUID? = nil,
    identity: String? = nil
  ) {
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
      identity: FileSystem.fileIdentity(at: target.url))
  }

  public static func duplicate(_ file: LargeFile, keeper: URL?) -> PlanItem {
    PlanItem(
      url: file.url, displayName: file.url.lastPathComponent, kind: .duplicateCopy,
      expectedBytes: file.size,
      reason: keeper.map { "Identical to \($0.lastPathComponent), which is kept." }
        ?? "Exact duplicate; another copy is kept.",
      source: "Duplicates", needsAttention: true,
      identity: file.identity ?? FileSystem.fileIdentity(at: file.url))
  }

  public static func developer(_ item: DevStorageItem) -> PlanItem? {
    guard let url = item.url, item.canTrash else { return nil }
    return PlanItem(
      url: url, displayName: "\(item.tool): \(item.title)", kind: .developerArtifact,
      expectedBytes: item.bytes, reason: item.rebuild.explanation, source: item.group.rawValue,
      needsAttention: item.rebuild == .review || item.isActive,
      identity: FileSystem.fileIdentity(at: url))
  }

  public static func largeFile(_ file: LargeFile) -> PlanItem {
    PlanItem(
      url: file.url, displayName: file.url.lastPathComponent, kind: .reviewedFile,
      expectedBytes: file.size, reason: "Large file you chose to remove.", source: "Large Files",
      needsAttention: true, identity: file.identity ?? FileSystem.fileIdentity(at: file.url))
  }
}

public struct OperationPlan: Identifiable, Sendable {
  public let id: UUID
  public let title: String
  public let items: [PlanItem]
  /// Items dropped because a selected parent folder already includes them.
  public let covered: [PlanItem]
  /// Selected items that cannot be part of this plan, with the reason.
  public let excluded: [OperationFailure]

  public init(
    id: UUID = UUID(), title: String, items: [PlanItem], covered: [PlanItem] = [],
    excluded: [OperationFailure] = []
  ) {
    self.id = id
    self.title = title
    self.items = items
    self.covered = covered
    self.excluded = excluded
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
    excluded: [OperationFailure] = []
  ) -> OperationPlan {
    var rejected = excluded
    var eligible: [PlanItem] = []
    for item in items {
      if FileSystem.isIgnored(item.url, ignoredPaths: ignoredPaths) {
        rejected.append(OperationFailure(url: item.url, message: "Item is on your exclusion list."))
      } else if FileSystem.containsIgnoredDescendant(item.url, ignoredPaths: ignoredPaths) {
        rejected.append(
          OperationFailure(
            url: item.url, message: "Folder contains an excluded item. Rescan to clean around it."))
      } else {
        eligible.append(item)
      }
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
      let path = item.url.standardizedFileURL.path
      if keptPaths.contains(where: { path == $0 || path.hasPrefix($0 + "/") }) {
        covered.append(item)
      } else {
        keptPaths.append(path)
        keptIDs.insert(item.id)
      }
    }
    // Keep the caller's order (it reflects dependencies such as app before its data).
    let kept = eligible.filter { keptIDs.contains($0.id) }
    return OperationPlan(title: title, items: kept, covered: covered, excluded: rejected)
  }
}
