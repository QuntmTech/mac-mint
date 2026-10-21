import AppKit
import Foundation
import MacCleanerCore

/// Startup-volume reading. Important-usage capacity can take noticeable time to compute,
/// so views show a cached value refreshed off the main actor.
struct VolumeSummary: Equatable, Sendable {
  var name = "Startup Disk"
  var used: Int64 = 0
  var free: Int64 = 0
  var total: Int64 = 0
  /// False when macOS did not report both capacities; the zeros are then unknown, not empty.
  var isMeasured: Bool { total > 0 }

  static func read(_ url: URL = FileManager.default.homeDirectoryForCurrentUser) -> VolumeSummary {
    let values = try? url.resourceValues(forKeys: [
      .volumeLocalizedNameKey, .volumeTotalCapacityKey,
      .volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey,
    ])
    return summary(name: values?.volumeLocalizedName, total: values?.volumeTotalCapacity.map(Int64.init),
      free: values?.volumeAvailableCapacityForImportantUsage ?? values?.volumeAvailableCapacity.map(Int64.init))
  }

  /// True when the sidebar and Overview would show the same text and state.
  func displaysSame(as other: VolumeSummary) -> Bool {
    name == other.name && total == other.total && isMeasured == other.isMeasured
      && ByteFormatter.string(free) == ByteFormatter.string(other.free)
      && ByteFormatter.string(used) == ByteFormatter.string(other.used)
  }

  static func summary(name: String?, total: Int64?, free: Int64?) -> VolumeSummary {
    let name = name ?? "Startup Disk"
    guard let total, total > 0, let free, free >= 0 else { return VolumeSummary(name: name) }
    return VolumeSummary(name: name, used: max(0, total - free), free: free, total: total)
  }
}

extension AppViewModel {
  @discardableResult
  func refreshVolumeSummary() async -> VolumeSummary {
    let reading = await Task.detached(priority: .utility) { VolumeSummary.read() }.value
    // Every view observing the model redraws when `volume` changes, and free space moves by a
    // few bytes almost every minute; only a change people can see is published.
    if !reading.displaysSame(as: volume) { volume = reading }
    return reading
  }

  /// Synchronous refresh for the offscreen render harness.
  func refreshVolumeSummaryNow() { volume = VolumeSummary.read() }

  var storageCurrentNode: StorageNode? {
    guard let root = storageScan?.root else { return nil }
    if let path = storagePath, let node = root.node(at: path) { return node }
    return root
  }

  var storageTrail: [StorageNode] {
    guard let root = storageScan?.root else { return [] }
    guard let path = storagePath else { return [root] }
    let trail = root.trail(to: path)
    return trail.isEmpty ? [root] : trail
  }

  var queuedStorageNodes: [StorageNode] {
    guard let root = storageScan?.root else { return [] }
    return selectedStoragePaths.sorted().compactMap { root.node(at: $0) }.filter(\.isActionable)
  }

  func scanStorage() {
    guard !isScanning, !isWorking else { return }
    let root = storageRoot
    guard beginScan(title: "Storage", message: "Mapping \(root.lastPathComponent)…") else { return }
    storageScannedCount = 0
    let scanner = StorageTreeScanner()

    currentTask = Task { [weak self] in
      guard let self else { return }
      let scan = await scanner.scan(root, ignoredPaths: ignoredPaths) { count, _ in
        Task { @MainActor [weak self] in
          guard let self, self.isScanning else { return }
          self.storageScannedCount = count
          self.statusMessage = "Mapping \(root.lastPathComponent)… \(count.formatted()) items"
        }
      }
      guard !Task.isCancelled else {
        finishCancelledOperation()
        return
      }
      storageScan = scan
      storagePrunedFolders = []
      storagePath = nil
      selectedStoragePaths = []
      if !scan.coverage.wasCancelled { recordStorageSnapshot(scan.root) }
      scanIssues = scan.coverage.inaccessiblePaths.prefix(200).map {
        ScanIssue(area: "Storage", path: $0, message: "Could not be read; its size is not included.")
      }
      lastScanDuration = scan.duration
      finishScan(
        message:
          "Mapped \(ByteFormatter.string(scan.root.allocatedBytes)) in \(scan.coverage.scannedItems.formatted()) items")
    }
  }

  func chooseStorageFolder() {
    if let url = chooseFolder(prompt: "Choose a folder or drive to map") {
      storageRoot = url
      selectedSection = .storage
      scanStorage()
    }
  }

  func canOpenStorageNode(_ node: StorageNode) -> Bool {
    node.kind == .folder && (!node.children.isEmpty || storagePrunedFolders.contains(node.id))
  }

  func openStorageNode(_ node: StorageNode) {
    if storagePrunedFolders.contains(node.id), node.children.isEmpty { remapStorageFolder(node); return }
    guard node.kind == .folder, !node.children.isEmpty else { return }
    storagePath = node.id
  }

  /// Drops the deep levels of the map while they aren't on screen. Totals, the visible trail
  /// and selected items stay; a pruned folder is mapped again when it is opened.
  @discardableResult
  func compactStorageMap() -> Bool {
    guard let scan = storageScan, !(isScanning && operationTitle == "Storage") else { return false }
    let root = scan.root.id
    var expanding = Set<String>()
    for path in selectedStoragePaths { expanding.formUnion(StorageNode.ancestors(of: path, within: root)) }
    if let path = storagePath { expanding.insert(path); expanding.formUnion(StorageNode.ancestors(of: path, within: root)) }
    let compact = scan.root.compacted(levels: 2, expanding: expanding)
    guard !compact.pruned.isEmpty else { return false }
    storagePrunedFolders.formUnion(compact.pruned)
    storageScan = StorageScan(root: compact.node, coverage: scan.coverage, duration: scan.duration)
    return true
  }

  func remapStorageFolder(_ node: StorageNode) {
    guard !isScanning, !isWorking, requireExclusions() else { return }
    isScanning = true
    operationTitle = "Storage"
    statusMessage = "Mapping \(node.name)…"
    let id = node.id, url = node.url, name = node.name
    let scanner = StorageTreeScanner()
    currentTask = Task { [weak self] in
      guard let self else { return }
      let scan = await scanner.scan(url, ignoredPaths: ignoredPaths)
      guard !Task.isCancelled, !scan.coverage.wasCancelled, let current = storageScan else {
        finishCancelledOperation()
        return
      }
      storageScan = StorageScan(root: current.root.replacing(id, with: scan.root), coverage: current.coverage,
        duration: current.duration)
      storagePrunedFolders = storagePrunedFolders.filter { $0 != id && !$0.hasPrefix(id + "/") }
      storagePath = id
      finishScan(message: "Mapped \(name) in \(scan.coverage.scannedItems.formatted()) items")
    }
  }

  func storageRemovalAllowed(_ node: StorageNode) -> Bool {
    node.isActionable && safetyPolicy.reviewedFileDecision(for: node.url).allowed
      && !FileSystem.containsIgnoredDescendant(node.url, ignoredPaths: ignoredPaths)
  }

  func toggleStorageSelection(_ node: StorageNode) {
    guard storageRemovalAllowed(node) else {
      statusMessage = "This location can be inspected. Generic removal is limited to eligible items in your home folder."; return
    }
    setFileSelection(node.url, selected: !selectedStoragePaths.contains(node.id))
  }

  func reviewStorageSelection() {
    let items = queuedStorageNodes.map(PlanItem.storage)
    let plan = OperationPlanner.plan(title: "Remove from Storage", items: items, ignoredPaths: ignoredPaths)
    guard !isWorking, !isScanning, !plan.isEmpty || !plan.excluded.isEmpty else { return }
    pendingPlan = plan
  }

  func pruneStorage(_ movedPaths: Set<String>) {
    guard let scan = storageScan, !movedPaths.isEmpty else { return }
    storageScan = StorageScan(
      root: scan.root.removing(movedPaths), coverage: scan.coverage, duration: scan.duration)
    selectedStoragePaths.subtract(movedPaths)
    if let path = storagePath, storageScan?.root.node(at: path) == nil { storagePath = nil }
  }
}

extension PlanItem {
  /// Folders kept in sync with other devices: removing an item here removes it everywhere.
  private static let syncRoots = [
    "Dropbox", "Google Drive", "OneDrive", "Box", "Library/CloudStorage", "Library/Mobile Documents",
  ].map { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent($0).path.lowercased() }

  static func isSynced(_ url: URL) -> Bool {
    let path = url.standardizedFileURL.path.lowercased()
    return syncRoots.contains { path.hasPrefix($0 + "/") }
      || path.contains("/onedrive - ")  // "OneDrive - Company" folders
  }

  static func storage(_ node: StorageNode) -> PlanItem {
    let base = node.kind == .file
      ? "File you chose in Storage."
      : "Folder you chose in Storage (\(node.itemCount.formatted()) items)."
    return PlanItem(
      url: node.url, displayName: node.name, kind: .reviewedFile, expectedBytes: node.allocatedBytes,
      reason: isSynced(node.url)
        ? "Synced folder — moving it to the Trash also removes it from your other devices."
        : base,
      source: "Storage", needsAttention: true, identity: node.identity,
      snapshot: node.kind == .file ? FileSnapshot(size: node.logicalBytes, modified: node.modified) : nil)
  }
}
