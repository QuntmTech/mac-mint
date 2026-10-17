import AppKit
import Foundation
import MacCleanerCore

enum PhotoSource: Equatable {
  case library
  case folder(URL)

  var title: String {
    switch self {
    case .library: return "Photos Library"
    case .folder(let url): return url.lastPathComponent
    }
  }
}

enum PhotoTab: String, CaseIterable, Identifiable {
  case deck = "Review deck"
  case similar = "Similar"
  case blurry = "Blurry"
  case screenshots = "Screenshots"
  var id: String { rawValue }
}

/// In-memory browsing state belongs to the scan, rather than a disposable view.
/// New results discard the trail; navigation and cancelled scans preserve it.
struct PhotoReviewSession {
  struct Choice {
    let index: Int
    let photoID: String
    let wasSelected: Bool
  }
  var cursor = 0
  var choices: [Choice] = []
}

extension AppViewModel {
  // MARK: Derived state

  var allScannedPhotos: [PhotoFingerprint] { photoScan?.photos ?? [] }

  /// The photo kept in a group: the user's choice if they picked one, otherwise the suggestion.
  func keeper(of group: SimilarPhotoGroup) -> PhotoFingerprint {
    if let chosen = photoKeeperOverrides[group.id], let photo = group.photos.first(where: { $0.id == chosen }) {
      return photo
    }
    return group.keeper
  }

  func group(containing photo: PhotoFingerprint) -> SimilarPhotoGroup? {
    photoScan?.group(containing: photo.id)
  }

  var selectedPhotos: [PhotoFingerprint] { photoScan?.selectedPhotos(ids: selectedPhotoIDs) ?? [] }

  var selectedPhotoBytes: Int64 { selectedPhotos.reduce(0) { $0 + $1.bytes } }

  /// Folder-based selections as Trash plan items (library assets never take this path).
  var queuedPhotoFileItems: (items: [PlanItem], libraryCount: Int) {
    var items: [PlanItem] = []
    var library = 0
    for photo in selectedPhotos {
      if photo.isLibraryAsset {
        library += 1
        continue
      }
      let group = group(containing: photo)
      let kept = group.map(keeper(of:))
      let reason: String
      if let kept {
        reason = "Similar to \(kept.url.lastPathComponent), which is kept."
      } else if photo.isScreenshot {
        reason = "Screenshot you chose to remove."
      } else {
        reason = "Photo you chose to remove."
      }
      if let item = PlanItem.photo(photo, keeper: kept, reason: reason) { items.append(item) }
    }
    return (items, library)
  }

  // MARK: Scanning

  func choosePhotoFolder() {
    guard let url = chooseFolder(prompt: "Choose a folder of photos to check") else { return }
    photoSource = .folder(url)
    scanPhotos()
  }

  func scanPhotos() {
    guard !isScanning, !isWorking else { return }
    let source = photoSource
    guard beginScan(title: "Photos", message: "Looking for similar, blurry, and screenshot photos…") else { return }
    photoProgress = (0, 0)

    currentTask = Task { [weak self] in
      guard let self else { return }
      let report: (@Sendable (Int, Int) -> Void) = { done, total in
        Task { @MainActor [weak self] in
          guard let self, self.isScanning else { return }
          self.photoProgress = (done, total)
          self.statusMessage = "Analysing photos… \(done.formatted()) of \(total.formatted())"
        }
      }
      let result: PhotoScanResult
      switch source {
      case .library:
        if !PhotoLibraryService.isAuthorized, !(await PhotoLibraryService.requestAccess()) {
          photoProgress = nil
          finishScan(message: "MacMint needs access to Photos — allow it in System Settings ▸ Privacy & Security ▸ Photos")
          return
        }
        let library = await PhotoLibraryService.fingerprints(progress: report)
        let issues = library.total > library.photos.count ? [ScanIssue(area: "Photos", path: nil, severity: .info,
          message: "\(library.total - library.photos.count) library assets could not be analyzed from local thumbnails. Cloud-only, unreadable or unsupported items may be omitted. No cloud downloads were requested.")] : []
        let analysis = Task.detached(priority: .userInitiated) {
          PhotoScanResult(photos: library.photos, similarGroups: PhotoAnalysis.group(library.photos),
            blurry: PhotoAnalysis.blurry(library.photos), screenshots: [], skippedLibraries: [], issues: issues,
            wasCancelled: Task.isCancelled)
        }
        result = await withTaskCancellationHandler(operation: { await analysis.value }, onCancel: { analysis.cancel() })
      case .folder(let url):
        result = await PhotoScanner().scan([url], ignoredPaths: ignoredPaths, progress: report)
      }
      guard !Task.isCancelled else {
        photoProgress = nil
        finishCancelledOperation()
        return
      }
      photoScan = result
      selectedPhotoIDs = []
      photoKeeperOverrides = [:]
      photoProgress = nil
      scanIssues = result.issues
      let similar = result.similarGroups.reduce(0) { $0 + $1.others.count }
      finishScan(
        message:
          "Checked \(result.photos.count.formatted()) photos — \(similar) similar, \(result.blurry.count) blurry, \(result.screenshots.count) screenshots")
    }
  }

  // MARK: Selection

  func decidePhotoReview(removing: Bool) -> String? {
    guard !isWorking, !isScanning, !isPreparingPlan, let scan = photoScan,
      scan.photos.indices.contains(photoReviewSession.cursor) else { return nil }
    let photo = scan.photos[photoReviewSession.cursor]
    if removing, let group = group(containing: photo), keeper(of: group).id == photo.id {
      return "Choose a different keeper in Compare before queuing this photo."
    }
    let before = selectedPhotoIDs.contains(photo.id)
    if before != removing { togglePhoto(photo) }
    guard selectedPhotoIDs.contains(photo.id) == removing else { return statusMessage }
    photoReviewSession.choices.append(.init(index: photoReviewSession.cursor, photoID: photo.id, wasSelected: before))
    photoReviewSession.cursor += 1
    return nil
  }

  func undoPhotoReview() -> String? {
    guard !isWorking, !isScanning, !isPreparingPlan, let scan = photoScan,
      let previous = photoReviewSession.choices.last else { return nil }
    guard scan.photos.indices.contains(previous.index), scan.photos[previous.index].id == previous.photoID else {
      photoReviewSession = PhotoReviewSession()
      return "The photo results changed. Review the current scan again."
    }
    let photo = scan.photos[previous.index]
    if selectedPhotoIDs.contains(photo.id) != previous.wasSelected { togglePhoto(photo) }
    guard selectedPhotoIDs.contains(photo.id) == previous.wasSelected else { return statusMessage }
    photoReviewSession.choices.removeLast()
    photoReviewSession.cursor = previous.index
    return nil
  }

  func restartPhotoReview() {
    guard !isWorking, !isScanning, !isPreparingPlan else { return }
    photoReviewSession = PhotoReviewSession()
  }

  func togglePhoto(_ photo: PhotoFingerprint) {
    if !photo.isLibraryAsset { setFileSelection(photo.url, selected: !selectedPhotoIDs.contains(photo.id)); return }
    if selectedPhotoIDs.contains(photo.id) {
      selectedPhotoIDs.remove(photo.id)
      return
    }
    // The kept shot of a group is never selectable; choose a different keeper first.
    if let group = group(containing: photo), keeper(of: group).id == photo.id {
      statusMessage = "Keep a different photo in this group first"
      return
    }
    selectedPhotoIDs.insert(photo.id)
  }

  func keepInstead(_ photo: PhotoFingerprint) {
    guard let group = group(containing: photo) else { return }
    photoKeeperOverrides[group.id] = photo.id
    if photo.isLibraryAsset { selectedPhotoIDs.remove(photo.id) } else { setFileSelection(photo.url, selected: false) }
  }

  /// Selects every shot except the kept one — only when the user asks.
  func selectAllButKeeper(in group: SimilarPhotoGroup) {
    let kept = keeper(of: group).id
    for photo in group.photos where photo.id != kept {
      if photo.isLibraryAsset { selectedPhotoIDs.insert(photo.id) } else { setFileSelection(photo.url, selected: true) }
    }
  }

  // MARK: Removing

  func reviewPhotos() {
    let files = queuedPhotoFileItems
    if files.items.isEmpty, files.libraryCount > 0 {
      Task { await deleteSelectedLibraryPhotos() }
      return
    }
    guard !isWorking, !isScanning, !files.items.isEmpty else { return }
    pendingPlan = OperationPlanner.plan(
      title: "Remove photos", items: files.items, ignoredPaths: ignoredPaths)
  }

  /// Library photos go through Photos itself (system confirmation, Recently Deleted for 30 days).
  func deleteSelectedLibraryPhotos() async {
    let assets = selectedPhotos.filter(\.isLibraryAsset)
    guard !assets.isEmpty, !isWorking, requirePaidAccess() else { return }
    isWorking = true
    operationTitle = "Photos"
    statusMessage = "Waiting for your confirmation in Photos…"
    defer {
      isWorking = false
      operationTitle = nil
    }
    do {
      let selectedIDs = Set(assets.map(\.id))
      let keepers = (photoScan?.similarGroups ?? []).filter { group in
        group.photos.contains { selectedIDs.contains($0.id) }
      }.compactMap { keeper(of: $0).assetID }
      let deleted = try await PhotoLibraryService.delete(assetIDs: assets.compactMap(\.assetID), protecting: keepers)
      guard deleted else {
        statusMessage = "Nothing was deleted"
        return
      }
      let bytes = assets.reduce(0) { $0 + $1.bytes }
      await record(
        HistoryEntry(
          action: "Photos: \(assets.count) moved to Recently Deleted", paths: [], bytes: bytes,
          notes: "Restore through Photos ▸ Recently Deleted while available. Deletion can sync to other devices. Local byte savings are unavailable from Photos.", recoveryKind: .photos))
      let ids = Set(assets.map(\.id))
      removePhotos { ids.contains($0.id) }
      statusMessage = "\(assets.count) photo\(assets.count == 1 ? "" : "s") moved to Photos ▸ Recently Deleted"
    } catch {
      statusMessage = "Photos couldn't delete them: \(error.localizedDescription)"
    }
  }

  /// Drops photos from the current results (after they were moved or deleted).
  func removePhotos(where shouldRemove: (PhotoFingerprint) -> Bool) {
    guard let scan = photoScan else { return }
    let photos = scan.photos.filter { !shouldRemove($0) }
    guard photos.count != scan.photos.count else { return }
    let remaining = Set(photos.map(\.id))
    let groups = scan.similarGroups.compactMap { group -> SimilarPhotoGroup? in
      let members = group.photos.filter { remaining.contains($0.id) }
      guard members.count > 1 else { return nil }
      let keptID = group.keeper.id
      let index = members.firstIndex { $0.id == keptID } ?? 0
      return SimilarPhotoGroup(id: group.id, photos: members, keeperIndex: index)
    }
    photoScan = PhotoScanResult(
      photos: photos, similarGroups: groups,
      blurry: scan.blurry.filter { remaining.contains($0.id) },
      screenshots: scan.screenshots.filter { remaining.contains($0.id) },
      skippedLibraries: scan.skippedLibraries, issues: scan.issues, wasCancelled: scan.wasCancelled)
    selectedPhotoIDs.formIntersection(remaining)
  }

  // MARK: Trash

  func refreshTrashStatus() {
    Task { trashStatus = await TrashBinService.status() }
  }

  func emptyTrash() {
    NSWorkspace.shared.open(TrashBinService.trashURL)
    statusMessage = "Review Trash in Finder. Emptying it permanently erases items and prevents Restore."
  }

  // MARK: Removed apps

  var queuedOrphans: [OrphanedItem] { orphans.filter { selectedOrphanIDs.contains($0.id) } }

  func scanOrphans() {
    guard !isScanning, !isWorking else { return }
    guard beginScan(title: "Removed Apps", message: "Looking for data left by apps you've removed…") else { return }
    let running = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
    let scanner = OrphanScanner()
    currentTask = Task { [weak self] in
      guard let self else { return }
      let report = await scanner.scan(knownBundleIDs: running, ignoredPaths: ignoredPaths)
      guard !Task.isCancelled else {
        finishCancelledOperation()
        return
      }
      orphans = report.value
      selectedOrphanIDs = []
      orphansScanned = true
      scanIssues = report.issues
      finishScan(
        message:
          "Found \(ByteFormatter.string(report.value.reduce(0) { $0 + $1.bytes })) left by \(Set(report.value.map(\.bundleID)).count) removed app(s)")
    }
  }

  func reviewOrphans() {
    guard !isWorking, !isScanning, !queuedOrphans.isEmpty else { return }
    pendingPlan = OperationPlanner.plan(
      title: "Remove leftover app data", items: queuedOrphans.map(PlanItem.orphan),
      ignoredPaths: ignoredPaths)
  }
}
