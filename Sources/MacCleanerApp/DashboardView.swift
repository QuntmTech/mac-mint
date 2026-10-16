import MacCleanerCore
import SwiftUI

struct DashboardView: View {
  @EnvironmentObject private var model: AppViewModel


  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 22) {
        hero
        SurfaceCard {
          VStack(alignment: .leading, spacing: 7) {
            Label("Scan coverage", systemImage: "checklist").font(.headline)
            Text(model.scanCompletedAreas.isEmpty ? "Quick Scan checks known cache, app, developer, Downloads and home Trash locations. Storage maps, duplicate hashing, Photos and project searches run separately." : "Completed: " + model.scanCompletedAreas.joined(separator: "; "))
              .font(.callout).foregroundStyle(.secondary)
            Text("\(model.ignoredPaths.count) exclusions · \(model.scanIssues.count) access or scan issues")
              .font(.caption).foregroundStyle(model.scanIssues.isEmpty ? Color.secondary : Color.orange)
            if let date = model.lastScanDate { Text("Quick Scan updated " + date.formatted()).font(.caption).foregroundStyle(.secondary) }
            if !model.scanIssues.isEmpty { Button("Review coverage issues") { model.showingScanIssues = true } }
          }
        }

        HStack(spacing: 14) {
          MetricCard(
            title: "Rebuildable data",
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

        trashCard

        if !model.recommendations.isEmpty {
          SmartCareList()
        }

        SpaceHistoryCard()

        moduleGrid

        if model.recommendations.isEmpty {
          cleanupPreview
        }
      }
      .padding(AppTheme.pagePadding)
      .onAppear {
        model.refreshTrashStatus()
        model.recordFreeSpace()
        model.refreshRecommendations()
      }
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

          Text("Quick Scan")
            .font(.system(size: 34, weight: .bold, design: .rounded))
          Text(
            "One pass over caches, apps, developer data, Downloads, and leftovers — ranked by how much space each frees and how sure MacMint is. Nothing changes until you review it."
          )
          .font(.callout)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
          .frame(maxWidth: 630, alignment: .leading)

          HStack(spacing: 10) {
            Button {
              model.runSmartCare()
            } label: {
              Label(model.isScanning ? "Scanning…" : "Run Quick Scan", systemImage: "sparkles")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(model.isScanning || model.isWorking)

            if model.isScanning {
              Button("Cancel") { model.cancelCurrentOperation() }
                .controlSize(.large)
            } else if model.safeRecommendationBytes > 0 {
              Button("Review Rebuildable Items (\(ByteFormatter.string(model.safeRecommendationBytes)))") {
                model.reviewAllSafe()
              }
              .controlSize(.large)
              .help("Caches, build data, and firmware that rebuild or re-download automatically")
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

  /// Emptying the Trash is permanent, so it is its own action with its own warning.
  @ViewBuilder
  private var trashCard: some View {
    if let status = model.trashStatus, status.items > 0 || !status.isComplete {
      SurfaceCard {
        HStack(spacing: 14) {
          Image(systemName: "trash.fill")
            .font(.title2)
            .foregroundStyle(AppTheme.accentText)
            .frame(width: 38)
          VStack(alignment: .leading, spacing: 3) {
            Text("Trash").font(.headline)
            if status.isComplete {
              Text(
                "\(ByteFormatter.string(status.bytes)) in \(status.items) item\(status.items == 1 ? "" : "s"). Space is only freed once the Trash is emptied."
              )
              .font(.caption)
              .foregroundStyle(.secondary)
            } else {
              Text("Grant Full Disk Access in Settings to see how much the Trash holds.")
                .font(.caption)
                .foregroundStyle(.secondary)
            }
          }
          Spacer()
          Button("Review Trash in Finder") { model.emptyTrash() }
            .disabled(model.isWorking || status.items == 0)
        }
      }

    }
  }

  private var moduleGrid: some View {
    LazyVGrid(
      columns: Array(repeating: GridItem(.flexible(), spacing: 14), count: 4), spacing: 14
    ) {
      moduleCard(
        title: "Storage",
        detail: "A visual map of what's using your disk — click to dive into any folder.",
        icon: "chart.pie",
        value: model.storageScan.map { ByteFormatter.string($0.root.allocatedBytes) + " mapped" }
          ?? "Map my Mac",
        section: .storage)
      moduleCard(
        title: "Downloads",
        detail: "Big downloads you never opened, using Spotlight's record of what you've used.",
        icon: "arrow.down.circle",
        value: model.downloadsScanned
          ? ByteFormatter.string(model.downloadItems.reduce(0) { $0 + $1.bytes }) + " idle" : "Check Downloads",
        section: .downloads)
      moduleCard(
        title: "Photos",
        detail: "Similar shots, blurry photos, and old screenshots — the best shot is always kept.",
        icon: "photo.on.rectangle.angled",
        value: model.photoScan.map {
          "\($0.similarGroups.reduce(0) { $0 + $1.others.count } + $0.blurry.count) to review"
        } ?? "Check photos",
        section: .photos)
      moduleCard(
        title: "Removed Apps",
        detail: "Settings and caches left behind by apps you've already deleted.",
        icon: "folder.badge.questionmark",
        value: model.orphansScanned
          ? ByteFormatter.string(model.orphans.reduce(0) { $0 + $1.bytes }) + " found" : "Find leftovers",
        section: .removedApps)
      moduleCard(
        title: "Developer & AI",
        detail: "Xcode build data, package caches, project build folders, and local AI models.",
        icon: "hammer",
        value: model.devItems.isEmpty
          ? "Find clutter"
          : ByteFormatter.string(model.devItems.reduce(0) { $0 + $1.bytes }) + " found",
        section: .developer)
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
              .foregroundStyle(AppTheme.accentText)
            Spacer()
            Image(systemName: "arrow.up.right")
              .font(.caption.bold())
              .foregroundStyle(.tertiary)
          }
          Text(title).font(.headline)
          Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(3)
            .fixedSize(horizontal: false, vertical: true)
          Text(value).font(.caption.weight(.semibold)).foregroundStyle(AppTheme.accentText)
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
                .foregroundStyle(item.isSelected ? AppTheme.accentText : .secondary)
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
