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
  @Environment(\.areaSwatch) private var swatch
  @Environment(\.areaSymbol) private var areaSymbol
  @State private var pendingQuit: SystemMonitor.AppUsage?
  @State private var monitoringLease = UUID()
  @State private var pausedReading: SystemMonitor.Reading?
  @State private var previewPaused: Bool?
  @State private var search = ""
  @State private var sort = PerformancePresentation.Sort()
  @State private var forceQuit = false
  @State private var insights: DiskInsights?
  @State private var showingExceptions = false
  @State private var expandedRows: Set<PerformancePresentation.ProcessID> = []

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
      LazyVStack(alignment: .leading, spacing: 12) {
        header(feed)
        PerformanceCards(live: monitor.live, feed: feed, sort: sort) { sort.select($0) }
        processCard(feed)
        explainer
        insightsAndActions
      }
      .frame(maxWidth: 1180)
      .padding(.horizontal, 24).padding(.top, 16).padding(.bottom, 28)
      .frame(maxWidth: .infinity)
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

  private struct Meaning: Sendable {
    let title: String
    let detail: String
    let icon: String
    let swatch: AppTheme.Swatch
  }
  /// Short, plain explanations: memory and disk space are different things.
  private static let meanings: [Meaning] = [
    Meaning(title: "Memory (RAM) is your desk", detail: "It holds the apps and windows you have open right now. macOS keeps it nearly full on purpose; the pressure label tells you when it is actually short.",
      icon: "memorychip", swatch: .violet),
    Meaning(title: "Swap is overflow onto the disk", detail: "When memory is short, macOS moves some of it to the SSD. A few GB is normal. If swap keeps growing while pressure stays Elevated or High, close something you are not using.",
      icon: "arrow.left.arrow.right", swatch: .amber),
    Meaning(title: "Disk space (SSD) is your filing cabinet", detail: "It stores files and apps. More free space does not make apps faster, but very little free space slows updates, builds and swap.",
      icon: "internaldrive", swatch: .indigo),
    Meaning(title: "CPU is how hard the Mac is working", detail: "Short bursts during builds or photo analysis are normal. One app at 100% is using one of this Mac's cores.",
      icon: "cpu", swatch: .sky),
  ]

  // MARK: Header

  /// A 36 pt header: badge, title, a static Live indicator and Pause.
  private func header(_ feed: PerformanceFeed) -> some View {
    HStack(spacing: 12) {
      SwatchBadge(symbol: areaSymbol, swatch: swatch, size: 36, glow: true)
      VStack(alignment: .leading, spacing: 1) {
        Text("Performance").font(.system(size: 21, weight: .bold)).tracking(-0.5)
          .foregroundStyle(AppTheme.ink).lineLimit(1).accessibilityAddTraits(.isHeader)
        Text("See what is busy, find the app, and decide what to do.")
          .font(.system(size: 12.5)).foregroundStyle(AppTheme.ink2).lineLimit(1).truncationMode(.tail)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      PerformanceLiveText(live: monitor.live, feed: feed, kind: .status)
        .padding(.horizontal, 10).frame(height: 26)
        .background { Capsule().fill(AppTheme.surface).elevation(.card) }
        .fixedSize()
      Button(action: togglePaused) {
        Label(paused ? "Resume" : "Pause", systemImage: paused ? "play.fill" : "pause.fill").labelStyle(.titleAndIcon)
      }
      .buttonStyle(MintButtonStyle(.secondary)).controlSize(.small).fixedSize()
      .help(paused ? "Resume live readings" : "Freeze the displayed readings")
      .accessibilityIdentifier("performance-pause")
    }
    .frame(minHeight: 36)
  }

  // MARK: Explainer and support

  /// Four colored "what these numbers mean" cards: one row when there is room, else two by two.
  private var explainer: some View {
    ViewThatFits(in: .horizontal) {
      HStack(alignment: .top, spacing: 10) {
        ForEach(Self.meanings, id: \.title) { meaning in meaningCard(meaning) }
      }
      .fixedSize(horizontal: false, vertical: true)
      Grid(horizontalSpacing: 10, verticalSpacing: 10) {
        GridRow { meaningCard(Self.meanings[0]); meaningCard(Self.meanings[1]) }
        GridRow { meaningCard(Self.meanings[2]); meaningCard(Self.meanings[3]) }
      }
      .fixedSize(horizontal: false, vertical: true)
    }
  }

  private func meaningCard(_ meaning: Meaning) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      Image(systemName: meaning.icon).font(.system(size: 14, weight: .semibold)).symbolVariant(.fill)
        .foregroundStyle(meaning.swatch.text).frame(width: 30, height: 30)
        .background(meaning.swatch.tint, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .accessibilityHidden(true)
      Text(meaning.title).font(.system(size: 13, weight: .semibold)).foregroundStyle(AppTheme.ink)
        .fixedSize(horizontal: false, vertical: true)
      Text(meaning.detail).font(.system(size: 12)).foregroundStyle(AppTheme.ink2).lineSpacing(1.5)
        .fixedSize(horizontal: false, vertical: true)
    }
    .padding(14)
    .frame(minWidth: 200, idealWidth: 200, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .cardBackground(radius: 14)
    .accessibilityElement(children: .combine)
  }

  /// Disk insights and "When to take action" side by side, stacked when narrow.
  private var insightsAndActions: some View {
    ViewThatFits(in: .horizontal) {
      HStack(alignment: .top, spacing: 10) { diskInsightsCard; actionCard }
        .fixedSize(horizontal: false, vertical: true)
      VStack(alignment: .leading, spacing: 10) { diskInsightsCard; actionCard }
    }
  }

  private var actionCard: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("When to take action").font(.system(size: 14, weight: .bold)).tracking(-0.2)
        .foregroundStyle(AppTheme.ink).accessibilityAddTraits(.isHeader)
      Text("Short CPU spikes during builds or photo analysis are normal. Quit unused apps when memory pressure stays Elevated or High. High memory use by itself is normal: macOS keeps useful caches in RAM.")
        .font(.system(size: 12.5)).foregroundStyle(AppTheme.ink2).lineSpacing(2).fixedSize(horizontal: false, vertical: true)
      Text("Each app's numbers include the helper processes it started, such as browser tabs and editor extensions; open an app's breakdown to see them. MacMint does not purge memory. For processes macOS starts on an app's behalf and detailed diagnostics, open Activity Monitor.")
        .font(.system(size: 11.5)).foregroundStyle(AppTheme.ink3).lineSpacing(1.5).fixedSize(horizontal: false, vertical: true)
      HStack(spacing: 6) {
        Button("Open Activity Monitor") { model.openActivityMonitor() }
          .buttonStyle(MintButtonStyle(.secondary))
        Button("Review Storage") { model.selectedSection = .storage }
          .buttonStyle(MintButtonStyle(.plain))
      }
      .controlSize(.small).padding(.top, 2)
    }
    .padding(.horizontal, 16).padding(.vertical, 14)
    .frame(minWidth: 320, idealWidth: 320, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .cardBackground(radius: 14)
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
      neverSlow: { bundleID, name, protected in monitor.setNeverSlow(bundleID: bundleID, name: name, protected: protected) },
      toggleBreakdown: { id in
        if expandedRows.contains(id) { expandedRows.remove(id) } else { expandedRows.insert(id) }
      })
  }

  // MARK: Running apps

  private func processCard(_ feed: PerformanceFeed) -> some View {
    VStack(alignment: .leading, spacing: 0) {
      listHeader(feed)
        .padding(.leading, 16).padding(.trailing, 12).padding(.vertical, 10)
        .overlay(alignment: .bottom) { Rectangle().fill(AppTheme.divider).frame(height: 1) }
      PerformanceProcessRows(live: monitor.live, feed: feed, query: search, sort: sort, taming: tamingDisplay.state,
        expanded: expandedRows, actions: rowActions, clearSearch: { search = "" }, selectSort: { sort.select($0, toggle: true) })
      footnotes
        .padding(.horizontal, 16).padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .top) { Rectangle().fill(AppTheme.divider).frame(height: 1) }
    }
    .cardBackground()
  }

  /// Title, count and sort on the left; search, Auto Tame and settings on the right. The
  /// search field drops to its own line when the window is narrow.
  private func listHeader(_ feed: PerformanceFeed) -> some View {
    ViewThatFits(in: .horizontal) {
      HStack(spacing: 10) {
        listTitle(feed)
        Spacer(minLength: 8)
        SearchField(prompt: "Find by app, PID or bundle", text: $search).frame(width: 220)
        tamingControls
      }
      VStack(alignment: .leading, spacing: 8) {
        HStack(spacing: 10) {
          listTitle(feed)
          Spacer(minLength: 8)
          tamingControls
        }
        SearchField(prompt: "Find by app, PID or bundle", text: $search)
      }
    }
  }

  private func listTitle(_ feed: PerformanceFeed) -> some View {
    HStack(spacing: 8) {
      Text("Running apps").font(.system(size: 14, weight: .bold)).tracking(-0.2)
        .foregroundStyle(AppTheme.ink).lineLimit(1).accessibilityAddTraits(.isHeader)
      PerformanceLiveText(live: monitor.live, feed: feed, kind: .count(query: search))
      Menu {
        ForEach(PerformancePresentation.SortKey.allCases, id: \.self) { key in
          Button(key.rawValue) { sort.select(key) }
        }
        Divider()
        Button(sort.direction == .descending ? "Sort ascending" : "Sort descending") { sort.select(sort.key, toggle: true) }
      } label: { Label(sort.key.rawValue, systemImage: sort.direction == .descending ? "arrow.down" : "arrow.up") }
        .menuStyle(.borderlessButton).font(.system(size: 12, weight: .medium)).fixedSize()
        .help(sort.description).accessibilityLabel("Sort running apps").accessibilityValue(sort.description)
    }
    .fixedSize()
  }

  private var tamingControls: some View {
    HStack(spacing: 8) {
      Toggle("Auto Tame", isOn: Binding(get: { tamingDisplay.automatic }, set: { monitor.setAutomaticTaming($0) }))
        .toggleStyle(.switch).controlSize(.small).fixedSize().disabled(preview != nil)
        .font(.system(size: 12, weight: .medium))
        .help("Lower priority for sustained background CPU load. The foreground app and exceptions are protected.")
      Menu {
        Button("Restore all & turn off Auto Tame") { monitor.restoreAllApps() }
          .disabled(monitor.taming.state.receipts.isEmpty && !monitor.taming.automatic)
        Button("Never slow down…") { showingExceptions = true }
      } label: { Image(systemName: "slider.horizontal.3").accessibilityLabel("Slowdown settings") }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().frame(width: 28, height: 28)
        .disabled(preview != nil)
    }
    .fixedSize()
  }

  private var footnotes: some View {
    VStack(alignment: .leading, spacing: 4) {
      Text("App CPU: 100% = one core and values can exceed 100%. Bars show the share of this Mac's total CPU capacity or installed RAM.")
        .font(.system(size: 11)).foregroundStyle(AppTheme.ink3).fixedSize(horizontal: false, vertical: true)
      Text("Slowdown lowers CPU, disk and network priority, not a CPU/RAM cap. Auto Tame checks sustained background load every ~8 seconds; foreground apps and exceptions stay protected. Pause freezes readings; enabled controls continue in the background.")
        .font(.system(size: 11)).foregroundStyle(AppTheme.ink3).fixedSize(horizontal: false, vertical: true)
      if let message = tamingDisplay.message {
        Text(message).font(.system(size: 11, weight: .medium)).foregroundStyle(AppTheme.ink2)
          .fixedSize(horizontal: false, vertical: true)
          .textSelection(.enabled)
      }
    }
  }

  // MARK: Disk insights

  private var diskInsightsCard: some View {
    VStack(alignment: .leading, spacing: 0) {
      Text("Disk insights").font(.system(size: 14, weight: .bold)).tracking(-0.2)
        .foregroundStyle(AppTheme.ink).accessibilityAddTraits(.isHeader)
        .padding(.bottom, 8)
      if let insights {
        insightRow(
          "Drive health",
          value: insights.health?.rawValue ?? "Unknown",
          detail: insights.health == .failing
            ? "The drive reports it may fail soon. Back up now with Time Machine."
            : "Reported by the drive's self-monitoring (SMART).",
          tint: insights.health == .failing ? AppTheme.danger : insights.health == .verified ? AppTheme.accentText : AppTheme.ink2)
        if let fs = insights.fileSystem {
          insightRow("File system", value: fs, detail: "Copies of a file on APFS can share space, so freed space may be less than a file's size.", tint: AppTheme.ink2)
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
          tint: AppTheme.ink2)
      } else {
        ProgressView().controlSize(.small).padding(.vertical, 8)
      }
    }
    .padding(.horizontal, 16).padding(.vertical, 14)
    .frame(minWidth: 320, idealWidth: 320, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .cardBackground(radius: 14)
  }

  private func insightRow(_ title: String, value: String, detail: String, tint: Color) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 12) {
      VStack(alignment: .leading, spacing: 2) {
        Text(title).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(AppTheme.ink)
        Text(detail).font(.system(size: 11.5)).foregroundStyle(AppTheme.ink3).fixedSize(horizontal: false, vertical: true)
      }
      Spacer(minLength: 8)
      Text(value).font(.system(size: 12.5, weight: .semibold)).monospacedDigit().foregroundStyle(tint)
    }
    .padding(.vertical, 7)
    .overlay(alignment: .top) { Rectangle().fill(AppTheme.divider).frame(height: 1) }
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
      PerformancePresentation.App(id: .init(pid: app.id, started: app.started), name: app.name, bundleID: app.bundleID,
        memoryBytes: app.totalMemoryBytes, cpuPercent: app.totalCPUPercent, helpers: app.helpers,
        ownMemoryBytes: app.memoryBytes, ownCPUPercent: app.cpuPercent)
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
  let toggleBreakdown: (PerformancePresentation.ProcessID) -> Void
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
      subtitle: "Whole Mac · \(feed.logicalCPUCount) logical cores", icon: "cpu", key: .cpu,
      tint: cpuFraction == nil ? AppTheme.ink3 : AppTheme.ink2, iconColor: AppTheme.Swatch.sky.text,
      meter: AppTheme.Swatch.sky.start, fraction: PerformancePresentation.quantized(cpuFraction),
      status: cpuFraction == nil ? "CPU reading unavailable" : "Across all cores", sort: sort, select: select)
    let memory = PerformanceResourceCard(title: "Memory", value: used.map(ByteFormatter.string) ?? "—",
      subtitle: snapshot.physicalMemory > 0 ? "of \(ByteFormatter.string(snapshot.physicalMemory)) installed RAM" : "Installed RAM unavailable",
      icon: "memorychip", key: .memory, tint: Self.pressureTint(snapshot.pressure), iconColor: AppTheme.Swatch.violet.text,
      meter: Self.pressureMeter(snapshot.pressure),
      fraction: PerformancePresentation.quantized(PerformancePresentation.memoryFraction(used, physicalMemory: snapshot.physicalMemory)),
      status: "Pressure: " + snapshot.pressure.rawValue, sort: sort, select: select)
    let swap = PerformanceStatCard(title: "Swap", value: snapshot.swapUsedBytes.map(ByteFormatter.string) ?? "—",
      subtitle: "Memory moved to the SSD", icon: "arrow.left.arrow.right", iconColor: AppTheme.Swatch.amber.text,
      status: "", statusColor: AppTheme.ink2, fraction: nil, meter: AppTheme.Swatch.amber.start, showsMeter: false)
    let disk = PerformanceStatCard(title: "Free disk",
      value: snapshot.hasDiskReading ? ByteFormatter.string(snapshot.freeBytes) : "—",
      subtitle: snapshot.hasDiskReading ? "free of \(ByteFormatter.string(snapshot.totalBytes))" : "Disk reading unavailable",
      icon: "internaldrive", iconColor: AppTheme.Swatch.indigo.text,
      status: snapshot.diskStale ? "Earlier reading" : "", statusColor: AppTheme.warning,
      fraction: PerformancePresentation.quantized(snapshot.diskUsedFraction), meter: AppTheme.Swatch.indigo.start,
      showsMeter: snapshot.hasDiskReading)
    ViewThatFits(in: .horizontal) {
      HStack(alignment: .top, spacing: 10) {
        cpu.equatable(); memory.equatable(); swap.equatable(); disk.equatable()
      }
      VStack(spacing: 10) {
        HStack(alignment: .top, spacing: 10) { cpu.equatable(); memory.equatable() }
        HStack(alignment: .top, spacing: 10) { swap.equatable(); disk.equatable() }
      }
    }
  }

  static func pressureTint(_ pressure: SystemMonitor.Pressure) -> Color {
    switch pressure {
    case .normal: return AppTheme.accentText
    case .warning: return AppTheme.warning
    case .critical: return AppTheme.danger
    case .unknown: return AppTheme.ink3
    }
  }

  /// Memory meters are violet; they take the warning colors while pressure is up.
  static func pressureMeter(_ pressure: SystemMonitor.Pressure) -> Color {
    switch pressure {
    case .normal, .unknown: return AppTheme.Swatch.violet.start
    case .warning: return AppTheme.warning
    case .critical: return AppTheme.danger
    }
  }
}

/// The shared look of the four metric cards: icon, title and state; a rounded number; a
/// caption; and a 4 pt meter.
private struct PerformanceCardFace: View {
  let title: String
  let icon: String
  let iconColor: Color
  let status: String
  let statusColor: Color
  let value: String
  let subtitle: String
  let fraction: Double?
  let meter: Color
  let showsMeter: Bool
  let arrow: String?
  let arrowColor: Color

  var body: some View {
    VStack(alignment: .leading, spacing: 3) {
      HStack(spacing: 6) {
        Image(systemName: icon).font(.system(size: 12, weight: .semibold)).symbolVariant(.fill)
          .foregroundStyle(iconColor).frame(width: 15)
        Text(title).font(.system(size: 11.5, weight: .semibold)).foregroundStyle(AppTheme.ink)
          .lineLimit(1).layoutPriority(1)
        Spacer(minLength: 4)
        if !status.isEmpty {
          Text(status).font(.system(size: 11, weight: .semibold)).foregroundStyle(statusColor)
            .lineLimit(1).truncationMode(.tail)
        }
      }
      HStack(alignment: .firstTextBaseline, spacing: 5) {
        Text(value).font(AppTheme.number(22)).tracking(-0.5).monospacedDigit()
          .foregroundStyle(AppTheme.ink).lineLimit(1).minimumScaleFactor(0.6)
        Spacer(minLength: 4)
        if let arrow {
          Image(systemName: arrow).font(.system(size: 10, weight: .bold)).foregroundStyle(arrowColor)
        }
      }
      Text(subtitle).font(.system(size: 11)).foregroundStyle(AppTheme.ink3).lineLimit(1).truncationMode(.tail)
      PerformanceMeter(fraction: fraction, tint: meter).frame(height: 4).padding(.top, 3)
        .opacity(showsMeter ? 1 : 0)
    }
    .padding(.horizontal, 13).padding(.vertical, 11)
    .frame(minWidth: 140, idealWidth: 150, maxWidth: .infinity, alignment: .leading)
  }
}

/// CPU and Memory: a card that chooses the list's sort. The selected one gets a sky ring.
private struct PerformanceResourceCard: View, Equatable {
  let title: String
  let value: String
  let subtitle: String
  let icon: String
  let key: PerformancePresentation.SortKey
  let tint: Color
  let iconColor: Color
  let meter: Color
  let fraction: Double?
  let status: String
  let sort: PerformancePresentation.Sort
  let select: (PerformancePresentation.SortKey) -> Void

  nonisolated static func == (left: Self, right: Self) -> Bool {
    let text: Bool = left.title == right.title && left.value == right.value && left.subtitle == right.subtitle
      && left.status == right.status
    let look: Bool = left.tint == right.tint && left.iconColor == right.iconColor && left.meter == right.meter
    return text && look && left.fraction == right.fraction && left.sort == right.sort
  }

  private var selected: Bool { sort.key == key }

  var body: some View {
    let shape = RoundedRectangle(cornerRadius: 13, style: .continuous)
    let hint: String = "Sorts running apps by highest \(title.lowercased()) use"
    let label: String = "\(title), \(value). \(subtitle). \(status)"
    let identifier: String = "performance-card-\(key.rawValue.lowercased())"
    let arrow: String = selected && sort.direction == .ascending ? "arrow.up" : "arrow.down"
    Button { select(key) } label: {
      PerformanceCardFace(title: title, icon: icon, iconColor: iconColor, status: status, statusColor: tint,
        value: value, subtitle: subtitle, fraction: fraction, meter: meter, showsMeter: true,
        arrow: arrow, arrowColor: selected ? AppTheme.Swatch.sky.text : AppTheme.ink3)
        .cardBackground(radius: 13)
        .overlay {
          if selected { shape.strokeBorder(AppTheme.Swatch.sky.text, lineWidth: 1.5) }
        }
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

/// Swap and Free disk: the same card, read only.
private struct PerformanceStatCard: View, Equatable {
  let title: String
  let value: String
  let subtitle: String
  let icon: String
  let iconColor: Color
  let status: String
  let statusColor: Color
  let fraction: Double?
  let meter: Color
  let showsMeter: Bool

  nonisolated static func == (left: Self, right: Self) -> Bool {
    let text: Bool = left.title == right.title && left.value == right.value && left.subtitle == right.subtitle
      && left.status == right.status
    let look: Bool = left.statusColor == right.statusColor && left.iconColor == right.iconColor && left.meter == right.meter
    return text && look && left.fraction == right.fraction && left.showsMeter == right.showsMeter
  }

  var body: some View {
    let label: String = "\(title), \(value). \(subtitle)" + (status.isEmpty ? "" : ". " + status)
    PerformanceCardFace(title: title, icon: icon, iconColor: iconColor, status: status, statusColor: statusColor,
      value: value, subtitle: subtitle, fraction: fraction, meter: meter, showsMeter: showsMeter,
      arrow: nil, arrowColor: AppTheme.ink3)
      .cardBackground(radius: 13)
      .accessibilityElement(children: .combine)
      .accessibilityLabel(label)
  }
}

/// The two short texts that change with each sample: the list count and the header's
/// static Live indicator (a plain dot; it never animates).
private struct PerformanceLiveText: View {
  enum Kind { case count(query: String), status }
  @ObservedObject var live: SystemMonitor.LiveReadings
  let feed: PerformanceFeed
  let kind: Kind

  var body: some View {
    switch kind {
    case .count(let query):
      let apps = feed.apps(live)
      Text("\(PerformancePresentation.matchCount(apps, query: query)) of \(apps.count)")
        .font(AppTheme.number(11.5, weight: .medium)).monospacedDigit().foregroundStyle(AppTheme.ink3)
    case .status:
      let sampledAt = feed.sampledAt(live)
      let time = sampledAt?.formatted(date: .omitted, time: .standard)
      let state = feed.paused ? "Paused" : (sampledAt == nil ? "Measuring" : "Live")
      let reading: String = time.map { "\(state) · \($0)" } ?? state
      let detail: String = Self.detail(time: time, paused: feed.paused, interval: feed.samplingInterval)
      let dot: Color = feed.paused ? AppTheme.warning : (sampledAt == nil ? AppTheme.ink3 : AppTheme.brand)
      HStack(spacing: 6) {
        Circle().fill(dot).frame(width: 7, height: 7).accessibilityHidden(true)
        Text(reading).font(.system(size: 11.5)).monospacedDigit().foregroundStyle(AppTheme.ink2).lineLimit(1)
      }
      .help(detail)
      .accessibilityElement(children: .combine)
      .accessibilityLabel("Apps with the helpers they started · \(reading)")
    }
  }

  private static func detail(time: String?, paused: Bool, interval: TimeInterval) -> String {
    guard let time else {
      return paused ? "Paused before the first sample. Resume to measure activity." : "Measuring app activity…"
    }
    let scope = " Helpers macOS starts for an app (for example some web content and system services) are not counted."
    return (paused ? "Readings frozen at \(time). Quit still checks the current process before acting."
      : "Updated \(time) · refreshes about every \(Int(interval)) seconds") + scope
  }
}

private struct PerformanceProcessRows: View {
  @ObservedObject var live: SystemMonitor.LiveReadings
  let feed: PerformanceFeed
  let query: String
  let sort: PerformancePresentation.Sort
  let taming: TamingState
  let expanded: Set<PerformancePresentation.ProcessID>
  let actions: PerformanceRowActions
  let clearSearch: () -> Void
  let selectSort: (PerformancePresentation.SortKey) -> Void
  @State private var cache = PerformancePresentation.RowCache()

  var body: some View {
    let snapshot = feed.snapshot(live)
    let rows = cache.rows(.init(apps: feed.apps(live), query: query, sort: sort, taming: taming,
      physicalMemory: snapshot.physicalMemory, logicalCPUCount: feed.logicalCPUCount, controllable: feed.controllable(live),
      expanded: expanded))
    let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
    if rows.isEmpty {
      VStack(spacing: 6) {
        Image(systemName: trimmed.isEmpty ? "waveform.path.ecg" : "magnifyingglass")
          .font(.system(size: 26, weight: .medium)).foregroundStyle(AppTheme.Swatch.sky.text).accessibilityHidden(true)
        Text(trimmed.isEmpty ? (feed.paused ? "No apps in this paused sample" : "Waiting for an app sample") : "No matching apps")
          .font(.system(size: 14, weight: .semibold)).foregroundStyle(AppTheme.ink)
        Text(trimmed.isEmpty ? "\(feed.paused ? "Resume" : "Leave this view open") to measure activity." : "Try an app name, process ID or bundle identifier.")
          .font(.system(size: 12)).foregroundStyle(AppTheme.ink2).multilineTextAlignment(.center)
        if !trimmed.isEmpty {
          Button("Clear search", action: clearSearch)
            .buttonStyle(MintButtonStyle(.secondary)).controlSize(.small).padding(.top, 6)
        }
      }
      .frame(maxWidth: .infinity).padding(.vertical, 32).padding(.horizontal, 20)
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
      header(.cpu).frame(width: PerformanceColumns.cpu, alignment: .trailing)
      header(.memory).frame(width: PerformanceColumns.memory, alignment: .trailing)
      Text("Actions").font(.system(size: 11, weight: .semibold)).foregroundStyle(AppTheme.ink2)
        .frame(width: PerformanceColumns.actions, alignment: .trailing)
    }
    .padding(.horizontal, 16).padding(.vertical, 7)
    .background(AppTheme.panel)
  }

  private func header(_ key: PerformancePresentation.SortKey) -> some View {
    Button { select(key) } label: {
      HStack(spacing: 4) {
        Text(key.rawValue)
        Image(systemName: sort.key == key && sort.direction == .ascending ? "arrow.up" : "arrow.down")
          .font(.system(size: 9, weight: .bold))
          .opacity(sort.key == key ? 1 : 0.3)
      }
      .font(.system(size: 11, weight: .semibold))
      .foregroundStyle(sort.key == key ? AppTheme.ink : AppTheme.ink2)
      .contentShape(Rectangle())
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
    VStack(alignment: .leading, spacing: 0) {
      HStack(spacing: 12) {
        HStack(spacing: 10) {
          PerformanceAppIcon(id: row.id, fallbackSymbol: row.fallbackSymbol, application: application)
          VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
              Text(row.name).font(.system(size: 13, weight: .semibold)).foregroundStyle(AppTheme.ink)
                .lineLimit(1).truncationMode(.middle)
              statusChip
            }
            Text(row.detail)
              .font(.system(size: 11)).foregroundStyle(AppTheme.ink3).lineLimit(1).truncationMode(.middle)
          }
          if row.helperCount > 0 { helperToggle }
          Spacer(minLength: 0)
        }.frame(maxWidth: .infinity, alignment: .leading)
          .help(row.help)
        PerformanceMetricCell(text: row.cpuText, fraction: row.cpuFraction, tint: AppTheme.Swatch.sky.start,
          label: "CPU", value: row.cpuAccessibility).frame(width: PerformanceColumns.cpu)
        PerformanceMetricCell(text: row.memoryText, fraction: row.memoryFraction, tint: AppTheme.Swatch.violet.start,
          label: "Memory footprint", value: row.memoryAccessibility).frame(width: PerformanceColumns.memory)
        PerformanceRowControls(control: row.control, actions: actions).equatable()
      }
      .frame(minHeight: 48)
      if row.expanded && !row.breakdown.isEmpty {
        PerformanceBreakdown(lines: row.breakdown).padding(.leading, 38).padding(.bottom, 10)
      }
    }
    .accessibilityElement(children: .contain)
    .accessibilityLabel(row.name + ", PID \(row.id.pid)")
    .padding(.horizontal, 16)
    .overlay(alignment: .top) { Rectangle().fill(AppTheme.divider).frame(height: 1) }
  }

  /// Slowed or Protected, read from the row's control state.
  @ViewBuilder private var statusChip: some View {
    if row.control.slowed {
      Chip(title: "Slowed", symbol: "tortoise.fill", swatch: .amber).fixedSize()
    } else if row.control.excepted {
      Chip(title: "Protected", symbol: "lock.shield.fill", swatch: .mint).fixedSize()
    }
  }

  /// The helper count with a chevron; opens the read-only breakdown below the row.
  private var helperToggle: some View {
    Button { actions.toggleBreakdown(row.id) } label: {
      HStack(spacing: 3) {
        Text("\(row.helperCount)").font(AppTheme.number(10.5, weight: .semibold)).monospacedDigit()
        Image(systemName: row.expanded ? "chevron.up" : "chevron.down").font(.system(size: 8.5, weight: .bold))
      }
      .foregroundStyle(AppTheme.ink2)
      .padding(.horizontal, 6).frame(height: 20)
      .background(AppTheme.panel, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .fixedSize()
    .help(row.expanded ? "Hide helper processes" : "Show helper processes")
    .accessibilityLabel(row.expanded ? "Hide helper processes of " + row.name : "Show helper processes of " + row.name)
  }
}

/// Column widths shared by the header, the rows and the helper breakdown.
private enum PerformanceColumns {
  static let cpu: CGFloat = 100
  static let memory: CGFloat = 110
  static let actions: CGFloat = 186
  /// The breakdown sits in a panel inset with 10 pt of inner padding.
  static let breakdownTrailing: CGFloat = 176
}

/// Read-only list of what makes up an app's total. Helpers have no controls of their own.
private struct PerformanceBreakdown: View {
  let lines: [PerformancePresentation.BreakdownLine]

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      ForEach(lines) { line in
        HStack(spacing: 12) {
          Text(line.name).font(.system(size: 11.5)).foregroundStyle(AppTheme.ink2).lineLimit(1).truncationMode(.middle)
            .frame(maxWidth: .infinity, alignment: .leading)
          Text(line.cpuText).font(AppTheme.number(11.5, weight: .medium)).monospacedDigit().foregroundStyle(AppTheme.ink2)
            .frame(width: PerformanceColumns.cpu, alignment: .trailing)
          Text(line.memoryText).font(AppTheme.number(11.5, weight: .medium)).monospacedDigit().foregroundStyle(AppTheme.ink2)
            .frame(width: PerformanceColumns.memory, alignment: .trailing)
          Color.clear.frame(width: PerformanceColumns.breakdownTrailing, height: 1)
        }
        .frame(minHeight: 22)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(line.name)
        .accessibilityValue("CPU \(line.cpuText), memory \(line.memoryText)")
      }
    }
    .padding(.horizontal, 10).padding(.vertical, 6)
    .background(AppTheme.panel, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
  }
}

private struct PerformanceMetricCell: View {
  let text: String
  let fraction: Double?
  let tint: Color
  let label: String
  let value: String

  var body: some View {
    VStack(alignment: .trailing, spacing: 4) {
      Text(text).font(AppTheme.number(12.5, weight: .semibold)).monospacedDigit()
        .foregroundStyle(AppTheme.ink).lineLimit(1).minimumScaleFactor(0.7)
      PerformanceMeter(fraction: fraction, tint: tint).frame(width: 72, height: 3)
    }
    .frame(maxWidth: .infinity, alignment: .trailing)
    .accessibilityElement(children: .ignore).accessibilityLabel(label).accessibilityValue(value)
  }
}

private struct PerformanceRowControls: View, Equatable {
  let control: PerformancePresentation.Control
  let actions: PerformanceRowActions
  nonisolated static func == (left: Self, right: Self) -> Bool { left.control == right.control }

  var body: some View {
    let id = control.id, name = control.name
    let chip = RoundedRectangle(cornerRadius: 6, style: .continuous)
    HStack(spacing: 4) {
      if control.slowed {
        Button("Restore") { actions.restore(id) }
          .buttonStyle(MintButtonStyle(.secondary)).controlSize(.small)
          .help("Restore normal priority for " + name)
      } else {
        Menu {
          Button("Slow for 15 minutes") { actions.slow(id, 900) }
          Button("Slow for 1 hour") { actions.slow(id, 3600) }
        } label: { Text(control.excepted ? "Protected" : "Slow") }
          .menuStyle(.borderlessButton).fixedSize()
          .font(.system(size: 11.5, weight: .medium))
          .padding(.horizontal, 7).frame(height: 24)
          .background(AppTheme.surface, in: chip)
          .overlay(chip.strokeBorder(AppTheme.border, lineWidth: 1))
          .disabled(control.excepted)
          .accessibilityLabel("Slow down " + name)
          .help("Lower CPU, disk and network priority until expiry or until you switch to this app")
      }
      Button { actions.quit(id, false) } label: { Label("Quit", systemImage: "power").labelStyle(.titleAndIcon) }
        .buttonStyle(MintButtonStyle(.secondary)).controlSize(.small)
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
        .frame(width: 24, height: 24).accessibilityLabel("More actions for " + name)
    }.frame(width: PerformanceColumns.actions, alignment: .trailing)
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
  var count: Int { cache.count }
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
