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
    VStack(alignment: .leading, spacing: 14) {
      MenuBarReadings(live: monitor.live, volumeName: model.volumeName)

      Divider()

      Button {
        open(.dashboard)
        model.runSmartScan()
      } label: {
        Label(model.isScanning ? "Scanning…" : "Quick Scan", systemImage: "sparkles")
          .frame(maxWidth: .infinity)
      }
      .buttonStyle(MintButtonStyle())
      .disabled(model.isScanning || model.isWorking)
      HStack {
        Button("Storage") { open(.storage) }
        Button("Performance") { open(.performance) }
        Button("Review (\(model.queuedCount))") { open(.review) }
      }
      .controlSize(.small)

      HStack {
        Button("Open MacMint") { open(nil) }
        Spacer()
        Button("Quit") { NSApp.terminate(nil) }
      }
      .buttonStyle(.borderless)
      .font(.callout)
    }
    .padding(16)
    .frame(width: 320)
    .background(AppTheme.canvas)
    // The popover samples only while it is open, whether or not a window is in front.
    .onAppear { monitor.start(lease: monitoringLease, interval: 4, kind: .popover) }
    .onDisappear { monitor.stop(lease: monitoringLease) }
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
  private var snapshot: SystemMonitor.Snapshot { live.reading.snapshot }

  var body: some View {
    HStack(spacing: 10) {
      BrandMark(size: 26)
      VStack(alignment: .leading, spacing: 1) {
        Text("MacMint").font(.headline)
        Text(monitorSummary).font(.caption).foregroundStyle(.secondary)
      }
      Spacer()
    }

    VStack(alignment: .leading, spacing: 6) {
      HStack {
        Text(volumeName).font(.callout.weight(.medium))
        Spacer()
        Text("\(ByteFormatter.string(snapshot.freeBytes)) free")
          .font(.callout.monospacedDigit())
          .foregroundStyle(.secondary)
      }
      ProgressView(value: snapshot.diskUsedFraction)
        .tint(snapshot.diskUsedFraction > 0.9 ? .orange : AppTheme.accent)
    }

    HStack(spacing: 8) {
      MetricTile(
        title: "Memory", value: snapshot.pressure.rawValue,
        detail: snapshot.memoryUsedBytes.map {
          "\(ByteFormatter.string($0)) of \(ByteFormatter.string(snapshot.physicalMemory))"
        } ?? "—",
        tint: pressureColor)
      MetricTile(
        title: "CPU",
        value: snapshot.cpuUsage.map { "\(Int(($0 * 100).rounded()))%" } ?? "…",
        detail: "all cores", tint: AppTheme.accentText)
      MetricTile(
        title: "Swap",
        value: snapshot.swapUsedBytes.map { ByteFormatter.string($0) } ?? "—",
        detail: "in use", tint: .secondary)
    }
  }

  private var monitorSummary: String {
    switch snapshot.pressure {
    case .critical: return "Memory is under heavy pressure"
    case .warning: return "Memory is getting tight"
    case .unknown: return "Readings are not available yet"
    case .normal:
      return snapshot.diskUsedFraction > 0.9 ? "Disk is almost full" : "Everything looks healthy"
    }
  }

  private var pressureColor: Color {
    switch snapshot.pressure {
    case .normal: return AppTheme.accentText
    case .warning: return AppTheme.warning
    case .critical: return AppTheme.danger
    case .unknown: return .secondary
    }
  }

}

struct MetricTile: View {
  let title: String
  let value: String
  let detail: String
  var tint: Color = AppTheme.accentText

  var body: some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(title).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
      Text(value).font(.system(.callout, design: .rounded).weight(.bold)).foregroundStyle(tint)
        .lineLimit(1)
        .minimumScaleFactor(0.7)
      Text(detail).font(.caption2).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.7)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(8)
    .background(AppTheme.panel, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    .accessibilityElement(children: .combine)
  }
}
