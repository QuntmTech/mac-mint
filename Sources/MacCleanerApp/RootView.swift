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
  @State private var hoveredFooter: String?
  @Environment(\.colorScheme) private var colorScheme
  @State private var lastTabs: [AppViewModel.Section: AppViewModel.Section] = [:]

  var body: some View {
    HStack(spacing: 0) {
      sidebar
        .frame(width: 228)
        .background(AppTheme.sidebar.ignoresSafeArea())
      Rectangle().fill(AppTheme.divider).frame(width: 1).ignoresSafeArea()
      VStack(spacing: 0) {
        updateBanner
        workspaceBar
          .background(GeometryReader { geometry in Color.clear.preference(key: WorkspaceLayoutFrames.self, value: ["workspace controls": geometry.frame(in: .global)]) })
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
        .background(AreaWash())
        .scrollContentBackground(.hidden)
        operationBar
      }
      .area(model.selectedSection)
      .background(AppTheme.canvas.ignoresSafeArea())
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
      model.runLaunchScanIfEnabled(inFront: !NSApp.isHidden)
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
      let scan = scanAfterSetup
      scanAfterSetup = false
      model.selectedSection = .dashboard
      if scan { model.runSmartCare() }
      // First run: show where everything is. It never blocks the scan, and it can be skipped.
      if !UserDefaults.standard.bool(forKey: AppViewModel.tourSeenKey) { model.startTour() }
    }) {
      OnboardingView(onFinish: { scanAfterSetup = $0 })
    }
    .onChange(of: model.selectedSection) { old, section in
      lastTabs[section.parent] = section
      if old == .photos || old == .duplicates || old == .applications { PreviewCaches.release(); MemoryRelief.shared.relieveSoon() }
      if old == .storage { model.compactStorageMap(); MemoryRelief.shared.relieveSoon() }
    }
    .onChange(of: account.snapshot?.user.id) { _, _ in model.resetAIState() }
    .overlayPreferenceValue(TourTargetFrames.self) { frames in
      if let index = model.tourStep, GuidedTour.steps.indices.contains(index) {
        TourOverlay(step: GuidedTour.steps[index], index: index, count: GuidedTour.steps.count, frames: frames,
          back: { model.retreatTour() }, next: { model.advanceTour() }, skip: { model.endTour(finished: false) })
      }
    }
    .onAppear {
      guard !SmokeTest.isRequested else { return }
      model.authorizeRemoval = { [weak account] in account?.isUnlocked == true }
      if !onboardingDone {
        showingOnboarding = true
      }
    }
    .task { await ResourceProbeSession.runIfRequested(model) }
    .task(id: model.exclusionsReady) {
      // Quick Scan when MacMint opens, once the window has settled (Settings can turn it off).
      guard model.exclusionsReady, AppViewModel.autoLoadAllowed else { return }
      try? await Task.sleep(for: .seconds(1))
      model.runLaunchScanIfEnabled(inFront: NSApp.isActive && !NSApp.isHidden)
    }
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

  // MARK: Sidebar

  /// Brand, Go to…, the seven areas, the disk card, then Settings and Help. In the window the
  /// traffic lights sit in the title bar strip above the brand row.
  private var sidebar: some View {
    VStack(alignment: .leading, spacing: 0) {
      sidebarBrand
        .background(GeometryReader { geometry in Color.clear.preference(key: WorkspaceLayoutFrames.self, value: ["brand": geometry.frame(in: .global)]) })
        .padding(.horizontal, 16).padding(.top, 10).padding(.bottom, 12)

      Button { model.showingCommandPalette = true } label: {
        HStack(spacing: 7) {
          Image(systemName: "magnifyingglass").font(.system(size: 12, weight: .medium))
          Text("Go to…").font(.system(size: 12.5))
          Spacer(minLength: 0)
          Text("⌘K").font(.system(size: 10.5, weight: .semibold)).foregroundStyle(AppTheme.ink2)
            .padding(.horizontal, 5).padding(.vertical, 2)
            .background(AppTheme.panel, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
        }
        .foregroundStyle(AppTheme.ink3)
        .padding(.leading, 9).padding(.trailing, 6).frame(height: 30)
        .background(sidebarField, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(AppTheme.border))
        .contentShape(RoundedRectangle(cornerRadius: 8))
      }
      .buttonStyle(.plain).help("Go to any page · ⌘K").accessibilityLabel("Go to")
      .tourTarget(.goTo).padding(.horizontal, 12)

      Eyebrow("Workspace").padding(.horizontal, 20).padding(.top, 18).padding(.bottom, 6)
      VStack(spacing: 2) {
        ForEach(AppViewModel.Section.primary) { section in
          sidebarDestination(section)
        }
      }
      .padding(.horizontal, 10)

      Spacer(minLength: 12)
      diskCard.padding(.horizontal, 12).padding(.bottom, 10)
      Rectangle().fill(AppTheme.divider).frame(height: 1)
      HStack(spacing: 6) {
        Button { model.selectedSection = .settings } label: {
          HStack(spacing: 7) {
            Image(systemName: "gearshape").font(.system(size: 14))
            Text("Settings").font(.system(size: 12.5, weight: .medium))
            Spacer(minLength: 0)
          }
          .foregroundStyle(model.selectedSection == .settings ? AppTheme.ink : AppTheme.ink2)
          .padding(.horizontal, 8).frame(height: 28)
          .background(model.selectedSection == .settings ? sidebarSelected : hoveredFooter == "settings" ? sidebarHover : .clear,
            in: RoundedRectangle(cornerRadius: 7, style: .continuous))
          .contentShape(RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain).onHover { hoveredFooter = $0 ? "settings" : nil }
        .accessibilityAddTraits(model.selectedSection == .settings ? .isSelected : [])
        Button { model.showingHelp = true } label: {
          Image(systemName: "questionmark.circle").font(.system(size: 15)).foregroundStyle(AppTheme.ink2)
            .frame(width: 28, height: 28)
            .background(hoveredFooter == "help" ? sidebarHover : .clear, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain).onHover { hoveredFooter = $0 ? "help" : nil }
        .help("Help & diagnostics").accessibilityLabel("Help and diagnostics").tourTarget(.help)
      }
      .padding(.horizontal, 12).padding(.top, 8).padding(.bottom, 12)
    }
    .tourTarget(.map)
  }

  private var sidebarField: Color { colorScheme == .dark ? Color.white.opacity(0.06) : Color.white.opacity(0.78) }
  private var sidebarHover: Color { colorScheme == .dark ? Color.white.opacity(0.045) : AppTheme.ink.opacity(0.055) }
  private var sidebarSelected: Color { colorScheme == .dark ? Color.white.opacity(0.085) : AppTheme.surface }

  private var sidebarBrand: some View {
    HStack(spacing: 10) {
      BrandMark(size: 40).frame(width: 40, height: 40)
      VStack(alignment: .leading, spacing: 1) {
        Text("MacMint").font(.system(size: 15, weight: .bold)).tracking(-0.35).foregroundStyle(AppTheme.ink)
        Text(account.isUnlocked ? (account.isOffline ? "Pro · offline" : "Pro · this Mac") : "Local inspection")
          .font(.system(size: 11)).foregroundStyle(AppTheme.ink3)
      }
      Spacer(minLength: 0)
    }
    .accessibilityElement(children: .combine)
  }

  private func sidebarDestination(_ section: AppViewModel.Section) -> some View {
    let selected = model.selectedSection.parent == section
    let meta = sidebarMeta(section)
    return Button { model.selectedSection = lastTabs[section] ?? section } label: {
      HStack(spacing: 10) {
        SwatchBadge(symbol: section.icon, swatch: section.swatch, size: 24)
        Text(section.rawValue).font(.system(size: 13, weight: selected ? .semibold : .medium))
          .foregroundStyle(AppTheme.ink).lineLimit(1)
        Spacer(minLength: 4)
        if let meta {
          Text(meta).font(AppTheme.number(11, weight: .medium)).monospacedDigit()
            .foregroundStyle(selected ? AppTheme.ink2 : AppTheme.ink3).lineLimit(1)
        }
      }
      .padding(.horizontal, 8).frame(height: 34)
      .background {
        let shape = RoundedRectangle(cornerRadius: 9, style: .continuous)
        if selected {
          if colorScheme == .dark { shape.fill(sidebarSelected) } else { shape.fill(AppTheme.surface).elevation(.card) }
        } else if hoveredSection == section {
          shape.fill(sidebarHover)
        }
      }
      .contentShape(RoundedRectangle(cornerRadius: 9))
    }
    .buttonStyle(SidebarPressStyle()).onHover { hoveredSection = $0 ? section : nil }
    .accessibilityAddTraits(selected ? .isSelected : []).accessibilityLabel(section.rawValue)
    .accessibilityValue(meta ?? "")
    .help(section.rawValue)
    .modifier(SidebarTourTarget(section: section))
  }

  /// What each area found, once a scan has results; nothing before that.
  private func sidebarMeta(_ section: AppViewModel.Section) -> String? {
    func bytes(_ value: Int64) -> String? { value > 0 ? ByteFormatter.string(value) : nil }
    switch section {
    case .cleaner:
      return bytes(model.cleanupTargets.reduce(Int64(0)) { OverviewPresentation.add($0, $1.size) })
    case .storage:
      return model.storageScan.flatMap { bytes($0.root.allocatedBytes) }
    case .applications:
      return model.apps.isEmpty ? nil : "\(model.apps.count)"
    case .photos:
      guard let scan = model.photoScan else { return nil }
      let count = scan.similarGroups.count + scan.screenshots.count + scan.blurry.count
      return count > 0 ? "\(count)" : nil
    case .developer:
      return bytes(model.devItems.reduce(Int64(0)) { OverviewPresentation.add($0, $1.bytes) })
    case .history:
      return model.history.isEmpty ? nil : "\(model.history.count)"
    default:
      return nil
    }
  }

  /// The startup disk: name, share used, the same colored breakdown as Overview's disk bar,
  /// and what is available.
  private var diskCard: some View {
    let stats = model.volume
    let fraction = stats.isMeasured ? min(1, Double(stats.used) / Double(stats.total)) : 0
    let bar = OverviewPresentation.bar(OverviewPresentation.categories(model.recommendations), used: stats.used, total: stats.total)
    return VStack(alignment: .leading, spacing: 9) {
      HStack(spacing: 7) {
        Image(systemName: "internaldrive").font(.system(size: 13)).foregroundStyle(AppTheme.ink2)
        Text(stats.name).lineLimit(1).font(.system(size: 12, weight: .semibold)).foregroundStyle(AppTheme.ink)
        Spacer(minLength: 4)
        if stats.isMeasured {
          Text("\(Int((fraction * 100).rounded()))% used").font(.system(size: 11)).monospacedDigit().foregroundStyle(AppTheme.ink3)
        }
      }
      GeometryReader { geometry in
        HStack(spacing: 1) {
          if let bar {
            ForEach(bar.segments) { segment in
              Rectangle().fill(segment.category.swatch.gradient).frame(width: max(0, geometry.size.width * segment.fraction))
            }
            Rectangle().fill(AppTheme.borderStrong).frame(width: max(0, geometry.size.width * bar.rest))
          }
          Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppTheme.track)
        .clipShape(Capsule())
      }
      .frame(height: 6)
      .accessibilityElement()
      .accessibilityLabel(stats.isMeasured ? "Disk \(Int(fraction * 100)) percent used" : "Disk space unavailable")
      HStack(alignment: .firstTextBaseline, spacing: 4) {
        Text(stats.isMeasured ? ByteFormatter.string(stats.free) : "—").font(AppTheme.number(17)).tracking(-0.3)
          .monospacedDigit().foregroundStyle(AppTheme.ink)
        Text(stats.isMeasured ? "available of " + ByteFormatter.string(stats.total) : "unavailable")
          .font(.system(size: 11)).foregroundStyle(AppTheme.ink3).lineLimit(1).minimumScaleFactor(0.85)
      }
    }
    .padding(12)
    .background(colorScheme == .dark ? Color.white.opacity(0.04) : Color.white.opacity(0.6),
      in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(AppTheme.border))
  }

  // MARK: Top bar

  private var workspaceBar: some View {
    HStack(spacing: 8) {
      if model.selectedSection.tabs.isEmpty {
        HStack(spacing: 6) {
          Image(systemName: model.selectedSection.icon).font(.system(size: 12))
          Text(model.selectedSection.rawValue).font(.system(size: 12.5))
        }
        .foregroundStyle(AppTheme.ink3)
        .accessibilityElement(children: .combine)
      } else {
        // A segmented track; the selected tab is a raised surface with its area's badge.
        HStack(spacing: 2) {
          ForEach(model.selectedSection.tabs) { section in
            let selected = model.selectedSection == section
            Button { model.selectedSection = section } label: {
              HStack(spacing: 6) {
                if selected {
                  SwatchBadge(symbol: section.icon, swatch: section.swatch, size: 18)
                } else {
                  Image(systemName: section.icon).font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(AppTheme.ink3).frame(width: 18, height: 18)
                }
                Text(section.rawValue).font(.system(size: 12.5, weight: selected ? .semibold : .medium))
                  .foregroundStyle(selected ? AppTheme.ink : AppTheme.ink2)
              }
              .padding(.leading, 5).padding(.trailing, 11).frame(height: 27)
              .background {
                if selected { RoundedRectangle(cornerRadius: 7, style: .continuous).fill(AppTheme.surface).elevation(.card) }
              }
              .contentShape(RoundedRectangle(cornerRadius: 7))
            }.buttonStyle(.plain).accessibilityAddTraits(selected ? .isSelected : [])
              .modifier(SidebarTourTarget(section: section, tab: true))
          }
        }
        .padding(2)
        .background(AppTheme.panel, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
      }
      Spacer(minLength: 8)
      if account.aiAvailable {
        Button { model.selectedSection = .assistant } label: {
          HStack(spacing: 6) {
            Image(systemName: "sparkles").font(.system(size: 13, weight: .semibold))
            Text("Ask").font(.system(size: 12.5, weight: .semibold))
          }
          .foregroundStyle(AppTheme.Swatch.iris.text)
          .padding(.leading, 9).padding(.trailing, 11).frame(height: 30)
          .background(AppTheme.Swatch.iris.tint, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
          .contentShape(RoundedRectangle(cornerRadius: 8))
        }.buttonStyle(.plain)
          .help("Ask MacMint").accessibilityLabel("Ask MacMint")
      }
      reviewButton
      Button { model.openAccount() } label: { avatar }
        .buttonStyle(.plain)
        .help(account.isUnlocked ? "Account" : "Connect your MacMint account")
        .accessibilityLabel(account.isUnlocked ? "Account" : "Connect your MacMint account")
    }
    .padding(.leading, 20).padding(.trailing, 16).frame(height: 52)
    .background(AppTheme.canvas)
    .overlay(alignment: .bottom) { Rectangle().fill(AppTheme.divider).frame(height: 1) }
  }

  /// The strongest control in the window once something is picked: filled mint with a count.
  private var reviewButton: some View {
    let count = model.queuedCount
    let filled = count > 0
    return Button { model.selectedSection = .review } label: {
      HStack(spacing: 7) {
        Image(systemName: "checklist").font(.system(size: 13, weight: .semibold))
        Text("Review").font(.system(size: 12.5, weight: .semibold))
        Text("\(count)").font(AppTheme.number(11)).monospacedDigit()
          .foregroundStyle(filled ? AppTheme.accent : AppTheme.ink2)
          .padding(.horizontal, 6).frame(minWidth: 20, minHeight: 20)
          .background(filled ? Color.white : AppTheme.panel, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
      }
      .foregroundStyle(filled ? Color.white : AppTheme.ink)
      .padding(.leading, 10).padding(.trailing, 5).frame(height: 30)
      .background {
        let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
        if filled {
          shape.fill(AppTheme.commitGradient).shadow(color: AppTheme.accent.opacity(0.35), radius: 6, y: 3)
        } else {
          shape.fill(AppTheme.surface).overlay(shape.strokeBorder(model.selectedSection == .review ? AppTheme.accentText : AppTheme.border))
        }
      }
      .contentShape(RoundedRectangle(cornerRadius: 8))
    }
    .buttonStyle(SidebarPressStyle())
    .help("Review selected items · " + ByteFormatter.string(model.queuedBytes))
    .accessibilityLabel("Review, \(count) item\(count == 1 ? "" : "s") selected")
    .tourTarget(.review)
  }

  private var avatar: some View {
    let initials = account.snapshot.map { snapshot in
      String(snapshot.user.email.prefix { $0 != "@" }.filter(\.isLetter).prefix(2)).uppercased()
    } ?? ""
    return ZStack {
      Circle().fill(LinearGradient(colors: [AppTheme.Swatch.violet.start, AppTheme.Swatch.pink.start],
        startPoint: .topLeading, endPoint: .bottomTrailing))
      if initials.isEmpty {
        Image(systemName: "person.fill").font(.system(size: 13, weight: .semibold))
      } else {
        Text(initials).font(.system(size: 11.5, weight: .bold))
      }
    }
    .foregroundStyle(.white)
    .frame(width: 30, height: 30)
    .overlay(Circle().strokeBorder(AppTheme.border, lineWidth: 1).padding(-3))
    .padding(3)
  }

  // MARK: Update banner and status bar

  /// One banner for every update source. Sparkle installs whenever it has the update; the
  /// download page remains the fallback for the server's required/available notice.
  @ViewBuilder
  private var updateBanner: some View {
    if updater.isWaitingForWork {
      updateBannerRow(icon: "clock.arrow.circlepath", tint: AppTheme.accentText,
        text: "The update is ready. MacMint restarts to install it when the current operation finishes.")
    } else if let update = updater.reminder {
      updateBannerRow(icon: "arrow.down.circle.fill", tint: AppTheme.accentText,
        text: "MacMint \(update.title) is ready. You have \(UpdaterController.current.versionAndBuild). It installs when you choose.") {
        Button("Install…") { updater.checkForUpdates() }
          .buttonStyle(MintButtonStyle(.commit)).controlSize(.small)
        dismissButton { updater.dismissReminder() }
      }
    } else if let release = updates.bannerRelease {
      updateBannerRow(icon: updates.isRequired ? "exclamationmark.triangle.fill" : "arrow.down.circle.fill",
        tint: updates.isRequired ? AppTheme.warning : AppTheme.accentText,
        text: updates.isRequired
          ? "This version of MacMint is no longer supported. Please update to \(release.version)."
          : "MacMint \(release.version) is available. You have \(UpdateService.currentVersion).") {
        if updater.availableUpdate != nil {
          Button("Install…") { updater.checkForUpdates() }
            .buttonStyle(MintButtonStyle(.commit)).controlSize(.small)
        } else {
          Button("Download") { updates.openDownload(release) }
            .buttonStyle(MintButtonStyle(.commit)).controlSize(.small)
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
      Image(systemName: icon).font(.system(size: 15)).foregroundStyle(tint)
      Text(text).font(.system(size: 12.5)).foregroundStyle(AppTheme.ink).fixedSize(horizontal: false, vertical: true)
      Spacer()
      actions()
    }
    .padding(.leading, 20).padding(.trailing, 16)
    .padding(.vertical, 8)
    .background(LinearGradient(colors: [AppTheme.Swatch.mint.tint, AppTheme.Swatch.sky.tint], startPoint: .leading, endPoint: .trailing))
    .overlay(alignment: .bottom) { Rectangle().fill(AppTheme.divider).frame(height: 1) }
  }

  private func dismissButton(_ action: @escaping () -> Void) -> some View {
    Button(action: action) {
      Image(systemName: "xmark").font(.system(size: 11, weight: .semibold)).foregroundStyle(AppTheme.ink2)
        .frame(width: 24, height: 24).contentShape(Rectangle())
    }
    .buttonStyle(.plain)
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
        Image(systemName: "leaf.fill").font(.system(size: 12)).foregroundStyle(AppTheme.brand)
          .accessibilityHidden(true)
      }

      HStack(spacing: 6) {
        if let title = model.operationTitle {
          Text(title).font(.system(size: 11.5, weight: .semibold)).foregroundStyle(AppTheme.ink)
        }
        Text(model.statusMessage)
          .font(.system(size: 11.5))
          .foregroundStyle(AppTheme.ink2)
          .lineLimit(1)
      }

      Spacer()

      if model.isWorking, let progress = model.operationProgress {
        Text("\(progress.completed) of \(progress.total)")
          .font(AppTheme.number(11.5, weight: .semibold)).monospacedDigit()
          .foregroundStyle(AppTheme.ink2)
        GeometryReader { geometry in
          Capsule().fill(AppTheme.track).overlay(alignment: .leading) {
            Capsule().fill(AppTheme.commitGradient).frame(width: geometry.size.width * min(1, max(0, progress.fraction)))
          }
        }
        .frame(width: 140, height: 5)
        .accessibilityHidden(true)
      }

      if model.isScanning || model.isWorking || model.isPreparingPlan {
        Button(model.isWorking ? "Stop" : "Cancel") { model.cancelCurrentOperation() }
          .buttonStyle(MintButtonStyle(.secondary)).controlSize(.small)
      }

      if !model.scanIssues.isEmpty {
        Button {
          model.showingScanIssues = true
        } label: {
          Chip(title: "\(model.scanIssues.count) issue\(model.scanIssues.count == 1 ? "" : "s")",
            symbol: "exclamationmark.triangle.fill", swatch: .amber)
        }
        .buttonStyle(.plain)
        .help("Show what the scan skipped")
      }
    }
    .padding(.horizontal, 16)
    .frame(minHeight: 32)
    .padding(.vertical, 2)
    .background(colorScheme == .dark ? AppTheme.hex(0x131917) : AppTheme.hex(0xFAFBFA))
    .overlay(alignment: .top) { Rectangle().fill(AppTheme.divider).frame(height: 1) }
  }
}

/// Sidebar rows and the Review button sink slightly while pressed.
private struct SidebarPressStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    configuration.label.scaleEffect(configuration.isPressed ? 0.98 : 1)
  }
}

/// Sidebar areas and tabs on the guided tour: every area reports its frame for the map step,
/// History is its own stop, and the Performance tab stands for tabs.
private struct SidebarTourTarget: ViewModifier {
  let section: AppViewModel.Section
  var tab = false

  func body(content: Content) -> some View {
    if tab {
      if section == .performance { content.tourTarget(.performance) } else { content }
    } else if section == .history {
      content.tourTarget(.area(section)).tourTarget(.history)
    } else {
      content.tourTarget(.area(section))
    }
  }
}
