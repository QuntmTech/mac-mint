import Foundation
import MacCleanerCore

extension AppViewModel {
  /// A file has one selection across inventories. Source-specific IDs remain stable, while
  /// canonical paths join discoveries from different modules (including parent aliases).
  func setFileSelection(_ url: URL, selected: Bool, userChoice: Bool = true) {
    setFileSelections([url], selected: selected, userChoice: userChoice)
  }

  /// A bulk action walks each inventory once and publishes each selection set once.
  func setFileSelections(_ urls: [URL], selected: Bool, userChoice: Bool = true) {
    guard !urls.isEmpty else { return }
    let literals = Set(urls.map { $0.standardizedFileURL.path })
    let names = Set(urls.map { $0.lastPathComponent.lowercased() })
    let paths = Set(urls.map(FileSystem.comparisonPath))
    func matches(_ candidate: URL) -> Bool {
      if literals.contains(candidate.standardizedFileURL.path) { return true }
      return names.contains(candidate.lastPathComponent.lowercased()) && paths.contains(FileSystem.comparisonPath(candidate))
    }
    var blocked: Set<String> = []
    if selected {
      for group in duplicateGroups {
        let keeper = group.files.first { !selectedDuplicateIDs.contains($0.id) } ?? group.files.first
        if let keeper, matches(keeper.url) { blocked.insert(FileSystem.comparisonPath(keeper.url)) }
      }
      for group in photoScan?.similarGroups ?? [] {
        let keeper = keeper(of: group)
        if !keeper.isLibraryAsset, matches(keeper.url) { blocked.insert(FileSystem.comparisonPath(keeper.url)) }
      }
      if !blocked.isEmpty { statusMessage = "Protected keepers were left unselected" }
    }
    let chosen = selected ? paths.subtracting(blocked).subtracting(userChoice ? [] : keptQueuePaths) : []
    func chooses(_ candidate: URL) -> Bool { chosen.contains(FileSystem.comparisonPath(candidate)) }
    if userChoice { keptQueuePaths.formUnion(paths.subtracting(chosen)); keptQueuePaths.subtract(chosen) }
    var cleanup = cleanupTargets
    for index in cleanup.indices where matches(cleanup[index].url) {
      cleanup[index].isSelected = chooses(cleanup[index].url) && cleanup[index].risk != .restricted
    }
    if cleanup != cleanupTargets { cleanupTargets = cleanup }
    func update<ID: Hashable>(_ values: [(ID, URL)], _ current: Set<ID>) -> Set<ID> {
      var next = current
      for (id, url) in values where matches(url) {
        if chooses(url) { next.insert(id) } else { next.remove(id) }
      }
      return next
    }
    selectedLargeFileIDs = update(largeFiles.map { ($0.id, $0.url) }, selectedLargeFileIDs)
    selectedDuplicateIDs = update(duplicateGroups.flatMap(\.files).map { ($0.id, $0.url) }, selectedDuplicateIDs)
    selectedDevIDs = update(devItems.filter(\.canTrash).compactMap { item in item.url.map { (item.id, $0) } }, selectedDevIDs)
    selectedPhotoIDs = update((photoScan?.photos ?? []).filter { !$0.isLibraryAsset }.map { ($0.id, $0.url) }, selectedPhotoIDs)
    selectedOrphanIDs = update(orphans.map { ($0.id, $0.url) }, selectedOrphanIDs)
    selectedDownloadIDs = update(downloadItems.map { ($0.id, $0.url) }, selectedDownloadIDs)
    selectedStoragePaths = Set(selectedStoragePaths.filter {
      let url = URL(fileURLWithPath: $0); return !matches(url) || chooses(url)
    })
    if selected {
      for url in urls where chooses(url) {
        if let node = storageScan?.root.node(at: url.standardizedFileURL.path), storageRemovalAllowed(node) { selectedStoragePaths.insert(node.id) }
      }
    }
  }

  func synchronizeQueueSelections() {
    let urls = sourceSelections.map(\.url)
    setFileSelections(urls, selected: true, userChoice: false)
  }

  func keepQueuedFiles(_ urls: [URL]) {
    setFileSelections(urls, selected: false)
  }
}
