import AppKit
import MacCleanerCore
import SwiftUI

struct RootView: View {
  @EnvironmentObject private var model: AppViewModel
  @EnvironmentObject private var account: AccountStore
  @EnvironmentObject private var updates: UpdateService
  @EnvironmentObject private var updater: UpdaterController
  @AppStorage(CareService.Keys.onboardingDone) private var onboardingDone = false
  @State private var showingOnboarding = false
  @State private var scanAfterSetup = false
  @State private var hoveredSection: AppViewModel.Section?
  @State private var lastTabs: [AppViewModel.Section: AppViewModel.Section] = [:]

  var body: some View {
    NavigationSplitView {
      VStack(spacing: 0) {
        sidebarBrand
          .background(GeometryReader { geometry in Color.clear.preference(key: WorkspaceLayoutFrames.self, value: ["brand": geometry.frame(in: .global)]) })
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
      GeometryReader { geometry in
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
      .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
      }
      .background(AppTheme.canvas)
      .scrollContentBackground(.hidden)
      .safeAreaInset(edge: .top, spacing: 0) {
        VStack(spacing: 0) {
          updateBanner
          workspaceBar
            .background(GeometryReader { geometry in Color.clear.preference(key: WorkspaceLayoutFrames.self, value: ["workspace controls": geometry.frame(in: .global)]) })
        }
      }
      .safeAreaInset(edge: .bottom) {
        operationBar
      }
    }
    .sheet(isPresented: $model.showingAccount, onDismiss: {
      // Only a paid action's gate returns to its review; opening the account never does. A
      // gate closed without access drops its plan (the selections stay in the review queue).
      guard model.accountPurpose == .paidAction else { return }
      if account.isUnlocked, let plan = model.deferredPlan {
        model.pendingPlan = OperationPlanner.plan(title: plan.title, items: plan.items + plan.covered, ignoredPaths: model.ignoredPaths)
      }
      model.deferredPlan = nil
    }) { AccountAccessSheet(purpose: model.accountPurpose, hasDeferredPlan: model.deferredPlan != nil) }
    .sheet(isPresented: $model.showingHelp) { HelpView() }
    .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
      guard !SmokeTest.isRequested else { return }
      Task {
        await account.refreshAccess()
        await account.refreshAIStatusIfStale()
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
    .sheet(isPresented: $showingOnboarding, onDismiss: {
      guard scanAfterSetup else { return }
      scanAfterSetup = false
      model.selectedSection = .dashboard
      model.runSmartCare()
    }) {
      OnboardingView(onFinish: { scanAfterSetup = $0 })
    }
    .onChange(of: model.selectedSection) { old, section in
      lastTabs[section.parent] = section
      if old == .photos || old == .duplicates || old == .applications { PreviewCaches.release(); MemoryRelief.shared.relieveSoon() }
      if old == .storage { model.compactStorageMap(); MemoryRelief.shared.relieveSoon() }
    }
    .onChange(of: account.snapshot?.user.id) { _, _ in model.resetAIState() }
    .onAppear {
      guard !SmokeTest.isRequested else { return }
      model.authorizeRemoval = { [weak account] in account?.isUnlocked == true }
      if !onboardingDone {
        showingOnboarding = true
      }
    }
    .task { await ResourceProbeSession.runIfRequested(model) }
    .task {
      // The sidebar's disk reading: on appear, after operations (recordFreeSpace), and every
      // minute while the workspace is in front. Hidden or background windows skip it.
      guard !SmokeTest.isRequested else { return }
      var refreshed = false
      while !Task.isCancelled {
        if !refreshed || AppActivity.shared.isForeground { await model.refreshVolumeSummary(); refreshed = true }
        try? await Task.sleep(for: .seconds(60))
      }
    }
  }

  private var workspaceBar: some View {
    HStack(spacing: 6) {
      if model.selectedSection.tabs.isEmpty {
        Label("Your workspace", systemImage: "square.grid.2x2").font(.caption).foregroundStyle(.secondary)
      } else {
        ForEach(model.selectedSection.tabs) { section in
          Button { model.selectedSection = section } label: {
            HStack(spacing: 6) {
              Image(systemName: section.icon).font(.system(size: 11))
              Text(section.rawValue).font(.system(size: 12, weight: model.selectedSection == section ? .semibold : .medium))
            }.padding(.horizontal, 11).padding(.vertical, 8)
              .foregroundStyle(model.selectedSection == section ? AppTheme.accentText : Color.secondary)
              .background(model.selectedSection == section ? AppTheme.surface : .clear, in: RoundedRectangle(cornerRadius: 8))
              .contentShape(RoundedRectangle(cornerRadius: 8))
          }.buttonStyle(.plain).accessibilityAddTraits(model.selectedSection == section ? .isSelected : [])
        }
      }
      Spacer(minLength: 8)
      if account.aiAvailable {
        Button { model.selectedSection = .assistant } label: {
          Image(systemName: "sparkles").font(.system(size: 15)).frame(width: 30, height: 30)
        }.buttonStyle(.plain).foregroundStyle(AppTheme.accentText)
          .help("Ask MacMint").accessibilityLabel("Ask MacMint")
      }
      Button { model.selectedSection = .review } label: {
        HStack(spacing: 7) {
          Image(systemName: "checklist")
          Text("Review").fontWeight(.medium)
          if model.queuedCount > 0 {
            Text("\(model.queuedCount)").font(.system(size: 10, weight: .semibold)).monospacedDigit()
              .foregroundStyle(.white).padding(.horizontal, 6).padding(.vertical, 2)
              .background(AppTheme.accent, in: Capsule())
          }
        }.font(.system(size: 12)).padding(.horizontal, 11).padding(.vertical, 8)
          .foregroundStyle(AppTheme.accentText)
          .background(model.queuedCount > 0 || model.selectedSection == .review ? AppTheme.selection : AppTheme.surface,
            in: RoundedRectangle(cornerRadius: 8)).contentShape(RoundedRectangle(cornerRadius: 8))
      }.buttonStyle(.plain).help("Review selected items · " + ByteFormatter.string(model.queuedBytes))
      Button { model.openAccount() } label: {
        Image(systemName: "person.crop.circle").font(.system(size: 19)).frame(width: 32, height: 32)
      }.buttonStyle(.plain).foregroundStyle(.secondary)
        .help(account.isUnlocked ? "Account" : "Connect your MacMint account")
        .accessibilityLabel(account.isUnlocked ? "Account" : "Connect your MacMint account")
    }.padding(.horizontal, AppTheme.pagePadding).padding(.vertical, 10)
      .background(AppTheme.canvas).overlay(alignment: .bottom) { Divider().opacity(0.5) }
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
    return Button { model.selectedSection = lastTabs[section] ?? section } label: {
      HStack(spacing: 11) {
        SwatchBadge(symbol: section.icon, swatch: section.swatch, size: 24)
        Text(section.rawValue).font(.system(size: 13, weight: selected ? .semibold : .medium))
        Spacer(minLength: 0)
        if selected { Circle().fill(AppTheme.accentText).frame(width: 5, height: 5) }
      }.foregroundStyle(selected ? AppTheme.ink : AppTheme.ink.opacity(0.8))
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(selected ? AppTheme.selection : hoveredSection == section ? AppTheme.panel : .clear, in: RoundedRectangle(cornerRadius: 10))
        .contentShape(RoundedRectangle(cornerRadius: 10))
    }.buttonStyle(.plain).onHover { hoveredSection = $0 ? section : nil }
      .accessibilityAddTraits(selected ? .isSelected : []).accessibilityLabel(section.rawValue)
      .help(section.rawValue)
  }

  private var sidebarFooter: some View {
    let stats = model.volume
    let fraction = stats.total > 0 ? min(1, Double(stats.used) / Double(stats.total)) : 0
    return VStack(alignment: .leading, spacing: 11) {
      HStack(spacing: 8) {
        Image(systemName: "internaldrive").foregroundStyle(AppTheme.accentText)
        Text(stats.name).lineLimit(1).font(.caption.weight(.semibold))
      }
      GeometryReader { geometry in
        Capsule().fill(AppTheme.border)
          .overlay(alignment: .leading) {
            Capsule().fill(AppTheme.accentText).frame(width: geometry.size.width * fraction)
          }
      }.frame(height: 5).accessibilityLabel(stats.isMeasured ? "Disk \(Int(fraction * 100)) percent used" : "Disk space unavailable")
      HStack(alignment: .firstTextBaseline, spacing: 4) {
        Text(stats.isMeasured ? ByteFormatter.string(stats.free) : "—").font(.system(size: 17, weight: .semibold)).monospacedDigit()
        Text(stats.isMeasured ? "available" : "unavailable").font(.caption).foregroundStyle(.secondary)
      }
    }.padding(14).background(AppTheme.surface.opacity(0.7), in: RoundedRectangle(cornerRadius: 13))
  }

  /// One banner for every update source. Sparkle installs whenever it has the update; the
  /// download page remains the fallback for the server's required/available notice.
  @ViewBuilder
  private var updateBanner: some View {
    if updater.isWaitingForWork {
      updateBannerRow(icon: "clock.arrow.circlepath", tint: AppTheme.accentText,
        text: "The update is ready. MacMint restarts to install it when the current operation finishes.")
    } else if let update = updater.reminder {
      updateBannerRow(icon: "arrow.down.circle.fill", tint: AppTheme.accentText,
        text: "MacMint \(update.title) is available — you have \(UpdaterController.current.versionAndBuild).") {
        Button("Install…") { updater.checkForUpdates() }
          .buttonStyle(.borderedProminent)
          .controlSize(.small)
        dismissButton { updater.dismissReminder() }
      }
    } else if let release = updates.bannerRelease {
      updateBannerRow(icon: updates.isRequired ? "exclamationmark.triangle.fill" : "arrow.down.circle.fill",
        tint: updates.isRequired ? .orange : AppTheme.accentText,
        text: updates.isRequired
          ? "This version of MacMint is no longer supported. Please update to \(release.version)."
          : "MacMint \(release.version) is available — you have \(UpdateService.currentVersion).") {
        if updater.availableUpdate != nil {
          Button("Install…") { updater.checkForUpdates() }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        } else {
          Button("Download") { updates.openDownload(release) }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        }
        if !updates.isRequired {
          dismissButton { updates.dismissedVersion = release.version }
        }
      }
    }
  }

  private func updateBannerRow<Actions: View>(icon: String, tint: Color, text: String,
    @ViewBuilder actions: () -> Actions = { EmptyView() }) -> some View {
    HStack(spacing: 10) {
      Image(systemName: icon).foregroundStyle(tint)
      Text(text).font(.callout)
      Spacer()
      actions()
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 8)
    .background(AppTheme.surface)
    .overlay(alignment: .bottom) { Divider() }
  }

  private func dismissButton(_ action: @escaping () -> Void) -> some View {
    Button(action: action) {
      Image(systemName: "xmark")
        .accessibilityLabel("Dismiss")
    }
    .buttonStyle(.borderless)
    .accessibilityLabel("Dismiss update notice")
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

      if model.isScanning || model.isWorking || model.isPreparingPlan {
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
