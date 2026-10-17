import AppKit
import MacCleanerCore
import SwiftUI

/// Read-only scene fixtures contain scalar readings only, never process-control handles.
struct PerformancePreview: Sendable {
  let snapshot: SystemMonitor.Snapshot
  let apps: [PerformancePresentation.App]
  let sampledAt: Date?
  let logicalCPUCount: Int
  var paused = false
}

private struct PerformancePreviewKey: EnvironmentKey {
  static let defaultValue: PerformancePreview? = nil
}

extension EnvironmentValues {
  var performancePreview: PerformancePreview? {
    get { self[PerformancePreviewKey.self] }
    set { self[PerformancePreviewKey.self] = newValue }
  }
}

struct PerformanceView: View {
  @EnvironmentObject private var model: AppViewModel
  @EnvironmentObject private var monitor: SystemMonitor
  @Environment(\.scenePhase) private var scenePhase
  @Environment(\.performancePreview) private var preview
  @Environment(\.colorSchemeContrast) private var contrast
  @State private var pendingQuit: SystemMonitor.AppUsage?
  @State private var monitoringLease = UUID()
  @State private var pausedReading: Reading?
  @State private var previewPaused: Bool?
  @State private var search = ""
  @State private var sort = PerformancePresentation.Sort()
  @State private var forceQuit = false
  @State private var insights: DiskInsights?

  private struct Reading {
    let snapshot: SystemMonitor.Snapshot
    let apps: [SystemMonitor.AppUsage]
    let sampledAt: Date?
    @MainActor init(_ monitor: SystemMonitor) {
      snapshot = monitor.snapshot; apps = monitor.apps; sampledAt = monitor.sampledAt
    }
  }

  private var paused: Bool { preview.map { previewPaused ?? $0.paused } ?? (pausedReading != nil) }
  private var snapshot: SystemMonitor.Snapshot { preview?.snapshot ?? pausedReading?.snapshot ?? monitor.snapshot }
  private var sampledAt: Date? {
    if let preview { return preview.sampledAt }
    if let pausedReading { return pausedReading.sampledAt }
    return monitor.sampledAt
  }
  private var logicalCPUCount: Int { preview?.logicalCPUCount ?? ProcessInfo.processInfo.processorCount }
  private var query: String { search.trimmingCharacters(in: .whitespacesAndNewlines) }
  private var usages: [SystemMonitor.AppUsage] { preview == nil ? (pausedReading?.apps ?? monitor.apps) : [] }
  private var appRows: [PerformancePresentation.App] {
    preview?.apps ?? usages.map { app in
      .init(id: .init(pid: app.id, started: app.started), name: app.name, bundleID: app.bundleID,
        memoryBytes: app.memoryBytes, cpuPercent: app.cpuPercent)
    }
  }
  private var samplingDetail: String {
    guard let sampledAt else { return paused ? "Paused before the first sample. Resume to measure activity." : "Measuring app activity…" }
    let time = sampledAt.formatted(date: .omitted, time: .standard)
    return paused ? "Readings frozen at \(time). Quit still checks the current process before acting."
      : "Updated \(time) · refreshes about every \(Int(preview == nil ? (monitor.samplingInterval ?? 4) : 4)) seconds"
  }

  private var readingStatus: String {
    let state = paused ? "Paused" : (sampledAt == nil ? "Measuring" : "Live")
    return sampledAt.map { state + " · " + $0.formatted(date: .omitted, time: .standard) } ?? state
  }

  var body: some View {
    ScrollView {
      LazyVStack(alignment: .leading, spacing: 18) {
        PageHeader("Performance", subtitle: "See what is busy, find the app, and decide what to do.")
        ViewThatFits(in: .horizontal) {
          HStack(alignment: .top, spacing: 14) { cpuCard; memoryCard }
          VStack(spacing: 14) { cpuCard; memoryCard }
        }
        processCard
        ViewThatFits(in: .horizontal) {
          HStack(spacing: 18) { supportingMetric("Swap", value: snapshot.swapUsedBytes.map(ByteFormatter.string) ?? "—", icon: "arrow.left.arrow.right"); freeSpaceMetric }
          VStack(alignment: .leading, spacing: 8) { supportingMetric("Swap", value: snapshot.swapUsedBytes.map(ByteFormatter.string) ?? "—", icon: "arrow.left.arrow.right"); freeSpaceMetric }
        }
        diskInsightsCard
        SurfaceCard {
          VStack(alignment: .leading, spacing: 10) {
            Label("When to take action", systemImage: "info.circle").font(.headline)
            Text("Short CPU spikes during builds or photo analysis are normal. Quit unused apps when memory pressure stays Elevated or High. High memory use by itself is normal: macOS keeps useful caches in RAM.")
              .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Text("MacMint does not purge memory. For helper processes and detailed diagnostics, open Activity Monitor.")
              .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
              Button("Open Activity Monitor") { model.openActivityMonitor() }
              Button("Review Storage") { model.selectedSection = .storage }
            }
          }
        }
      }
      .padding(AppTheme.pagePadding)
    }
    .background {
      if preview != nil {
        GeometryReader { geometry in
          let frame = geometry.frame(in: .global)
          let inset = geometry.safeAreaInsets
          // The detail frame already excludes the NavigationSplitView sidebar.
          // SwiftUI also propagates that column as a leading safe-area inset; adding
          // it again shifts the measured viewport into the process table. Retain the
          // vertical exclusions for the fixed workspace and operation controls.
          Color.clear.preference(key: WorkspaceLayoutFrames.self, value: ["performance viewport":
            CGRect(x: frame.minX, y: frame.minY + inset.top, width: frame.width,
              height: max(0, frame.height - inset.top - inset.bottom))])
        }
      }
    }
    .onAppear { updateMonitoring() }
    .onChange(of: scenePhase) { _, _ in updateMonitoring() }
    .onChange(of: paused) { _, _ in updateMonitoring() }
    .task { if preview == nil { insights = await DiskInsightsService.load() } }
    .onDisappear { monitor.stop(lease: monitoringLease) }
    .alert(
      "\(forceQuit ? "Force quit" : "Quit") \(pendingQuit?.name ?? "app")?",
      isPresented: Binding(get: { pendingQuit != nil }, set: { if !$0 { pendingQuit = nil } }),
      presenting: pendingQuit
    ) { app in
      Button("Cancel", role: .cancel) {}
      Button(forceQuit ? "Force Quit" : "Quit", role: forceQuit ? .destructive : nil) {
        model.statusMessage = monitor.requestQuit(app, force: forceQuit)
          ? (forceQuit ? "Sent a force-quit request to \(app.name)" : "Asked \(app.name) to quit — it may ask you to save first")
          : "The app changed, exited, or refused the request. Refresh and try again."
      }
    } message: { _ in
      Text(forceQuit ? "Unsaved changes may be lost. Use Force Quit only when normal Quit has not worked." : "The app is asked to quit normally, so it can prompt you to save any unsaved work.")
    }
  }

  private func updateMonitoring() {
    guard preview == nil else { return }
    if !paused && scenePhase == .active { monitor.start(lease: monitoringLease) }
    else { monitor.stop(lease: monitoringLease) }
  }

  private func togglePaused() {
    if let preview { previewPaused = !(previewPaused ?? preview.paused) }
    else { pausedReading = paused ? nil : Reading(monitor) }
  }

  private var cpuCard: some View {
    let fraction = PerformancePresentation.fraction(snapshot.cpuUsage, capacity: 1)
    return resourceCard(title: "CPU", value: fraction.map { "\(Int(($0 * 100).rounded()))%" } ?? "—",
      subtitle: "Whole Mac · \(logicalCPUCount) logical cores", icon: "cpu", key: .cpu, tint: AppTheme.info,
      fraction: fraction, status: fraction == nil ? "CPU reading unavailable" : "Across all cores")
  }

  private var memoryCard: some View {
    let used = snapshot.memoryUsedBytes.flatMap { $0 >= 0 ? $0 : nil }
    return resourceCard(title: "Memory", value: used.map(ByteFormatter.string) ?? "—",
      subtitle: snapshot.physicalMemory > 0 ? "of \(ByteFormatter.string(snapshot.physicalMemory)) installed RAM" : "Installed RAM unavailable",
      icon: "memorychip", key: .memory, tint: pressureTint,
      fraction: PerformancePresentation.memoryFraction(used, physicalMemory: snapshot.physicalMemory),
      status: "Pressure: " + snapshot.pressure.rawValue)
  }

  private func resourceCard(title: String, value: String, subtitle: String, icon: String,
    key: PerformancePresentation.SortKey, tint: Color, fraction: Double?, status: String) -> some View {
    Button { sort.select(key) } label: {
      VStack(alignment: .leading, spacing: 6) {
        HStack {
          Label(title, systemImage: icon).font(.callout.weight(.semibold)).foregroundStyle(.primary)
          Spacer(minLength: 8)
          Text(status).font(.caption.weight(.medium)).foregroundStyle(tint).lineLimit(1)
        }
        HStack(alignment: .firstTextBaseline) {
          Text(value).font(.system(size: 32, weight: .semibold, design: .rounded)).monospacedDigit()
            .tracking(-0.8).foregroundStyle(AppTheme.ink).lineLimit(1).minimumScaleFactor(0.6)
          Spacer(minLength: 8)
          Image(systemName: sort.key == key && sort.direction == .ascending ? "arrow.up" : "arrow.down")
            .font(.caption.weight(.semibold)).foregroundStyle(sort.key == key ? .primary : .secondary)
        }
        Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.8)
        PerformanceMeter(fraction: fraction, tint: tint).frame(height: 5)
      }
      .frame(minWidth: 210, maxWidth: .infinity, alignment: .leading)
      .padding(14)
      .background(AppTheme.surface, in: RoundedRectangle(cornerRadius: AppTheme.corner))
      .overlay(RoundedRectangle(cornerRadius: AppTheme.corner).strokeBorder(
        sort.key == key || contrast == .increased ? AppTheme.ink.opacity(0.45) : AppTheme.border,
        lineWidth: sort.key == key ? 1.5 : 1))
      .contentShape(RoundedRectangle(cornerRadius: AppTheme.corner))
    }
    .buttonStyle(.plain)
    .help("Sort running apps by highest " + title.lowercased() + " use")
    .accessibilityElement(children: .combine)
    .accessibilityLabel(title + ", " + value + ". " + subtitle + ". " + status)
    .accessibilityHint("Sorts running apps by highest " + title.lowercased() + " use")
    .accessibilityIdentifier("performance-card-" + key.rawValue.lowercased())
  }

  private var freeSpaceMetric: some View {
    supportingMetric("Free disk", value: snapshot.totalBytes > 0 ? ByteFormatter.string(snapshot.freeBytes) : "—", icon: "internaldrive")
  }

  private func supportingMetric(_ title: String, value: String, icon: String) -> some View {
    Label {
      HStack(spacing: 5) { Text(title).foregroundStyle(.secondary); Text(value).foregroundStyle(.primary) }
    } icon: {
      Image(systemName: icon).foregroundStyle(.secondary)
    }
    .font(.callout).monospacedDigit().accessibilityElement(children: .combine)
  }

  private var processCard: some View {
    let rows = appRows
    let displayed = PerformancePresentation.apps(rows, query: search, sort: sort)
    let handles = Dictionary(uniqueKeysWithValues: usages.map { (PerformancePresentation.ProcessID(pid: $0.id, started: $0.started), $0) })
    return SurfaceCard {
      VStack(alignment: .leading, spacing: 8) {
        HStack(spacing: 10) {
          Text("Running apps").font(.headline)
          Text("\(displayed.count) of \(rows.count)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
          Spacer(minLength: 8)
          Label(readingStatus, systemImage: paused ? "pause.circle" : "clock")
            .font(.caption).foregroundStyle(.secondary).help(samplingDetail)
            .accessibilityValue(samplingDetail)
          Button(action: togglePaused) {
            Label(paused ? "Resume" : "Pause", systemImage: paused ? "play.fill" : "pause.fill")
          }
          .controlSize(.small).help(paused ? "Resume live readings" : "Freeze the displayed readings")
          .accessibilityIdentifier("performance-pause")
        }
        Text("Main app processes · helpers not included · 100% CPU = one core")
          .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        HStack(spacing: 12) {
          SearchField(prompt: "Find by app, PID or bundle", text: $search)
          Menu {
            ForEach(PerformancePresentation.SortKey.allCases, id: \.self) { key in
              Button(key.rawValue) { sort.select(key) }
            }
            Divider()
            Button(sort.direction == .descending ? "Sort ascending" : "Sort descending") { sort.select(sort.key, toggle: true) }
          } label: { Label(sort.key.rawValue, systemImage: sort.direction == .descending ? "arrow.down" : "arrow.up") }
            .fixedSize().help(sort.description).accessibilityLabel("Sort running apps").accessibilityValue(sort.description)
        }
        Divider()
        if displayed.isEmpty {
          VStack(spacing: 8) {
            Image(systemName: query.isEmpty ? "waveform.path.ecg" : "magnifyingglass").font(.title2).foregroundStyle(.secondary)
            Text(query.isEmpty ? (paused ? "No apps in this paused sample" : "Waiting for an app sample") : "No matching apps").font(.callout.weight(.medium))
            Text(query.isEmpty ? "\(paused ? "Resume" : "Leave this view open") to measure activity." : "Try an app name, process ID or bundle identifier.")
              .font(.caption).foregroundStyle(.secondary)
            if !query.isEmpty { Button("Clear search") { search = "" }.controlSize(.small) }
          }.frame(maxWidth: .infinity).padding(.vertical, 24)
        } else {
          HStack(spacing: 12) {
            sortHeader(.name).frame(maxWidth: .infinity, alignment: .leading)
            sortHeader(.cpu).frame(width: 96, alignment: .trailing)
            sortHeader(.memory).frame(width: 104, alignment: .trailing)
            Text("Actions").font(.caption).foregroundStyle(.secondary).frame(width: 98, alignment: .trailing)
          }.padding(.horizontal, 10)
          LazyVStack(spacing: 0) {
            ForEach(Array(displayed.enumerated()), id: \.element.id) { index, app in
              processRow(app, usage: handles[app.id])
                .padding(.horizontal, 10).padding(.vertical, 10)
                .background(index.isMultiple(of: 2) ? AppTheme.panel.opacity(0.45) : Color.clear,
                  in: RoundedRectangle(cornerRadius: 9))
                .background {
                  if preview != nil && index < 5 {
                    GeometryReader { geometry in
                      Color.clear.preference(key: WorkspaceLayoutFrames.self,
                        value: ["performance app row \(index)": geometry.frame(in: .global)])
                    }
                  }
                }
            }
          }
        }
        Text("App CPU: 100% = one core and values can exceed 100%. Bars show the share of this Mac's total CPU capacity or installed RAM.")
          .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        Text("MacMint slows sampling in Low Power Mode or when your Mac is hot. Pause freezes this view; an open menu bar panel may continue sampling.")
          .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
      }
    }
  }

  private func sortHeader(_ key: PerformancePresentation.SortKey) -> some View {
    Button { sort.select(key, toggle: true) } label: {
      HStack(spacing: 4) {
        Text(key.rawValue)
        Image(systemName: sort.key == key && sort.direction == .ascending ? "chevron.up" : "chevron.down")
          .opacity(sort.key == key ? 1 : 0.25)
      }.font(.caption.weight(.semibold)).foregroundStyle(sort.key == key ? .primary : .secondary)
    }
    .buttonStyle(.plain).help("Sort by " + key.rawValue.lowercased())
    .accessibilityValue(sort.key == key ? sort.description : "Not selected")
    .accessibilityIdentifier("performance-sort-" + key.rawValue.lowercased())
  }

  private func processRow(_ app: PerformancePresentation.App, usage: SystemMonitor.AppUsage?) -> some View {
    HStack(spacing: 12) {
      HStack(spacing: 10) {
        PerformanceAppIcon(app: app, application: usage?.application)
        VStack(alignment: .leading, spacing: 3) {
          Text(app.name).font(.callout.weight(.medium)).lineLimit(1).truncationMode(.middle)
          Text("PID \(app.id.pid)" + (app.bundleID.map { " · " + $0 } ?? ""))
            .font(.caption2).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
        }
        Spacer(minLength: 0)
      }.frame(maxWidth: .infinity, alignment: .leading)
        .help(app.name + " · PID \(app.id.pid)" + (app.bundleID.map { " · " + $0 } ?? ""))
      VStack(alignment: .trailing, spacing: 5) {
        Text(PerformancePresentation.validCPU(app.cpuPercent).map { String(format: "%.1f%%", $0) } ?? "—")
          .font(.callout.monospacedDigit()).lineLimit(1).minimumScaleFactor(0.7)
        PerformanceMeter(fraction: PerformancePresentation.cpuFraction(app.cpuPercent, logicalCPUCount: logicalCPUCount), tint: AppTheme.info)
          .frame(height: 3)
      }.frame(width: 96)
        .accessibilityElement(children: .ignore).accessibilityLabel("CPU")
        .accessibilityValue(PerformancePresentation.validCPU(app.cpuPercent).map { String(format: "%.1f percent of one core", $0) } ?? "Not measured yet")
      VStack(alignment: .trailing, spacing: 5) {
        Text(app.memoryBytes >= 0 ? ByteFormatter.string(app.memoryBytes) : "—")
          .font(.callout.monospacedDigit()).lineLimit(1).minimumScaleFactor(0.7)
        PerformanceMeter(fraction: PerformancePresentation.memoryFraction(app.memoryBytes, physicalMemory: snapshot.physicalMemory), tint: AppTheme.violet)
          .frame(height: 3)
      }.frame(width: 104)
        .accessibilityElement(children: .ignore).accessibilityLabel("Memory footprint")
        .accessibilityValue(app.memoryBytes >= 0 ? ByteFormatter.string(app.memoryBytes) : "Unavailable")
      HStack(spacing: 5) {
        Button { if let usage { forceQuit = false; pendingQuit = usage } } label: { Label("Quit", systemImage: "power") }
          .controlSize(.small).buttonStyle(.bordered).tint(AppTheme.ink)
          .help("Ask " + app.name + " to quit normally").accessibilityLabel("Quit " + app.name)
        Menu {
          Button("Force Quit…", role: .destructive) { if let usage { forceQuit = true; pendingQuit = usage } }
        } label: { Image(systemName: "ellipsis").accessibilityLabel("More actions for " + app.name) }
          .menuStyle(.borderlessButton).menuIndicator(.hidden).tint(AppTheme.ink)
          .frame(width: 18).accessibilityLabel("More actions for " + app.name)
      }.frame(width: 98, alignment: .trailing)
        .disabled(!(usage?.canControl ?? false))
        .help(usage?.canControl == true ? "Quit or force quit " + app.name : "Process controls are unavailable for this app")
    }
    .accessibilityElement(children: .contain)
    .accessibilityLabel(app.name + ", PID \(app.id.pid)")
  }

  private var diskInsightsCard: some View {
    SurfaceCard {
      VStack(alignment: .leading, spacing: 10) {
        Label("Disk insights", systemImage: "internaldrive").font(.headline)
        if let insights {
          insightRow(
            "Drive health",
            value: insights.health?.rawValue ?? "Unknown",
            detail: insights.health == .failing
              ? "The drive reports it may fail soon. Back up now with Time Machine."
              : "Reported by the drive's self-monitoring (SMART).",
            tint: insights.health == .failing ? AppTheme.danger : insights.health == .verified ? AppTheme.accentText : .secondary)
          if let fs = insights.fileSystem {
            insightRow("File system", value: fs, detail: "Copies of a file on APFS can share space, so freed space may be less than a file's size.", tint: .secondary)
          }
          if let purgeable = insights.purgeableBytes {
            insightRow(
              "Purgeable", value: ByteFormatter.string(purgeable),
              detail: "macOS frees this automatically when an app needs room — no cleaning needed.",
              tint: AppTheme.accentText)
          }
          insightRow(
            "Local snapshots",
            value: insights.snapshotsReadable ? "\(insights.localSnapshots.count)" : "Unavailable",
            detail: insights.localSnapshots.first.map {
              "Time Machine keeps these hourly copies on this disk and removes them by itself as space is needed (oldest \($0.formatted(date: .abbreviated, time: .shortened)))."
            } ?? "Time Machine snapshots stored on this disk, managed by macOS.",
            tint: .secondary)
        } else {
          ProgressView().controlSize(.small)
        }
      }
    }
  }

  private func insightRow(_ title: String, value: String, detail: String, tint: Color) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 12) {
      VStack(alignment: .leading, spacing: 2) {
        Text(title).font(.callout.weight(.medium))
        Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
      }
      Spacer()
      Text(value).font(.callout.weight(.semibold)).foregroundStyle(tint)
    }
    .accessibilityElement(children: .combine)
  }

  private var pressureTint: Color {
    switch snapshot.pressure {
    case .normal: return AppTheme.info
    case .warning: return AppTheme.warning
    case .critical: return AppTheme.danger
    case .unknown: return .secondary
    }
  }
}

private struct PerformanceMeter: View {
  let fraction: Double?
  let tint: Color
  var body: some View {
    GeometryReader { proxy in
      ZStack(alignment: .leading) {
        Capsule().fill(AppTheme.panel)
        if let fraction { Capsule().fill(tint).frame(width: proxy.size.width * fraction) }
      }
    }.accessibilityHidden(true)
  }
}

private struct PerformanceAppIcon: View {
  let app: PerformancePresentation.App
  let application: NSRunningApplication?
  @State private var icon: NSImage?
  var body: some View {
    Group {
      if let icon { Image(nsImage: icon).resizable().scaledToFit() }
      else { Image(systemName: app.fallbackSymbol).font(.system(size: 20)).foregroundStyle(.secondary) }
    }
    .frame(width: 30, height: 30).accessibilityHidden(true)
    .task(id: app.id) {
      icon = application.flatMap { PerformanceIconCache.shared.icon(for: $0) }
    }
  }
}

/// Small icons only, capped at 64 entries / 2 MiB. No repeated filesystem work or
/// full-resolution app artwork is retained by a live process row.
@MainActor
private final class PerformanceIconCache {
  static let shared = PerformanceIconCache()
  private let cache = NSCache<NSString, NSImage>()
  private init() { cache.countLimit = 64; cache.totalCostLimit = 2 * 1024 * 1024 }
  func icon(for app: NSRunningApplication) -> NSImage? {
    let key = (app.bundleURL?.path ?? app.bundleIdentifier ?? String(app.processIdentifier)) as NSString
    if let icon = cache.object(forKey: key) { return icon }
    guard let source = app.icon,
      let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 64, pixelsHigh: 64, bitsPerSample: 8,
        samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 256, bitsPerPixel: 32),
      let context = NSGraphicsContext(bitmapImageRep: bitmap) else { return nil }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    source.draw(in: NSRect(x: 0, y: 0, width: 64, height: 64), from: .zero, operation: .sourceOver, fraction: 1)
    NSGraphicsContext.restoreGraphicsState()
    let icon = NSImage(size: NSSize(width: 32, height: 32))
    icon.addRepresentation(bitmap)
    cache.setObject(icon, forKey: key, cost: 64 * 64 * 4)
    return icon
  }
}
