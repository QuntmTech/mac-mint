import AppKit
import Darwin
import IOKit.ps
import MacCleanerCore
import SwiftUI

/// Overview's storage categories: what Quick Scan found, in the sidebar's colors.
enum OverviewPresentation {
  struct Category: Identifiable, Equatable {
    let destination: Recommendation.Destination
    let title: String
    let symbol: String
    let swatch: AppTheme.Swatch
    let bytes: Int64
    let detail: String
    var id: String { destination.rawValue }
  }

  static func style(_ destination: Recommendation.Destination) -> (title: String, symbol: String, swatch: AppTheme.Swatch) {
    switch destination {
    case .developer: return ("Developer", "hammer.fill", AppTheme.Swatch.orange)
    case .cleaner: return ("Caches & cleanup", "archivebox.fill", AppTheme.Swatch.sky)
    case .downloads: return ("Downloads", "arrow.down.circle.fill", AppTheme.Swatch.teal)
    case .removedApps: return ("Removed-app data", "folder.badge.questionmark", AppTheme.Swatch.rose)
    case .applications: return ("Unused apps", "app.dashed", AppTheme.Swatch.violet)
    case .photos: return ("Screenshots", "camera.viewfinder", AppTheme.Swatch.pink)
    case .duplicates: return ("Duplicates", "square.on.square.fill", AppTheme.Swatch.indigo)
    case .trash: return ("Trash", "trash.fill", AppTheme.Swatch.graphite)
    case .storage: return ("Growing folders", "chart.line.uptrend.xyaxis", AppTheme.Swatch.amber)
    }
  }

  /// Recommendations claim each path once, so their sizes add up without double counting.
  /// Growing folders measure change, not space that can be removed, and are left out.
  static func categories(_ recommendations: [Recommendation]) -> [Category] {
    let grouped = Dictionary(grouping: recommendations.filter { $0.destination != .storage && $0.bytes > 0 },
      by: \.destination)
    return grouped.map { destination, group in
      let look = Self.style(destination)
      let bytes = group.reduce(Int64(0)) { add($0, $1.bytes) }
      let count = group.reduce(0) { $0 + $1.count }
      // A group mixing rebuildable and review-only findings must not read as all rebuildable.
      let levels = Set(group.map(\.confidence))
      let safety = levels.count == 1 ? (levels.first?.label.lowercased() ?? "") : "some need review"
      let detail = destination == .trash ? "Empty the Trash to free this space"
        : (count == 1 ? "1 item" : "\(count) items") + " · " + safety
      return Category(destination: destination, title: look.title, symbol: look.symbol, swatch: look.swatch,
        bytes: bytes, detail: detail)
    }.sorted { $0.bytes != $1.bytes ? $0.bytes > $1.bytes : $0.title < $1.title }
  }

  /// Shares of the whole disk: each category, everything else that is used, and free space.
  /// Categories are scaled down if they ever add up to more than the used space.
  struct Bar: Equatable {
    struct Segment: Identifiable, Equatable {
      let category: Category
      let fraction: Double
      var id: String { category.id }
    }
    var segments: [Segment]
    var rest: Double
    var free: Double
  }

  static func bar(_ categories: [Category], used: Int64, total: Int64) -> Bar? {
    guard total > 0, used >= 0 else { return nil }
    let used = min(used, total)
    let found = categories.reduce(Int64(0)) { add($0, $1.bytes) }
    let scale = found > used ? Double(used) / Double(found) : 1
    let segments = categories.map { Bar.Segment(category: $0, fraction: Double($0.bytes) * scale / Double(total)) }
    let foundShare = segments.reduce(0) { $0 + $1.fraction }
    return Bar(segments: segments, rest: max(0, Double(used) / Double(total) - foundShare),
      free: Double(total - used) / Double(total))
  }

  static func add(_ left: Int64, _ right: Int64) -> Int64 {
    let (sum, overflow) = left.addingReportingOverflow(max(0, right))
    return overflow ? .max : sum
  }
}

// MARK: - System health

/// One-shot readings for Overview's health row: memory, swap and pressure (the same readers as
/// Performance), load average and battery. No sampler runs for it; it refreshes about once a
/// minute while MacMint is in front, and only this row redraws when a value changes.
@MainActor
final class HealthMonitor: ObservableObject {
  struct Reading: Equatable, Sendable {
    struct Battery: Equatable, Sendable {
      var percent: Int
      var charging: Bool
      var onPower: Bool
    }
    /// Rounded to 50 MB so tiny changes don't redraw.
    var memoryUsed: Int64?
    var physicalMemory: Int64
    var pressure: SystemMonitor.Pressure
    var swapUsed: Int64?
    /// One-minute load average, rounded to a tenth.
    var load: Double?
    var cores: Int
    var battery: Battery?
  }

  @Published private(set) var reading: Reading?

  init(readNow: Bool = false) {
    if readNow { reading = Self.read() }
  }

  func refresh() async {
    let next = await Task.detached(priority: .utility) { HealthMonitor.read() }.value
    if next != reading { reading = next }
  }

  nonisolated static func read() -> Reading {
    func rounded(_ bytes: Int64?) -> Int64? {
      let step: Int64 = 52_428_800  // 50 MB
      guard let bytes else { return nil }
      return (bytes + step / 2) / step * step
    }
    var loads = [Double](repeating: 0, count: 3)
    var load: Double?
    if getloadavg(&loads, 3) == 3 { load = (loads[0] * 10).rounded() / 10 }
    return Reading(memoryUsed: rounded(ResourceSampler.memoryUsed()),
      physicalMemory: Int64(ProcessInfo.processInfo.physicalMemory), pressure: ResourceSampler.pressure(),
      swapUsed: rounded(ResourceSampler.swapUsed()), load: load,
      cores: ProcessInfo.processInfo.activeProcessorCount, battery: battery())
  }

  /// The internal battery, if this Mac has one.
  nonisolated static func battery() -> Reading.Battery? {
    guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
      let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
    for source in sources {
      guard let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
        description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
        let current = description[kIOPSCurrentCapacityKey] as? Int,
        let maximum = description[kIOPSMaxCapacityKey] as? Int, maximum > 0 else { continue }
      return Reading.Battery(percent: Int((Double(current) / Double(maximum) * 100).rounded()),
        charging: description[kIOPSIsChargingKey] as? Bool ?? false,
        onPower: description[kIOPSPowerSourceStateKey] as? String == kIOPSACPowerValue)
    }
    return nil
  }
}

/// Disk, memory, CPU load and battery at a glance. Live per-app detail stays in Performance.
struct SystemHealthRow: View {
  let volume: VolumeSummary
  let openPerformance: () -> Void
  @StateObject private var health = HealthMonitor(readNow: SmokeTest.isRequested)

  var body: some View {
    let reading = health.reading
    let cards = cardsFor(reading)
    LazyVGrid(columns: [GridItem(.adaptive(minimum: 160), spacing: 12)], spacing: 12) {
      ForEach(cards, id: \.title) { card in
        HealthCard(card: card, action: card.title == "Disk" ? nil : openPerformance)
      }
    }
    .task {
      guard !SmokeTest.isRequested else { return }
      while !Task.isCancelled {
        if health.reading == nil || AppActivity.shared.isForeground { await health.refresh() }
        try? await Task.sleep(for: .seconds(60))
      }
    }
  }

  fileprivate struct Card {
    let title: String
    let symbol: String
    let swatch: AppTheme.Swatch
    let value: String
    let detail: String
    let fraction: Double?
    /// A one-word state beside the title (Normal, Getting full); `strained` colors it amber.
    var state: String? = nil
    var strained = false
  }

  private func cardsFor(_ reading: HealthMonitor.Reading?) -> [Card] {
    var cards: [Card] = []
    if volume.isMeasured {
      let fraction = Double(volume.used) / Double(volume.total)
      cards.append(Card(title: "Disk", symbol: "internaldrive.fill", swatch: .indigo, value: "\(Int((fraction * 100).rounded()))%",
        detail: "\(ByteFormatter.string(volume.free)) free of \(ByteFormatter.string(volume.total))", fraction: fraction,
        state: fraction > 0.9 ? "Nearly full" : fraction > 0.8 ? "Getting full" : "Normal", strained: fraction > 0.8))
    } else {
      cards.append(Card(title: "Disk", symbol: "internaldrive.fill", swatch: .indigo, value: "—",
        detail: "Disk space unavailable", fraction: nil))
    }
    var memoryFraction: Double?
    if let reading, let used = reading.memoryUsed, reading.physicalMemory > 0 {
      memoryFraction = min(1, Double(used) / Double(reading.physicalMemory))
    }
    let swap = reading?.swapUsed.map { " · swap " + ByteFormatter.string($0) } ?? ""
    cards.append(Card(title: "Memory", symbol: "memorychip.fill", swatch: .violet,
      value: memoryFraction.map { "\(Int(($0 * 100).rounded()))%" } ?? "—",
      detail: reading.map { "Pressure \($0.pressure.rawValue.lowercased())" + swap } ?? "Reading…",
      fraction: memoryFraction, state: reading.flatMap { $0.pressure == .unknown ? nil : $0.pressure == .normal ? "Normal" : "Under pressure" },
      strained: reading.map { $0.pressure == .warning || $0.pressure == .critical } ?? false))
    var loadFraction: Double?
    if let reading, let load = reading.load, reading.cores > 0 { loadFraction = min(1, load / Double(reading.cores)) }
    cards.append(Card(title: "CPU load", symbol: "cpu.fill", swatch: .sky,
      value: reading?.load.map { String(format: "%.1f", $0) } ?? "—",
      detail: reading.map { "1-minute average on \($0.cores) cores" } ?? "Reading…", fraction: loadFraction,
      state: loadFraction.map { $0 > 0.85 ? "Busy" : "Normal" }, strained: (loadFraction ?? 0) > 0.85))
    if let battery = reading?.battery {
      cards.append(Card(title: "Battery", symbol: battery.charging ? "battery.100.bolt" : "battery.75", swatch: .mint,
        value: "\(battery.percent)%",
        detail: battery.charging ? "Charging" : battery.onPower ? "On power adapter" : "On battery",
        fraction: Double(battery.percent) / 100,
        state: battery.percent <= 15 && !battery.onPower ? "Low" : "Normal", strained: battery.percent <= 15 && !battery.onPower))
    }
    return cards
  }
}

private struct HealthCard: View {
  let card: SystemHealthRow.Card
  let action: (() -> Void)?

  var body: some View {
    if let action {
      Button(action: action) { face }.buttonStyle(CardButtonStyle()).help("Open Performance")
    } else {
      face
    }
  }

  private var face: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack(spacing: 8) {
        SwatchBadge(symbol: card.symbol, swatch: card.swatch, size: 22)
        Eyebrow(card.title)
        Spacer(minLength: 4)
        if let state = card.state {
          Text(state).font(.system(size: 11, weight: .semibold))
            .foregroundStyle(card.strained ? AppTheme.warning : AppTheme.accentText)
        }
      }
      Text(card.value).font(AppTheme.number(24)).tracking(-0.5).monospacedDigit().foregroundStyle(AppTheme.ink)
      Text(card.detail).font(.system(size: 11.5)).foregroundStyle(AppTheme.ink2).lineLimit(1).minimumScaleFactor(0.8)
      Capsule().fill(AppTheme.track).frame(height: 5)
        .overlay(alignment: .leading) {
          if let fraction = card.fraction {
            GeometryReader { geometry in
              Capsule().fill(card.swatch.gradient).frame(width: geometry.size.width * min(1, max(0, fraction)))
            }
          }
        }
        .clipShape(Capsule())
    }
    .padding(.horizontal, 15).padding(.vertical, 14)
    .frame(maxWidth: .infinity, alignment: .leading)
    .cardBackground(radius: 14)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(card.title)
    .accessibilityValue(card.value + ", " + card.detail + (card.state.map { ", " + $0 } ?? ""))
  }
}

// MARK: - Storage overview

/// The disk as one bar: what Quick Scan found (in each category's color), everything else that
/// is used, and free space, with a legend of measured sizes.
struct StorageOverviewCard: View {
  let categories: [OverviewPresentation.Category]
  let volume: VolumeSummary
  let scanned: Bool

  var body: some View {
    SurfaceCard(padding: 0) {
      VStack(alignment: .leading, spacing: 14) {
        HStack(alignment: .firstTextBaseline) {
          Text("Storage overview").font(.system(size: 15, weight: .bold)).tracking(-0.2).foregroundStyle(AppTheme.ink)
          Spacer()
          if volume.isMeasured {
            (Text(ByteFormatter.string(volume.used)).fontWeight(.semibold).foregroundColor(AppTheme.ink)
              + Text(" of \(ByteFormatter.string(volume.total)) used"))
              .font(.system(size: 12.5)).foregroundStyle(AppTheme.ink2).monospacedDigit()
          } else {
            Text("Disk space unavailable").font(.system(size: 12.5)).foregroundStyle(AppTheme.ink2)
          }
        }
        if let bar = OverviewPresentation.bar(categories, used: volume.used, total: volume.total), volume.isMeasured {
          GeometryReader { geometry in
            let gaps = CGFloat(bar.segments.count) * 2
            let width = max(0, geometry.size.width - gaps)
            HStack(spacing: 2) {
              ForEach(bar.segments) { segment in
                Rectangle().fill(segment.category.swatch.gradient).frame(width: width * segment.fraction)
              }
              Rectangle().fill(AppTheme.borderStrong).frame(width: width * bar.rest)
              Spacer(minLength: 0)
            }
          }
          .frame(height: 20)
          .background(AppTheme.track)
          .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
          .accessibilityHidden(true)
          LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 18, alignment: .leading)], alignment: .leading, spacing: 8) {
            ForEach(categories) { category in
              legend(category.title, ByteFormatter.string(category.bytes), fill: AnyShapeStyle(category.swatch.gradient))
            }
            legend("Everything else", ByteFormatter.string(otherUsed), fill: AnyShapeStyle(AppTheme.borderStrong))
            legend("Free", ByteFormatter.string(volume.free), fill: AnyShapeStyle(AppTheme.track))
          }
        }
        Text(scanned
          ? "Colored parts are what Quick Scan found to review. Space frees up after you review items and empty the Trash."
          : "Run Quick Scan to see which parts of the used space are caches, leftovers and other things worth reviewing.")
          .font(.system(size: 11.5)).foregroundStyle(AppTheme.ink3).fixedSize(horizontal: false, vertical: true)
      }
      .padding(.horizontal, 20).padding(.vertical, 18)
    }
  }

  /// Used space outside the colored categories.
  private var otherUsed: Int64 {
    let found = categories.reduce(Int64(0)) { OverviewPresentation.add($0, $1.bytes) }
    return max(0, volume.used - found)
  }

  private func legend(_ title: String, _ value: String, fill: AnyShapeStyle) -> some View {
    HStack(spacing: 6) {
      RoundedRectangle(cornerRadius: 3).fill(fill).frame(width: 10, height: 10)
        .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(Color.black.opacity(0.12), lineWidth: 0.5))
      Text(title).foregroundStyle(AppTheme.ink2).lineLimit(1)
      Text(value).fontWeight(.semibold).foregroundStyle(AppTheme.ink).monospacedDigit()
    }
    .font(.system(size: 12))
    .accessibilityElement(children: .combine)
  }
}

/// A large colored tile for one category, in its area's color; white text meets WCAG AA.
struct CategoryTile: View {
  let category: OverviewPresentation.Category
  let action: () -> Void
  @Environment(\.colorSchemeContrast) private var contrast

  var body: some View {
    let shape = RoundedRectangle(cornerRadius: AppTheme.corner, style: .continuous)
    Button(action: action) {
      VStack(alignment: .leading, spacing: 0) {
        HStack {
          Image(systemName: category.symbol).font(.system(size: 16, weight: .semibold))
            .frame(width: 32, height: 32)
            .background(Color.white.opacity(0.2), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
          Spacer()
          Image(systemName: "arrow.up.right").font(.system(size: 12, weight: .semibold))
        }
        Spacer(minLength: 8)
        Text(ByteFormatter.string(category.bytes)).font(AppTheme.number(26)).tracking(-0.6).monospacedDigit()
          .lineLimit(1).minimumScaleFactor(0.7)
        Text(category.title).font(.system(size: 13, weight: .semibold)).lineLimit(1).padding(.top, 3)
        Text(category.detail).font(.system(size: 11.5)).foregroundStyle(Color.white.opacity(0.88))
          .lineLimit(1).minimumScaleFactor(0.85).padding(.top, 1)
      }
      .foregroundStyle(.white)
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
      .padding(.horizontal, 16).padding(.vertical, 15)
      .background {
        ZStack(alignment: .bottomTrailing) {
          shape.fill(category.swatch.gradient)
          Image(systemName: category.symbol).font(.system(size: 104)).foregroundStyle(Color.white.opacity(0.08))
            .offset(x: 18, y: 26)
        }
        .clipShape(shape)
      }
      .overlay(shape.strokeBorder(Color.white.opacity(contrast == .increased ? 0.7 : 0.18), lineWidth: contrast == .increased ? 2 : 0.5))
      .shadow(color: category.swatch.color.opacity(0.3), radius: 6, y: 4)
      .contentShape(shape)
    }
    .buttonStyle(TileButtonStyle())
    .accessibilityElement(children: .combine)
    .accessibilityLabel("\(category.title), \(ByteFormatter.string(category.bytes))")
    .accessibilityHint(category.detail)
  }
}
