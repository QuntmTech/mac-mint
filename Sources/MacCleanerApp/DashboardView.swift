import MacCleanerCore
import SwiftUI

struct DashboardView: View {
  @EnvironmentObject private var model: AppViewModel
  @Environment(\.colorSchemeContrast) private var contrast

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 24) {
        PageHeader("Overview", subtitle: "Understand your storage. Choose what to keep.", eyebrow: "A little more breathing room")
        hero
        SystemHealthRow(volume: model.volume) { model.selectedSection = .performance }
        let categories = OverviewPresentation.categories(model.recommendations)
        StorageOverviewCard(categories: categories, volume: model.volume, scanned: model.lastScanDate != nil)
        if categories.isEmpty { metrics } else { categoryTiles(categories) }
        if !model.recommendations.isEmpty { SmartCareList() }
        tools
        coverage
        trashCard
        SpaceHistoryCard()
      }
      .frame(maxWidth: 1200).padding(AppTheme.pagePadding).frame(maxWidth: .infinity)
    }
    .onAppear {
      guard !SmokeTest.isRequested else { return }
      model.refreshTrashStatus(); model.recordFreeSpace(); model.refreshRecommendations()
    }
  }

  private var metrics: some View {
    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 14), count: 3), spacing: 14) {
      MetricCard(title: "Rebuildable data", value: scannedValue(model.reclaimableBytes),
        subtitle: "Caches and generated files", icon: "arrow.triangle.2.circlepath", swatch: AppTheme.Swatch.mint,
        action: { model.selectedSection = .cleaner })
      MetricCard(title: "A closer look", value: scannedValue(model.reviewableBytes),
        subtitle: "Items that need your judgment", icon: "eye", swatch: AppTheme.Swatch.amber,
        action: { model.selectedSection = .cleaner })
      MetricCard(title: "Installed apps", value: model.lastScanDate == nil && model.apps.isEmpty ? "—" : "\(model.apps.count)",
        subtitle: "Inspect apps and related files", icon: "square.grid.2x2", swatch: AppTheme.Swatch.violet,
        action: { model.selectedSection = .applications })
    }
  }

  /// What Quick Scan found, one colored tile per area, largest first.
  private func categoryTiles(_ categories: [OverviewPresentation.Category]) -> some View {
    VStack(alignment: .leading, spacing: 14) {
      HStack(alignment: .firstTextBaseline) {
        Text("Where space can come back").font(.system(size: 18, weight: .semibold)).tracking(-0.3)
        Spacer()
        Text("Estimates · you review everything first").font(.caption).foregroundStyle(.secondary)
      }
      LazyVGrid(columns: [GridItem(.adaptive(minimum: 190), spacing: 14)], spacing: 14) {
        ForEach(categories) { category in
          CategoryTile(category: category) {
            if category.destination == .trash { model.emptyTrash() } else { model.open(category.destination) }
          }
        }
      }
    }
  }

  private func scannedValue(_ bytes: Int64) -> String {
    model.lastScanDate == nil && model.cleanupTargets.isEmpty ? "—" : ByteFormatter.string(bytes)
  }

  private var hero: some View {
    let stats = model.volume
    return HStack(spacing: 24) {
      VStack(alignment: .leading, spacing: 16) {
        Label("QUICK SCAN", systemImage: "sparkle")
          .font(.system(size: 10, weight: .semibold)).tracking(1.6).foregroundStyle(AppTheme.accentText)
        VStack(alignment: .leading, spacing: 10) {
          Text(model.isScanning ? "Getting the full picture." : "Make space, confidently.")
            .font(.system(size: 32, weight: .semibold)).tracking(-1.1).foregroundStyle(AppTheme.ink)
            .fixedSize(horizontal: false, vertical: true)
          Text("Find caches, app leftovers, and developer clutter. You review every change before anything moves.")
            .font(.callout).foregroundStyle(AppTheme.ink.opacity(0.75))
            .fixedSize(horizontal: false, vertical: true).frame(maxWidth: 410, alignment: .leading)
        }
        ViewThatFits(in: .horizontal) {
          HStack(spacing: 10) { scanButton; reviewButton }
          VStack(alignment: .leading, spacing: 10) { scanButton; reviewButton }
        }
        HStack(spacing: 6) {
          if model.isScanning {
            ProgressView().controlSize(.mini)
            Text(model.scanCompletedAreas.isEmpty ? "Checking known storage locations…" : "\(model.scanCompletedAreas.count) categories complete")
          } else {
            Image(systemName: model.lastScanDate == nil ? "lock.shield" : "clock")
            if let date = model.lastScanDate {
              Text("Last scanned \(date.formatted(.relative(presentation: .named)))")
            } else { Text("Local scan · No account needed") }
          }
        }.font(.caption).foregroundStyle(AppTheme.ink.opacity(0.82))
      }.frame(maxWidth: .infinity, alignment: .leading)
      VStack(spacing: 18) {
        StorageRing(used: stats.used, total: stats.total,
          centerValue: stats.isMeasured ? ByteFormatter.string(stats.free) : "—",
          centerLabel: stats.isMeasured ? "available" : "unavailable")
        Text(stats.isMeasured ? "\(ByteFormatter.string(stats.used)) of \(ByteFormatter.string(stats.total)) used"
          : "macOS did not report this disk's capacity")
          .font(.caption).foregroundStyle(AppTheme.ink.opacity(0.82)).monospacedDigit()
      }.padding(.horizontal, 12)
    }
    .padding(28).frame(maxWidth: .infinity, alignment: .leading)
    .background {
      RoundedRectangle(cornerRadius: 22).fill(LinearGradient(
        colors: [AppTheme.heroStart, AppTheme.heroMiddle, AppTheme.heroEnd],
        startPoint: .topLeading, endPoint: .bottomTrailing))
        .overlay(alignment: .topTrailing) {
          Circle().fill(AppTheme.ink.opacity(0.025)).frame(width: 280, height: 280)
            .offset(x: 75, y: -100).allowsHitTesting(false)
        }.clipShape(RoundedRectangle(cornerRadius: 22))
    }
    .overlay(RoundedRectangle(cornerRadius: 22).strokeBorder(AppTheme.accentText.opacity(0.15)))
  }

  private var scanButton: some View {
    Button { model.runSmartCare() } label: {
      Label(model.isScanning ? "Scanning…" : "Run Quick Scan", systemImage: "sparkles")
    }.buttonStyle(MintButtonStyle()).disabled(model.isScanning || model.isWorking)
  }

  @ViewBuilder private var reviewButton: some View {
    if model.isScanning {
      Button("Cancel scan") { model.cancelCurrentOperation() }.buttonStyle(MintButtonStyle(prominent: false))
    } else if model.safeRecommendationBytes > 0 {
      Button { model.reviewAllSafe() } label: {
        Label("Review \(ByteFormatter.string(model.safeRecommendationBytes))", systemImage: "checklist")
      }.buttonStyle(MintButtonStyle(prominent: false)).disabled(model.isWorking)
        .help("Review rebuildable items before moving them to Trash")
    }
  }

  private var tools: some View {
    VStack(alignment: .leading, spacing: 14) {
      HStack {
        Text("Take a closer look").font(.system(size: 18, weight: .semibold)).tracking(-0.3)
        Spacer()
        Text("Your files. Your decisions.").font(.caption).foregroundStyle(.secondary)
      }
      LazyVGrid(columns: [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14)], spacing: 14) {
        tool("Explore storage", detail: "See what’s taking up room, folder by folder.", symbol: "chart.pie", section: .storage)
        tool("Manage apps", detail: "Inspect apps and the data they leave behind.", symbol: "square.grid.2x2", section: .applications)
        tool("Review photos", detail: "Compare similar shots and choose your keeper.", symbol: "photo.on.rectangle.angled", section: .photos)
        tool("Developer workspace", detail: "Understand build output, caches, and local models.", symbol: "hammer", section: .developer)
      }
    }
  }

  /// A colored tile in its area's sidebar color; white text meets WCAG AA on every swatch.
  private func tool(_ title: String, detail: String, symbol: String, section: AppViewModel.Section) -> some View {
    let swatch = section.swatch
    let shape = RoundedRectangle(cornerRadius: AppTheme.corner, style: .continuous)
    return Button { model.selectedSection = section } label: {
      HStack(alignment: .top, spacing: 13) {
        Image(systemName: symbol).font(.system(size: 17, weight: .semibold))
          .frame(width: 40, height: 40)
          .background(Color.white.opacity(0.2), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
          .accessibilityHidden(true)
        VStack(alignment: .leading, spacing: 5) {
          Text(title).font(.system(size: 13, weight: .semibold))
          Text(detail).font(.caption).fixedSize(horizontal: false, vertical: true)
        }.frame(maxWidth: .infinity, alignment: .leading)
        Image(systemName: "arrow.up.right").font(.caption.weight(.semibold))
      }
      .foregroundStyle(.white)
      .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
      .padding(AppTheme.cardPadding)
      .background(swatch.gradient, in: shape)
      .overlay(shape.strokeBorder(Color.white.opacity(contrast == .increased ? 0.7 : 0.12), lineWidth: contrast == .increased ? 2 : 1))
      .shadow(color: swatch.color.opacity(0.28), radius: 10, y: 5)
      .contentShape(shape)
    }.buttonStyle(TileButtonStyle()).accessibilityElement(children: .combine)
  }

  private var coverage: some View {
    SurfaceCard {
      DisclosureGroup {
        VStack(alignment: .leading, spacing: 10) {
          Text(model.scanCompletedAreas.isEmpty
            ? "Quick Scan checks known cache, app, developer, Downloads, and home Trash locations. Run a scan to see coverage here."
            : "Completed: " + model.scanCompletedAreas.joined(separator: "; "))
          Text("Storage mapping, duplicate matching, Photos analysis, and project searches run separately.")
          if !model.scanIssues.isEmpty {
            Button("Review \(model.scanIssues.count) scan issues") { model.showingScanIssues = true }
          }
          Button("Manage exclusions") { model.selectedSection = .settings }
        }.font(.callout).foregroundStyle(.secondary).padding(.top, 12)
      } label: {
        HStack(spacing: 12) {
          IconTile(symbol: "checklist", size: 34, swatch: AppTheme.Swatch.slate)
          VStack(alignment: .leading, spacing: 3) {
            Text("Know what’s been checked").font(.system(size: 13, weight: .semibold))
            Text("\(model.scanCompletedAreas.count) completed categories · \(model.ignoredPaths.count) exclusions · \(model.scanIssues.count) issues")
              .font(.caption).foregroundStyle(.secondary)
          }
          Spacer()
        }
      }
    }
  }

  @ViewBuilder private var trashCard: some View {
    if let status = model.trashStatus, status.items > 0 || !status.isComplete {
      SurfaceCard {
        HStack(spacing: 14) {
          IconTile(symbol: "trash", swatch: AppTheme.Swatch.graphite)
          VStack(alignment: .leading, spacing: 4) {
            Text("Still in the Trash").font(.headline)
            Text(status.isComplete
              ? "\(ByteFormatter.string(status.bytes)) in \(status.items) items in your home Trash. Space is released after emptying it."
              : "Full Disk Access is needed to measure your home Trash.")
              .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
          }
          Spacer(minLength: 12)
          Button("Open in Finder") { model.emptyTrash() }.disabled(model.isWorking)
        }
      }
    }
  }
}
