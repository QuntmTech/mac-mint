import Foundation

public struct DuplicateRemovalPlan: Sendable {
  public let approved: [LargeFile]
  public let skipped: [OperationFailure]
  public let wasCancelled: Bool

  public var approvedBytes: Int64 { approved.reduce(0) { $0 + $1.size } }
}

/// Re-checks duplicate selections against the live filesystem immediately before removal.
/// Scan results can be stale: a "keeper" may have been moved or edited, or a selected copy may
/// have changed. Every group must keep at least one verified copy; changed files are skipped.
public actor DuplicateRemovalVerifier {
  private let safetyPolicy: SafetyPolicy
  private let hash: @Sendable (URL) throws -> String

  public init(
    safetyPolicy: SafetyPolicy = SafetyPolicy(),
    hash: @escaping @Sendable (URL) throws -> String = { try SHA256.hexDigest(file: $0) }
  ) {
    self.safetyPolicy = safetyPolicy
    self.hash = hash
  }

  public func plan(
    groups: [DuplicateGroup], selectedIDs: Set<UUID>, ignoredPaths: Set<String> = []
  ) -> DuplicateRemovalPlan {
    var approved: [LargeFile] = []
    var skipped: [OperationFailure] = []

    for group in groups {
      if Task.isCancelled {
        return DuplicateRemovalPlan(approved: approved, skipped: skipped, wasCancelled: true)
      }
      let selected = group.files.filter { selectedIDs.contains($0.id) }
      guard !selected.isEmpty else { continue }

      let keepers = group.files.filter { !selectedIDs.contains($0.id) }
      guard !keepers.isEmpty else {
        skipped.append(
          contentsOf: selected.map {
            OperationFailure(url: $0.url, message: "Every copy was selected; one must remain.")
          })
        continue
      }

      guard let keeper = keepers.first(where: { matches($0, group: group) }) else {
        skipped.append(
          contentsOf: selected.map {
            OperationFailure(
              url: $0.url,
              message: "No unchanged copy would remain in this group. Rescan before removing.")
          })
        continue
      }

      for file in selected {
        if FileSystem.isIgnored(file.url, ignoredPaths: ignoredPaths) {
          skipped.append(OperationFailure(url: file.url, message: "Item is on your exclusion list."))
          continue
        }
        let decision = safetyPolicy.reviewedFileDecision(for: file.url)
        guard decision.allowed else {
          skipped.append(OperationFailure(url: file.url, message: decision.reason))
          continue
        }
        // A hard link to the keeper is the same data; no content check needed.
        let liveIdentity = FileSystem.fileIdentity(at: file.url)
        if let liveIdentity, liveIdentity == FileSystem.fileIdentity(at: keeper.url) {
          approved.append(file)
          continue
        }
        if matches(file, group: group) {
          approved.append(file)
        } else {
          skipped.append(
            OperationFailure(
              url: file.url, message: "File changed or moved since the scan. Rescan to review it."))
        }
      }
    }
    return DuplicateRemovalPlan(approved: approved, skipped: skipped, wasCancelled: false)
  }

  private func matches(_ file: LargeFile, group: DuplicateGroup) -> Bool {
    guard let meta = FileSystem.logicalFileMetadata(at: file.url), meta.size == file.size else {
      return false
    }
    return (try? hash(file.url)) == group.fingerprint
  }
}
