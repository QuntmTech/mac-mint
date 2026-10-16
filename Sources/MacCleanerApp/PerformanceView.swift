import MacCleanerCore
import SwiftUI

struct PerformanceView: View {
  @EnvironmentObject private var model: AppViewModel
  @EnvironmentObject private var monitor: SystemMonitor
  @State private var pendingQuit: SystemMonitor.AppUsage?

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 18) {
        VStack(alignment: .leading, spacing: 4) {
          Text("Performance").font(.system(size: 30, weight: .bold, design: .rounded))
          Text("Live readings, refreshed every few seconds while this screen is open.")
            .foregroundStyle(.secondary)
        }

        HStack(spacing: 14) {
          gauge(
            "Memory pressure", value: monitor.snapshot.pressure.rawValue,
            detail: memoryDetail, icon: "memorychip", tint: pressureTint)
          gauge(
            "CPU", value: monitor.snapshot.cpuUsage.map { "\(Int(($0 * 100).rounded()))%" } ?? "Measuring…",
            detail: "Across all cores", icon: "cpu", tint: AppTheme.accentText)
          gauge(
            "Swap", value: monitor.snapshot.swapUsedBytes.map { ByteFormatter.string($0) } ?? "—",
            detail: "Memory written to disk", icon: "arrow.left.arrow.right", tint: .blue)
          gauge(
            "Free space", value: ByteFormatter.string(monitor.snapshot.freeBytes),
            detail: "of \(ByteFormatter.string(monitor.snapshot.totalBytes))", icon: "internaldrive",
            tint: monitor.snapshot.diskUsedFraction > 0.9 ? .orange : AppTheme.accentText)
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

        SurfaceCard {
          VStack(alignment: .leading, spacing: 10) {
            Text("Apps using the most memory").font(.headline)
            if monitor.topApps.isEmpty {
              Text("Measuring…").foregroundStyle(.secondary)
            }
            ForEach(monitor.topApps) { app in
              HStack(spacing: 10) {
                if let icon = app.icon {
                  Image(nsImage: icon).resizable().frame(width: 22, height: 22)
                } else {
                  Image(systemName: "app").frame(width: 22, height: 22)
                }
                Text(app.name)
                Spacer()
                Text(ByteFormatter.string(app.memoryBytes))
                  .font(.callout.monospacedDigit())
                  .foregroundStyle(.secondary)
                if app.bundleID != Bundle.main.bundleIdentifier {
                  Button("Quit…") { pendingQuit = app }
                    .controlSize(.small)
                }
              }
              if app.id != monitor.topApps.last?.id { Divider() }
            }
          }
        }
      }
      .padding(AppTheme.pagePadding)
    }
    .onAppear { monitor.start() }
    .onDisappear { monitor.stop() }
    .alert(
      "Quit \(pendingQuit?.name ?? "app")?",
      isPresented: Binding(get: { pendingQuit != nil }, set: { if !$0 { pendingQuit = nil } }),
      presenting: pendingQuit
    ) { app in
      Button("Cancel", role: .cancel) {}
      Button("Quit") {
        model.statusMessage =
          monitor.requestQuit(app)
          ? "Asked \(app.name) to quit — it may ask you to save first"
          : "\(app.name) didn't respond to the quit request"
      }
    } message: { _ in
      Text("The app is asked to quit normally, so it can prompt you to save any unsaved work.")
    }
  }

  private var memoryDetail: String {
    guard let used = monitor.snapshot.memoryUsedBytes else { return "—" }
    return "\(ByteFormatter.string(used)) of \(ByteFormatter.string(monitor.snapshot.physicalMemory)) used"
  }

  private var pressureTint: Color {
    switch monitor.snapshot.pressure {
    case .normal: return .green
    case .warning: return .orange
    case .critical: return .red
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
