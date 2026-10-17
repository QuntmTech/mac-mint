import MacCleanerCore
import SwiftUI

struct PerformanceView: View {
  @EnvironmentObject private var model: AppViewModel
  @EnvironmentObject private var monitor: SystemMonitor
  @State private var pendingQuit: SystemMonitor.AppUsage?
  @Environment(\.scenePhase) private var scenePhase
  @State private var monitoringLease = UUID()
  @State private var paused = false
  @State private var search = ""
  @State private var sortByCPU = false
  @State private var forceQuit = false
  @State private var insights: DiskInsights?

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 18) {
        PageHeader("Performance", subtitle: "Live readings, with context that helps you decide when to act.")
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 190), spacing: 14)], spacing: 14) {
          gauge(
            "Memory pressure", value: monitor.snapshot.pressure.rawValue,
            detail: memoryDetail, icon: "memorychip", tint: pressureTint)
          gauge(
            "CPU", value: monitor.snapshot.cpuUsage.map { "\(Int(($0 * 100).rounded()))%" } ?? "Measuring…",
            detail: "Across all cores", icon: "cpu", tint: AppTheme.accentText)
          gauge(
            "Swap", value: monitor.snapshot.swapUsedBytes.map { ByteFormatter.string($0) } ?? "—",
            detail: "Memory written to disk", icon: "arrow.left.arrow.right", tint: AppTheme.info)
          gauge(
            "Free space", value: ByteFormatter.string(monitor.snapshot.freeBytes),
            detail: "of \(ByteFormatter.string(monitor.snapshot.totalBytes))", icon: "internaldrive",
            tint: monitor.snapshot.diskUsedFraction > 0.9 ? AppTheme.warning : AppTheme.accentText)
        }

        processCard
        diskInsightsCard
        SurfaceCard {
          VStack(alignment: .leading, spacing: 8) {
            Text("When to take action").font(.headline)
            Text("Short CPU spikes during builds or photo analysis are normal. If CPU stays high while the Mac is slow, inspect Activity Monitor. If free space stays below 10%, review storage. Quit unused apps when memory pressure remains elevated.")
              .font(.callout).foregroundStyle(.secondary)
            HStack {
              Button("Review Storage") { model.selectedSection = .storage }
              Button("Open Activity Monitor") { model.openActivityMonitor() }
            }
          }
        }

        SurfaceCard {
          VStack(alignment: .leading, spacing: 10) {
            Label("About memory", systemImage: "info.circle").font(.headline)
            Text(
              "macOS keeps unused memory filled with cached files to make your Mac faster, so a high \"used\" number is normal. Memory pressure is the signal that matters: if it stays Elevated or High, quit apps you aren't using. MacMint never \"purges\" memory — that only throws away useful caches."
            )
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
          }
        }


      }
      .padding(AppTheme.pagePadding)
    }
    .onAppear { updateMonitoring() }
    .onChange(of: scenePhase) { _, _ in updateMonitoring() }
    .onChange(of: paused) { _, _ in updateMonitoring() }
    .task { insights = await DiskInsightsService.load() }
    .onDisappear { monitor.stop(lease: monitoringLease) }
    .alert(
      "\(forceQuit ? "Force quit" : "Quit") \(pendingQuit?.name ?? "app")?",
      isPresented: Binding(get: { pendingQuit != nil }, set: { if !$0 { pendingQuit = nil } }),
      presenting: pendingQuit
    ) { app in
      Button("Cancel", role: .cancel) {}
      Button(forceQuit ? "Force Quit" : "Quit", role: forceQuit ? .destructive : nil) {
        model.statusMessage =
          monitor.requestQuit(app, force: forceQuit)
          ? (forceQuit ? "Sent a force-quit request to \(app.name)" : "Asked \(app.name) to quit — it may ask you to save first")
          : "The app changed, exited, or refused the request. Refresh and try again."
      }
    } message: { _ in
      Text(forceQuit ? "Unsaved changes may be lost. Use Force Quit only when normal Quit has not worked." : "The app is asked to quit normally, so it can prompt you to save any unsaved work.")
    }
  }

  private func updateMonitoring() {
    if !paused && scenePhase == .active { monitor.start(lease: monitoringLease) }
    else { monitor.stop(lease: monitoringLease) }
  }

  private var visibleApps: [SystemMonitor.AppUsage] {
    monitor.apps.filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) }
      .sorted {
        let left = sortByCPU ? ($0.cpuPercent ?? -1) : Double($0.memoryBytes)
        let right = sortByCPU ? ($1.cpuPercent ?? -1) : Double($1.memoryBytes)
        return left == right ? $0.name < $1.name : left > right
      }
  }

  private var processCard: some View {
    let displayed = visibleApps
    return SurfaceCard {
      VStack(alignment: .leading, spacing: 12) {
        HStack {
          Label("Running apps", systemImage: "waveform.path.ecg").font(.headline)
          Spacer()
          Button(paused ? "Resume" : "Pause") { paused.toggle() }.controlSize(.small)
        }
        HStack {
          SearchField(prompt: "Find an app", text: $search)
          Picker("Sort apps", selection: $sortByCPU) { Text("Memory").tag(false); Text("CPU").tag(true) }
            .pickerStyle(.segmented).labelsHidden().frame(width: 170)
        }
        Text(paused ? "Readings paused in this window. The menu bar may continue sampling while open." : "Main app processes · 100% CPU equals one core · refreshes every \(Int(monitor.samplingInterval ?? 4)) seconds")
          .font(.caption).foregroundStyle(.secondary)
        if displayed.isEmpty { Text(search.isEmpty ? "Waiting for a sample…" : "No matching apps").foregroundStyle(.secondary) }
        ForEach(displayed) { app in
          HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
              Text(app.name).font(.callout.weight(.medium))
              Text("PID \(app.id)").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Text(app.cpuPercent.map { String(format: "%.1f%%", $0) } ?? "—")
              .font(.callout.monospacedDigit()).frame(width: 70, alignment: .trailing).accessibilityLabel("CPU")
            Text(ByteFormatter.string(app.memoryBytes)).font(.callout.monospacedDigit())
              .frame(width: 85, alignment: .trailing).accessibilityLabel("Memory")
            Menu {
              Button("Quit…") { forceQuit = false; pendingQuit = app }
              Button("Force Quit…", role: .destructive) { forceQuit = true; pendingQuit = app }
            } label: { Image(systemName: "ellipsis.circle").accessibilityLabel("Actions for " + app.name) }
              .menuStyle(.borderlessButton).fixedSize().disabled(!app.canControl)
          }
          if app.id != displayed.last?.id { Divider() }
        }
        Text("Helper processes are shown in Activity Monitor. MacMint reduces its sampling in Low Power Mode and when your Mac is hot.")
          .font(.caption).foregroundStyle(.secondary)
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

  private var memoryDetail: String {
    guard let used = monitor.snapshot.memoryUsedBytes else { return "—" }
    return "\(ByteFormatter.string(used)) of \(ByteFormatter.string(monitor.snapshot.physicalMemory)) used"
  }

  private var pressureTint: Color {
    switch monitor.snapshot.pressure {
    case .normal: return AppTheme.accentText
    case .warning: return AppTheme.warning
    case .critical: return AppTheme.danger
    case .unknown: return .secondary
    }
  }

  private func gauge(_ title: String, value: String, detail: String, icon: String, tint: Color)
    -> some View
  {
    SurfaceCard {
      VStack(alignment: .leading, spacing: 8) {
        Image(systemName: icon).font(.title3.weight(.semibold)).foregroundStyle(tint)
        Text(value)
          .font(.system(size: 24, weight: .bold, design: .rounded))
          .monospacedDigit()
          .lineLimit(1)
          .minimumScaleFactor(0.6)
        Text(title).font(.headline)
        Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .accessibilityElement(children: .combine)
  }
}
