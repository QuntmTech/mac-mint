import AppKit
import Foundation
import MacCleanerCore
import ServiceManagement
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class AppViewModel: ObservableObject {
  enum Section: String, CaseIterable, Identifiable {
    case dashboard = "Overview"
    case review = "Review"
    case cleaner = "Cleanup"
    case storage = "Storage"
    case developer = "Developer"
    case assistant = "Ask MacMint"
    case downloads = "Downloads"
    case photos = "Photos"
    case removedApps = "Removed Apps"
    case performance = "Performance"
    case applications = "Apps"
    case largeFiles = "Large Files"
    case duplicates = "Duplicates"
    case startup = "Startup Items"
    case history = "History"
    case settings = "Settings"

    var id: String { rawValue }

    static let primary: [Section] = [.dashboard, .cleaner, .storage, .applications, .photos, .developer, .history]
    var parent: Section {
      switch self {
      case .performance: return .dashboard
      case .downloads: return .cleaner
      case .largeFiles, .duplicates: return .storage
      case .removedApps, .startup: return .applications
      default: return self
      }
    }
    var tabs: [Section] {
      switch parent {
      case .dashboard: return [.dashboard, .performance]
      case .cleaner: return [.cleaner, .downloads]
      case .storage: return [.storage, .largeFiles, .duplicates]
      case .applications: return [.applications, .removedApps, .startup]
      default: return []
      }
    }

    var icon: String {
      switch self {
      case .dashboard: return "sparkles"
      case .review: return "checklist"
      case .cleaner: return "trash.circle"
      case .storage: return "chart.pie"
      case .developer: return "hammer"
      case .assistant: return "bubble.left.and.text.bubble.right"
      case .downloads: return "arrow.down.circle"
      case .photos: return "photo.on.rectangle.angled"
      case .removedApps: return "folder.badge.questionmark"
      case .performance: return "gauge.with.dots.needle.33percent"
      case .applications: return "app.dashed"
      case .largeFiles: return "externaldrive"
      case .duplicates: return "square.on.square"
      case .startup: return "bolt.horizontal.circle"
      case .history: return "clock.arrow.circlepath"
      case .settings: return "gearshape"
      }
    }
  }

  @Published var showingAccount = false
  @Published var showingHelp = false
  @Published var deferredPlan: OperationPlan?
  var authorizeRemoval: () -> Bool = { false }

  func requirePaidAccess() -> Bool {
    guard requireExclusions() else { return false }
    guard authorizeRemoval() else {
      statusMessage = "Sign in with an active plan to move items. Your selections are kept."
      showingAccount = true
      return false
    }
    return true
  }

  @Published var selectedSection: Section = .dashboard
  @Published var cleanupTargets: [CleanupTarget] = []
  @Published var apps: [AppRecord] = []
  @Published var startupItems: [StartupItem] = []
  @Published var largeFiles: [LargeFile] = []
  @Published var duplicateGroups: [DuplicateGroup] = []
  @Published var selectedDuplicateIDs: Set<UUID> = []
  @Published var selectedApp: AppRecord?
  @Published var appLeftovers: [AppLeftover] = []
  @Published var selectedLeftoverIDs: Set<UUID> = []
  @Published var history: [HistoryEntry] = []
  @Published var scanIssues: [ScanIssue] = []
  @Published var showingScanIssues = false
  @Published var recoveryWarnings: [ScanIssue] = []
  @Published var ignoredPaths: Set<String> = []
  @Published private(set) var exclusionsReady = false
  @Published private(set) var exclusionLoadError: String?
  var keptQueuePaths: Set<String> = []
  @Published var scanCompletedAreas: [String] = []
  @Published var isScanning = false
  @Published var isWorking = false
  @Published var statusMessage = "Ready"
  @Published var operationTitle: String?
  @Published var lastScanDate: Date?
  @Published var lastScanDuration: TimeInterval?
  @Published var selectedLargeFileIDs: Set<UUID> = []
  @Published var largeFilesViaSpotlight = false
  @Published var showingCommandPalette = false
  @Published var storageRoot = FileManager.default.homeDirectoryForCurrentUser
  @Published var storageScan: StorageScan?
  @Published var storagePath: String?
  @Published var storageScannedCount = 0
  @Published var selectedStoragePaths: Set<String> = []
  @Published var devItems: [DevStorageItem] = []
  @Published var selectedDevIDs: Set<String> = []
  @Published var photoSource: PhotoSource = .library
  @Published var photoReviewSession = PhotoReviewSession()
  @Published var photoScan: PhotoScanResult? {
    didSet {
      if oldValue?.generation != photoScan?.generation { photoReviewSession = PhotoReviewSession() }
    }
  }
  @Published var photoProgress: (done: Int, total: Int)?
  @Published var selectedPhotoIDs: Set<String> = []
  @Published var photoKeeperOverrides: [String: String] = [:]
  @Published var orphans: [OrphanedItem] = []
  @Published var selectedOrphanIDs: Set<String> = []
  @Published var orphansScanned = false
  @Published var trashStatus: TrashBinService.Status?
  @Published var recommendations: [Recommendation] = []
  @Published var smartCareRanAt: Date?
  @Published var downloadItems: [DownloadItem] = []
  @Published var selectedDownloadIDs: Set<String> = []
  @Published var downloadsScanned = false
  @Published var spaceHistory: [SpaceSample] = []
  @Published var storageGrowth: [StorageGrowth] = []
  @Published var applicationsSortByLastOpened = false
  @Published var explainTarget: ExplainTarget?
  @Published var explanations: [String: AIExplanation] = [:]
  @Published var aiReview: AIReview?
  @Published var aiReviewBusy = false
  @Published var aiOrderRecommendations = false
  @Published var assistantTurns: [AITurn] = []
  @Published var assistantDraft = ""
  @Published var assistantBusy = false
  var aiGeneration = UUID()
  var pendingAIAction: (@MainActor () -> Void)?
  var aiReviewTask: Task<Void, Never>?
  var assistantTask: Task<Void, Never>?
  var explanationTask: Task<Void, Never>?
  @Published var explanationError: String?
  @Published var reviewAIError: String?
  @Published var aiPayloadPreview = ""
  @Published var aiError: String?
  @Published var aiConsentPending = false
  @Published var pendingPlan: OperationPlan?
  @Published var isPreparingPlan = false
  @Published var operationProgress: OperationProgress?
  @Published var lastReport: OperationReport?
  @Published var restoreConflicts: [RestoreConflict] = []
  @Published var largeFileRoot = FileManager.default.homeDirectoryForCurrentUser
  @Published var duplicateRoot = FileManager.default.homeDirectoryForCurrentUser
  @Published var largeFileMinimum: Int64 = 100 * 1_048_576
  @Published var duplicateMinimum: Int64 = 1 * 1_048_576

  private let smartScan = SmartScanService()
  private let appScanner = AppScanner()
  private let largeFileFinder = LargeFileFinder()
  private let duplicateFinder = DuplicateFinder()
  let safetyPolicy = SafetyPolicy()
  let duplicateVerifier = DuplicateRemovalVerifier()
  let organizationStore: OrganizationStore
  let historyStore: HistoryStore
  let supportDirectory: URL
  var operationJournalDirectory: URL { supportDirectory.appendingPathComponent("Operations", isDirectory: true) }
  var restoreJournalDirectory: URL { supportDirectory.appendingPathComponent("Restores", isDirectory: true) }
  private let ignoreStore: IgnoreStore
  var currentTask: Task<Void, Never>?

  init(supportDirectory: URL? = nil) {
    // A read-only launch shortcut also lets the packaged resource probe measure live UI.
    if CommandLine.arguments.contains("--performance") { selectedSection = .performance }
    let support = supportDirectory ?? AppPaths.supportDirectory
    self.supportDirectory = support
    organizationStore = OrganizationStore(directory: support.appendingPathComponent("Organization"))
    historyStore = HistoryStore(url: support.appendingPathComponent("history.json"))
    ignoreStore = IgnoreStore(url: support.appendingPathComponent("ignored-paths.json"))

    Task {
      do {
        ignoredPaths = try await ignoreStore.loadChecked()
        exclusionsReady = true
      } catch {
        exclusionLoadError = "Saved exclusions could not be read. Scanning and new removal are paused. Inspect or reset exclusions in Settings; History and Restore remain available."
        statusMessage = exclusionLoadError!
      }
      do { history = try await historyStore.loadChecked() }
      catch { recoveryWarnings.append(ScanIssue(area: "Recovery", path: nil,
        message: "History could not be read. The existing file has been preserved; check recovery records before further cleanup.")) }
      await recoverInterruptedOperations()
    }
  }

  var selectedCleanupBytes: Int64 {
    OperationPlanner.plan(title: "Selected cleanup", items: cleanupTargets.filter(\.isSelected).map { PlanItem.cleanup($0) }, ignoredPaths: ignoredPaths).totalBytes
  }

  var selectedReviewBytes: Int64 {
    cleanupTargets.filter { $0.isSelected && $0.risk == .review }.reduce(0) { $0 + $1.size }
  }

  var reclaimableBytes: Int64 {
    OperationPlanner.plan(title: "Rebuildable estimate", items: cleanupTargets.filter { $0.risk == .safe }.map { PlanItem.cleanup($0) }, ignoredPaths: ignoredPaths).totalBytes
  }

  var reviewableBytes: Int64 {
    OperationPlanner.plan(title: "Review estimate", items: cleanupTargets.filter { $0.risk == .review }.map { PlanItem.cleanup($0) }, ignoredPaths: ignoredPaths).totalBytes
  }

  var volumeName: String {
    let values = try? FileManager.default.homeDirectoryForCurrentUser.resourceValues(forKeys: [
      .volumeLocalizedNameKey
    ])
    return values?.volumeLocalizedName ?? "Startup Disk"
  }

  var duplicateSelectedBytes: Int64 {
    duplicateGroups.flatMap(\.files).filter { selectedDuplicateIDs.contains($0.id) }.reduce(0) {
      $0 + $1.size
    }
  }

  var selectedAppIsRunning: Bool {
    guard let app = selectedApp else { return false }
    return !runningInstances(of: app).isEmpty
  }

  var volumeStats: (used: Int64, free: Int64, total: Int64) {
    let home = FileManager.default.homeDirectoryForCurrentUser
    let values = try? home.resourceValues(forKeys: [
      .volumeTotalCapacityKey,
      .volumeAvailableCapacityForImportantUsageKey,
      .volumeAvailableCapacityKey,
    ])
    let total = Int64(values?.volumeTotalCapacity ?? 0)
    let free =
      values?.volumeAvailableCapacityForImportantUsage
      ?? Int64(values?.volumeAvailableCapacity ?? 0)
    return (max(0, total - free), max(0, free), max(0, total))
  }

  func runSmartScan() { runSmartCare() }

  func cancelCurrentOperation() {
    guard isScanning || isWorking else { return }
    currentTask?.cancel()
    statusMessage = isWorking ? "Stopping after the current item…" : "Stopping scan…"
  }

  func toggleCleanup(_ id: UUID, selected: Bool) {
    guard let index = cleanupTargets.firstIndex(where: { $0.id == id }) else { return }
    guard cleanupTargets[index].risk != .restricted else { return }
    setFileSelection(cleanupTargets[index].url, selected: selected)
  }

  func selectSafeCleanupOnly() {
    for index in cleanupTargets.indices {
      setFileSelection(cleanupTargets[index].url, selected: cleanupTargets[index].risk == .safe)
    }
  }

  func deselectAllCleanup() {
    keepQueuedFiles(cleanupTargets.map(\.url))
  }

  func inspectDroppedApp(_ url: URL) {
    guard url.isFileURL, url.pathExtension.lowercased() == "app" else {
      statusMessage = "Drop an installed .app bundle to inspect it"; return
    }
    selectedSection = .applications
    if let app = apps.first(where: { FileSystem.comparisonPath($0.url) == FileSystem.comparisonPath(url) }) {
      loadLeftovers(for: app)
    } else {
      Task {
        guard let app = await appScanner.inspect(url) else { statusMessage = "This is not a readable application bundle"; return }
        if !apps.contains(where: { $0.url == url }) { apps.append(app) }
        loadLeftovers(for: app)
      }
    }
  }

  func loadLeftovers(for app: AppRecord) {
    guard !isScanning, !isWorking else { return }
    selectedApp = app
    appLeftovers = []
    selectedLeftoverIDs = []
    guard beginScan(title: "Inspecting \(app.name)", message: "Finding related application data…") else { return }

    currentTask = Task { [weak self] in
      guard let self else { return }
      let others = Set(apps.compactMap(\.bundleIdentifier))
      let report = await appScanner.leftoversReport(
        for: app, otherBundleIDs: others, ignoredPaths: ignoredPaths,
        hasOtherInstallation: app.bundleIdentifier != nil && apps.contains { $0.bundleIdentifier == app.bundleIdentifier
          && FileSystem.comparisonPath($0.url) != FileSystem.comparisonPath(app.url) })
      guard !Task.isCancelled else {
        finishCancelledOperation()
        return
      }
      appLeftovers = report.value
      selectedLeftoverIDs = Set(report.value.filter(\.isSuggested).map(\.id))
      scanIssues = report.issues
      lastScanDuration = report.duration
      finishScan(message: "Found \(report.value.count) related item(s)")
    }
  }

  func scanInstalledApps() {
    guard !isScanning, !isWorking,
      beginScan(title: "Installed apps", message: "Finding installed applications…") else { return }
    currentTask = Task { [weak self] in
      guard let self else { return }
      let report = await appScanner.installedAppsReport(ignoredPaths: ignoredPaths)
      guard !Task.isCancelled else { finishCancelledOperation(); return }
      apps = report.value
      if let selectedApp, !apps.contains(where: { $0.url == selectedApp.url }) {
        self.selectedApp = nil; appLeftovers = []; selectedLeftoverIDs = []
      }
      scanIssues = report.issues; lastScanDuration = report.duration
      finishScan(message: "Found \(apps.count) installed apps. Choose one to review its related files.")
    }
  }

  func chooseAppForUninstall() {
    guard !isScanning, !isWorking else { return }
    let panel = NSOpenPanel()
    panel.title = "Choose an app to uninstall"; panel.prompt = "Inspect App"
    panel.canChooseDirectories = false; panel.canChooseFiles = true
    panel.allowedContentTypes = [.applicationBundle]
    panel.directoryURL = URL(fileURLWithPath: "/Applications")
    if panel.runModal() == .OK, let url = panel.url { inspectDroppedApp(url) }
  }

  func requestQuitSelectedApp() {
    guard let app = selectedApp else { return }
    let running = runningInstances(of: app)
    guard !running.isEmpty else {
      statusMessage = "\(app.name) is already closed"
      return
    }
    let requested = running.reduce(false) { $1.terminate() || $0 }
    statusMessage =
      requested
      ? "Quit requested for \(app.name). Finish any save prompts, then uninstall."
      : "Could not request \(app.name) to quit"
  }

  /// Spotlight answers first (verified against the disk); `fullScan` walks every folder instead.
  func scanLargeFiles(fullScan: Bool = false) {
    guard !isScanning, !isWorking else { return }
    guard beginScan(title: "Large Files", message: "Scanning \(largeFileRoot.lastPathComponent)…") else { return }

    currentTask = Task { [weak self] in
      guard let self else { return }
      if !fullScan,
        let instant = await SpotlightLargeFiles.search(
          in: largeFileRoot, minimumSize: largeFileMinimum, excludedRoots: defaultReviewExclusions,
          ignoredPaths: ignoredPaths)
      {
        guard !Task.isCancelled else {
          finishCancelledOperation()
          return
        }
        largeFiles = instant
        largeFilesViaSpotlight = true
        selectedLargeFileIDs = []
        scanIssues = []
        finishScan(message: "Found \(instant.count) large file(s) instantly via Spotlight")
        return
      }
      let report = await largeFileFinder.findReport(
        in: [largeFileRoot],
        minimumSize: largeFileMinimum,
        excludedRoots: defaultReviewExclusions,
        ignoredPaths: ignoredPaths
      )
      guard !Task.isCancelled else {
        finishCancelledOperation()
        return
      }
      largeFiles = report.value
      largeFilesViaSpotlight = false
      selectedLargeFileIDs = []
      scanIssues = report.issues
      lastScanDuration = report.duration
      finishScan(message: "Found \(report.value.count) large file(s)")
    }
  }

  func scanDuplicates() {
    guard !isScanning, !isWorking else { return }
    guard beginScan(
      title: "Duplicate Finder", message: "Comparing files in \(duplicateRoot.lastPathComponent)…") else { return }

    currentTask = Task { [weak self] in
      guard let self else { return }
      let report = await duplicateFinder.findReport(
        in: [duplicateRoot],
        minimumSize: duplicateMinimum,
        excludedRoots: defaultReviewExclusions,
        ignoredPaths: ignoredPaths
      )
      guard !Task.isCancelled else {
        finishCancelledOperation()
        return
      }
      duplicateGroups = report.value
      selectedDuplicateIDs = []
      scanIssues = report.issues
      lastScanDuration = report.duration
      finishScan(message: "Found \(report.value.count) exact duplicate group(s)")
    }
  }

  func selectDuplicateCopies(in groupID: UUID) {
    guard let group = duplicateGroups.first(where: { $0.id == groupID }), group.files.count > 1
    else { return }
    let chosen = Set(group.files.dropFirst().map(\.id))
    applyDuplicateSelection(selectedDuplicateIDs.subtracting(group.files.map(\.id)).union(chosen))
  }

  func applyDuplicateSelection(_ ids: Set<UUID>) {
    selectedDuplicateIDs = ids
    for file in duplicateGroups.flatMap(\.files) { setFileSelection(file.url, selected: ids.contains(file.id)) }
  }

  func keepDuplicate(_ file: LargeFile, in group: DuplicateGroup) {
    let copies = Set(group.files.filter { $0.id != file.id && (file.identity == nil || $0.identity != file.identity) }.map(\.id))
    applyDuplicateSelection(selectedDuplicateIDs.subtracting(group.files.map(\.id)).union(copies))
  }

  func clearDuplicateSelection(in groupID: UUID? = nil) {
    let removals = duplicateGroups.filter { groupID == nil || $0.id == groupID }.flatMap(\.files).map(\.id)
    applyDuplicateSelection(selectedDuplicateIDs.subtracting(removals))
  }

  func toggleDuplicate(_ fileID: UUID, in groupID: UUID, selected: Bool) {
    guard let group = duplicateGroups.first(where: { $0.id == groupID }),
      group.files.contains(where: { $0.id == fileID })
    else { return }
    if !selected {
      if let file = group.files.first(where: { $0.id == fileID }) { setFileSelection(file.url, selected: false) }
      return
    }

    let selectedInGroup = group.files.filter { selectedDuplicateIDs.contains($0.id) }.count
    guard selectedInGroup < group.files.count - 1 else {
      statusMessage = "At least one copy must remain in each duplicate group"
      return
    }
    if let file = group.files.first(where: { $0.id == fileID }) { setFileSelection(file.url, selected: true) }
  }

  func ignore(_ url: URL) {
    Task {
      do {
        ignoredPaths = try await ignoreStore.add(url)
        cleanupTargets.removeAll { FileSystem.isIgnored($0.url, ignoredPaths: ignoredPaths) }
        largeFiles.removeAll { FileSystem.isIgnored($0.url, ignoredPaths: ignoredPaths) }
        selectedLargeFileIDs.formIntersection(largeFiles.map(\.id))
        duplicateGroups = duplicateGroups.compactMap { group in
          let updated = DuplicateGroup(
            id: group.id, fingerprint: group.fingerprint,
            files: group.files.filter { !FileSystem.isIgnored($0.url, ignoredPaths: ignoredPaths) })
          return updated.physicalCopyCount > 1 ? updated : nil
        }
        selectedDuplicateIDs.formIntersection(duplicateGroups.flatMap(\.files).map(\.id))
        // Cleanup targets that contain the new exclusion can no longer be acted on as a whole.
        cleanupTargets.removeAll {
          FileSystem.containsIgnoredDescendant($0.url, ignoredPaths: ignoredPaths)
        }
        let blockedLeftovers = Set(
          appLeftovers.filter {
            FileSystem.isIgnored($0.url, ignoredPaths: ignoredPaths)
              || FileSystem.containsIgnoredDescendant($0.url, ignoredPaths: ignoredPaths)
          }.map(\.id))
        appLeftovers.removeAll { blockedLeftovers.contains($0.id) }
        selectedLeftoverIDs.subtract(blockedLeftovers)
        statusMessage = "Added \(url.lastPathComponent) to exclusions"
      } catch {
        statusMessage = "Could not save exclusion: \(error.localizedDescription)"
      }
    }
  }

  func removeIgnore(path: String) {
    Task {
      do {
        ignoredPaths = try await ignoreStore.remove(path: path)
        statusMessage = "Exclusion removed"
      } catch {
        statusMessage = "Could not remove exclusion: \(error.localizedDescription)"
      }
    }
  }

  func clearIgnores() {
    Task {
      do {
        try await ignoreStore.clear()
        ignoredPaths = []
        exclusionLoadError = nil
        exclusionsReady = true
        statusMessage = "All exclusions cleared"
      } catch {
        statusMessage = "Could not clear exclusions: \(error.localizedDescription)"
      }
    }
  }

  func chooseLargeFileFolder() {
    if let url = chooseFolder(prompt: "Choose a folder to scan for large files") {
      largeFileRoot = url
      selectedSection = .largeFiles
      scanLargeFiles()
    }
  }

  func chooseDuplicateFolder() {
    if let url = chooseFolder(prompt: "Choose a folder to scan for duplicate files") {
      duplicateRoot = url
      selectedSection = .duplicates
      scanDuplicates()
    }
  }

  func reveal(_ url: URL) {
    NSWorkspace.shared.activateFileViewerSelecting([url])
  }

  func openActivityMonitor() {
    NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app"))
  }

  func openLoginItemsSettings() {
    SMAppService.openSystemSettingsLoginItems()
  }

  func openSystemSettings() {
    if !PermissionsService.openSettings(.fullDiskAccess) {
      statusMessage = "Open \(PermissionSettingsPane.fullDiskAccess.path) from the Apple menu."
    }
  }

  @discardableResult
  func record(_ entry: HistoryEntry) async -> Bool {
    do {
      try await historyStore.append(entry)
      history = await historyStore.load()
      return true
    } catch {
      statusMessage = "Could not save history: \(error.localizedDescription)"
    }
    return false
  }

  private func runningInstances(of app: AppRecord) -> [NSRunningApplication] {
    if let bundleID = app.bundleIdentifier {
      let matches = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
      if !matches.isEmpty { return matches }
    }
    let target = app.url.standardizedFileURL.path
    return NSWorkspace.shared.runningApplications.filter {
      $0.bundleURL?.standardizedFileURL.path == target
    }
  }

  private var defaultReviewExclusions: [URL] {
    let home = FileManager.default.homeDirectoryForCurrentUser
    return [
      home.appendingPathComponent("Library"),
      home.appendingPathComponent(".Trash"),
    ]
  }

  func requireExclusions() -> Bool {
    guard exclusionsReady else {
      statusMessage = exclusionLoadError ?? "Loading saved exclusions. Try again in a moment."
      return false
    }
    return true
  }

  func beginScan(title: String, message: String) -> Bool {
    guard requireExclusions() else { return false }
    isScanning = true
    operationTitle = title
    invalidateAIReview()
    statusMessage = message
    scanIssues = []
    return true
  }

  func finishScan(message: String) {
    synchronizeQueueSelections()
    isScanning = false
    operationTitle = nil
    currentTask = nil
    statusMessage = message
  }

  func finishCancelledOperation() {
    isScanning = false
    operationTitle = nil
    currentTask = nil
    statusMessage = "Scan cancelled"
  }

  func chooseFolder(prompt: String) -> URL? {
    let panel = NSOpenPanel()
    panel.title = prompt
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.allowsMultipleSelection = false
    panel.prompt = "Scan"
    return panel.runModal() == .OK ? panel.url : nil
  }
}
