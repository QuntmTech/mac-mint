import Foundation
import MacCleanerCore

extension AppViewModel {
  /// A file has one selection across inventories. Source-specific IDs remain stable, while
  /// canonical paths join discoveries from different modules (including parent aliases).
  func setFileSelection(_ url: URL, selected: Bool, userChoice: Bool = true) {
    let path = FileSystem.comparisonPath(url)
    let literal = url.standardizedFileURL.path
    let name = url.lastPathComponent.lowercased()
    func matches(_ candidate: URL) -> Bool {
      if candidate.standardizedFileURL.path == literal { return true }
      guard candidate.lastPathComponent.lowercased() == name else { return false }
      return FileSystem.comparisonPath(candidate) == path
    }
    var choose = selected && (userChoice || !keptQueuePaths.contains(path))
    if choose {
      for group in duplicateGroups where group.files.contains(where: { matches($0.url) }) {
        let keeper = group.files.first { !selectedDuplicateIDs.contains($0.id) } ?? group.files.first
        if let keeper, matches(keeper.url) {
          choose = false; statusMessage = "Keep another duplicate copy before selecting this one"
        }
      }
      if let group = photoScan?.similarGroups.first(where: { $0.photos.contains { !$0.isLibraryAsset && matches($0.url) } }),
        matches(keeper(of: group).url) {
        choose = false; statusMessage = "Keep another photo before selecting this one"
      }
    }
    if userChoice {
      if choose { keptQueuePaths.remove(path) } else { keptQueuePaths.insert(path) }
    }
    for index in cleanupTargets.indices where matches(cleanupTargets[index].url) {
      cleanupTargets[index].isSelected = choose && cleanupTargets[index].risk != .restricted
    }
    for file in largeFiles where matches(file.url) {
      if choose { selectedLargeFileIDs.insert(file.id) } else { selectedLargeFileIDs.remove(file.id) }
    }
    for file in duplicateGroups.flatMap(\.files) where matches(file.url) {
      if choose { selectedDuplicateIDs.insert(file.id) } else { selectedDuplicateIDs.remove(file.id) }
    }
    for item in devItems where item.url.map(matches) == true && item.canTrash {
      if choose { selectedDevIDs.insert(item.id) } else { selectedDevIDs.remove(item.id) }
    }
    for photo in allScannedPhotos where !photo.isLibraryAsset && matches(photo.url) {
      if choose { selectedPhotoIDs.insert(photo.id) } else { selectedPhotoIDs.remove(photo.id) }
    }
    for item in orphans where matches(item.url) {
      if choose { selectedOrphanIDs.insert(item.id) } else { selectedOrphanIDs.remove(item.id) }
    }
    for item in downloadItems where matches(item.url) {
      if choose { selectedDownloadIDs.insert(item.id) } else { selectedDownloadIDs.remove(item.id) }
    }
    if !choose {
      selectedStoragePaths = Set(selectedStoragePaths.filter { !matches(URL(fileURLWithPath: $0)) })
    } else if let node = storageScan?.root.node(at: url.standardizedFileURL.path), storageRemovalAllowed(node) {
      selectedStoragePaths.insert(node.id)
    }
  }

  func synchronizeQueueSelections() {
    let urls = sourceSelections.map(\.url)
    for url in urls { setFileSelection(url, selected: true, userChoice: false) }
  }

  func keepQueuedFiles(_ urls: [URL]) {
    for url in urls { setFileSelection(url, selected: false) }
  }
}
