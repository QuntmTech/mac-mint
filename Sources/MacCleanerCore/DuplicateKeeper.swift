import Foundation

/// Which copy to keep when auto-selecting duplicates for review.
public enum DuplicateKeeperRule: String, CaseIterable, Identifiable, Sendable {
  case newest = "Keep the newest"
  case oldest = "Keep the oldest"
  case shortestPath = "Keep the shortest path"
  case preferredFolder = "Keep copies in my preferred folders"

  public var id: String { rawValue }
}

public enum DuplicateKeeper {
  /// The copy that stays under `rule`. Preferred folders are tried in order; when none match,
  /// the shortest path wins (usually the "original" location).
  public static func keeper(
    in group: DuplicateGroup, rule: DuplicateKeeperRule, preferredFolders: [URL] = []
  ) -> LargeFile? {
    let files = group.files
    guard !files.isEmpty else { return nil }
    let byPath: (LargeFile, LargeFile) -> Bool = { lhs, rhs in
      let l = lhs.url.standardizedFileURL.path
      let r = rhs.url.standardizedFileURL.path
      return l.count == r.count ? l < r : l.count < r.count
    }
    switch rule {
    case .newest:
      // Ties go to the shorter path.
      return files.sorted(by: byPath).max {
        ($0.modifiedAt ?? .distantPast) < ($1.modifiedAt ?? .distantPast)
      }
    case .oldest:
      return files.sorted(by: byPath).min {
        ($0.modifiedAt ?? .distantFuture) < ($1.modifiedAt ?? .distantFuture)
      }
    case .shortestPath:
      return files.min(by: byPath)
    case .preferredFolder:
      for folder in preferredFolders {
        if let match = files.filter({ FileSystem.path($0.url, isInsideOrEqual: folder) }).min(by: byPath) {
          return match
        }
      }
      return files.min(by: byPath)
    }
  }

  /// Copies to select for review: everything except the keeper and its hard links
  /// (removing a hard link of the keeper frees nothing).
  public static func copiesToSelect(
    in groups: [DuplicateGroup], rule: DuplicateKeeperRule, preferredFolders: [URL] = []
  ) -> Set<UUID> {
    var selected: Set<UUID> = []
    for group in groups {
      guard let keeper = keeper(in: group, rule: rule, preferredFolders: preferredFolders) else { continue }
      for file in group.files where file.id != keeper.id {
        if let identity = file.identity, identity == keeper.identity { continue }
        selected.insert(file.id)
      }
    }
    return selected
  }
}
