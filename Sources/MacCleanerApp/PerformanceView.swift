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
  var taming: SystemMonitor.TamingDisplay? = nil
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
  @Environment(\.performancePreview) private var preview
  @State private var pendingQuit: SystemMonitor.AppUsage?
  @State private var monitoringLease = UUID()
  @State private var pausedReading: SystemMonitor.Reading?
  @State private var previewPaused: Bool?
  @State private var search = ""
  @State private var sort = PerformancePresentation.Sort()
  @State private var forceQuit = false
  @State private var insights: DiskInsights?
  @State private var showingExceptions = false

  private var paused: Bool { preview.map { previewPaused ?? $0.paused } ?? (pausedReading != nil) }
  private var tamingDisplay: SystemMonitor.TamingDisplay { preview?.taming ?? monitor.taming }
  private var feed: PerformanceFeed {
    PerformanceFeed(preview: preview, frozen: pausedReading, paused: paused,
      logicalCPUCount: preview?.logicalCPUCount ?? ProcessInfo.processInfo.processorCount,
      samplingInterval: preview == nil ? (monitor.samplingInterval ?? 4) : 4)
  }

  var body: some View {
    let feed = self.feed
    ScrollView {
      LazyVStack(alignment: .leading, spacing: 18) {
        PageHeader("Performance", subtitle: "See what is busy, find the app, and decide what to do.")
        PerformanceCards(live: monitor.live, feed: feed, sort: sort) { sort.select($0) }
        processCard(feed)
        PerformanceSupportingMetrics(live: monitor.live, feed: feed)
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
    // Sampling follows this screen; the monitor itself pauses window leases while the
    // workspace is hidden, inactive, minimized or covered.
    .onAppear { updateMonitoring() }
    .onChange(of: paused) { _, _ in updateMonitoring() }
    .task { if preview == nil { insights = await DiskInsightsService.cached() } }
    .onDisappear { monitor.stop(lease: monitoringLease) }
    .sheet(isPresented: $showingExceptions) { TamingExceptionsView().environmentObject(monitor) }
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
    if !paused { monitor.start(lease: monitoringLease) }
    else { monitor.stop(lease: monitoringLease) }
  }

  private func togglePaused() {
    if let preview { previewPaused = !(previewPaused ?? preview.paused) }
    else { pausedReading = paused ? nil : monitor.live.reading }
  }

  /// Handles are resolved when an action runs, from the reading on screen.
  private func usage(_ id: PerformancePresentation.ProcessID) -> SystemMonitor.AppUsage? {
    guard preview == nil else { return nil }
    return (pausedReading ?? monitor.live.reading).apps.first { $0.id == id.pid && $0.started == id.started }
  }

  private var rowActions: PerformanceRowActions {
    PerformanceRowActions(
      slow: { id, duration in if let usage = usage(id) { monitor.slowApp(usage, duration: duration) } },
      restore: { id in if let usage = usage(id) { monitor.restoreApp(usage) } },
      quit: { id, force in if let usage = usage(id) { forceQuit = force; pendingQuit = usage } },
      neverSlow: { bundleID, name, protected in monitor.setNeverSlow(bundleID: bundleID, name: name, protected: protected) })
  }

  private func processCard(_ feed: PerformanceFeed) -> some View {
    SurfaceCard {
      VStack(alignment: .leading, spacing: 8) {
        HStack(spacing: 10) {
          Text("Running apps").font(.headline)
          PerformanceLiveText(live: monitor.live, feed: feed, kind: .count(query: search))
          Spacer(minLength: 8)
          Toggle("Auto Tame", isOn: Binding(get: { tamingDisplay.automatic }, set: { monitor.setAutomaticTaming($0) }))
            .toggleStyle(.switch).controlSize(.small).fixedSize().disabled(preview != nil)
            .help("Lower priority for sustained background CPU load. The foreground app and exceptions are protected.")
          Menu {
            Button("Restore all & turn off Auto Tame") { monitor.restoreAllApps() }
              .disabled(monitor.taming.state.receipts.isEmpty && !monitor.taming.automatic)
            Button("Never slow down…") { showingExceptions = true }
          } label: { Image(systemName: "slider.horizontal.3").accessibilityLabel("Slowdown settings") }
            .menuStyle(.borderlessButton).fixedSize().disabled(preview != nil)
          Button(action: togglePaused) {
            Label(paused ? "Resume" : "Pause", systemImage: paused ? "play.fill" : "pause.fill")
          }
          .controlSize(.small).help(paused ? "Resume live readings" : "Freeze the displayed readings")
          .accessibilityIdentifier("performance-pause")
        }
        PerformanceLiveText(live: monitor.live, feed: feed, kind: .status)
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
        PerformanceProcessRows(live: monitor.live, feed: feed, query: search, sort: sort, taming: tamingDisplay.state,
          actions: rowActions, clearSearch: { search = "" }, selectSort: { sort.select($0, toggle: true) })
        Text("App CPU: 100% = one core and values can exceed 100%. Bars show the share of this Mac's total CPU capacity or installed RAM.")
          .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        Text("Slowdown lowers CPU, disk and network priority, not a CPU/RAM cap. Auto Tame checks sustained background load every ~8 seconds; foreground apps and exceptions stay protected. Pause freezes readings; enabled controls continue in the background.")
          .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        if let message = tamingDisplay.message {
          Text(message).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
        }
      }
    }
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
}

/// What the live subviews display: a scene fixture, a frozen reading, or the monitor's.
private struct PerformanceFeed {
  let preview: PerformancePreview?
  let frozen: SystemMonitor.Reading?
  let paused: Bool
  let logicalCPUCount: Int
  let samplingInterval: TimeInterval

  @MainActor func reading(_ live: SystemMonitor.LiveReadings) -> SystemMonitor.Reading {
    frozen ?? live.reading
  }
  @MainActor func snapshot(_ live: SystemMonitor.LiveReadings) -> SystemMonitor.Snapshot {
    preview?.snapshot ?? reading(live).snapshot
  }
  @MainActor func sampledAt(_ live: SystemMonitor.LiveReadings) -> Date? {
    preview.map(\.sampledAt) ?? reading(live).sampledAt
  }
  @MainActor func apps(_ live: SystemMonitor.LiveReadings) -> [PerformancePresentation.App] {
    preview?.apps ?? reading(live).apps.map { app in
      .init(id: .init(pid: app.id, started: app.started), name: app.name, bundleID: app.bundleID,
        memoryBytes: app.memoryBytes, cpuPercent: app.cpuPercent)
    }
  }
  @MainActor func controllable(_ live: SystemMonitor.LiveReadings) -> Set<PerformancePresentation.ProcessID> {
    guard preview == nil else { return [] }
    return Set(reading(live).apps.filter(\.canControl).map { PerformancePresentation.ProcessID(pid: $0.id, started: $0.started) })
  }
  @MainActor func applications(_ live: SystemMonitor.LiveReadings) -> [PerformancePresentation.ProcessID: NSRunningApplication] {
    guard preview == nil else { return [:] }
    return Dictionary(reading(live).apps.map { (PerformancePresentation.ProcessID(pid: $0.id, started: $0.started), $0.application) },
      uniquingKeysWith: { first, _ in first })
  }
}

@MainActor
struct PerformanceRowActions {
  let slow: (PerformancePresentation.ProcessID, TimeInterval) -> Void
  let restore: (PerformancePresentation.ProcessID) -> Void
  let quit: (PerformancePresentation.ProcessID, Bool) -> Void
  let neverSlow: (String, String, Bool) -> Void
}

private struct PerformanceCards: View {
  @ObservedObject var live: SystemMonitor.LiveReadings
  let feed: PerformanceFeed
  let sort: PerformancePresentation.Sort
  let select: (PerformancePresentation.SortKey) -> Void

  var body: some View {
    let snapshot = feed.snapshot(live)
    let cpuFraction = PerformancePresentation.fraction(snapshot.cpuUsage, capacity: 1)
    let used = snapshot.memoryUsedBytes.flatMap { $0 >= 0 ? $0 : nil }
    let cpu = PerformanceResourceCard(title: "CPU", value: cpuFraction.map { "\(Int(($0 * 100).rounded()))%" } ?? "—",
      subtitle: "Whole Mac · \(feed.logicalCPUCount) logical cores", icon: "cpu", key: .cpu, tint: AppTheme.info,
      fraction: PerformancePresentation.quantized(cpuFraction),
      status: cpuFraction == nil ? "CPU reading unavailable" : "Across all cores", sort: sort, select: select)
    let memory = PerformanceResourceCard(title: "Memory", value: used.map(ByteFormatter.string) ?? "—",
      subtitle: snapshot.physicalMemory > 0 ? "of \(ByteFormatter.string(snapshot.physicalMemory)) installed RAM" : "Installed RAM unavailable",
      icon: "memorychip", key: .memory, tint: Self.pressureTint(snapshot.pressure),
      fraction: PerformancePresentation.quantized(PerformancePresentation.memoryFraction(used, physicalMemory: snapshot.physicalMemory)),
      status: "Pressure: " + snapshot.pressure.rawValue, sort: sort, select: select)
    ViewThatFits(in: .horizontal) {
      HStack(alignment: .top, spacing: 14) { cpu.equatable(); memory.equatable() }
      VStack(spacing: 14) { cpu.equatable(); memory.equatable() }
    }
  }

  static func pressureTint(_ pressure: SystemMonitor.Pressure) -> Color {
    switch pressure {
    case .normal: return AppTheme.info
    case .warning: return AppTheme.warning
    case .critical: return AppTheme.danger
    case .unknown: return .secondary
    }
  }
}

private struct PerformanceResourceCard: View, Equatable {
  let title: String
  let value: String
  let subtitle: String
  let icon: String
  let key: PerformancePresentation.SortKey
  let tint: Color
  let fraction: Double?
  let status: String
  let sort: PerformancePresentation.Sort
  let select: (PerformancePresentation.SortKey) -> Void
  @Environment(\.colorSchemeContrast) private var contrast

  nonisolated static func == (left: Self, right: Self) -> Bool {
    left.title == right.title && left.value == right.value && left.subtitle == right.subtitle && left.tint == right.tint
      && left.fraction == right.fraction && left.status == right.status && left.sort == right.sort
  }

  private var selected: Bool { sort.key == key }

  private var face: some View {
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
        Image(systemName: selected && sort.direction == .ascending ? "arrow.up" : "arrow.down")
          .font(.caption.weight(.semibold)).foregroundStyle(selected ? Color.primary : Color.secondary)
      }
      Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.8)
      PerformanceMeter(fraction: fraction, tint: tint).frame(height: 5)
    }
  }

  var body: some View {
    let shape = RoundedRectangle(cornerRadius: AppTheme.corner)
    let stroke: Color = selected || contrast == .increased ? AppTheme.ink.opacity(0.45) : AppTheme.border
    let hint: String = "Sorts running apps by highest \(title.lowercased()) use"
    let label: String = "\(title), \(value). \(subtitle). \(status)"
    let identifier: String = "performance-card-\(key.rawValue.lowercased())"
    Button { select(key) } label: {
      face
        .frame(minWidth: 210, maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(AppTheme.surface, in: shape)
        .overlay(shape.strokeBorder(stroke, lineWidth: selected ? 1.5 : 1))
        .contentShape(shape)
    }
    .buttonStyle(.plain)
    .help("Sort running apps by highest \(title.lowercased()) use")
    .accessibilityElement(children: .combine)
    .accessibilityLabel(label)
    .accessibilityHint(hint)
    .accessibilityIdentifier(identifier)
  }
}

private struct PerformanceSupportingMetrics: View {
  @ObservedObject var live: SystemMonitor.LiveReadings
  let feed: PerformanceFeed

  var body: some View {
    let snapshot = feed.snapshot(live)
    let swap = snapshot.swapUsedBytes.map(ByteFormatter.string) ?? "—"
    let free = snapshot.totalBytes > 0 ? ByteFormatter.string(snapshot.freeBytes) : "—"
    ViewThatFits(in: .horizontal) {
      HStack(spacing: 18) { metric("Swap", value: swap, icon: "arrow.left.arrow.right"); metric("Free disk", value: free, icon: "internaldrive") }
      VStack(alignment: .leading, spacing: 8) { metric("Swap", value: swap, icon: "arrow.left.arrow.right"); metric("Free disk", value: free, icon: "internaldrive") }
    }
  }

  private func metric(_ title: String, value: String, icon: String) -> some View {
    Label {
      HStack(spacing: 5) { Text(title).foregroundStyle(.secondary); Text(value).foregroundStyle(.primary) }
    } icon: {
      Image(systemName: icon).foregroundStyle(.secondary)
    }
    .font(.callout).monospacedDigit().accessibilityElement(children: .combine)
  }
}

/// The two short texts in the process card that change with each sample.
private struct PerformanceLiveText: View {
  enum Kind { case count(query: String), status }
  @ObservedObject var live: SystemMonitor.LiveReadings
  let feed: PerformanceFeed
  let kind: Kind

  var body: some View {
    switch kind {
    case .count(let query):
      let apps = feed.apps(live)
      Text("\(PerformancePresentation.matchCount(apps, query: query)) of \(apps.count)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
    case .status:
      let sampledAt = feed.sampledAt(live)
      let time = sampledAt?.formatted(date: .omitted, time: .standard)
      let state = feed.paused ? "Paused" : (sampledAt == nil ? "Measuring" : "Live")
      let reading: String = time.map { "\(state) · \($0)" } ?? state
      let detail: String = Self.detail(time: time, paused: feed.paused, interval: feed.samplingInterval)
      Text("Main processes · helpers not included · \(reading)")
        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        .help(detail)
    }
  }

  private static func detail(time: String?, paused: Bool, interval: TimeInterval) -> String {
    guard let time else {
      return paused ? "Paused before the first sample. Resume to measure activity." : "Measuring app activity…"
    }
    return paused ? "Readings frozen at \(time). Quit still checks the current process before acting."
      : "Updated \(time) · refreshes about every \(Int(interval)) seconds"
  }
}

private struct PerformanceProcessRows: View {
  @ObservedObject var live: SystemMonitor.LiveReadings
  let feed: PerformanceFeed
  let query: String
  let sort: PerformancePresentation.Sort
  let taming: TamingState
  let actions: PerformanceRowActions
  let clearSearch: () -> Void
  let selectSort: (PerformancePresentation.SortKey) -> Void
  @State private var cache = PerformancePresentation.RowCache()

  var body: some View {
    let snapshot = feed.snapshot(live)
    let rows = cache.rows(.init(apps: feed.apps(live), query: query, sort: sort, taming: taming,
      physicalMemory: snapshot.physicalMemory, logicalCPUCount: feed.logicalCPUCount, controllable: feed.controllable(live)))
    let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
    if rows.isEmpty {
      VStack(spacing: 8) {
        Image(systemName: trimmed.isEmpty ? "waveform.path.ecg" : "magnifyingglass").font(.title2).foregroundStyle(.secondary)
        Text(trimmed.isEmpty ? (feed.paused ? "No apps in this paused sample" : "Waiting for an app sample") : "No matching apps").font(.callout.weight(.medium))
        Text(trimmed.isEmpty ? "\(feed.paused ? "Resume" : "Leave this view open") to measure activity." : "Try an app name, process ID or bundle identifier.")
          .font(.caption).foregroundStyle(.secondary)
        if !trimmed.isEmpty { Button("Clear search", action: clearSearch).controlSize(.small) }
      }.frame(maxWidth: .infinity).padding(.vertical, 24)
    } else {
      let applications = feed.applications(live)
      PerformanceColumnHeader(sort: sort, select: selectSort).equatable()
      LazyVStack(spacing: 0) {
        ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
          PerformanceRowView(row: row, application: applications[row.id], actions: actions)
            .equatable()
            .background {
              if feed.preview != nil && index < 5 {
                GeometryReader { geometry in
                  Color.clear.preference(key: WorkspaceLayoutFrames.self,
                    value: ["performance app row \(index)": geometry.frame(in: .global)])
                }
              }
            }
        }
      }
    }
  }
}

private struct PerformanceColumnHeader: View, Equatable {
  let sort: PerformancePresentation.Sort
  let select: (PerformancePresentation.SortKey) -> Void
  nonisolated static func == (left: Self, right: Self) -> Bool { left.sort == right.sort }

  var body: some View {
    HStack(spacing: 12) {
      header(.name).frame(maxWidth: .infinity, alignment: .leading)
      header(.cpu).frame(width: 96, alignment: .trailing)
      header(.memory).frame(width: 104, alignment: .trailing)
      Text("Actions").font(.caption).foregroundStyle(.secondary).frame(width: 182, alignment: .trailing)
    }.padding(.horizontal, 10)
  }

  private func header(_ key: PerformancePresentation.SortKey) -> some View {
    Button { select(key) } label: {
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
}

/// Equal rows are skipped entirely; the action menus sit in their own equatable view, so
/// changing numbers never rebuild them.
private struct PerformanceRowView: View, Equatable {
  let row: PerformancePresentation.Row
  let application: NSRunningApplication?
  let actions: PerformanceRowActions
  // The row ID carries the PID and kernel start time, so it identifies the same process.
  nonisolated static func == (left: Self, right: Self) -> Bool { left.row == right.row }

  var body: some View {
    HStack(spacing: 12) {
      HStack(spacing: 10) {
        PerformanceAppIcon(id: row.id, fallbackSymbol: row.fallbackSymbol, application: application)
        VStack(alignment: .leading, spacing: 3) {
          Text(row.name).font(.callout.weight(.medium)).lineLimit(1).truncationMode(.middle)
          Text(row.detail)
            .font(.caption2).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
        }
        Spacer(minLength: 0)
      }.frame(maxWidth: .infinity, alignment: .leading)
        .help(row.help)
      PerformanceMetricCell(text: row.cpuText, fraction: row.cpuFraction, tint: AppTheme.info,
        label: "CPU", value: row.cpuAccessibility).frame(width: 96)
      PerformanceMetricCell(text: row.memoryText, fraction: row.memoryFraction, tint: AppTheme.violet,
        label: "Memory footprint", value: row.memoryAccessibility).frame(width: 104)
      PerformanceRowControls(control: row.control, actions: actions).equatable()
    }
    .accessibilityElement(children: .contain)
    .accessibilityLabel(row.name + ", PID \(row.id.pid)")
    .padding(.horizontal, 10).padding(.vertical, 10)
    .background(row.stripe ? AppTheme.panel.opacity(0.45) : Color.clear, in: RoundedRectangle(cornerRadius: 9))
  }
}

private struct PerformanceMetricCell: View {
  let text: String
  let fraction: Double?
  let tint: Color
  let label: String
  let value: String

  var body: some View {
    VStack(alignment: .trailing, spacing: 5) {
      Text(text).font(.callout.monospacedDigit()).lineLimit(1).minimumScaleFactor(0.7)
      PerformanceMeter(fraction: fraction, tint: tint).frame(height: 3)
    }
    .accessibilityElement(children: .ignore).accessibilityLabel(label).accessibilityValue(value)
  }
}

private struct PerformanceRowControls: View, Equatable {
  let control: PerformancePresentation.Control
  let actions: PerformanceRowActions
  nonisolated static func == (left: Self, right: Self) -> Bool { left.control == right.control }

  var body: some View {
    let id = control.id, name = control.name
    HStack(spacing: 5) {
      if control.slowed {
        Button("Restore") { actions.restore(id) }
          .controlSize(.small).help("Restore normal priority for " + name)
      } else {
        Menu {
          Button("Slow for 15 minutes") { actions.slow(id, 900) }
          Button("Slow for 1 hour") { actions.slow(id, 3600) }
        } label: { Text(control.excepted ? "Protected" : "Slow") }
          .menuStyle(.borderlessButton).fixedSize().disabled(control.excepted)
          .accessibilityLabel("Slow down " + name)
          .help("Lower CPU, disk and network priority until expiry or until you switch to this app")
      }
      Button { actions.quit(id, false) } label: { Label("Quit", systemImage: "power") }
        .controlSize(.small).buttonStyle(.bordered).tint(AppTheme.ink)
        .help("Ask " + name + " to quit normally").accessibilityLabel("Quit " + name)
      Menu {
        if let bundleID = control.bundleID {
          Button(control.excepted ? "Allow slowdown" : "Never slow down this app") {
            actions.neverSlow(bundleID, name, !control.excepted)
          }
        }
        Divider()
        Button("Force Quit…", role: .destructive) { actions.quit(id, true) }
      } label: { Image(systemName: "ellipsis").accessibilityLabel("More actions for " + name) }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).tint(AppTheme.ink)
        .frame(width: 18).accessibilityLabel("More actions for " + name)
    }.frame(width: 182, alignment: .trailing)
      .disabled(!control.canControl)
      .help(control.canControl ? "Quit or force quit " + name : "Process controls are unavailable for this app")
  }
}

private struct TamingExceptionsView: View {
  @EnvironmentObject private var monitor: SystemMonitor
  @Environment(\.dismiss) private var dismiss
  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text("Never slow down").font(.title2.bold())
      Text("Exceptions apply to manual slowdown and Auto Tame, including after an app relaunch. Adding an exception restores any current slowdown.")
        .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
      List {
        ForEach(monitor.taming.state.exceptions.keys.sorted(), id: \.self) { id in
          HStack {
            VStack(alignment: .leading) {
              Text(monitor.taming.state.exceptions[id] ?? id).fontWeight(.medium)
              Text(id).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Remove") { monitor.setNeverSlow(bundleID: id, name: "", protected: false) }
          }
        }
        if monitor.taming.state.exceptions.isEmpty {
          Text("No saved exceptions. Add one from an app's ••• menu.").foregroundStyle(.secondary)
        }
      }.frame(minHeight: 160, maxHeight: 260)
      Text("Auto Tame is off at each MacMint launch. It waits for ≥80% of one core for 20 seconds while overall CPU is ≥65%, affects at most two background main processes, and restores after cooling or five minutes. System and common calling/audio apps are excluded automatically.")
        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
      HStack { Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.defaultAction) }
    }.padding(24).frame(width: 540).background(AppTheme.canvas)
  }
}

/// A fill scaled inside a fixed track: value changes redraw without a layout pass or a
/// GeometryReader per bar.
private struct PerformanceMeter: View {
  let fraction: Double?
  let tint: Color
  var body: some View {
    Capsule().fill(AppTheme.panel)
      .overlay(alignment: .leading) {
        if let fraction {
          Rectangle().fill(tint).scaleEffect(x: min(1, max(0, fraction)), y: 1, anchor: .leading)
        }
      }
      .clipShape(Capsule())
      .accessibilityHidden(true)
  }
}

private struct PerformanceAppIcon: View {
  let id: PerformancePresentation.ProcessID
  let fallbackSymbol: String
  let application: NSRunningApplication?
  @State private var icon: NSImage?
  var body: some View {
    Group {
      if let icon { Image(nsImage: icon).resizable().scaledToFit() }
      else { Image(systemName: fallbackSymbol).font(.system(size: 20)).foregroundStyle(.secondary) }
    }
    .frame(width: 30, height: 30).accessibilityHidden(true)
    .task(id: id) {
      icon = application.flatMap { PerformanceIconCache.shared.icon(for: $0) }
    }
  }
}

/// Small icons only, capped at 64 entries / 2 MiB. No repeated filesystem work or
/// full-resolution app artwork is retained by a live process row.
@MainActor
final class PerformanceIconCache {
  static let shared = PerformanceIconCache()
  private let cache = PreviewImageCache(byteLimit: 2 * 1024 * 1024, countLimit: 64)
  private init() {}
  func removeAll() { cache.removeAll() }
  func icon(for app: NSRunningApplication) -> NSImage? {
    let key = app.bundleURL?.path ?? app.bundleIdentifier ?? String(app.processIdentifier)
    if let icon = cache.image(for: key) { return icon }
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
    cache.insert(icon, for: key)
    return icon
  }
}
