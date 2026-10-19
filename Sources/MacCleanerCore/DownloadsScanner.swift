import Foundation

public enum DownloadKind: String, CaseIterable, Codable, Hashable, Sendable {
  case installer = "Installers"
  case archive = "Archives"
  case video = "Videos"
  case audio = "Audio"
  case image = "Images"
  case document = "Documents"
  case folder = "Folders"
  case other = "Other"

  static func of(_ url: URL, isDirectory: Bool) -> DownloadKind {
    if isDirectory { return url.pathExtension.lowercased() == "app" ? .installer : .folder }
    switch url.pathExtension.lowercased() {
    case "dmg", "pkg", "mpkg", "iso", "xip", "app": return .installer
    case "zip", "tar", "gz", "tgz", "bz2", "xz", "rar", "7z": return .archive
    case "mov", "mp4", "m4v", "mkv", "avi", "webm": return .video
    case "mp3", "m4a", "wav", "aiff", "flac", "aac": return .audio
    case "jpg", "jpeg", "png", "heic", "gif", "tiff", "webp", "psd", "raw": return .image
    case "pdf", "doc", "docx", "xls", "xlsx", "ppt", "pptx", "key", "pages", "numbers", "txt", "csv",
      "rtf", "epub":
      return .document
    default: return .other
    }
  }
}

/// One top-level item in ~/Downloads with the evidence for why it may no longer be needed.
public struct DownloadItem: Identifiable, Hashable, Sendable {
  public let id: String
  public let url: URL
  public let kind: DownloadKind
  public let bytes: Int64
  public let usage: UsageEvidence
  public let modified: Date?
  public let logicalSize: Int64?
  public let identity: String?
  public let idleDays: Int

  public init(
    url: URL, kind: DownloadKind, bytes: Int64, usage: UsageEvidence, modified: Date?,
    logicalSize: Int64?, identity: String?, idleDays: Int
  ) {
    self.id = url.standardizedFileURL.path
    self.url = url
    self.kind = kind
    self.bytes = bytes
    self.usage = usage
    self.modified = modified
    self.logicalSize = logicalSize
    self.identity = identity
    self.idleDays = idleDays
  }

  /// Plain-English evidence, e.g. "Downloaded 8 months ago from github.com with no recorded opens".
  public var evidence: String {
    let age = RelativeAge.describe(days: idleDays)
    let from = usage.source.map { " from \($0)" } ?? ""
    if usage.neverOpened {
      return "Downloaded \(age) ago\(from) with no recorded opens"
    }
    if usage.lastUsed != nil {
      return "Last opened \(age) ago\(from.isEmpty ? "" : " · came\(from)")"
    }
    return "Not changed in \(age)\(from.isEmpty ? "" : " · came\(from)")"
  }
}

/// Finds large, idle items at the top level of ~/Downloads. Review-only: everything here is
/// personal data, so nothing is ever preselected and each item explains its evidence.
public actor DownloadsScanner {
  private let fileManager: FileManager
  private let downloads: URL
  private let usage: any UsageProviding
  private let now: @Sendable () -> Date

  public init(
    fileManager: FileManager = .default, downloadsDirectory: URL? = nil,
    usage: any UsageProviding = SpotlightUsage(), now: @escaping @Sendable () -> Date = { Date() }
  ) {
    self.fileManager = fileManager
    self.downloads =
      downloadsDirectory ?? fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")
    self.usage = usage
    self.now = now
  }

  /// Items idle for at least `minimumIdleDays` and at least `minimumBytes`, largest first.
  /// When Spotlight has no evidence, the modification date is used — but only as "not changed",
  /// never as proof that it was unused.
  public func scan(
    minimumIdleDays: Int = 90, minimumBytes: Int64 = 5 * 1_048_576, ignoredPaths: Set<String> = []
  ) async -> ScanReport<[DownloadItem]> {
    let started = Date()
    guard !FileSystem.isIgnored(downloads, ignoredPaths: ignoredPaths) else {
      return ScanReport(value: [], duration: Date().timeIntervalSince(started))
    }
    let keys: [URLResourceKey] = [
      .isDirectoryKey, .isSymbolicLinkKey, .contentModificationDateKey, .fileSizeKey,
    ]
    let entries: [URL]
    do {
      entries = try fileManager.contentsOfDirectory(
        at: downloads, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])
    } catch {
      return ScanReport(
        value: [],
        issues: [ScanIssue(area: "Downloads", path: downloads.path, message: error.localizedDescription)],
        duration: Date().timeIntervalSince(started))
    }

    let today = now()
    var items: [DownloadItem] = []
    for entry in entries {
      if Task.isCancelled { break }
      // This inventory acts on whole top-level items. Do not traverse a folder
      // containing excluded descendants or offer an ancestor that cannot be removed.
      if FileSystem.isIgnored(entry, ignoredPaths: ignoredPaths) ||
        FileSystem.containsIgnoredDescendant(entry, ignoredPaths: ignoredPaths) { continue }
      guard let values = try? FileSystem.fresh(entry).resourceValues(forKeys: Set(keys)),
        values.isSymbolicLink != true
      else { continue }
      // Partial downloads are still being written by the browser.
      let ext = entry.pathExtension.lowercased()
      if ["crdownload", "download", "part", "partial"].contains(ext) { continue }

      let evidence = usage.evidence(for: entry)
      let idle: Int
      if let days = evidence.idleDays(now: today) {
        idle = days
      } else if let modified = values.contentModificationDate {
        idle = max(0, Int(today.timeIntervalSince(modified) / 86_400))
      } else {
        continue
      }
      guard idle >= minimumIdleDays else { continue }

      let bytes = FileSystem.itemSize(at: entry, fileManager: fileManager)
      guard bytes >= minimumBytes else { continue }
      let isDirectory = values.isDirectory == true
      items.append(
        DownloadItem(
          url: entry, kind: DownloadKind.of(entry, isDirectory: isDirectory), bytes: bytes,
          usage: evidence, modified: values.contentModificationDate,
          logicalSize: isDirectory ? nil : values.fileSize.map(Int64.init),
          identity: FileSystem.fileIdentity(at: entry), idleDays: idle))
    }
    return ScanReport(
      value: items.sorted { $0.bytes > $1.bytes }, duration: Date().timeIntervalSince(started),
      wasCancelled: Task.isCancelled)
  }
}

extension PlanItem {
  /// A Downloads item through the normal review pipeline (personal data: always needs attention).
  public static func download(_ item: DownloadItem) -> PlanItem {
    PlanItem(
      url: item.url, displayName: item.url.lastPathComponent, kind: .reviewedFile,
      expectedBytes: item.bytes, reason: item.evidence + ".", source: "Downloads",
      needsAttention: true, identity: item.identity,
      snapshot: item.kind == .folder ? nil : FileSnapshot(size: item.logicalSize, modified: item.modified))
  }
}
