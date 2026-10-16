import Foundation

public enum ItemOutcomeStatus: String, Codable, Hashable, Sendable {
  case moved
  case skipped
  case failed
  case notAttempted
}

public struct ItemOutcome: Identifiable, Codable, Hashable, Sendable {
  public let item: PlanItem
  public let status: ItemOutcomeStatus
  public let message: String?
  public let receipt: TrashReceipt?

  public var id: UUID { item.id }

  public init(
    item: PlanItem, status: ItemOutcomeStatus, message: String? = nil, receipt: TrashReceipt? = nil
  ) {
    self.item = item
    self.status = status
    self.message = message
    self.receipt = receipt
  }
}

public struct OperationProgress: Sendable, Hashable {
  public let completed: Int
  public let total: Int
  public let currentName: String?
  public let bytesMoved: Int64

  public init(completed: Int, total: Int, currentName: String?, bytesMoved: Int64) {
    self.completed = completed
    self.total = total
    self.currentName = currentName
    self.bytesMoved = bytesMoved
  }

  public var fraction: Double { total > 0 ? Double(completed) / Double(total) : 0 }
}

/// What actually happened to a plan. Persisted as a journal while running so an interrupted
/// operation can still be explained (and restored) after relaunch.
public struct OperationReport: Identifiable, Codable, Hashable, Sendable {
  public let id: UUID
  public let title: String
  public let startedAt: Date
  public var finishedAt: Date?
  public var outcomes: [ItemOutcome]
  public var wasCancelled: Bool
  public var wasInterrupted: Bool

  public init(
    id: UUID, title: String, startedAt: Date, finishedAt: Date? = nil, outcomes: [ItemOutcome],
    wasCancelled: Bool = false, wasInterrupted: Bool = false
  ) {
    self.id = id
    self.title = title
    self.startedAt = startedAt
    self.finishedAt = finishedAt
    self.outcomes = outcomes
    self.wasCancelled = wasCancelled
    self.wasInterrupted = wasInterrupted
  }

  public var moved: [ItemOutcome] { outcomes.filter { $0.status == .moved } }
  public var problems: [ItemOutcome] {
    outcomes.filter { $0.status == .skipped || $0.status == .failed }
  }
  public var notAttempted: [ItemOutcome] { outcomes.filter { $0.status == .notAttempted } }
  public var receipts: [TrashReceipt] { outcomes.compactMap(\.receipt) }
  public var bytesMoved: Int64 { receipts.reduce(0) { $0 + $1.bytes } }

  public var summary: String {
    var parts = ["\(moved.count) item\(moved.count == 1 ? "" : "s") moved to Trash"]
    if !problems.isEmpty { parts.append("\(problems.count) skipped") }
    if wasCancelled { parts.append("stopped early") }
    if wasInterrupted { parts.append("interrupted") }
    return parts.joined(separator: ", ")
  }

  public func historyEntry() -> HistoryEntry {
    var notes = summary + "."
    if let first = problems.first, let message = first.message {
      notes += " First issue: \(message)"
    }
    return HistoryEntry(
      id: id, date: finishedAt ?? startedAt, action: title,
      paths: moved.map { $0.item.url.path }, bytes: bytesMoved, notes: notes, receipts: receipts)
  }
}

/// Runs an OperationPlan. Every item is re-validated immediately before it moves:
/// it must still exist, be the same file that was planned, not be excluded, pass the safety
/// rule for its kind, and have its dependency satisfied. Nothing is ever deleted permanently.
public actor OperationExecutor {
  public typealias ProgressHandler = @Sendable (OperationProgress) -> Void

  private let trashService: any TrashService
  private let safetyPolicy: SafetyPolicy
  private let fileManager: FileManager
  private let journalDirectory: URL?
  /// Custom model/cache locations configured through environment variables (e.g. HF_HUB_CACHE).
  private let developerRoots: [URL]
  private let isAppRunning: @Sendable (String) -> Bool

  public init(
    trashService: any TrashService,
    safetyPolicy: SafetyPolicy = SafetyPolicy(),
    fileManager: FileManager = .default,
    journalDirectory: URL? = nil,
    developerRoots: [URL] = DeveloperStorageScanner.configuredRoots(),
    isAppRunning: @escaping @Sendable (String) -> Bool = { _ in false }
  ) {
    self.isAppRunning = isAppRunning
    self.trashService = trashService
    self.safetyPolicy = safetyPolicy
    self.fileManager = fileManager
    self.journalDirectory = journalDirectory
    self.developerRoots = developerRoots
  }

  public func run(
    _ plan: OperationPlan, ignoredPaths: Set<String> = [], progress: ProgressHandler? = nil
  ) async -> OperationReport {
    var report = OperationReport(
      id: plan.id, title: plan.title, startedAt: Date(),
      outcomes: plan.items.map { ItemOutcome(item: $0, status: .notAttempted) })
    writeJournal(report)

    var movedIDs: Set<UUID> = []
    var bytesMoved: Int64 = 0
    for (index, item) in plan.items.enumerated() {
      if Task.isCancelled {
        report.wasCancelled = true
        break
      }
      progress?(
        OperationProgress(
          completed: index, total: plan.items.count, currentName: item.displayName,
          bytesMoved: bytesMoved))

      let outcome = await execute(item, movedIDs: movedIDs, ignoredPaths: ignoredPaths)
      if outcome.status == .moved {
        movedIDs.insert(item.id)
        bytesMoved += outcome.receipt?.bytes ?? 0
      }
      report.outcomes[index] = outcome
      writeJournal(report)
    }

    report.finishedAt = Date()
    progress?(
      OperationProgress(
        completed: report.outcomes.filter { $0.status != .notAttempted }.count,
        total: plan.items.count, currentName: nil, bytesMoved: bytesMoved))
    removeJournal(report.id)
    return report
  }

  private func execute(_ item: PlanItem, movedIDs: Set<UUID>, ignoredPaths: Set<String>) async
    -> ItemOutcome
  {
    if let dependency = item.dependsOn, !movedIDs.contains(dependency) {
      return ItemOutcome(
        item: item, status: .skipped,
        message: "Left untouched because the item it belongs to was not moved.")
    }
    if let owner = item.ownerBundleID, isAppRunning(owner) {
      return ItemOutcome(
        item: item, status: .skipped,
        message: "The app that uses this data is open. Quit it and try again.")
    }
    guard fileManager.fileExists(atPath: item.url.path) || isSymlink(item.url) else {
      return ItemOutcome(
        item: item, status: .skipped, message: "No longer exists; it may already have been removed."
      )
    }
    if let expected = item.identity, let current = FileSystem.fileIdentity(at: item.url),
      expected != current
    {
      return ItemOutcome(
        item: item, status: .skipped,
        message: "A different item now exists at this location. Rescan before removing it.")
    }
    if FileSystem.isIgnored(item.url, ignoredPaths: ignoredPaths) {
      return ItemOutcome(item: item, status: .skipped, message: "Item is on your exclusion list.")
    }
    if FileSystem.containsIgnoredDescendant(item.url, ignoredPaths: ignoredPaths) {
      return ItemOutcome(
        item: item, status: .skipped,
        message: "Folder contains an excluded item. Rescan to clean around it.")
    }

    let decision = decision(for: item)
    guard decision.allowed else {
      return ItemOutcome(item: item, status: .skipped, message: decision.reason)
    }

    let size = FileSystem.itemSize(at: item.url, fileManager: fileManager)
    do {
      let trashURL = try await trashService.trash(item.url)
      return ItemOutcome(
        item: item, status: .moved,
        receipt: TrashReceipt(originalPath: item.url.path, trashPath: trashURL?.path, bytes: size))
    } catch {
      return ItemOutcome(item: item, status: .failed, message: error.localizedDescription)
    }
  }

  private func decision(for item: PlanItem) -> (allowed: Bool, reason: String) {
    switch item.kind {
    case .cleanupTarget(let category, let risk):
      guard risk != .restricted else {
        return (false, "Restricted items require a specific reviewed file target.")
      }
      return safetyPolicy.cleanupDecision(for: item.url, category: category)
    case .appBundle:
      return safetyPolicy.appBundleDecision(for: item.url)
    case .appLeftover:
      return safetyPolicy.appLeftoverDecision(for: item.url)
    case .duplicateCopy, .reviewedFile:
      return safetyPolicy.reviewedFileDecision(for: item.url)
    case .developerArtifact:
      return safetyPolicy.developerArtifactDecision(for: item.url, extraRoots: developerRoots)
    }
  }

  private func isSymlink(_ url: URL) -> Bool {
    (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true
  }

  // MARK: Journal

  private func journalURL(_ id: UUID) -> URL? {
    journalDirectory?.appendingPathComponent("operation-\(id.uuidString).json")
  }

  private func writeJournal(_ report: OperationReport) {
    guard let url = journalURL(report.id) else { return }
    try? fileManager.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    if let data = try? OperationJournal.encoder.encode(report) {
      try? data.write(to: url, options: .atomic)
    }
  }

  private func removeJournal(_ id: UUID) {
    guard let url = journalURL(id) else { return }
    try? fileManager.removeItem(at: url)
  }
}

public enum OperationJournal {
  static let encoder: JSONEncoder = {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    return encoder
  }()

  static let decoder: JSONDecoder = {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return decoder
  }()

  /// Reports left behind by operations that never finished (app quit or crashed mid-run).
  /// Each journal is removed once read; callers record the reports in history.
  public static func recoverInterrupted(in directory: URL, fileManager: FileManager = .default)
    -> [OperationReport]
  {
    guard
      let files = try? fileManager.contentsOfDirectory(
        at: directory, includingPropertiesForKeys: nil)
    else { return [] }
    return files.filter { $0.lastPathComponent.hasPrefix("operation-") }.compactMap { url in
      defer { try? fileManager.removeItem(at: url) }
      guard let data = try? Data(contentsOf: url),
        var report = try? decoder.decode(OperationReport.self, from: data)
      else { return nil }
      report.wasInterrupted = true
      report.finishedAt = report.finishedAt ?? Date()
      return report
    }
  }
}
