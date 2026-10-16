import MacCleanerCore
import SwiftUI

struct RootView: View {
  @EnvironmentObject private var model: AppViewModel
  @EnvironmentObject private var account: AccountStore
  @EnvironmentObject private var updates: UpdateService
  @AppStorage(CareService.Keys.onboardingDone) private var onboardingDone = false
  @State private var showingIssues = false
  @State private var showingOnboarding = false

  var body: some View {
    NavigationSplitView {
      VStack(spacing: 0) {
        sidebarBrand
          .padding(.horizontal, 12)
          .padding(.top, 12)
          .padding(.bottom, 8)

        List(
          AppViewModel.Section.allCases.filter { $0 != .assistant || account.aiAvailable },
          selection: Binding(
            get: { Optional(model.selectedSection) },
            set: { if let section = $0 { model.selectedSection = section } }
          )
        ) { section in
          Label(section.rawValue, systemImage: section.icon)
            .font(.callout.weight(.medium))
            .padding(.vertical, 4)
            .badge(section == .review ? model.queuedCount : 0)
            .tag(section)
        }
        .listStyle(.sidebar)

        sidebarFooter
          .padding(12)
      }
      .navigationSplitViewColumnWidth(min: 210, ideal: 230, max: 260)
    } detail: {
      Group {
        switch model.selectedSection {
        case .dashboard: DashboardView()
        case .review: ReviewQueueView()
        case .cleaner: CleanerView()
        case .storage: StorageExplorerView()
        case .developer: DeveloperView()
        case .assistant: AssistantView()
        case .photos: PhotosView()
        case .removedApps: RemovedAppsView()
        case .downloads: DownloadsView()
        case .performance: PerformanceView()
        case .applications: ApplicationsView()
        case .largeFiles: LargeFilesView()
        case .duplicates: DuplicatesView()
        case .startup: StartupItemsView()
        case .history: HistoryView()
        case .settings: SettingsView()
        }
      }
      .background(Color(nsColor: .windowBackgroundColor))
      .safeAreaInset(edge: .top, spacing: 0) {
        updateBanner
      }
      .safeAreaInset(edge: .bottom) {
        operationBar
      }
    }
    .sheet(isPresented: $showingIssues) {
      ScanIssueSheet(issues: model.scanIssues)
    }
    .sheet(item: $model.pendingPlan) { plan in
      PlanReviewSheet(plan: plan)
    }
    .sheet(item: $model.lastReport) { report in
      OperationReportSheet(report: report)
    }
    .alert(
      "Couldn't restore",
      isPresented: Binding(
        get: { model.restoreConflict != nil }, set: { if !$0 { model.restoreConflict = nil } }),
      presenting: model.restoreConflict
    ) { conflict in
      Button("Restore to Another Folder…") { model.restoreElsewhere(conflict) }
      Button("Show in Trash") { model.revealInTrash(conflict.receipt) }
      Button("Cancel", role: .cancel) {}
    } message: { conflict in
      Text(conflict.message)
    }
    .sheet(item: $model.explainTarget) { target in
      ExplainSheet(target: target)
    }
    .sheet(isPresented: $model.aiConsentPending) {
      AIConsentSheet()
    }
    .sheet(isPresented: $model.showingCommandPalette) {
      CommandPalette()
    }
    .sheet(isPresented: $showingOnboarding) {
      OnboardingView()
    }
    .onAppear {
      if !onboardingDone {
        showingOnboarding = true
      } else if model.cleanupTargets.isEmpty {
        model.runSmartScan()
      }
    }
  }

  private var sidebarBrand: some View {
    HStack(spacing: 11) {
      BrandMark()
      VStack(alignment: .leading, spacing: 1) {
        Text("MacMint")
          .font(.headline)
        Text(account.isOffline ? "Pro • Offline" : "Pro")
          .font(.caption2)
          .foregroundStyle(.secondary)
      }
      Spacer()
    }
  }

  private var sidebarFooter: some View {
    let stats = model.volumeStats
    let fraction = stats.total > 0 ? min(1, Double(stats.used) / Double(stats.total)) : 0
    return VStack(alignment: .leading, spacing: 8) {
      HStack {
        Text(model.volumeName)
          .lineLimit(1)
          .font(.caption.weight(.semibold))
        Spacer()
        Text(ByteFormatter.string(stats.free) + " free")
          .font(.caption2)
          .foregroundStyle(.secondary)
      }
      ProgressView(value: fraction)
        .progressViewStyle(.linear)
      Text("Trash-first • Scans stay local")
        .font(.caption2)
        .foregroundStyle(.tertiary)
    }
    .padding(12)
    .background(AppTheme.panel, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
  }

  @ViewBuilder
  private var updateBanner: some View {
    if let release = updates.bannerRelease {
      HStack(spacing: 10) {
        Image(systemName: updates.isRequired ? "exclamationmark.triangle.fill" : "arrow.down.circle.fill")
          .foregroundStyle(updates.isRequired ? .orange : AppTheme.accentText)
        Text(
          updates.isRequired
            ? "This version of MacMint is no longer supported. Please update to \(release.version)."
            : "MacMint \(release.version) is available — you have \(UpdateService.currentVersion)."
        )
        .font(.callout)
        Spacer()
        Button("Download") { updates.openDownload(release) }
          .buttonStyle(.borderedProminent)
          .controlSize(.small)
        if !updates.isRequired {
          Button {
            updates.dismissedVersion = release.version
          } label: {
            Image(systemName: "xmark")
              .accessibilityLabel("Dismiss")
          }
          .buttonStyle(.borderless)
          .accessibilityLabel("Dismiss update notice")
        }
      }
      .padding(.horizontal, 16)
      .padding(.vertical, 8)
      .background(.bar)
      .overlay(alignment: .bottom) { Divider() }
    }
  }

  private var operationBar: some View {
    HStack(spacing: 10) {
      if model.isWorking, let progress = model.operationProgress {
        ProgressView(value: progress.fraction)
          .progressViewStyle(.circular)
          .controlSize(.small)
      } else if model.isScanning || model.isWorking || model.isPreparingPlan {
        ProgressView().controlSize(.small)
      } else {
        Image(
          systemName: model.scanIssues.isEmpty
            ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
        )
        .foregroundStyle(model.scanIssues.isEmpty ? .green : .orange)
      }

      VStack(alignment: .leading, spacing: 1) {
        if let title = model.operationTitle {
          Text(title).font(.caption.weight(.semibold))
        }
        Text(model.statusMessage)
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }

      Spacer()

      if model.isWorking, let progress = model.operationProgress {
        Text("\(progress.completed) of \(progress.total)")
          .font(.caption.monospacedDigit())
          .foregroundStyle(.secondary)
        ProgressView(value: progress.fraction)
          .frame(width: 140)
      }

      if model.isScanning || model.isWorking {
        Button(model.isWorking ? "Stop" : "Cancel") { model.cancelCurrentOperation() }
          .controlSize(.small)
      }

      if !model.scanIssues.isEmpty {
        Button {
          showingIssues = true
        } label: {
          Label(
            "\(model.scanIssues.count) issue\(model.scanIssues.count == 1 ? "" : "s")",
            systemImage: "exclamationmark.triangle")
        }
        .controlSize(.small)
      }
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 8)
    .background(.bar)
    .overlay(alignment: .top) { Divider() }
  }
}
