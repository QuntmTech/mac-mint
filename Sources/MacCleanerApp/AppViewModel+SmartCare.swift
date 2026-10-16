import AppKit
import Foundation
import MacCleanerCore

/// Smart Care: one pass over every scanner, ranked into plain-English recommendations.
/// Review always opens the normal review sheet; nothing is removed from here directly.
extension AppViewModel {
  static let snapshotStore = StorageSnapshotStore(
    url: AppPaths.supportDirectory.appendingPathComponent("storage-snapshots.json"), limit: 30)
  static let spaceStore = SpaceHistoryStore(
    url: AppPaths.supportDirectory.appendingPathComponent("space-history.json"), retentionDays: 90)

  // MARK: Smart Care

  func runSmartCare() {
    guard !isScanning, !isWorking else { return }
    beginScan(
      title: "Smart Care", message: "Checking caches, apps, developer data, Downloads, and leftovers…")
    let ignored = ignoredPaths
    let roots = devProjectRoots
    let running = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))

    currentTask = Task { [weak self] in
      guard let self else { return }
      async let summary = SmartScanService().scan(ignoredPaths: ignored)
      async let developer = DeveloperStorageScanner().scan(projectRoots: roots)
      async let leftovers = OrphanScanner().scan(knownBundleIDs: running, ignoredPaths: ignored)
      async let downloads = DownloadsScanner().scan(ignoredPaths: ignored)
      async let trash = TrashBinService.status()
      let (scan, dev, orphanReport, downloadReport, trashStatus) = await (
        summary, developer, leftovers, downloads, trash
      )
      guard !Task.isCancelled else {
        finishCancelledOperation()
        return
      }
      cleanupTargets = scan.cleanupTargets
      apps = scan.apps
      startupItems = scan.startupItems
      devItems = dev.value
      selectedDevIDs = selectedDevIDs.intersection(dev.value.map(\.id))
      orphans = orphanReport.value
      selectedOrphanIDs = selectedOrphanIDs.intersection(orphanReport.value.map(\.id))
      orphansScanned = true
      downloadItems = downloadReport.value
      selectedDownloadIDs = selectedDownloadIDs.intersection(downloadReport.value.map(\.id))
      downloadsScanned = true
      self.trashStatus = trashStatus
      lastScanDate = scan.scannedAt
      lastScanDuration = scan.duration
      scanIssues = scan.issues + dev.issues + orphanReport.issues + downloadReport.issues
      smartCareRanAt = Date()
      refreshRecommendations()
      recordFreeSpace()
      let actionable = recommendations.filter(\.canReview).reduce(Int64(0)) { $0 + $1.bytes }
      finishScan(
        message: recommendations.isEmpty
          ? "Smart Care is done — nothing worth cleaning right now"
          : "Smart Care found about \(ByteFormatter.string(actionable)) you can review")
    }
  }

  func refreshRecommendations() {
    var inputs = RecommendationEngine.Inputs()
    inputs.cleanupTargets = cleanupTargets
    inputs.developer = devItems
    inputs.downloads = downloadItems
    inputs.orphans = orphans
    inputs.apps = apps
    inputs.screenshots = (photoScan?.screenshots ?? []).filter { !$0.isLibraryAsset }
    inputs.duplicateGroups = duplicateGroups
    inputs.trashBytes = trashStatus?.isComplete == true ? trashStatus?.bytes ?? 0 : 0
    inputs.growth = storageGrowth
    recommendations = RecommendationEngine.recommend(inputs)
  }

  func review(_ recommendation: Recommendation) {
    guard recommendation.canReview, !isWorking, !isScanning else {
      open(recommendation.destination)
      return
    }
    pendingPlan = OperationPlanner.plan(
      title: recommendation.title, items: recommendation.items, ignoredPaths: ignoredPaths)
  }

  /// Everything rated Safe (rebuilt or re-downloaded automatically), as one review.
  func reviewAllSafe() {
    let items = RecommendationEngine.safeItems(recommendations)
    guard !items.isEmpty, !isWorking, !isScanning else { return }
    pendingPlan = OperationPlanner.plan(
      title: "Smart Care — safe items", items: items, ignoredPaths: ignoredPaths)
  }

  var safeRecommendationBytes: Int64 {
    recommendations.filter { $0.confidence == .safe }.reduce(0) { $0 + $1.bytes }
  }

  func open(_ destination: Recommendation.Destination) {
    switch destination {
    case .cleaner: selectedSection = .cleaner
    case .developer: selectedSection = .developer
    case .downloads: selectedSection = .downloads
    case .applications:
      applicationsSortByLastOpened = true
      selectedSection = .applications
    case .removedApps: selectedSection = .removedApps
    case .photos: selectedSection = .photos
    case .duplicates: selectedSection = .duplicates
    case .storage: selectedSection = .storage
    case .trash: selectedSection = .dashboard
    }
  }

  // MARK: Downloads

  var queuedDownloads: [DownloadItem] { downloadItems.filter { selectedDownloadIDs.contains($0.id) } }

  func scanDownloads() {
    guard !isScanning, !isWorking else { return }
    beginScan(title: "Downloads", message: "Checking what you've downloaded and never used…")
    let ignored = ignoredPaths
    currentTask = Task { [weak self] in
      guard let self else { return }
      let report = await DownloadsScanner().scan(ignoredPaths: ignored)
      guard !Task.isCancelled else {
        finishCancelledOperation()
        return
      }
      downloadItems = report.value
      selectedDownloadIDs = []
      downloadsScanned = true
      scanIssues = report.issues
      refreshRecommendations()
      finishScan(
        message:
          "Found \(ByteFormatter.string(report.value.reduce(0) { $0 + $1.bytes })) in \(report.value.count) idle downloads")
    }
  }

  func reviewDownloads() {
    guard !isWorking, !isScanning, !queuedDownloads.isEmpty else { return }
    pendingPlan = OperationPlanner.plan(
      title: "Remove downloads", items: queuedDownloads.map(PlanItem.download), ignoredPaths: ignoredPaths)
  }

  // MARK: History

  /// Records today's free space (at most one sample per day) and reloads the chart.
  func recordFreeSpace() {
    let stats = volumeStats
    Task {
      if let samples = try? await Self.spaceStore.record(freeBytes: stats.free, totalBytes: stats.total) {
        spaceHistory = samples
      }
    }
  }

  /// After a Storage map of the home folder: compare with the previous map of the same folder.
  func recordStorageSnapshot(_ tree: StorageNode) {
    let snapshot = StorageSnapshot(tree: tree)
    Task {
      let previous = await Self.snapshotStore.previous(root: snapshot.root)
      try? await Self.snapshotStore.append(snapshot)
      storageGrowth = previous.map { StorageGrowthAnalyzer.growth(from: $0, to: snapshot) } ?? []
      refreshRecommendations()
    }
  }

  /// Change in free space over the last week, from the recorded history.
  var weeklySpaceChange: Int64? { SpaceTrend.freeSpaceChange(spaceHistory, days: 7) }
}
