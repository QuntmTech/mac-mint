import AppKit
import Foundation
import MacCleanerCore

/// Review → execute → recover. Every action that moves files builds an OperationPlan, shows it
/// in the review sheet, and runs through OperationExecutor so all checks and receipts are shared.
extension AppViewModel {
  struct RestoreConflict: Identifiable, Sendable {
    let id = UUID()
    let entryID: UUID
    let receipt: TrashReceipt
    let message: String
  }

  // MARK: Queue (everything currently selected across screens)

  var queuedCleanupTargets: [CleanupTarget] { cleanupTargets.filter(\.isSelected) }

  var queuedDuplicateFiles: [(file: LargeFile, keeper: LargeFile?)] {
    duplicateGroups.flatMap { group in
      let keeper = group.files.first { !selectedDuplicateIDs.contains($0.id) }
      return group.files.filter { selectedDuplicateIDs.contains($0.id) }.map { ($0, keeper) }
    }
  }

  var queuedLargeFiles: [LargeFile] { largeFiles.filter { selectedLargeFileIDs.contains($0.id) } }

  /// Unverified preview of what "Review everything" would include.
  var queuedItems: [PlanItem] {
    queuedCleanupTargets.map { PlanItem.cleanup($0) }
      + queuedDuplicateFiles.map { PlanItem.duplicate($0.file, keeper: $0.keeper) }
      + queuedLargeFiles.map(PlanItem.largeFile)
      + queuedStorageNodes.map(PlanItem.storage)
      + queuedDevItems.compactMap(PlanItem.developer)
      + queuedPhotoFileItems.items
      + queuedOrphans.map(PlanItem.orphan)
      + queuedDownloads.map(PlanItem.download)
  }

  var queuedCount: Int {
    queuedCleanupTargets.count + queuedDuplicateFiles.count + queuedLargeFiles.count
      + queuedStorageNodes.count + queuedDevItems.count + queuedPhotoFileItems.items.count
      + queuedOrphans.count + queuedDownloads.count
  }

  var queuedBytes: Int64 {
    OperationPlanner.plan(title: "Queue estimate", items: queuedItems, ignoredPaths: ignoredPaths).totalBytes
  }

  func dequeue(_ item: PlanItem) {
    let path = item.url.standardizedFileURL.path
    for index in cleanupTargets.indices where cleanupTargets[index].url.standardizedFileURL.path == path {
      cleanupTargets[index].isSelected = false
    }
    let ids = Set(
      (duplicateGroups.flatMap(\.files) + largeFiles)
        .filter { $0.url.standardizedFileURL.path == path }.map(\.id))
    selectedDuplicateIDs.subtract(ids)
    selectedLargeFileIDs.subtract(ids)
    selectedStoragePaths.remove(path)
    selectedDevIDs.remove(path)
    selectedPhotoIDs.remove(path)
    selectedOrphanIDs.remove(path)
    selectedDownloadIDs.remove(path)
  }

  func clearQueue() {
    deselectAllCleanup()
    selectedDuplicateIDs = []
    selectedLargeFileIDs = []
    selectedStoragePaths = []
    selectedDevIDs = []
    selectedPhotoIDs = []
    selectedOrphanIDs = []
    selectedDownloadIDs = []
  }

  // MARK: Building plans

  func reviewCleanup() {
    presentPlan(
      OperationPlanner.plan(
        title: "Cleanup", items: queuedCleanupTargets.map { PlanItem.cleanup($0) },
        ignoredPaths: ignoredPaths))
  }

  func reviewLargeFiles(_ files: [LargeFile]? = nil) {
    let chosen = files ?? queuedLargeFiles
    presentPlan(
      OperationPlanner.plan(
        title: chosen.count == 1 ? "Remove large file" : "Remove large files",
        items: chosen.map(PlanItem.largeFile), ignoredPaths: ignoredPaths))
  }

  func reviewDuplicates() {
    preparePlan(message: "Verifying duplicate copies…") { model in
      let duplicates = await model.verifiedDuplicateItems()
      return OperationPlanner.plan(
        title: "Remove duplicates", items: duplicates.items, ignoredPaths: model.ignoredPaths,
        excluded: duplicates.skipped)
    }
  }

  func reviewEverything() {
    preparePlan(message: "Preparing your review…") { model in
      let duplicates = await model.verifiedDuplicateItems()
      let items =
        model.queuedCleanupTargets.map { PlanItem.cleanup($0) } + duplicates.items
        + model.queuedLargeFiles.map(PlanItem.largeFile)
        + model.queuedStorageNodes.map(PlanItem.storage)
        + model.queuedDevItems.compactMap(PlanItem.developer)
        + model.queuedPhotoFileItems.items + model.queuedOrphans.map(PlanItem.orphan)
        + model.queuedDownloads.map(PlanItem.download)
      return OperationPlanner.plan(
        title: "Review queue", items: items, ignoredPaths: model.ignoredPaths,
        excluded: duplicates.skipped)
    }
  }

  func reviewUninstall() {
    guard let app = selectedApp else { return }
    if selectedAppIsRunning {
      statusMessage = "Quit \(app.name) before uninstalling it"
      return
    }
    let source = "Uninstall \(app.name)"
    let bundle = PlanItem(
      url: app.url, displayName: app.name, kind: .appBundle, expectedBytes: app.bundleSize,
      reason: app.version.map { "\(app.name) \($0)" } ?? app.name, source: source,
      identity: app.identity, ownerBundleID: app.bundleIdentifier)
    let leftovers = appLeftovers.filter { selectedLeftoverIDs.contains($0.id) }.map { leftover in
      PlanItem(
        url: leftover.url, displayName: leftover.url.lastPathComponent, kind: .appLeftover,
        expectedBytes: leftover.size, reason: leftover.reason, source: source,
        needsAttention: !leftover.isSuggested, dependsOn: bundle.id,
        identity: leftover.identity, ownerBundleID: app.bundleIdentifier)
    }
    presentPlan(
      OperationPlanner.plan(
        title: "Uninstall \(app.name)", items: [bundle] + leftovers, ignoredPaths: ignoredPaths))
  }

  private func presentPlan(_ plan: OperationPlan) {
    guard !isWorking, !isScanning else { return }
    guard !plan.isEmpty || !plan.excluded.isEmpty else {
      statusMessage = "Nothing selected to review"
      return
    }
    pendingPlan = plan
  }

  private func preparePlan(
    message: String, _ build: @escaping @MainActor (AppViewModel) async -> OperationPlan
  ) {
    guard !isWorking, !isScanning, !isPreparingPlan else { return }
    isPreparingPlan = true
    statusMessage = message
    Task { [weak self] in
      guard let self else { return }
      let plan = await build(self)
      isPreparingPlan = false
      statusMessage = "Ready"
      presentPlan(plan)
    }
  }

  /// Re-verifies selected duplicate copies (live keeper, unchanged content) before planning.
  private func verifiedDuplicateItems() async -> (items: [PlanItem], skipped: [OperationFailure]) {
    let groups = duplicateGroups
    let selection = selectedDuplicateIDs
    guard !selection.isEmpty else { return ([], []) }
    let verified = await duplicateVerifier.plan(
      groups: groups, selectedIDs: selection, ignoredPaths: ignoredPaths)
    let approvedIDs = Set(verified.approved.map(\.id))
    let items = groups.flatMap { group -> [PlanItem] in
      let keeper = group.files.first { !selection.contains($0.id) }
      return group.files.filter { approvedIDs.contains($0.id) }.map {
        PlanItem.duplicate($0, keeper: keeper)
      }
    }
    return (items, verified.skipped)
  }

  // MARK: Execution

  func execute(_ plan: OperationPlan) {
    pendingPlan = nil
    guard !isWorking, !isScanning, !plan.isEmpty else { return }
    guard authorizeRemoval() else {
      deferredPlan = plan
      Task { await Task.yield(); showingAccount = true }
      return
    }
    isWorking = true
    operationTitle = plan.title
    statusMessage = "Moving items to Trash…"
    operationProgress = OperationProgress(
      completed: 0, total: plan.items.count, currentName: nil, bytesMoved: 0)
    let excluded = ignoredPaths
    let executor = OperationExecutor(
      trashService: MacTrashService(), safetyPolicy: safetyPolicy,
      journalDirectory: AppPaths.journalDirectory,
      isAppRunning: { bundleID in
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
      })

    currentTask = Task { [weak self] in
      guard let self else { return }
      let report = await executor.run(plan, ignoredPaths: excluded) { progress in
        Task { @MainActor [weak self] in
          guard let self, self.isWorking else { return }
          self.operationProgress = progress
          if let name = progress.currentName {
            self.statusMessage = "\(progress.completed + 1) of \(progress.total) — \(name)"
          }
        }
      }
      await finish(report)
    }
  }

  private func finish(_ report: OperationReport) async {
    var recoveryIssues: [ScanIssue] = []
    let historySaved = await record(report.historyEntry())
    if historySaved {
      do { try OperationJournal.acknowledge(report.id, in: AppPaths.journalDirectory) }
      catch { recoveryIssues.append(ScanIssue(area: "Recovery", path: nil, message: "History is saved; the journal will be checked again next launch.")) }
    }
    applyMoved(report)
    scanIssues = recoveryIssues + report.problems.map {
      ScanIssue(area: report.title, path: $0.item.url.path, message: $0.message ?? "Skipped")
    }
    isWorking = false
    operationTitle = nil
    operationProgress = nil
    currentTask = nil
    statusMessage =
      report.moved.isEmpty
      ? report.summary
      : "\(ByteFormatter.string(report.bytesMoved)) moved to Trash — \(report.summary)"
    lastReport = report

    if !historySaved || report.persistenceError != nil {
      statusMessage += " — recovery needs attention; operation evidence has been retained"
    }
    refreshRecommendations()
    refreshTrashStatus()
  }

  /// Removes whatever actually moved from every list, and clears matching selections.
  private func applyMoved(_ report: OperationReport) {
    let movedPaths = Set(report.moved.map { $0.item.url.standardizedFileURL.path })
    guard !movedPaths.isEmpty else { return }
    let gone: (URL) -> Bool = { url in
      let path = url.standardizedFileURL.path
      return movedPaths.contains { path == $0 || path.hasPrefix($0 + "/") }
    }
    pruneStorage(movedPaths)
    devItems.removeAll { $0.url.map(gone) == true }
    selectedDevIDs.formIntersection(devItems.map(\.id))
    removePhotos { !$0.isLibraryAsset && gone($0.url) }
    orphans.removeAll { gone($0.url) }
    selectedOrphanIDs.formIntersection(orphans.map(\.id))
    downloadItems.removeAll { gone($0.url) }
    selectedDownloadIDs.formIntersection(downloadItems.map(\.id))
    refreshRecommendations()
    recordFreeSpace()
    cleanupTargets.removeAll { gone($0.url) }
    largeFiles.removeAll { gone($0.url) }
    selectedLargeFileIDs.formIntersection(largeFiles.map(\.id))
    duplicateGroups = duplicateGroups.compactMap { group in
      let updated = DuplicateGroup(
        id: group.id, fingerprint: group.fingerprint, files: group.files.filter { !gone($0.url) })
      return updated.physicalCopyCount > 1 ? updated : nil
    }
    selectedDuplicateIDs.formIntersection(duplicateGroups.flatMap(\.files).map(\.id))
    if let app = selectedApp, gone(app.url) {
      apps.removeAll { $0.id == app.id }
      selectedApp = nil
      appLeftovers = []
      selectedLeftoverIDs = []
    } else {
      appLeftovers.removeAll { gone($0.url) }
      selectedLeftoverIDs.formIntersection(appLeftovers.map(\.id))
    }
  }

  /// Called at launch: operations that never finished are recorded so nothing goes unexplained.
  func recoverInterruptedOperations() async {
    recoveryWarnings = OperationJournal.unreadableJournals(in: AppPaths.journalDirectory).map {
      ScanIssue(area: "Recovery", path: $0.path, message: "An operation record could not be read. It has been preserved for diagnosis. Use Finder to inspect the original locations and Trash.")
    }
    let reports = OperationJournal.recoverInterrupted(in: AppPaths.journalDirectory)
    guard !reports.isEmpty else { return }
    for report in reports {
      if await record(report.historyEntry()) {
        try? OperationJournal.acknowledge(report.id, in: AppPaths.journalDirectory)
      }
    }
    statusMessage =
      "Reconciled \(reports.count) operation record\(reports.count == 1 ? "" : "s") — see History"
  }

  // MARK: Recovery

  func canRestore(_ receipt: TrashReceipt) -> Bool { RecoveryService().canRestore(receipt) }

  func undo(_ report: OperationReport) {
    lastReport = nil
    restore(report.receipts, entryID: report.id)
  }

  func restore(_ receipts: [TrashReceipt], entryID: UUID) {
    guard !receipts.isEmpty, !isWorking, !isScanning else { return }
    isWorking = true
    operationTitle = "Restoring from Trash"
    currentTask = Task { [weak self] in
      guard let self else { return }
      var restored: [String] = []
      var conflicts: [RestoreConflict] = []
      for (index, receipt) in receipts.enumerated() {
        if Task.isCancelled { break }
        operationProgress = OperationProgress(completed: index, total: receipts.count,
          currentName: URL(fileURLWithPath: receipt.originalPath).lastPathComponent, bytesMoved: 0)
        let failure = await Task.detached(priority: .userInitiated) { () -> RestoreError? in
          do { try RecoveryService().restore(receipt); return nil }
          catch let error as RestoreError { return error }
          catch { return .failed(error.localizedDescription) }
        }.value
        if let failure {
          conflicts.append(RestoreConflict(entryID: entryID, receipt: receipt,
            message: failure.errorDescription ?? "Could not restore this item."))
        } else { restored.append(receipt.originalPath) }
      }
      var historyError: String?
      if !restored.isEmpty {
        do { try await historyStore.markRestored(entryID: entryID, originalPaths: restored) }
        catch { historyError = "Files were restored, but History could not be updated: \(error.localizedDescription)" }
        history = await historyStore.load()
      }
      restoreConflicts.append(contentsOf: conflicts)
      isWorking = false
      operationTitle = nil
      operationProgress = nil
      currentTask = nil
      statusMessage = historyError ?? "Restored \(restored.count) of \(receipts.count); \(conflicts.count) need attention"
      refreshTrashStatus()
    }
  }

  func skipRestoreConflict(_ conflict: RestoreConflict) {
    restoreConflicts.removeAll { $0.id == conflict.id }
  }

  func restoreElsewhere(_ conflict: RestoreConflict) {
    guard !isWorking else { return }
    let panel = NSOpenPanel()
    panel.title = "Choose where to restore “\(URL(fileURLWithPath: conflict.receipt.originalPath).lastPathComponent)”"
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.canCreateDirectories = true
    panel.prompt = "Restore Here"
    panel.begin { [weak self] response in
      guard response == .OK, let folder = panel.url else { return }
      Task { @MainActor [weak self] in
        guard let self else { return }
        self.isWorking = true
        self.operationTitle = "Restoring from Trash"
        do {
          let destination = try await Task.detached(priority: .userInitiated) {
            try RecoveryService().restore(conflict.receipt, into: folder)
          }.value
          do { try await self.historyStore.markRestored(entryID: conflict.entryID,
            originalPaths: [conflict.receipt.originalPath]) }
          catch { self.statusMessage = "Restored, but History could not be updated: \(error.localizedDescription)" }
          self.history = await self.historyStore.load()
          self.skipRestoreConflict(conflict)
          self.reveal(destination)
        } catch {
          self.statusMessage = (error as? RestoreError)?.errorDescription ?? error.localizedDescription
        }
        self.isWorking = false
        self.operationTitle = nil
        self.refreshTrashStatus()
      }
    }
  }

  func revealInTrash(_ receipt: TrashReceipt) {
    if let path = receipt.trashPath, FileManager.default.fileExists(atPath: path) {
      reveal(URL(fileURLWithPath: path))
    } else {
      NSWorkspace.shared.open(FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".Trash"))
    }
  }
}
