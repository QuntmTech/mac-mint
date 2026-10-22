import AppKit
import MacCleanerCore
import SwiftUI

/// Opt-in menu bar companion: disk, memory, and CPU at a glance, plus quick actions.
struct MenuBarView: View {
  @EnvironmentObject private var model: AppViewModel
  @EnvironmentObject private var account: AccountStore
  @EnvironmentObject private var monitor: SystemMonitor
  @Environment(\.openWindow) private var openWindow

  @State private var monitoringLease = UUID()

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      MenuBarReadings(live: monitor.live, volumeName: model.volumeName,
        settings: { open(.settings) }, quit: { NSApp.terminate(nil) },
        storage: { open(.storage) }, performance: { open(.performance) })

      scanStrip

      HStack(spacing: 8) {
        Button("Open MacMint") { open(nil) }
          .buttonStyle(MintButtonStyle(.secondary))
        Button {
          open(.dashboard)
          model.runSmartScan()
        } label: {
          Label(model.isScanning ? "Scanning…" : "Quick Scan", systemImage: "sparkles")
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(MintButtonStyle(.commit))
        .disabled(model.isScanning || model.isWorking)
      }
    }
    .padding(14)
    .frame(width: 320)
    .background(AppTheme.canvas)
    // The popover samples only while it is open, whether or not a window is in front.
    .onAppear { monitor.start(lease: monitoringLease, interval: 4, kind: .popover) }
    .onDisappear { monitor.stop(lease: monitoringLease) }
  }

  /// Quick Scan's latest result on a mint strip, with the way into Review.
  private var scanStrip: some View {
    HStack(spacing: 10) {
      SwatchBadge(symbol: "sparkles", swatch: .mint, size: 28)
      VStack(alignment: .leading, spacing: 1) {
        HStack(spacing: 6) {
          Text(stripTitle).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(AppTheme.ink)
            .lineLimit(1).minimumScaleFactor(0.85)
          if model.isScanning { ProgressView().controlSize(.mini) }
        }
        Text(stripDetail).font(.system(size: 11)).foregroundStyle(AppTheme.Swatch.mint.text)
          .lineLimit(2).fixedSize(horizontal: false, vertical: true)
      }
      .accessibilityElement(children: .combine)
      Spacer(minLength: 4)
      Button("Review (\(model.queuedCount))") { open(.review) }
        .buttonStyle(MintButtonStyle(.plain)).controlSize(.small)
        .monospacedDigit()
        .help("Open Review")
    }
    .padding(.horizontal, 12).padding(.vertical, 10)
    .background(AppTheme.Swatch.mint.tint, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
  }

  private var stripTitle: String {
    if model.isScanning { return "Scanning…" }
    if model.lastScanDate == nil { return "No Quick Scan yet" }
    let found = model.safeRecommendationBytes
    return found > 0 ? "\(ByteFormatter.string(found)) rebuildable found" : "Nothing big to clear"
  }

  private var stripDetail: String {
    if model.isScanning {
      return model.scanCompletedAreas.isEmpty ? "Reading only. Nothing is removed." : "\(model.scanCompletedAreas.count) of 5 checks done"
    }
    guard let date = model.lastScanDate else { return "Quick Scan only reads. Nothing is removed." }
    return "Last scan \(date.formatted(.relative(presentation: .named))) · you review first"
  }

  private func open(_ section: AppViewModel.Section?) {
    if let section { model.selectedSection = section }
    // A WindowGroup creates another window on every openWindow call; reuse the open one.
    if !MainWindow.focusExisting() { openWindow(id: "main") }
    NSApp.activate(ignoringOtherApps: true)
  }
}

/// The popover's live readings; only this part re-renders when a sample arrives.
private struct MenuBarReadings: View {
  @ObservedObject var live: SystemMonitor.LiveReadings
  let volumeName: String
  let settings: () -> Void
  let quit: () -> Void
  let storage: () -> Void
  let performance: () -> Void
  private var snapshot: SystemMonitor.Snapshot { live.reading.snapshot }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      header
      HStack(spacing: 8) {
        MetricTile(
          title: "Free", value: freeValue, detail: freeDetail, swatch: .indigo,
          valueColor: (snapshot.diskUsedFraction ?? 0) > 0.9 ? AppTheme.warning : nil,
          fraction: snapshot.diskUsedFraction, action: storage)
          .opacity(snapshot.hasDiskReading ? 1 : 0.6)
          .help(snapshot.diskStale ? "macOS did not answer the last disk check; this is the previous reading."
            : "Space for new files on \(volumeName), including space macOS can free on its own when needed")
        MetricTile(
          title: "Memory", value: snapshot.pressure.rawValue,
          detail: snapshot.memoryUsedBytes.map {
            "\(ByteFormatter.string($0)) of \(ByteFormatter.string(snapshot.physicalMemory))"
          } ?? "—",
          swatch: .violet, valueColor: pressureColor, fraction: memoryFraction, action: performance)
          .help(swapText)
        MetricTile(
          title: "CPU",
          value: snapshot.cpuUsage.map { "\(Int(($0 * 100).rounded()))%" } ?? "…",
          detail: "all cores", swatch: .sky, fraction: snapshot.cpuUsage, action: performance)
      }
      if !busiest.isEmpty { busiestList }
    }
  }

  private var header: some View {
    HStack(spacing: 10) {
      BrandMark(size: 28).frame(width: 28, height: 28)
      VStack(alignment: .leading, spacing: 1) {
        Text("MacMint").font(.system(size: 14, weight: .bold)).tracking(-0.2).foregroundStyle(AppTheme.ink)
        Text(monitorSummary).font(.system(size: 11.5)).foregroundStyle(AppTheme.ink2).lineLimit(1)
        if let updated = updatedText {
          Text(updated).font(.system(size: 10.5)).foregroundStyle(AppTheme.ink3).lineLimit(1)
        }
      }
      .accessibilityElement(children: .combine)
      Spacer(minLength: 4)
      headerButton("gearshape", help: "Settings", action: settings)
      headerButton("power", help: "Quit MacMint", action: quit)
    }
  }

  private func headerButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      Image(systemName: symbol).font(.system(size: 13, weight: .medium)).foregroundStyle(AppTheme.ink2)
        .frame(width: 26, height: 26)
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .help(help)
    .accessibilityLabel(help)
  }

  /// The sample time as people say it; the popover re-renders with each sample, so no timer.
  private var updatedText: String? {
    guard let sampled = live.reading.sampledAt else { return nil }
    if Date().timeIntervalSince(sampled) < 15 { return "Updated just now" }
    return "Updated at " + sampled.formatted(date: .omitted, time: .shortened)
  }

  private var freeValue: String {
    snapshot.hasDiskReading ? ByteFormatter.string(snapshot.freeBytes) : "—"
  }

  private var freeDetail: String {
    guard snapshot.hasDiskReading else { return "unavailable" }
    return snapshot.diskStale ? "earlier reading" : "of \(ByteFormatter.string(snapshot.totalBytes))"
  }

  private var memoryFraction: Double? {
    guard let used = snapshot.memoryUsedBytes, snapshot.physicalMemory > 0 else { return nil }
    return min(1, max(0, Double(used) / Double(snapshot.physicalMemory)))
  }

  private var swapText: String {
    snapshot.swapUsedBytes.map { "Swap in use: " + ByteFormatter.string($0) } ?? "Swap reading unavailable"
  }

  /// The three apps using the most CPU in the latest sample (memory breaks ties).
  private var busiest: [SystemMonitor.AppUsage] {
    let apps = live.reading.apps
    guard !apps.isEmpty else { return [] }
    let sorted = apps.sorted { lhs, rhs in
      let left = lhs.cpuPercent ?? -1
      let right = rhs.cpuPercent ?? -1
      if left != right { return left > right }
      return lhs.memoryBytes > rhs.memoryBytes
    }
    return Array(sorted.prefix(3))
  }

  private var busiestList: some View {
    VStack(alignment: .leading, spacing: 6) {
      Eyebrow("Busiest right now")
      VStack(spacing: 0) {
        let rows = busiest
        ForEach(rows) { usage in
          MenuBarAppRow(usage: usage)
          if usage.id != rows.last?.id {
            Rectangle().fill(AppTheme.divider).frame(height: 1).padding(.leading, 38)
          }
        }
      }
      .padding(.horizontal, 10)
      .cardBackground(radius: 12)
    }
  }

  private var monitorSummary: String {
    switch snapshot.pressure {
    case .critical: return "Memory is under heavy pressure"
    case .warning: return "Memory is getting tight"
    case .unknown: return "Readings are not available yet"
    case .normal:
      guard let used = snapshot.diskUsedFraction else { return "Memory is normal · disk space unknown" }
      return used > 0.9 ? "Disk is almost full" : "Everything looks healthy"
    }
  }

  private var pressureColor: Color? {
    switch snapshot.pressure {
    case .normal: return nil
    case .warning: return AppTheme.warning
    case .critical: return AppTheme.danger
    case .unknown: return AppTheme.ink2
    }
  }
}

/// One app in "Busiest right now": its icon, name, CPU and memory from the latest sample.
private struct MenuBarAppRow: View {
  let usage: SystemMonitor.AppUsage
  @State private var icon: NSImage?

  var body: some View {
    HStack(spacing: 10) {
      Group {
        if let icon { Image(nsImage: icon).resizable().scaledToFit() }
        else { Image(systemName: "app.fill").font(.system(size: 15)).foregroundStyle(AppTheme.ink3) }
      }
      .frame(width: 20, height: 20)
      .accessibilityHidden(true)
      Text(usage.name).font(.system(size: 12.5, weight: .medium)).foregroundStyle(AppTheme.ink)
        .lineLimit(1).truncationMode(.tail)
      Spacer(minLength: 6)
      Text(cpuText).font(AppTheme.number(12, weight: .semibold)).monospacedDigit()
        .foregroundStyle(AppTheme.Swatch.sky.text)
      Text(ByteFormatter.string(usage.memoryBytes)).font(AppTheme.number(11.5, weight: .medium)).monospacedDigit()
        .foregroundStyle(AppTheme.ink3)
        .frame(minWidth: 52, alignment: .trailing)
    }
    .frame(height: 30)
    .accessibilityElement(children: .combine)
    .task(id: usage.id) {
      icon = PerformanceIconCache.shared.icon(for: usage.application)
    }
  }

  private var cpuText: String {
    guard let cpu = usage.cpuPercent, cpu.isFinite else { return "—" }
    return "\(Int(cpu.rounded()))%"
  }
}

/// A reading on its area's tint: label, value in SF Rounded, a short detail and a thin meter.
struct MetricTile: View {
  let title: String
  let value: String
  let detail: String
  var swatch: AppTheme.Swatch = .mint
  /// Overrides the swatch's text color for the value (pressure and low space).
  var valueColor: Color? = nil
  /// 0...1 for the meter; nil hides it.
  var fraction: Double? = nil
  var action: (() -> Void)? = nil

  var body: some View {
    if let action {
      Button(action: action) { tile }.buttonStyle(TileButtonStyle())
        .help("Open " + title)
    } else {
      tile
    }
  }

  private var tile: some View {
    VStack(alignment: .leading, spacing: 3) {
      Text(title.uppercased()).font(.system(size: 9.5, weight: .bold)).tracking(0.8)
        .foregroundStyle(swatch.text)
      Text(value).font(AppTheme.number(17)).tracking(-0.4).monospacedDigit()
        .foregroundStyle(valueColor ?? AppTheme.ink)
        .lineLimit(1).minimumScaleFactor(0.6)
      Text(detail).font(.system(size: 10.5)).foregroundStyle(swatch.text).lineLimit(1).minimumScaleFactor(0.7)
      meter.padding(.top, 2)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(10)
    .background(swatch.tint, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
    .contentShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
    .accessibilityElement(children: .combine)
  }

  @ViewBuilder private var meter: some View {
    if let fraction {
      GeometryReader { geometry in
        Capsule().fill(swatch.color.opacity(0.18)).overlay(alignment: .leading) {
          Capsule().fill(swatch.gradient)
            .frame(width: max(3, geometry.size.width * min(1, max(0, fraction))))
        }
      }
      .frame(height: 3)
      .accessibilityHidden(true)
    } else {
      Color.clear.frame(height: 3)
    }
  }
}
