import Foundation
import MacCleanerCore

/// Pages that fill themselves, so nobody has to find a Scan button before seeing anything.
extension AppViewModel {
  /// Changes when the app becomes free to start work, so a page waiting for its first load
  /// (another scan was running, exclusions were still loading, or the tour was open) retries.
  struct AutoLoadKey: Equatable {
    let busy: Bool
    let touring: Bool
    let ready: Bool
  }

  var autoLoadKey: AutoLoadKey {
    AutoLoadKey(busy: isScanning || isWorking || isPreparingPlan || pendingPlan != nil,
      touring: tourStep != nil, ready: exclusionsReady)
  }

  /// Screenshot tests and resource probes drive the app themselves; nothing starts on its own there.
  static var autoLoadAllowed: Bool { !SmokeTest.isRequested && ResourceProbeSession.folder == nil }

  /// True while a page has never been filled this session.
  func needsFirstLoad(_ section: Section) -> Bool {
    switch section {
    case .applications: return apps.isEmpty
    case .cleaner: return lastScanDate == nil && cleanupTargets.isEmpty
    case .startup: return !startupScanned
    case .removedApps: return !orphansScanned
    case .downloads: return !downloadsScanned
    case .developer: return devItems.isEmpty && !developerScanned
    case .largeFiles: return !largeFilesScanned
    default: return false
    }
  }

  /// Starts a page's own read-only scan the first time it opens. Each page loads by itself
  /// once per session (its Refresh button reloads it), and only when nothing else is running.
  /// Pages that need a folder choice, a permission or a long walk (Storage, Duplicates,
  /// Photos) keep their start screens instead.
  func autoLoadIfNeeded(_ section: Section) {
    guard Self.autoLoadAllowed, !autoLoaded.contains(section), tourStep == nil, exclusionsReady,
      !isScanning, !isWorking, !isPreparingPlan, pendingPlan == nil else { return }
    autoLoaded.insert(section)
    guard needsFirstLoad(section) else { return }
    switch section {
    case .applications: scanInstalledApps()
    case .cleaner: runSmartCare()
    case .startup: scanStartupItems()
    case .removedApps: scanOrphans()
    case .downloads: scanDownloads()
    case .developer: scanDeveloper()
    case .largeFiles: scanLargeFiles()
    default: break
    }
  }

  /// Quick Scan when MacMint opens (Settings ▸ Quick Scan when MacMint opens, on by default), so
  /// Overview, Cleanup, Apps, Startup Items, Removed Apps, Downloads and Developer are already
  /// filled when someone looks. Only after setup, and never during the tour or another scan.
  /// It waits for MacMint to be in front, so opening at login doesn't scan behind the person's back.
  func runLaunchScanIfEnabled(defaults: UserDefaults = .standard, inFront: Bool) {
    // Unset means on. bool(forKey:) also reads "NO" passed as a launch argument.
    let enabled = defaults.object(forKey: CareService.Keys.scanOnLaunch) == nil || defaults.bool(forKey: CareService.Keys.scanOnLaunch)
    guard Self.autoLoadAllowed, !launchScanStarted, inFront, enabled,
      defaults.bool(forKey: CareService.Keys.onboardingDone), lastScanDate == nil, tourStep == nil, exclusionsReady,
      !isScanning, !isWorking, !isPreparingPlan, pendingPlan == nil else { return }
    launchScanStarted = true
    runSmartCare()
  }

  /// Launch agents and daemons with their programs and launchd state; read-only and quick.
  func scanStartupItems() {
    guard !isScanning, !isWorking,
      beginScan(title: "Startup Items", message: "Reading launch agents and what launchd reports…") else { return }
    let ignored = ignoredPaths
    currentTask = Task { [weak self] in
      guard let self else { return }
      let report = await StartupItemScanner(launchd: { await LaunchdStateReader.snapshot() })
        .scanReport(ignoredPaths: ignored)
      guard !Task.isCancelled else { finishCancelledOperation(); return }
      startupItems = report.value
      startupScanned = true
      scanIssues = report.issues
      lastScanDuration = report.duration
      finishScan(message: "Found \(report.value.count) startup item\(report.value.count == 1 ? "" : "s")")
    }
  }
}
