import AppKit
import Foundation
import MacCleanerCore
import SwiftUI

@MainActor
final class AppViewModel: ObservableObject {
  enum Section: String, CaseIterable, Identifiable {
    case dashboard = "Overview"
    case cleaner = "Cleaner"
    case applications = "Applications"
    case largeFiles = "Large Files"
    case duplicates = "Duplicates"
    case startup = "Startup Items"
    case history = "History"
    case settings = "Settings"

    var id: String { rawValue }

    var icon: String {
      switch self {
      case .dashboard: return "sparkles"
      case .cleaner: return "trash.circle"
      case .applications: return "app.dashed"
      case .largeFiles: return "externaldrive"
      case .duplicates: return "square.on.square"
      case .startup: return "bolt.horizontal.circle"
      case .history: return "clock.arrow.circlepath"
      case .settings: return "gearshape"
      }
    }
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
  @Published var ignoredPaths: Set<String> = []
  @Published var isScanning = false
  @Published var isWorking = false
  @Published var statusMessage = "Ready"
  @Published var operationTitle: String?
  @Published var lastScanDate: Date?
  @Published var lastScanDuration: TimeInterval?
  @Published var lastCleanupResult: CleanupResult?
  @Published var largeFileRoot = FileManager.default.homeDirectoryForCurrentUser
  @Published var duplicateRoot = FileManager.default.homeDirectoryForCurrentUser
  @Published var largeFileMinimum: Int64 = 100 * 1_048_576
  @Published var duplicateMinimum: Int64 = 1 * 1_048_576

  private let smartScan = SmartScanService()
  private let appScanner = AppScanner()
  private let largeFileFinder = LargeFileFinder()
  private let duplicateFinder = DuplicateFinder()
  private let safetyPolicy = SafetyPolicy()
  private let historyStore: HistoryStore
  private let ignoreStore: IgnoreStore
  private var currentTask: Task<Void, Never>?

  init() {
    let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
      .first!
      .appendingPathComponent("MacCleanerHybridBase", isDirectory: true)
    historyStore = HistoryStore(url: support.appendingPathComponent("history.json"))
    ignoreStore = IgnoreStore(url: support.appendingPathComponent("ignored-paths.json"))

    Task {
      async let loadedHistory = historyStore.load()
      async let loadedIgnores = ignoreStore.load()
      history = await loadedHistory
      ignoredPaths = await loadedIgnores
    }
  }

  var selectedCleanupBytes: Int64 {
    cleanupTargets.filter(\.isSelected).reduce(0) { $0 + $1.size }
  }

  var selectedReviewBytes: Int64 {
    cleanupTargets.filter { $0.isSelected && $0.risk == .review }.reduce(0) { $0 + $1.size }
  }

  var reclaimableBytes: Int64 {
    cleanupTargets.filter { $0.risk == .safe }.reduce(0) { $0 + $1.size }
  }

  var reviewableBytes: Int64 {
    cleanupTargets.filter { $0.risk == .review }.reduce(0) { $0 + $1.size }
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

  func runSmartScan() {
    guard !isScanning, !isWorking else { return }
    beginScan(title: "Smart Scan", message: "Scanning caches, apps, and startup items…")

    currentTask = Task { [weak self] in
      guard let self else { return }
      let summary = await smartScan.scan(ignoredPaths: ignoredPaths)
      guard !Task.isCancelled else {
        finishCancelledOperation()
        return
      }

      cleanupTargets = summary.cleanupTargets
      apps = summary.apps
      startupItems = summary.startupItems
      scanIssues = summary.issues
      lastScanDate = summary.scannedAt
      lastScanDuration = summary.duration
      finishScan(
        message: summary.wasCancelled
          ? "Scan stopped"
          : "Scan complete — \(ByteFormatter.string(summary.reclaimableBytes)) safely reclaimable")
    }
  }

  func cancelCurrentOperation() {
    guard isScanning else { return }
    currentTask?.cancel()
    statusMessage = "Stopping scan…"
  }

  func toggleCleanup(_ id: UUID, selected: Bool) {
    guard let index = cleanupTargets.firstIndex(where: { $0.id == id }) else { return }
    guard cleanupTargets[index].risk != .restricted else { return }
    cleanupTargets[index].isSelected = selected
  }

  func selectSafeCleanupOnly() {
    for index in cleanupTargets.indices {
      cleanupTargets[index].isSelected = cleanupTargets[index].risk == .safe
    }
  }

  func deselectAllCleanup() {
    for index in cleanupTargets.indices { cleanupTargets[index].isSelected = false }
  }

  func cleanSelected() {
    guard !isWorking, !isScanning else { return }
    let selected = cleanupTargets.filter(\.isSelected)
    guard !selected.isEmpty else { return }

    isWorking = true
    operationTitle = "Cleaning"
    statusMessage = "Moving selected items to Trash…"
    lastCleanupResult = nil

    currentTask = Task { [weak self] in
      guard let self else { return }
      let engine = CleanupEngine(trashService: MacTrashService(), safetyPolicy: safetyPolicy)
      let result = await engine.execute(selected)
      lastCleanupResult = result

      let entry = HistoryEntry(
        action: "Cleanup",
        paths: result.movedToTrash.map(\.path),
        bytes: result.bytesMoved,
        notes: result.failed.isEmpty
          ? "All selected items moved to Trash."
          : "\(result.failed.count) item(s) could not be moved to Trash."
      )
      try? await historyStore.append(entry)
      history = await historyStore.load()
      isWorking = false
      operationTitle = nil
      currentTask = nil
      statusMessage =
        result.failed.isEmpty
        ? "Cleanup complete — \(ByteFormatter.string(result.bytesMoved)) moved to Trash"
        : "Cleanup finished with \(result.failed.count) issue(s)"

      runSmartScan()
    }
  }

  func loadLeftovers(for app: AppRecord) {
    guard !isScanning, !isWorking else { return }
    selectedApp = app
    appLeftovers = []
    selectedLeftoverIDs = []
    beginScan(title: "Inspecting \(app.name)", message: "Finding related application data…")

    currentTask = Task { [weak self] in
      guard let self else { return }
      let report = await appScanner.leftoversReport(for: app, ignoredPaths: ignoredPaths)
      guard !Task.isCancelled else {
        finishCancelledOperation()
        return
      }
      appLeftovers = report.value
      selectedLeftoverIDs = Set(report.value.filter { $0.confidence == .high }.map(\.id))
      scanIssues = report.issues
      lastScanDuration = report.duration
      finishScan(message: "Found \(report.value.count) related item(s)")
    }
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

  func uninstallSelectedApp() {
    guard let app = selectedApp, !isWorking, !isScanning else { return }
    if selectedAppIsRunning {
      statusMessage = "Quit \(app.name) before uninstalling it"
      return
    }
    isWorking = true
    operationTitle = "Uninstalling \(app.name)"
    statusMessage = "Moving app and selected leftovers to Trash…"
    let selectedLeftovers = appLeftovers.filter { selectedLeftoverIDs.contains($0.id) }

    currentTask = Task { [weak self] in
      guard let self else { return }
      let trash = MacTrashService()
      var moved: [URL] = []
      var failed: [OperationFailure] = []
      var bytesMoved: Int64 = 0
      var appMoved = false

      let appPath = app.url.standardizedFileURL.path
      let homeApps = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
        "Applications"
      ).standardizedFileURL.path
      let appAllowed =
        app.url.pathExtension.lowercased() == "app"
        && (appPath.hasPrefix("/Applications/") || appPath.hasPrefix(homeApps + "/"))
        && !appPath.hasPrefix("/System/Applications/")

      if appAllowed {
        do {
          try await trash.trash(app.url)
          moved.append(app.url)
          bytesMoved += app.bundleSize
          appMoved = true
        } catch {
          failed.append(OperationFailure(url: app.url, message: error.localizedDescription))
        }
      } else {
        failed.append(
          OperationFailure(
            url: app.url, message: "This application path is not eligible for uninstall."))
      }

      if !appMoved, !selectedLeftovers.isEmpty {
        failed.append(
          OperationFailure(
            url: app.url,
            message:
              "Related data was left untouched because the app itself was not moved to Trash."
          ))
      }

      for leftover in appMoved ? selectedLeftovers : [] {
        if Task.isCancelled { break }
        let decision = safetyPolicy.appLeftoverDecision(for: leftover.url)
        guard decision.allowed else {
          failed.append(OperationFailure(url: leftover.url, message: decision.reason))
          continue
        }
        do {
          try await trash.trash(leftover.url)
          moved.append(leftover.url)
          bytesMoved += leftover.size
        } catch {
          failed.append(OperationFailure(url: leftover.url, message: error.localizedDescription))
        }
      }

      try? await historyStore.append(
        HistoryEntry(
          action: "Uninstall \(app.name)",
          paths: moved.map(\.path),
          bytes: bytesMoved,
          notes: failed.isEmpty
            ? "App and selected leftovers moved to Trash."
            : "Completed with \(failed.count) failure(s)."
        ))
      history = await historyStore.load()
      isWorking = false
      operationTitle = nil
      currentTask = nil
      selectedApp = nil
      appLeftovers = []
      selectedLeftoverIDs = []
      statusMessage =
        failed.isEmpty
        ? "\(app.name) moved to Trash" : "Uninstall completed with \(failed.count) issue(s)"
      runSmartScan()
    }
  }

  func scanLargeFiles() {
    guard !isScanning, !isWorking else { return }
    beginScan(title: "Large Files", message: "Scanning \(largeFileRoot.lastPathComponent)…")

    currentTask = Task { [weak self] in
      guard let self else { return }
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
      scanIssues = report.issues
      lastScanDuration = report.duration
      finishScan(message: "Found \(report.value.count) large file(s)")
    }
  }

  func scanDuplicates() {
    guard !isScanning, !isWorking else { return }
    beginScan(
      title: "Duplicate Finder", message: "Comparing files in \(duplicateRoot.lastPathComponent)…")

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
    let groupIDs = Set(group.files.map(\.id))
    selectedDuplicateIDs.subtract(groupIDs)
    for file in group.files.dropFirst() { selectedDuplicateIDs.insert(file.id) }
  }

  func clearDuplicateSelection(in groupID: UUID? = nil) {
    guard let groupID else {
      selectedDuplicateIDs = []
      return
    }
    guard let group = duplicateGroups.first(where: { $0.id == groupID }) else { return }
    let groupIDs = Set(group.files.map(\.id))
    selectedDuplicateIDs.subtract(groupIDs)
  }

  func toggleDuplicate(_ fileID: UUID, in groupID: UUID, selected: Bool) {
    guard let group = duplicateGroups.first(where: { $0.id == groupID }),
      group.files.contains(where: { $0.id == fileID })
    else { return }
    if !selected {
      selectedDuplicateIDs.remove(fileID)
      return
    }

    let selectedInGroup = group.files.filter { selectedDuplicateIDs.contains($0.id) }.count
    guard selectedInGroup < group.files.count - 1 else {
      statusMessage = "At least one copy must remain in each duplicate group"
      return
    }
    selectedDuplicateIDs.insert(fileID)
  }

  func trashSelectedDuplicates() {
    guard !isWorking, !isScanning else { return }
    let files = duplicateGroups.flatMap { group -> [LargeFile] in
      let selected = group.files.filter { selectedDuplicateIDs.contains($0.id) }
      // Re-check the invariant at execution time rather than trusting only the UI toggles.
      return selected.count < group.files.count ? selected : []
    }
    guard !files.isEmpty else {
      statusMessage = "Nothing can be removed — at least one copy must remain in each group"
      return
    }

    isWorking = true
    operationTitle = "Removing duplicates"
    statusMessage = "Moving reviewed duplicate copies to Trash…"

    currentTask = Task { [weak self] in
      guard let self else { return }
      let trash = MacTrashService()
      var movedIDs: Set<UUID> = []
      var paths: [String] = []
      var bytesMoved: Int64 = 0
      var failures = 0

      for file in files {
        if Task.isCancelled { break }
        let decision = safetyPolicy.reviewedFileDecision(for: file.url)
        guard decision.allowed else {
          failures += 1
          continue
        }
        do {
          try await trash.trash(file.url)
          movedIDs.insert(file.id)
          paths.append(file.url.path)
          bytesMoved += file.size
        } catch {
          failures += 1
        }
      }

      duplicateGroups = duplicateGroups.compactMap { group in
        let remaining = group.files.filter { !movedIDs.contains($0.id) }
        return remaining.count > 1
          ? DuplicateGroup(id: group.id, fingerprint: group.fingerprint, files: remaining) : nil
      }
      selectedDuplicateIDs.subtract(movedIDs)

      try? await historyStore.append(
        HistoryEntry(
          action: "Remove duplicates",
          paths: paths,
          bytes: bytesMoved,
          notes: failures == 0
            ? "Reviewed duplicate copies moved to Trash." : "Completed with \(failures) failure(s)."
        ))
      history = await historyStore.load()
      isWorking = false
      operationTitle = nil
      currentTask = nil
      statusMessage =
        failures == 0
        ? "Moved \(ByteFormatter.string(bytesMoved)) of duplicates to Trash"
        : "Duplicate cleanup finished with \(failures) issue(s)"
    }
  }

  func trashReviewedFile(_ url: URL, bytes: Int64, action: String) {
    guard !isWorking, !isScanning else { return }
    let decision = safetyPolicy.reviewedFileDecision(for: url)
    guard decision.allowed else {
      statusMessage = decision.reason
      return
    }

    isWorking = true
    operationTitle = action
    currentTask = Task { [weak self] in
      guard let self else { return }
      do {
        try await MacTrashService().trash(url)
        try? await historyStore.append(
          HistoryEntry(
            action: action,
            paths: [url.path],
            bytes: bytes,
            notes: "Moved to Trash after explicit review."
          ))
        history = await historyStore.load()
        largeFiles.removeAll { $0.url == url }
        duplicateGroups = duplicateGroups.compactMap { group in
          let remaining = group.files.filter { $0.url != url }
          return remaining.count > 1
            ? DuplicateGroup(id: group.id, fingerprint: group.fingerprint, files: remaining) : nil
        }
        statusMessage = "Moved \(url.lastPathComponent) to Trash"
      } catch {
        statusMessage = "Could not move item: \(error.localizedDescription)"
      }
      isWorking = false
      operationTitle = nil
      currentTask = nil
    }
  }

  func ignore(_ url: URL) {
    Task {
      do {
        ignoredPaths = try await ignoreStore.add(url)
        cleanupTargets.removeAll { FileSystem.isIgnored($0.url, ignoredPaths: ignoredPaths) }
        largeFiles.removeAll { FileSystem.isIgnored($0.url, ignoredPaths: ignoredPaths) }
        duplicateGroups = duplicateGroups.compactMap { group in
          let remaining = group.files.filter {
            !FileSystem.isIgnored($0.url, ignoredPaths: ignoredPaths)
          }
          return remaining.count > 1
            ? DuplicateGroup(id: group.id, fingerprint: group.fingerprint, files: remaining) : nil
        }
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

  func openSystemSettings() {
    NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/System Settings.app"))
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

  private func beginScan(title: String, message: String) {
    isScanning = true
    operationTitle = title
    statusMessage = message
    scanIssues = []
  }

  private func finishScan(message: String) {
    isScanning = false
    operationTitle = nil
    currentTask = nil
    statusMessage = message
  }

  private func finishCancelledOperation() {
    isScanning = false
    operationTitle = nil
    currentTask = nil
    statusMessage = "Scan cancelled"
  }

  private func chooseFolder(prompt: String) -> URL? {
    let panel = NSOpenPanel()
    panel.title = prompt
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.allowsMultipleSelection = false
    panel.prompt = "Scan"
    return panel.runModal() == .OK ? panel.url : nil
  }
}
