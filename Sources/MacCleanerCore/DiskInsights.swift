import Foundation

/// Read-only facts about the startup disk. Nothing here is ever "cleaned": macOS manages
/// purgeable space and local snapshots itself.
public struct DiskInsights: Hashable, Sendable {
  public enum Health: String, Hashable, Sendable {
    case verified = "Verified"
    case failing = "Failing"
    case notSupported = "Not reported"
  }

  public var fileSystem: String?
  public var health: Health?
  /// Space macOS can reclaim on its own (iCloud-optimized files, caches, snapshots).
  public var purgeableBytes: Int64?
  public var localSnapshots: [Date]
  public var snapshotsReadable: Bool

  public init(
    fileSystem: String? = nil, health: Health? = nil, purgeableBytes: Int64? = nil,
    localSnapshots: [Date] = [], snapshotsReadable: Bool = false
  ) {
    self.fileSystem = fileSystem
    self.health = health
    self.purgeableBytes = purgeableBytes
    self.localSnapshots = localSnapshots
    self.snapshotsReadable = snapshotsReadable
  }

  /// Parses `tmutil listlocalsnapshots /` output
  /// ("com.apple.TimeMachine.2026-10-15-120000.local").
  public static func snapshotDates(fromTmutil output: String) -> [Date] {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyy-MM-dd-HHmmss"
    return output.split(whereSeparator: \.isNewline).compactMap { line in
      guard let range = line.range(of: #"\d{4}-\d{2}-\d{2}-\d{6}"#, options: .regularExpression),
        line.contains("TimeMachine") || line.contains("com.apple")
      else { return nil }
      return formatter.date(from: String(line[range]))
    }.sorted()
  }

  /// Parses `diskutil info -plist /`.
  public static func volumeInfo(fromDiskutilPlist data: Data) -> (fileSystem: String?, health: Health?) {
    guard let plist = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any]
    else { return (nil, nil) }
    let fs = (plist["FilesystemName"] as? String) ?? (plist["FilesystemType"] as? String)?.uppercased()
    let health: Health?
    switch (plist["SMARTStatus"] as? String)?.lowercased() {
    case "verified": health = .verified
    case "failing": health = .failing
    case .some: health = .notSupported
    case .none: health = nil
    }
    return (fs, health)
  }

  /// Important-usage capacity counts space macOS will purge on demand; the plain available
  /// capacity doesn't. The difference is what macOS can free by itself.
  public static func purgeable(important: Int64?, available: Int64?) -> Int64? {
    guard let important, let available else { return nil }
    return max(0, important - available)
  }
}
