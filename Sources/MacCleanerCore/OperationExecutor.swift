import Foundation

public enum ItemOutcomeStatus: String, Codable, Hashable, Sendable {
  case moved
  case skipped
  case failed
  case notAttempted
  /// Journal-only: the move had started when the app stopped. Resolved on recovery.
  case inFlight
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
    var movedPaths: [String] = []
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

      let outcome: ItemOutcome
      if let rejection = validate(
        item, movedIDs: movedIDs, movedPaths: movedPaths, ignoredPaths: ignoredPaths)
      {
        outcome = rejection
      } else {
        // Record intent first, so a crash mid-move still leaves an explanation behind.
        report.outcomes[index] = ItemOutcome(item: item, status: .inFlight)
        writeJournal(report)
        outcome = await move(item)
      }
      if outcome.status == .moved {
        movedIDs.insert(item.id)
        movedPaths.append(item.url.standardizedFileURL.path)
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

  /// Returns a skip outcome when the item must not be moved, or nil when it may proceed.
  private func validate(
    _ item: PlanItem, movedIDs: Set<UUID>, movedPaths: [String], ignoredPaths: Set<String>
  ) -> ItemOutcome? {
    let skip: (String) -> ItemOutcome = { ItemOutcome(item: item, status: .skipped, message: $0) }
    if let dependency = item.dependsOn, !movedIDs.contains(dependency) {
      return skip("Left untouched because the item it belongs to was not moved.")
    }
    if let owner = item.ownerBundleID, isAppRunning(owner) {
      return skip("The app that uses this data is open. Quit it and try again.")
    }
    guard fileManager.fileExists(atPath: item.url.path) || isSymlink(item.url) else {
      return skip("No longer exists; it may already have been removed.")
    }
    if let expected = item.identity, let current = FileSystem.fileIdentity(at: item.url),
      expected != current
    {
      return skip("A different item now exists at this location. Rescan before removing it.")
    }
    if let expected = item.snapshot, let current = FileSnapshot.current(item.url),
      !expected.matches(current)
    {
      return skip("This file changed since it was scanned. Rescan to review it again.")
    }
    if let keeper = item.keeper, let problem = keeperProblem(keeper, movedPaths: movedPaths) {
      return skip(problem)
    }
    if FileSystem.isIgnored(item.url, ignoredPaths: ignoredPaths) {
      return skip("Item is on your exclusion list.")
    }
    if FileSystem.containsIgnoredDescendant(item.url, ignoredPaths: ignoredPaths) {
      return skip("Folder contains an excluded item. Rescan to clean around it.")
    }
    let decision = decision(for: item)
    return decision.allowed ? nil : skip(decision.reason)
  }

  /// The copy being kept must still be there, be the same file, be unchanged, and not have
  /// been moved earlier in this run.
  private func keeperProblem(_ keeper: KeeperSnapshot, movedPaths: [String]) -> String? {
    let url = URL(fileURLWithPath: keeper.path)
    let name = url.lastPathComponent
    if movedPaths.contains(where: { keeper.path == $0 || keeper.path.hasPrefix($0 + "/") }) {
      return "The copy you're keeping (\(name)) was moved in this same operation."
    }
    guard fileManager.fileExists(atPath: keeper.path) else {
      return "The copy you're keeping (\(name)) is gone, so this one is kept too."
    }
    if let expected = keeper.identity, let current = FileSystem.fileIdentity(at: url),
      expected != current
    {
      return "The copy you're keeping (\(name)) was replaced. Rescan before removing duplicates."
    }
    if let expected = keeper.snapshot, let current = FileSnapshot.current(url),
      !expected.matches(current)
    {
      return "The copy you're keeping (\(name)) changed. Rescan before removing duplicates."
    }
    return nil
  }

  private func move(_ item: PlanItem) async -> ItemOutcome {
    let size = FileSystem.itemSize(at: item.url, fileManager: fileManager)
    let identity = FileSystem.fileIdentity(at: item.url)
    do {
      let trashURL = try await trashService.trash(item.url)
      return ItemOutcome(
        item: item, status: .moved,
        receipt: TrashReceipt(
          originalPath: item.url.path, trashPath: trashURL?.path, bytes: size, identity: identity))
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
    (try? FileSystem.fresh(url).resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true
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
      report.outcomes = report.outcomes.map { outcome in
        guard outcome.status == .inFlight else { return outcome }
        // The app stopped mid-move: if the item left its place it reached the Trash.
        let path = outcome.item.url.path
        let gone = !fileManager.fileExists(atPath: path) && FileSystem.fileIdentity(at: outcome.item.url) == nil
        return gone
          ? ItemOutcome(
            item: outcome.item, status: .moved,
            message: "Moved to the Trash while MacMint was quitting; find it there to restore.",
            receipt: TrashReceipt(originalPath: path, trashPath: nil, bytes: outcome.item.expectedBytes))
          : ItemOutcome(item: outcome.item, status: .notAttempted)
      }
      report.wasInterrupted = true
      report.finishedAt = report.finishedAt ?? Date()
      return report
    }
  }
}
