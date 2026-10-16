import MacCleanerCore
import SwiftUI

struct DashboardView: View {
  @EnvironmentObject private var model: AppViewModel

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 22) {
        hero

        HStack(spacing: 14) {
          MetricCard(
            title: "Safe to reclaim",
            value: ByteFormatter.string(model.reclaimableBytes),
            subtitle: "Known user-level caches and regenerable data",
            icon: "checkmark.shield",
            action: { model.selectedSection = .cleaner }
          )
          MetricCard(
            title: "Needs review",
            value: ByteFormatter.string(model.reviewableBytes),
            subtitle: "Archives, device backups, diagnostics, and installers",
            icon: "eye",
            action: { model.selectedSection = .cleaner }
          )
          MetricCard(
            title: "Installed apps",
            value: "\(model.apps.count)",
            subtitle: "Applications available for inspected uninstall",
            icon: "square.grid.2x2",
            action: { model.selectedSection = .applications }
          )
        }

        moduleGrid

        cleanupPreview
      }
      .padding(AppTheme.pagePadding)
    }
  }

  private var hero: some View {
    let stats = model.volumeStats
    return SurfaceCard {
      HStack(spacing: 28) {
        StorageRing(
          used: stats.used,
          total: stats.total,
          centerValue: ByteFormatter.string(stats.free),
          centerLabel: "free"
        )

        VStack(alignment: .leading, spacing: 12) {
          HStack(spacing: 8) {
            StatusPill(title: "Trash-first • Restorable", icon: "arrow.uturn.backward.circle", tint: .green)
            StatusPill(title: "No telemetry", icon: "lock.shield", tint: .blue)
            if !model.scanIssues.isEmpty {
              StatusPill(
                title:
                  "\(model.scanIssues.count) scan issue\(model.scanIssues.count == 1 ? "" : "s")",
                icon: "exclamationmark.triangle", tint: .orange)
            }
          }

          Text("Smart Scan")
            .font(.system(size: 34, weight: .bold, design: .rounded))
          Text(
            "A transparent cleanup pass that shows what is safe, what needs review, and what the app refuses to touch before anything changes."
          )
          .font(.callout)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
          .frame(maxWidth: 630, alignment: .leading)

          HStack(spacing: 10) {
            Button {
              model.runSmartScan()
            } label: {
              Label(model.isScanning ? "Scanning…" : "Run Smart Scan", systemImage: "sparkles")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(model.isScanning || model.isWorking)

            if model.isScanning {
              Button("Cancel") { model.cancelCurrentOperation() }
                .controlSize(.large)
            } else if model.selectedCleanupBytes > 0 {
              Button("Review & Clean \(ByteFormatter.string(model.selectedCleanupBytes))") {
                model.reviewCleanup()
              }
              .controlSize(.large)
            }
          }

          if let date = model.lastScanDate {
            HStack(spacing: 6) {
              Image(systemName: "clock")
              Text("Last scan \(date.formatted(date: .omitted, time: .shortened))")
              if let duration = model.lastScanDuration {
                Text("• \(duration.formatted(.number.precision(.fractionLength(1))))s")
              }
            }
            .font(.caption)
            .foregroundStyle(.tertiary)
          }
        }
        Spacer(minLength: 0)
      }
    }
  }

  private var moduleGrid: some View {
    LazyVGrid(
      columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 14
    ) {
      moduleCard(
        title: "Applications",
        detail: "Inspect app bundles and related Library data before uninstalling.",
        icon: "app.dashed", value: "\(model.apps.count) apps", section: .applications)
      moduleCard(
        title: "Large Files",
        detail: "Find space-hungry files without touching protected Library data.",
        icon: "externaldrive",
        value: model.largeFiles.isEmpty ? "Review manually" : "\(model.largeFiles.count) found",
        section: .largeFiles)
      moduleCard(
        title: "Duplicates",
        detail: "Verify exact copies with staged SHA-256 instead of filename guessing.",
        icon: "square.on.square",
        value: model.duplicateGroups.isEmpty
          ? "Exact matching" : "\(model.duplicateGroups.count) groups", section: .duplicates)
      moduleCard(
        title: "Startup Items",
        detail: "See launch agents and daemons that can affect login performance.",
        icon: "bolt.horizontal.circle", value: "\(model.startupItems.count) items",
        section: .startup)
      moduleCard(
        title: "History",
        detail: "Keep a local audit trail of every Trash operation this app performs.",
        icon: "clock.arrow.circlepath", value: "\(model.history.count) actions", section: .history)
      moduleCard(
        title: "Exclusions",
        detail: "Protect folders you never want cleanup or review scans to inspect.",
        icon: "hand.raised", value: "\(model.ignoredPaths.count) protected", section: .settings)
    }
  }

  private func moduleCard(
    title: String, detail: String, icon: String, value: String, section: AppViewModel.Section
  ) -> some View {
    Button {
      model.selectedSection = section
    } label: {
      SurfaceCard {
        VStack(alignment: .leading, spacing: 10) {
          HStack {
            Image(systemName: icon)
              .font(.title3.weight(.semibold))
              .foregroundStyle(AppTheme.accent)
            Spacer()
            Image(systemName: "arrow.up.right")
              .font(.caption.bold())
              .foregroundStyle(.tertiary)
          }
          Text(title).font(.headline)
          Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(2)
          Text(value).font(.caption.weight(.semibold)).foregroundStyle(AppTheme.accent)
        }
        .frame(maxWidth: .infinity, minHeight: 112, alignment: .leading)
      }
    }
    .buttonStyle(.plain)
  }

  private var cleanupPreview: some View {
    SurfaceCard {
      VStack(alignment: .leading, spacing: 13) {
        HStack {
          VStack(alignment: .leading, spacing: 2) {
            Text("Cleanup preview").font(.headline)
            Text("Safe items are preselected; review items remain opt-in.")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
          Spacer()
          Button("Review all") { model.selectedSection = .cleaner }
        }

        Divider()

        if model.cleanupTargets.isEmpty && !model.isScanning {
          Text("No reclaimable cleanup targets found yet.")
            .foregroundStyle(.secondary)
            .padding(.vertical, 14)
        } else {
          ForEach(model.cleanupTargets.prefix(6)) { item in
            HStack(spacing: 12) {
              Image(systemName: item.isSelected ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(item.isSelected ? AppTheme.accent : .secondary)
              VStack(alignment: .leading, spacing: 2) {
                Text(item.displayName).fontWeight(.medium)
                Text(item.detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
              }
              Spacer()
              RiskBadge(risk: item.risk)
              Text(ByteFormatter.string(item.size))
                .font(.callout.monospacedDigit())
                .frame(width: 92, alignment: .trailing)
            }
          }
        }
      }
    }
  }
}
