import AppKit
import MacCleanerCore
import SwiftUI

struct RootView: View {
  @EnvironmentObject private var model: AppViewModel
  @EnvironmentObject private var account: AccountStore
  @EnvironmentObject private var updates: UpdateService
  @AppStorage(CareService.Keys.onboardingDone) private var onboardingDone = false
  @State private var showingOnboarding = false

  var body: some View {
    NavigationSplitView {
      VStack(spacing: 0) {
        sidebarBrand
          .padding(.horizontal, 12)
          .padding(.top, 12)
          .padding(.bottom, 8)

        VStack(alignment: .leading, spacing: 5) {
          Text("WORKSPACE").font(.system(size: 9, weight: .semibold)).tracking(1.6)
            .foregroundStyle(.secondary).padding(.leading, 12).padding(.bottom, 7)
          ForEach(AppViewModel.Section.primary) { section in
            sidebarDestination(section)
          }
        }.padding(.horizontal, 12).padding(.top, 22)

        Spacer(minLength: 16)

        Button { model.showingCommandPalette = true } label: {
          HStack {
            Image(systemName: "magnifyingglass")
            Text("Go to…")
            Spacer()
            Text("⌘K").font(.caption).foregroundStyle(.secondary)
          }.font(.callout).foregroundStyle(.secondary).padding(10)
            .background(AppTheme.surface.opacity(0.6), in: RoundedRectangle(cornerRadius: 9))
        }.buttonStyle(.plain).padding(.horizontal, 16).padding(.bottom, 12)
        sidebarFooter.padding(.horizontal, 12).padding(.bottom, 12)
        Divider().padding(.horizontal, 16)
        HStack(spacing: 8) {
          Button { model.selectedSection = .settings } label: {
            Label("Settings", systemImage: "gearshape").font(.callout)
          }.buttonStyle(.plain)
            .foregroundStyle(model.selectedSection == .settings ? AppTheme.accentText : Color.secondary)
          Spacer()
          Button { model.showingHelp = true } label: { Image(systemName: "questionmark.circle") }
            .buttonStyle(.plain).foregroundStyle(.secondary).help("Help & diagnostics")
            .accessibilityLabel("Help and diagnostics")
        }.padding(18)
      }
      .background(AppTheme.sidebar)
      .navigationSplitViewColumnWidth(min: 200, ideal: 216, max: 250)
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
      .background(AppTheme.canvas)
      .scrollContentBackground(.hidden)
      .safeAreaInset(edge: .top, spacing: 0) {
        VStack(spacing: 0) {
          updateBanner
          if !model.selectedSection.tabs.isEmpty {
            HStack(spacing: 4) {
              ForEach(model.selectedSection.tabs) { section in
                Button { model.selectedSection = section } label: {
                  HStack(spacing: 6) {
                    Image(systemName: section.icon).font(.system(size: 11))
                    Text(section.rawValue).font(.system(size: 12, weight: model.selectedSection == section ? .semibold : .medium))
                  }.padding(.horizontal, 13).padding(.vertical, 8)
                    .foregroundStyle(model.selectedSection == section ? AppTheme.accentText : Color.secondary)
                    .background(model.selectedSection == section ? AppTheme.surface : .clear,
                      in: RoundedRectangle(cornerRadius: 8))
                    .contentShape(RoundedRectangle(cornerRadius: 8))
                }.buttonStyle(.plain)
                  .accessibilityAddTraits(model.selectedSection == section ? .isSelected : [])
              }
              Spacer(minLength: 0)
            }.padding(.horizontal, AppTheme.pagePadding).padding(.vertical, 10)
              .background(AppTheme.canvas).overlay(alignment: .bottom) { Divider().opacity(0.5) }
          }
        }
      }
      .safeAreaInset(edge: .bottom) {
        operationBar
      }
    }
    .toolbar {
      ToolbarItemGroup {
        Button { model.selectedSection = .review } label: {
          HStack(spacing: 7) {
            Image(systemName: "checklist")
            Text("Review")
            if model.queuedCount > 0 {
              Text("\(model.queuedCount)").font(.caption.weight(.semibold))
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(AppTheme.selection, in: Capsule())
            }
          }
        }
        .help("Review selected items · " + ByteFormatter.string(model.queuedBytes))
        if account.aiAvailable { Button { model.selectedSection = .assistant } label: { Label("Ask MacMint", systemImage: "sparkles") } }
        Button { model.showingAccount = true } label: {
          Label(account.isUnlocked ? "Account" : "Get Pro", systemImage: "person.crop.circle")
        }
      }
    }
    .sheet(isPresented: $model.showingAccount, onDismiss: {
      if account.isUnlocked, let plan = model.deferredPlan {
        model.deferredPlan = nil
        model.pendingPlan = OperationPlanner.plan(title: plan.title, items: plan.items + plan.covered, ignoredPaths: model.ignoredPaths)
      }
    }) { AccountAccessSheet() }
    .sheet(isPresented: $model.showingHelp) { HelpView() }
    .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
      guard !SmokeTest.isRequested else { return }
      Task {
        await account.refreshAccess()
        await account.refreshAIStatus()
      }
    }
    .sheet(isPresented: $model.showingScanIssues) {
      ScanIssueSheet(issues: model.scanIssues)
    }
    .sheet(item: $model.pendingPlan) { plan in
      PlanReviewSheet(plan: model.normalizeReview(plan))
    }
    .sheet(item: $model.lastReport) { report in
      OperationReportSheet(report: report)
    }
    .sheet(isPresented: Binding(
      get: { !model.restoreConflicts.isEmpty },
      set: { if !$0 { model.restoreConflicts = [] } })) {
      RestoreConflictsSheet()
    }
    .sheet(item: $model.explainTarget) { target in
      ExplainSheet(target: target)
    }
    .sheet(isPresented: $model.aiConsentPending, onDismiss: { model.pendingAIAction = nil }) {
      AIConsentSheet()
    }
    .sheet(isPresented: $model.showingCommandPalette) {
      CommandPalette()
    }
    .sheet(isPresented: $showingOnboarding) {
      OnboardingView()
    }
    .onChange(of: account.snapshot?.user.id) { _, _ in model.resetAIState() }
    .onAppear {
      guard !SmokeTest.isRequested else { return }
      model.authorizeRemoval = { [weak account] in account?.isUnlocked == true }
      if !onboardingDone {
        showingOnboarding = true
      } else if model.cleanupTargets.isEmpty {
        model.runSmartScan()
      }
    }
  }

  private var sidebarBrand: some View {
    HStack(spacing: 11) {
      BrandMark().frame(width: 36, height: 36)
      VStack(alignment: .leading, spacing: 1) {
        Text("MacMint")
          .font(.system(size: 18, weight: .semibold)).tracking(-0.4)
        Text(account.isUnlocked ? (account.isOffline ? "Pro • Offline" : "Pro") : "Local inspection")
          .font(.caption2)
          .foregroundStyle(.secondary)
      }
      Spacer()
    }
  }

  private func sidebarDestination(_ section: AppViewModel.Section) -> some View {
    let selected = model.selectedSection.parent == section
    return Button { model.selectedSection = section } label: {
      HStack(spacing: 11) {
        Image(systemName: section.icon).font(.system(size: 16, weight: selected ? .semibold : .regular))
          .frame(width: 22)
        Text(section.rawValue).font(.system(size: 13, weight: selected ? .semibold : .medium))
        Spacer(minLength: 0)
        if selected { Circle().fill(AppTheme.accentText).frame(width: 5, height: 5) }
      }.foregroundStyle(selected ? AppTheme.accentText : AppTheme.ink.opacity(0.8))
        .padding(.horizontal, 12).padding(.vertical, 11)
        .background(selected ? AppTheme.selection : .clear, in: RoundedRectangle(cornerRadius: 10))
        .contentShape(RoundedRectangle(cornerRadius: 10))
    }.buttonStyle(.plain).accessibilityAddTraits(selected ? .isSelected : [])
      .help(section.rawValue)
  }

  private var sidebarFooter: some View {
    let stats = model.volumeStats
    let fraction = stats.total > 0 ? min(1, Double(stats.used) / Double(stats.total)) : 0
    return VStack(alignment: .leading, spacing: 11) {
      HStack(spacing: 8) {
        Image(systemName: "internaldrive").foregroundStyle(AppTheme.accentText)
        Text(model.volumeName).lineLimit(1).font(.caption.weight(.semibold))
      }
      GeometryReader { geometry in
        Capsule().fill(AppTheme.border)
          .overlay(alignment: .leading) {
            Capsule().fill(AppTheme.accentText).frame(width: geometry.size.width * fraction)
          }
      }.frame(height: 5).accessibilityLabel("Disk \(Int(fraction * 100)) percent used")
      HStack(alignment: .firstTextBaseline, spacing: 4) {
        Text(ByteFormatter.string(stats.free)).font(.system(size: 17, weight: .semibold)).monospacedDigit()
        Text("available").font(.caption).foregroundStyle(.secondary)
      }
    }.padding(14).background(AppTheme.surface.opacity(0.7), in: RoundedRectangle(cornerRadius: 13))
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
      .background(AppTheme.surface)
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
            ? "leaf" : "exclamationmark.triangle.fill"
        )
        .foregroundStyle(model.scanIssues.isEmpty ? AppTheme.accentText : .orange)
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
          model.showingScanIssues = true
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
    .background(AppTheme.surface)
    .overlay(alignment: .top) { Divider() }
  }
}
