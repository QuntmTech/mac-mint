import AppKit
import Foundation
import MacCleanerCore

extension AppViewModel {
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
    beginScan(title: "Storage", message: "Mapping \(root.lastPathComponent)…")
    storageScannedCount = 0
    let scanner = StorageTreeScanner()

    currentTask = Task { [weak self] in
      guard let self else { return }
      let scan = await scanner.scan(root) { count, _ in
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
      storagePath = nil
      selectedStoragePaths = []
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

  func openStorageNode(_ node: StorageNode) {
    guard node.kind == .folder, !node.children.isEmpty else { return }
    storagePath = node.id
  }

  func toggleStorageSelection(_ node: StorageNode) {
    guard node.isActionable else { return }
    if selectedStoragePaths.contains(node.id) {
      selectedStoragePaths.remove(node.id)
    } else {
      selectedStoragePaths.insert(node.id)
    }
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
