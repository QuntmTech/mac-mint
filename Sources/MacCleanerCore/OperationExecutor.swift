import Foundation

public enum ItemOutcomeStatus: String, Codable, Hashable, Sendable {
  case moved
  case skipped
  case failed
  case notAttempted
  /// Journal-only: the move had started when the app stopped. Resolved on recovery.
  case inFlight
  /// A move was interrupted before its destination could be recorded. Never invent a receipt.
  case uncertain
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
  public var persistenceError: String?

  public init(
    id: UUID, title: String, startedAt: Date, finishedAt: Date? = nil, outcomes: [ItemOutcome],
    wasCancelled: Bool = false, wasInterrupted: Bool = false, persistenceError: String? = nil
  ) {
    self.id = id
    self.title = title
    self.startedAt = startedAt
    self.finishedAt = finishedAt
    self.outcomes = outcomes
    self.wasCancelled = wasCancelled
    self.wasInterrupted = wasInterrupted
    self.persistenceError = persistenceError
  }

  public var moved: [ItemOutcome] { outcomes.filter { $0.status == .moved } }
  public var problems: [ItemOutcome] {
    outcomes.filter { $0.status == .skipped || $0.status == .failed || $0.status == .uncertain }
  }
  public var notAttempted: [ItemOutcome] { outcomes.filter { $0.status == .notAttempted } }
  public var receipts: [TrashReceipt] { outcomes.compactMap(\.receipt) }
  public var bytesMoved: Int64 { receipts.reduce(0) { $0 + $1.bytes } }

  public var summary: String {
    var parts = ["\(moved.count) item\(moved.count == 1 ? "" : "s") moved to Trash"]
    if !problems.isEmpty { parts.append("\(problems.count) need attention") }
    if wasCancelled { parts.append("stopped early") }
    if wasInterrupted { parts.append("interrupted") }
    if persistenceError != nil { parts.append("recovery record could not be saved; operation stopped") }
    return parts.joined(separator: ", ")
  }

  public func historyEntry() -> HistoryEntry {
    var notes = summary + "."
    if let first = problems.first, let message = first.message {
      notes += " First issue: \(message)"
    }
    return HistoryEntry(
      id: id, date: finishedAt ?? startedAt, action: title,
      paths: outcomes.filter { $0.status == .moved || $0.status == .uncertain }.map { $0.item.url.path },
      bytes: bytesMoved, notes: notes + (persistenceError.map { " " + $0 } ?? ""), receipts: receipts,
      unresolvedPaths: outcomes.filter { $0.status == .uncertain }.map { $0.item.url.path })
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
  private let journalWriter: @Sendable (Data, URL) throws -> Void
  /// Custom model/cache locations configured through environment variables (e.g. HF_HUB_CACHE).
  private let developerRoots: [URL]
  private let isAppRunning: @Sendable (String) -> Bool

  public init(
    trashService: any TrashService,
    safetyPolicy: SafetyPolicy = SafetyPolicy(),
    fileManager: FileManager = .default,
    journalDirectory: URL? = nil,
    journalWriter: (@Sendable (Data, URL) throws -> Void)? = nil,
    developerRoots: [URL] = DeveloperStorageScanner.configuredRoots(),
    isAppRunning: @escaping @Sendable (String) -> Bool = { _ in false }
  ) {
    self.isAppRunning = isAppRunning
    self.trashService = trashService
    self.safetyPolicy = safetyPolicy
    self.fileManager = fileManager
    self.journalDirectory = journalDirectory
    self.journalWriter = journalWriter ?? { try FileSystem.writeDurably($0, to: $1) }
    self.developerRoots = developerRoots
  }

  public func run(
    _ plan: OperationPlan, ignoredPaths: Set<String> = [], progress: ProgressHandler? = nil
  ) async -> OperationReport {
    var report = OperationReport(
      id: plan.id, title: plan.title, startedAt: Date(),
      outcomes: plan.items.map { ItemOutcome(item: $0, status: .notAttempted) })
    do { try writeJournal(report) } catch {
      report.persistenceError = error.localizedDescription
      report.finishedAt = Date()
      return report
    }

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
        item, plan: plan, movedIDs: movedIDs, movedPaths: movedPaths, ignoredPaths: ignoredPaths)
      {
        outcome = rejection
      } else {
        // Record intent first, so a crash mid-move still leaves an explanation behind.
        report.outcomes[index] = ItemOutcome(item: item, status: .inFlight)
        do { try writeJournal(report) } catch {
          report.outcomes[index] = ItemOutcome(item: item, status: .notAttempted)
          report.persistenceError = error.localizedDescription
          break
        }
        // Sizing can be expensive. Check identity, policy, activity and keepers again after it.
        let size = FileSystem.itemSize(at: item.url, fileManager: fileManager)
        let libraryProblem = FileSystem.managedLibraryProblem(in: item.url, fileManager: fileManager)
        if Task.isCancelled {
          report.wasCancelled = true
          report.outcomes[index] = ItemOutcome(item: item, status: .notAttempted)
          break
        }
        if let libraryProblem {
          outcome = ItemOutcome(item: item, status: .skipped, message: libraryProblem)
        } else if let rejection = validate(item, plan: plan, movedIDs: movedIDs,
          movedPaths: movedPaths, ignoredPaths: ignoredPaths) {
          outcome = rejection
        } else {
          outcome = await move(item, size: size)
        }
      }
      if outcome.status == .moved {
        movedIDs.insert(item.id)
        movedPaths.append(item.url.standardizedFileURL.path)
        bytesMoved += outcome.receipt?.bytes ?? 0
      }
      report.outcomes[index] = outcome
      do { try writeJournal(report) } catch {
        report.persistenceError = error.localizedDescription
        break
      }
    }

    report.finishedAt = Date()
    progress?(
      OperationProgress(
        completed: report.outcomes.filter { $0.status != .notAttempted }.count,
        total: plan.items.count, currentName: nil, bytesMoved: bytesMoved))
    do { try writeJournal(report) } catch { report.persistenceError = error.localizedDescription }
    // The caller acknowledges only after HistoryStore commits this operation by ID.
    return report
  }

  /// Returns a skip outcome when the item must not be moved, or nil when it may proceed.
  private func validate(
    _ item: PlanItem, plan: OperationPlan, movedIDs: Set<UUID>, movedPaths: [String], ignoredPaths: Set<String>
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
    if let expected = item.identity, FileSystem.fileIdentity(at: item.url) != expected {
      return skip("A different item now exists at this location. Rescan before removing it.")
    }
    if let expected = item.snapshot {
      guard let current = FileSnapshot.current(item.url), expected.matches(current) else {
        return skip("This file changed or could not be verified. Rescan to review it again.")
      }
    }
    for constraint in plan.keeperConstraints {
      if FileSystem.path(URL(fileURLWithPath: constraint.keeper.path), isInsideOrEqual: item.url) {
        return skip("This selection would remove a copy that must be kept.")
      }
      if FileSystem.path(constraint.source, isInsideOrEqual: item.url),
        let problem = keeperProblem(constraint.keeper, movedPaths: movedPaths) { return skip(problem) }
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
    // Normalization may cover a more conservative child. Its ownership, identity and
    // recorded file metadata still constrain the ancestor that would move it.
    for child in plan.covered + plan.validationItems where FileSystem.path(child.url, isInsideOrEqual: item.url) {
      if case .cleanupTarget(_, .safe) = item.kind,
        case .developerArtifact = child.kind, child.needsAttention {
        return skip("This broad cleanup target includes developer data that needs individual review. Choose items in Developer.")
      }
      if let owner = child.ownerBundleID, isAppRunning(owner) {
        return skip("This folder includes data owned by an app that is open. Quit the app and review again.")
      }
      if let identity = child.identity, FileSystem.fileIdentity(at: child.url) != identity {
        return skip("A selected item inside this folder changed identity. Rescan before removing the folder.")
      }
      if let snapshot = child.snapshot {
        guard let current = FileSnapshot.current(child.url), snapshot.matches(current) else {
          return skip("A selected file inside this folder changed. Rescan before removing the folder.")
        }
      }
      if !decision(for: child).allowed { return skip("This folder covers an item that is protected by its removal policy.") }
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
    if let expected = keeper.identity, FileSystem.fileIdentity(at: url) != expected {
      return "The copy you're keeping (\(name)) was replaced. Rescan before removing duplicates."
    }
    if let expected = keeper.snapshot {
      guard let current = FileSnapshot.current(url), expected.matches(current) else {
        return "The copy you're keeping (\(name)) changed or could not be verified. Rescan before removing duplicates."
      }
    }
    return nil
  }

  private func move(_ item: PlanItem, size: Int64) async -> ItemOutcome {
    let identity = FileSystem.fileIdentity(at: item.url)
    if let expected = item.identity, identity != expected {
      return ItemOutcome(item: item, status: .skipped,
        message: "A different item now exists at this location. Rescan before removing it.")
    }
    do {
      let trashURL = try await trashService.trash(item.url)
      // The move is path-based, so prove afterwards that the reviewed item is what reached Trash.
      if let expected = item.identity ?? identity, let trashURL,
        FileSystem.fileIdentity(at: trashURL) != expected {
        return ItemOutcome(item: item, status: .uncertain,
          message: "Something moved to Trash at \(trashURL.lastPathComponent), but it isn't the item that was reviewed. Inspect Finder's Trash; no verified restore receipt is available.")
      }
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

  private func writeJournal(_ report: OperationReport) throws {
    guard let url = journalURL(report.id) else { return }
    try fileManager.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try journalWriter(OperationJournal.encoder.encode(report), url)
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
  /// Reading never consumes evidence. Call acknowledge only after a durable history commit.
  public static func recoverInterrupted(in directory: URL, fileManager: FileManager = .default)
    -> [OperationReport]
  {
    guard
      let files = try? fileManager.contentsOfDirectory(
        at: directory, includingPropertiesForKeys: nil)
    else { return [] }
    return files.filter { $0.lastPathComponent.hasPrefix("operation-") }.compactMap { url in
      guard let data = try? Data(contentsOf: url),
        var report = try? decoder.decode(OperationReport.self, from: data)
      else { return nil }
      report.outcomes = report.outcomes.map { outcome in
        guard outcome.status == .inFlight else { return outcome }
        if let identity = outcome.item.identity,
          FileSystem.fileIdentity(at: outcome.item.url) == identity {
          return ItemOutcome(item: outcome.item, status: .notAttempted)
        }
        return ItemOutcome(item: outcome.item, status: .uncertain,
          message: "MacMint stopped before recording the destination. Check the original folder and Finder's Trash; no verified restore receipt is available.")
      }
      report.wasInterrupted = report.finishedAt == nil || report.outcomes.contains { $0.status == .uncertain }
      report.finishedAt = report.finishedAt ?? Date()
      return report
    }
  }

  public static func unreadableJournals(in directory: URL, fileManager: FileManager = .default) -> [URL] {
    let files = (try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
    return files.filter { url in
      guard url.lastPathComponent.hasPrefix("operation-") else { return false }
      guard let data = try? Data(contentsOf: url) else { return true }
      return (try? decoder.decode(OperationReport.self, from: data)) == nil
    }
  }

  public static func acknowledge(_ id: UUID, in directory: URL, fileManager: FileManager = .default) throws {
    let url = directory.appendingPathComponent("operation-\(id.uuidString).json")
    if fileManager.fileExists(atPath: url.path) { try fileManager.removeItem(at: url) }
  }
}
