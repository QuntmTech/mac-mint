import AppKit
import MacCleanerCore
import SwiftUI

/// Opt-in menu bar companion: disk, memory, and CPU at a glance, plus quick actions.
struct MenuBarView: View {
  @EnvironmentObject private var model: AppViewModel
  @EnvironmentObject private var account: AccountStore
  @EnvironmentObject private var monitor: SystemMonitor
  @Environment(\.openWindow) private var openWindow

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
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
          Text(model.volumeName).font(.callout.weight(.medium))
          Spacer()
          Text("\(ByteFormatter.string(monitor.snapshot.freeBytes)) free")
            .font(.callout.monospacedDigit())
            .foregroundStyle(.secondary)
        }
        ProgressView(value: monitor.snapshot.diskUsedFraction)
          .tint(monitor.snapshot.diskUsedFraction > 0.9 ? .orange : AppTheme.accent)
      }

      HStack(spacing: 8) {
        MetricTile(
          title: "Memory", value: monitor.snapshot.pressure.rawValue,
          detail: monitor.snapshot.memoryUsedBytes.map {
            "\(ByteFormatter.string($0)) of \(ByteFormatter.string(monitor.snapshot.physicalMemory))"
          } ?? "—",
          tint: pressureColor)
        MetricTile(
          title: "CPU",
          value: monitor.snapshot.cpuUsage.map { "\(Int(($0 * 100).rounded()))%" } ?? "…",
          detail: "all cores", tint: AppTheme.accentText)
        MetricTile(
          title: "Swap",
          value: monitor.snapshot.swapUsedBytes.map { ByteFormatter.string($0) } ?? "—",
          detail: "in use", tint: .secondary)
      }

      Divider()

      if account.isUnlocked {
        Button {
          open(.dashboard)
          model.runSmartScan()
        } label: {
          Label(model.isScanning ? "Scanning…" : "Run Smart Scan", systemImage: "sparkles")
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .disabled(model.isScanning || model.isWorking)
        HStack {
          Button("Storage") { open(.storage) }
          Button("Performance") { open(.performance) }
          Button("Review (\(model.queuedCount))") { open(.review) }
        }
        .controlSize(.small)
      } else {
        Button("Sign in to MacMint") { open(nil) }
          .buttonStyle(.borderedProminent)
          .frame(maxWidth: .infinity)
      }

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
    .onAppear { monitor.start(interval: 3) }
    .onDisappear { monitor.stop() }
  }

  private var monitorSummary: String {
    switch monitor.snapshot.pressure {
    case .critical: return "Memory is under heavy pressure"
    case .warning: return "Memory is getting tight"
    default:
      return monitor.snapshot.diskUsedFraction > 0.9 ? "Disk is almost full" : "Everything looks healthy"
    }
  }

  private var pressureColor: Color {
    switch monitor.snapshot.pressure {
    case .normal: return .green
    case .warning: return .orange
    case .critical: return .red
    case .unknown: return .secondary
    }
  }

  private func open(_ section: AppViewModel.Section?) {
    if let section { model.selectedSection = section }
    openWindow(id: "main")
    NSApp.activate(ignoringOtherApps: true)
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
      Text(detail).font(.caption2).foregroundStyle(.tertiary).lineLimit(1).minimumScaleFactor(0.7)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(8)
    .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    .accessibilityElement(children: .combine)
  }
}
