import Foundation

/// One Smart Care suggestion: what it is, why MacMint thinks so, roughly how much space it
/// would free, and the items a "Review" would put in front of the user. Nothing here acts on
/// its own — Review always goes through the normal plan → review sheet → Trash pipeline.
public struct Recommendation: Identifiable, Hashable, Sendable {
  public enum Confidence: Int, Comparable, Hashable, Sendable {
    /// Rebuilt or re-downloaded automatically.
    case safe = 3
    /// Strong evidence it's unneeded (never opened, app removed), but it's your data.
    case likely = 2
    /// Worth a look; MacMint can't judge it for you.
    case review = 1

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

    var weight: Double {
      switch self {
      case .safe: return 1.0
      case .likely: return 0.6
      case .review: return 0.3
      }
    }

    public var label: String {
      switch self {
      case .safe: return "Safe"
      case .likely: return "Likely unneeded"
      case .review: return "Worth a look"
      }
    }
  }

  public enum Destination: String, Hashable, Sendable {
    case cleaner, developer, downloads, applications, removedApps, photos, duplicates, storage, trash
  }

  public let id: String
  public let symbol: String
  public let title: String
  public let detail: String
  /// Estimated space; actual savings appear after the Trash is emptied.
  public let bytes: Int64
  public let count: Int
  public let confidence: Confidence
  /// What Review opens in the review sheet. Empty when the decision needs its own screen.
  public let items: [PlanItem]
  public let destination: Destination

  public var score: Double { Double(bytes) * confidence.weight }
  public var canReview: Bool { !items.isEmpty }
}

public enum RecommendationEngine {
  public struct Inputs: Sendable {
    public var cleanupTargets: [CleanupTarget] = []
    public var developer: [DevStorageItem] = []
    public var downloads: [DownloadItem] = []
    public var orphans: [OrphanedItem] = []
    public var apps: [AppRecord] = []
    public var screenshots: [PhotoFingerprint] = []
    public var duplicateGroups: [DuplicateGroup] = []
    public var trashBytes: Int64 = 0
    public var growth: [StorageGrowth] = []
    public var now = Date()
    /// Apps not opened for this long are suggested for review.
    public var unusedAppDays = 180

    public init() {}
  }

  static let minimumBytes: Int64 = 20 * 1_048_576

  public static func recommend(_ inputs: Inputs) -> [Recommendation] {
    var claimed: Set<String> = []
    var results: [Recommendation] = []

    /// Each path belongs to one recommendation only (the first, highest-priority rule).
    func take(_ items: [PlanItem]) -> [PlanItem] {
      items.filter { claimed.insert($0.url.standardizedFileURL.path).inserted }
    }
    func add(
      _ id: String, symbol: String, title: String, detail: String, confidence: Recommendation.Confidence,
      items: [PlanItem], destination: Recommendation.Destination, bytes: Int64? = nil, count: Int? = nil
    ) {
      let total = bytes ?? items.reduce(0) { $0 + $1.expectedBytes }
      guard total >= minimumBytes || id == "trash" else { return }
      results.append(
        Recommendation(
          id: id, symbol: symbol, title: title, detail: detail, bytes: total,
          count: count ?? items.count, confidence: confidence, items: items, destination: destination))
    }

    // 1. Caches and logs that rebuild themselves.
    let rebuildCategories: Set<CleanupCategory> = [.userCaches, .userLogs, .browserCaches]
    let caches = inputs.cleanupTargets.filter { $0.risk == .safe && rebuildCategories.contains($0.category) }
    let cacheItems = take(caches.map { PlanItem.cleanup($0) })
    add(
      "caches", symbol: "shippingbox", title: "Caches and logs that rebuild themselves",
      detail: "From \(cacheItems.count) apps and browsers. They're recreated as needed; data for apps that are open is skipped.",
      confidence: .safe, items: cacheItems, destination: .cleaner)

    // 2. Developer build data (idle, rebuildable) + developer cleanup rules.
    let devTrash = inputs.developer.filter(\.isSuggested).compactMap(PlanItem.developer)
    let devCleanup = inputs.cleanupTargets
      .filter { $0.risk == .safe && $0.category == .developerJunk }.map { PlanItem.cleanup($0) }
    let devItems = take(devTrash + devCleanup)
    if !devItems.isEmpty {
      let tools = Dictionary(grouping: inputs.developer.filter(\.isSuggested), by: \.tool)
        .map { ($0.key, $0.value.reduce(Int64(0)) { $0 + $1.bytes }) }
        .sorted { $0.1 > $1.1 }.prefix(3)
        .map { "\($0.0) \(ByteFormatter.string($0.1))" }
      add(
        "developer", symbol: "hammer", title: "Build data you haven't touched recently",
        detail: (tools.isEmpty ? "Developer caches" : tools.joined(separator: " · "))
          + ". Rebuilt automatically the next time you build.",
        confidence: .safe, items: devItems, destination: .developer)
    }

    // 3. Device firmware.
    let firmware = take(inputs.cleanupTargets.filter { $0.category == .deviceFirmware }.map { PlanItem.cleanup($0) })
    add(
      "firmware", symbol: "iphone.and.arrow.forward", title: "iPhone and iPad software updates",
      detail: "Restore images Finder keeps after updating a device. Downloaded again the next time it's needed.",
      confidence: .safe, items: firmware, destination: .cleaner)

    // 4. Downloads never opened.
    let neverOpened = inputs.downloads.filter { $0.usage.neverOpened }
    let neverItems = take(neverOpened.map(PlanItem.download))
    add(
      "downloads-never-opened", symbol: "arrow.down.circle", title: "Downloads you never opened",
      detail: summary(neverOpened.map(\.kind)) + ", downloaded months ago and never opened since.",
      confidence: .likely, items: neverItems, destination: .downloads)

    // 5. Leftovers from deleted apps (only the stronger matches).
    let orphans = inputs.orphans.filter { $0.confidence == .medium }
    let orphanItems = take(orphans.map(PlanItem.orphan))
    add(
      "removed-apps", symbol: "folder.badge.questionmark", title: "Leftovers from apps you've deleted",
      detail: "\(Set(orphans.map(\.bundleID)).count) removed apps left settings and caches behind.",
      confidence: .likely, items: orphanItems, destination: .removedApps)

    // 6. Downloads opened long ago (or with no usage record).
    let stale = inputs.downloads.filter { !$0.usage.neverOpened && $0.idleDays >= 365 }
    let staleItems = take(stale.map(PlanItem.download))
    add(
      "downloads-stale", symbol: "clock.arrow.circlepath", title: "Downloads untouched for over a year",
      detail: summary(stale.map(\.kind)) + " in your Downloads folder.",
      confidence: .review, items: staleItems, destination: .downloads)

    // 7. Old screenshots (folder-based only; library photos go through Photos).
    let monthAgo = inputs.now.addingTimeInterval(-30 * 86_400)
    let screenshots = inputs.screenshots.filter { ($0.captured ?? $0.modified ?? inputs.now) < monthAgo }
    let screenshotItems = take(
      screenshots.compactMap { PlanItem.photo($0, keeper: nil, reason: "Screenshot older than a month.") })
    add(
      "screenshots", symbol: "camera.viewfinder", title: "Screenshots older than a month",
      detail: "Usually taken for a moment and forgotten.", confidence: .review, items: screenshotItems,
      destination: .photos)

    // 8. Mail attachments and other review-level cleanup.
    let mail = take(inputs.cleanupTargets.filter { $0.category == .mailAttachments }.map { PlanItem.cleanup($0) })
    add(
      "mail", symbol: "paperclip", title: "Mail attachments you've opened",
      detail: "Mail keeps a copy of attachments you've opened; IMAP and Exchange can download them again.",
      confidence: .review, items: mail, destination: .cleaner)
    let otherReview = take(
      inputs.cleanupTargets.filter {
        $0.risk == .review && [.diagnostics, .deviceBackups, .installers].contains($0.category)
      }.map { PlanItem.cleanup($0) })
    add(
      "review-cleanup", symbol: "eye", title: "Installers, crash reports, and device backups",
      detail: "Often no longer needed, but only you can tell.", confidence: .review, items: otherReview,
      destination: .cleaner)

    // 9. Unused apps — each uninstall needs its own review, so this opens Applications.
    let cutoff = inputs.now.addingTimeInterval(-Double(inputs.unusedAppDays) * 86_400)
    let unused = inputs.apps.filter { app in
      guard let lastUsed = app.lastUsed, lastUsed < cutoff else { return false }
      let id = app.bundleIdentifier?.lowercased() ?? ""
      return !id.hasPrefix("com.apple.") && !id.hasPrefix("co.macmint.")
        && !app.url.path.hasPrefix("/System/")
    }.sorted { $0.bundleSize > $1.bundleSize }
    if !unused.isEmpty {
      let names = unused.prefix(3).map(\.name).joined(separator: ", ")
      add(
        "unused-apps", symbol: "app.badge.clock", title: "Apps you haven't opened in \(RelativeAge.describe(days: inputs.unusedAppDays))",
        detail: names + (unused.count > 3 ? " and \(unused.count - 3) more" : "") + ".",
        confidence: .review, items: [], destination: .applications,
        bytes: unused.reduce(0) { $0 + $1.bundleSize }, count: unused.count)
    }

    // 10. Duplicates — keeper choices happen on their screen.
    let duplicateBytes = inputs.duplicateGroups.reduce(Int64(0)) { $0 + $1.reclaimableBytes }
    add(
      "duplicates", symbol: "square.on.square", title: "Exact duplicate files",
      detail: "\(inputs.duplicateGroups.count) sets of identical files. Choose which copy to keep.",
      confidence: .review, items: [], destination: .duplicates, bytes: duplicateBytes,
      count: inputs.duplicateGroups.count)

    // 11. Trash — space isn't freed until it's emptied.
    if inputs.trashBytes >= 100 * 1_048_576 {
      add(
        "trash", symbol: "trash", title: "The Trash is holding \(ByteFormatter.string(inputs.trashBytes))",
        detail: "Space comes back only after emptying it. Check you don't need anything first — emptying can't be undone.",
        confidence: .review, items: [], destination: .trash, bytes: inputs.trashBytes, count: 0)
    }

    var ranked = results.sorted { $0.score > $1.score }

    // 12. Biggest recent growth, as context (never a removal suggestion on its own).
    if let top = inputs.growth.first {
      ranked.append(
        Recommendation(
          id: "growth", symbol: "chart.line.uptrend.xyaxis",
          title: "\(URL(fileURLWithPath: top.path).lastPathComponent) grew by \(ByteFormatter.string(top.delta))",
          detail: "Since your previous Storage map. Open Storage to see what's inside.",
          bytes: top.delta, count: 1, confidence: .review, items: [], destination: .storage))
    }
    return ranked
  }

  /// "3 videos, 2 installers and 4 other files"
  static func summary(_ kinds: [DownloadKind]) -> String {
    let counts = Dictionary(grouping: kinds, by: { $0 }).mapValues(\.count)
      .sorted { $0.value > $1.value }
    let parts = counts.prefix(3).map { "\($0.value) \($0.key.rawValue.lowercased())" }
    let rest = counts.dropFirst(3).reduce(0) { $0 + $1.value }
    var text = parts.joined(separator: ", ")
    if rest > 0 { text += " and \(rest) other item\(rest == 1 ? "" : "s")" }
    return text.prefix(1).uppercased() + text.dropFirst()
  }

  /// Everything rated Safe, as one review.
  public static func safeItems(_ recommendations: [Recommendation]) -> [PlanItem] {
    recommendations.filter { $0.confidence == .safe }.flatMap(\.items)
  }
}
