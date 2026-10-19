import Foundation
import MacCleanerCore

extension AppViewModel {
  /// Keep unrelated results and user choices; invalidate paths actually changed by organization.
  func reconcileOrganization(_ record: OrganizationRecord) {
    let paths = Set(record.items.filter { [.moved, .undone, .moving, .undoing, .uncertain].contains($0.state) }.flatMap { item -> [String] in
      guard let file = record.inventory.files.first(where: { $0.id == item.id }),
        let folder = record.inventory.folders.first(where: { $0.id == item.proposal.folderID }) else { return [] }
      let destination = folder.id == "root" ? record.inventory.root : record.inventory.root.appendingPathComponent(folder.name)
      return [FileSystem.comparisonPath(record.inventory.root.appendingPathComponent(file.name)),
        FileSystem.comparisonPath(destination.appendingPathComponent(item.proposal.name))]
    })
    guard !paths.isEmpty else { return }
    func changed(_ url: URL) -> Bool { paths.contains(FileSystem.comparisonPath(url)) }
    cleanupTargets.removeAll { changed($0.url) }
    largeFiles.removeAll { changed($0.url) }; selectedLargeFileIDs.formIntersection(largeFiles.map(\.id))
    duplicateGroups.removeAll { $0.files.contains { changed($0.url) } }
    selectedDuplicateIDs.formIntersection(duplicateGroups.flatMap(\.files).map(\.id))
    removePhotos { !$0.isLibraryAsset && changed($0.url) }
    downloadItems.removeAll { changed($0.url) }; selectedDownloadIDs.formIntersection(downloadItems.map(\.id))
    if let scan = storageScan, paths.contains(where: { FileSystem.path(URL(fileURLWithPath: $0), isInsideOrEqual: scan.root.url) }) {
      storageScan = nil; selectedStoragePaths = []
    }
    scanIssues.append(ScanIssue(area: "Organization", path: nil, severity: .info,
      message: "Names or locations changed. Affected findings were invalidated; rescan to include their new locations."))
    invalidateAIReview(); refreshRecommendations()
  }
}

extension AppViewModel {
  enum OrganizationAccessError: LocalizedError {
    case busy, exclusions, recovery, activation
    var errorDescription: String? {
      switch self {
      case .busy: return "Wait for the current operation to finish."
      case .exclusions: return "Saved exclusions must be available before organizing files."
      case .recovery: return "MacMint is still checking recovery records from the last session. Try again in a moment."
      case .activation: return "Activate your plan before applying these changes. Your preview is kept."
      }
    }
  }

  func applyOrganization(_ inventory: OrganizationInventory, proposals: [OrganizationProposal]) async throws -> OrganizationRecord {
    guard !isWorking, !isScanning else { throw OrganizationAccessError.busy }
    guard exclusionsReady else { throw OrganizationAccessError.exclusions }
    guard recoveryReady else { throw OrganizationAccessError.recovery }
    guard authorizeRemoval() else { throw OrganizationAccessError.activation }
    isWorking = true; operationTitle = "Organization"
    defer { isWorking = false; operationTitle = nil }
    do {
      let record = try await organizationStore.apply(inventory, proposals: proposals, ignoredPaths: ignoredPaths)
      reconcileOrganization(record)
      return record
    } catch {
      if let history = try? await organizationStore.historyReport(), let record = history.records.first(where: { $0.id == inventory.id }) {
        reconcileOrganization(record)
      }
      throw error
    }
  }

  func undoOrganization(_ id: UUID) async throws -> OrganizationRecord {
    // Local recovery remains available after sign-out or expiry, and with unreadable exclusions.
    guard !isWorking, !isScanning else { throw OrganizationAccessError.busy }
    isWorking = true; operationTitle = "Undo organization"
    defer { isWorking = false; operationTitle = nil }
    do {
      let record = try await organizationStore.undo(recordID: id)
      reconcileOrganization(record)
      return record
    } catch {
      if let history = try? await organizationStore.historyReport(), let record = history.records.first(where: { $0.id == id }) {
        reconcileOrganization(record)
      }
      throw error
    }
  }
}
