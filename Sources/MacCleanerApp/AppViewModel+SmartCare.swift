import AppKit
import Foundation
import MacCleanerCore

private enum QuickScanResult: Sendable {
  case base(ScanSummary)
  case developer(ScanReport<[DevStorageItem]>)
  case leftovers(ScanReport<[OrphanedItem]>)
  case downloads(ScanReport<[DownloadItem]>)
  case trash(TrashBinService.Status)
}

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
    guard beginScan(title: "Quick Scan", message: "Checking known storage locations…") else { return }
    scanCompletedAreas = []
    let ignored = ignoredPaths
    let running = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
    let previousSelections = Dictionary(cleanupTargets.map { (FileSystem.comparisonPath($0.url), $0.isSelected) }, uniquingKeysWith: { $0 || $1 })
    let started = Date()
    currentTask = Task { [weak self] in
      guard let self else { return }
      await withTaskGroup(of: QuickScanResult.self) { group in
        group.addTask { .base(await SmartScanService().scan(ignoredPaths: ignored)) }
        // Deep project enumeration is a separate, deliberate Developer scan.
        group.addTask { .developer(await DeveloperStorageScanner().scan(ignoredPaths: ignored)) }
        group.addTask { .leftovers(await OrphanScanner().scan(knownBundleIDs: running, ignoredPaths: ignored)) }
        group.addTask { .downloads(await DownloadsScanner().scan(ignoredPaths: ignored)) }
        group.addTask { .trash(await TrashBinService.status()) }
        for await part in group {
          if Task.isCancelled { group.cancelAll(); break }
          switch part {
          case .base(let report):
            cleanupTargets = report.cleanupTargets.map { target in
              var copy = target
              copy.isSelected = previousSelections[FileSystem.comparisonPath(target.url)] ?? target.isSelected
              if target.category == .developerJunk || target.ownerBundleID.map(running.contains) == true { copy.isSelected = false }
              return copy
            }
            apps = report.apps
            startupItems = report.startupItems
            scanIssues += report.issues
            scanCompletedAreas.append("Caches, apps and startup inventory")
          case .developer(let report):
            // Keep explicitly scanned project results when refreshing known tool caches.
            devItems = report.value + devItems.filter { $0.group == .projects }
            selectedDevIDs.formIntersection(devItems.map(\.id))
            scanIssues += report.issues
            scanCompletedAreas.append("Known developer caches")
          case .leftovers(let report):
            orphans = report.value
            selectedOrphanIDs.formIntersection(orphans.map(\.id))
            orphansScanned = true
            scanIssues += report.issues
            scanCompletedAreas.append("Removed-app data")
          case .downloads(let report):
            downloadItems = report.value
            selectedDownloadIDs.formIntersection(downloadItems.map(\.id))
            downloadsScanned = true
            scanIssues += report.issues
            scanCompletedAreas.append("Downloads")
          case .trash(let status):
            trashStatus = status
            if !status.isComplete { scanIssues.append(ScanIssue(area: "Trash", message: "Trash could not be fully measured. Review it in Finder.")) }
            scanCompletedAreas.append("Home Trash")
          }
          for index in cleanupTargets.indices where cleanupTargets[index].category == .developerJunk {
            if devItems.contains(where: { dev in
              guard dev.isActive || dev.rebuild == .review, let url = dev.url else { return false }
              return FileSystem.path(url, isInsideOrEqual: cleanupTargets[index].url)
            }) { cleanupTargets[index].isSelected = false }
          }
          refreshRecommendations()
          statusMessage = "\(scanCompletedAreas.count) of 5 checks complete — results are available"
        }
      }
      guard !Task.isCancelled else { finishCancelledOperation(); return }
      lastScanDate = Date()
      lastScanDuration = Date().timeIntervalSince(started)
      smartCareRanAt = Date()
      UserDefaults.standard.set(Date(), forKey: CareService.Keys.lastScanDate)
      recordFreeSpace()
      let estimate = OperationPlanner.plan(title: "estimate", items: recommendations.flatMap(\.items), ignoredPaths: ignoredPaths).totalBytes
      finishScan(message: "Quick Scan complete — approximately \(ByteFormatter.string(estimate)) to inspect" + (scanIssues.isEmpty ? "" : "; some areas need attention"))
    }
  }

  func refreshRecommendations() {
    if aiReview != nil || aiReviewBusy || assistantBusy { invalidateAIReview() }
    var inputs = RecommendationEngine.Inputs()
    inputs.runningBundleIDs = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
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
    OperationPlanner.plan(title: "estimate", items: RecommendationEngine.safeItems(recommendations), ignoredPaths: ignoredPaths).totalBytes
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
    guard beginScan(title: "Downloads", message: "Checking what you've downloaded and never used…") else { return }
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
