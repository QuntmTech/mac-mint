import MacCleanerCore
import SwiftUI

struct CleanerView: View {
  @EnvironmentObject private var model: AppViewModel
  @EnvironmentObject private var account: AccountStore
  @SceneStorage("cleanup.search") private var search = ""
  @State private var riskFilter: RiskFilter = .all

  enum RiskFilter: String, CaseIterable, Identifiable {
    case all = "All"
    case safe = "Rebuildable"
    case review = "Review"
    var id: String { rawValue }
  }

  private func matchesSearch(_ item: CleanupTarget) -> Bool {
    search.isEmpty
      || item.displayName.localizedCaseInsensitiveContains(search)
      || item.detail.localizedCaseInsensitiveContains(search)
      || item.url.path.localizedCaseInsensitiveContains(search)
  }

  private func matchesRisk(_ item: CleanupTarget) -> Bool {
    switch riskFilter {
    case .all: return true
    case .safe: return item.risk == .safe
    case .review: return item.risk == .review
    }
  }

  /// Items that match the search, before the risk filter. The risk pills count these.
  private var searchMatches: [CleanupTarget] {
    model.cleanupTargets.filter { matchesSearch($0) }
  }

  private func grouped(_ targets: [CleanupTarget]) -> [(CleanupCategory, [CleanupTarget])] {
    CleanupCategory.allCases.compactMap { category in
      let items = targets.filter { $0.category == category }
      return items.isEmpty ? nil : (category, items)
    }
  }

  private var showsFilters: Bool {
    !model.cleanupTargets.isEmpty || !search.isEmpty || riskFilter != .all
  }

  var body: some View {
    let matches = searchMatches
    let targets = matches.filter { matchesRisk($0) }
    let loading = targets.isEmpty && model.isScanning
    VStack(spacing: 0) {
      header
      if showsFilters && !loading { filterBar(matches: matches, shown: targets.count) }

      if loading {
        let quick = model.operationTitle == "Quick Scan"
        LoadingState(title: quick ? "Looking for caches and logs…" : "Cleanup is next",
          detail: quick
            ? "Quick Scan is checking known cache, log and download locations. Results appear here as each check finishes."
            : "\(model.operationTitle ?? "Another scan") is running. Cleanup loads as soon as it finishes.",
          symbol: "sparkles", swatch: .sky,
          progress: quick ? Double(model.scanCompletedAreas.count) / 5 : nil,
          status: quick ? "\(model.scanCompletedAreas.count) of 5 checks done" : nil,
          cancel: quick ? { model.cancelCurrentOperation() } : nil)
      } else if targets.isEmpty {
        EmptyState(
          icon: search.isEmpty ? "checkmark.seal" : "magnifyingglass",
          title: !search.isEmpty || riskFilter != .all ? "No matching cleanup items" : model.lastScanDate == nil ? "Start with a Quick Scan" : "Nothing found in this scan",
          detail: !search.isEmpty || riskFilter != .all ? "Try a different search or filter." : model.lastScanDate == nil ? "Find caches, logs, and generated data. Nothing moves until you review it." : "Check scan coverage for any locations that could not be inspected.",
          actionTitle: model.lastScanDate == nil ? "Run Quick Scan" : "Scan again",
          action: { model.runSmartScan() }
        )
      } else {
        groupList(targets)
      }

      if !loading && !model.cleanupTargets.isEmpty { selectionBar }
    }
    .task(id: model.autoLoadKey) { model.autoLoadIfNeeded(.cleaner) }
  }

  // MARK: Header and filters

  private var header: some View {
    PageHeader(title: "Cleanup", subtitle: "Inspect caches and generated data. Keep anything you still need.") {
      Button(model.isScanning ? "Cancel" : "Rescan", systemImage: model.isScanning ? "xmark" : "arrow.clockwise") {
        if model.isScanning { model.cancelCurrentOperation() } else { model.runSmartScan() }
      }
      .buttonStyle(MintButtonStyle(model.isScanning ? .secondary : .area))
      .disabled(model.isWorking)
    }
    .padding(.horizontal, AppTheme.pagePadding)
    .padding(.top, AppTheme.pageTopPadding)
    .padding(.bottom, 14)
    .frame(maxWidth: 1180)
    .frame(maxWidth: .infinity)
  }

  private func filterBar(matches: [CleanupTarget], shown: Int) -> some View {
    let options = riskOptions(matches)
    return ViewThatFits(in: .horizontal) {
      HStack(spacing: 10) {
        SearchField(prompt: "Search cleanup items", text: $search)
          .frame(minWidth: 180, maxWidth: 300)
        riskPills(options)
        Spacer(minLength: 8)
        itemCount(shown)
        selectMenu
      }
      VStack(alignment: .leading, spacing: 10) {
        HStack(spacing: 10) {
          SearchField(prompt: "Search cleanup items", text: $search)
          selectMenu
        }
        HStack(spacing: 10) {
          riskPills(options)
          Spacer(minLength: 8)
          itemCount(shown)
        }
      }
    }
    .padding(.horizontal, AppTheme.pagePadding)
    .padding(.bottom, 14)
    .frame(maxWidth: 1180)
    .frame(maxWidth: .infinity)
  }

  private func riskOptions(_ matches: [CleanupTarget]) -> [SegmentedPills<RiskFilter>.Option] {
    let rebuildable = matches.filter { $0.risk == .safe }.count
    let review = matches.filter { $0.risk == .review }.count
    return [
      SegmentedPills<RiskFilter>.Option(value: .all, title: RiskFilter.all.rawValue, count: matches.count),
      SegmentedPills<RiskFilter>.Option(value: .safe, title: RiskFilter.safe.rawValue,
        dot: CleanupRisk.safe.swatch.color, count: rebuildable),
      SegmentedPills<RiskFilter>.Option(value: .review, title: RiskFilter.review.rawValue,
        dot: CleanupRisk.review.swatch.color, count: review),
    ]
  }

  private func riskPills(_ options: [SegmentedPills<RiskFilter>.Option]) -> some View {
    SegmentedPills(selection: $riskFilter, options: options)
      .fixedSize()
      .accessibilityElement(children: .contain)
      .accessibilityLabel("Risk")
  }

  private func itemCount(_ count: Int) -> some View {
    Text("\(count) items")
      .font(.system(size: 11.5)).monospacedDigit()
      .foregroundStyle(AppTheme.ink3)
      .lineLimit(1)
      .fixedSize()
  }

  private var selectMenu: some View {
    Menu("Select") {
      Button("Rebuildable items") { model.selectSafeCleanupOnly() }
      Button("Deselect all") { model.deselectAllCleanup() }
    }
    .fixedSize()
    .menuStyle(.borderlessButton)
  }

  private var selectionBar: some View {
    SelectionBar(
      count: model.cleanupTargets.filter(\.isSelected).count,
      bytes: model.selectedCleanupBytes,
      clear: { model.deselectAllCleanup() },
      commitTitle: "Review…",
      commitDisabled: model.selectedCleanupBytes == 0 || model.isWorking || model.isScanning,
      commit: { model.reviewCleanup() })
  }

  // MARK: Groups

  private func groupList(_ targets: [CleanupTarget]) -> some View {
    ScrollView {
      LazyVStack(spacing: 14) {
        ForEach(grouped(targets), id: \.0) { category, items in
          groupCard(category, items)
        }
      }
      .padding(.horizontal, AppTheme.pagePadding)
      .padding(.top, 2)
      .padding(.bottom, 24)
      .frame(maxWidth: 1180)
      .frame(maxWidth: .infinity)
    }
  }

  private func groupCard(_ category: CleanupCategory, _ items: [CleanupTarget]) -> some View {
    let mixed = Set(items.map(\.risk)).count > 1
    return VStack(spacing: 0) {
      groupHeader(category, items)
      ForEach(items) { item in
        Rectangle().fill(AppTheme.divider).frame(height: 1)
        cleanupRow(item, showsRisk: mixed)
      }
    }
    .clipShape(RoundedRectangle(cornerRadius: AppTheme.corner, style: .continuous))
    .cardBackground()
  }

  private func groupHeader(_ category: CleanupCategory, _ items: [CleanupTarget]) -> some View {
    let selectable = items.filter { $0.risk != .restricted }
    let chosen = selectable.filter(\.isSelected).count
    let state: CheckboxMark.Kind = chosen == 0 ? .off : (chosen == selectable.count ? .on : .mixed)
    let total = items.reduce(Int64(0)) { $0 + $1.size }
    return HStack(spacing: 11) {
      Button {
        model.setFileSelections(selectable.map(\.url), selected: chosen < selectable.count)
      } label: {
        CheckboxMark(state: state)
          .frame(width: 22, height: 22)
          .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .disabled(selectable.isEmpty)
      .opacity(selectable.isEmpty ? 0.4 : 1)
      .accessibilityLabel("Select all in \(category.rawValue)")
      .accessibilityValue(state == .on ? "Checked" : state == .mixed ? "Mixed" : "Unchecked")

      SwatchBadge(symbol: icon(for: category), swatch: swatch(for: category), size: 30)

      VStack(alignment: .leading, spacing: 1) {
        Text(category.rawValue)
          .font(.system(size: 13.5, weight: .bold)).tracking(-0.2)
          .foregroundStyle(AppTheme.ink)
          .lineLimit(1)
        Text("\(items.count) items · \(chosen) selected")
          .font(.system(size: 11.5)).monospacedDigit()
          .foregroundStyle(AppTheme.ink3)
          .lineLimit(1)
      }
      .accessibilityElement(children: .combine)

      Spacer(minLength: 8)

      groupRiskChip(items)

      Text(ByteFormatter.string(total))
        .font(AppTheme.number(13.5)).monospacedDigit()
        .foregroundStyle(AppTheme.ink)
        .frame(minWidth: 74, alignment: .trailing)
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 12)
  }

  @ViewBuilder
  private func groupRiskChip(_ items: [CleanupTarget]) -> some View {
    let risks = Set(items.map(\.risk))
    if risks.count == 1, let risk = risks.first {
      RiskBadge(risk: risk)
    } else {
      Chip(title: "Mixed", symbol: "square.stack.fill", swatch: .slate)
    }
  }

  // MARK: Rows

  private func cleanupRow(_ item: CleanupTarget, showsRisk: Bool) -> some View {
    let owner = OwnerResolver.hint(for: item.url, explicitBundleID: item.ownerBundleID)
    let reason = OwnerDirectory.owner(for: owner).map { "Used by \($0.name) — \(item.reason)" } ?? item.reason
    let restricted = item.risk == .restricted
    return HStack(spacing: 11) {
      Toggle(
        "",
        isOn: Binding(
          get: { model.cleanupTargets.first(where: { $0.id == item.id })?.isSelected ?? false },
          set: { model.toggleCleanup(item.id, selected: $0) }
        )
      )
      .toggleStyle(MintCheckboxStyle())
      .labelsHidden()
      .accessibilityLabel("Clean \(item.displayName), \(ByteFormatter.string(item.size))")
      .disabled(restricted)
      .opacity(restricted ? 0.4 : 1)
      .frame(width: 22)

      OwnerIcon(hint: owner, fallbackSymbol: icon(for: item.category), size: 30)

      VStack(alignment: .leading, spacing: 2) {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
          Text(item.displayName)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(AppTheme.ink)
            .lineLimit(1)
            .layoutPriority(1)
          Text((item.url.path as NSString).abbreviatingWithTildeInPath)
            .font(.system(size: 11, design: .monospaced))
            .foregroundStyle(AppTheme.ink3)
            .lineLimit(1).truncationMode(.middle)
            .help(item.url.path)
        }
        Text(reason)
          .font(.system(size: 11.5))
          .foregroundStyle(AppTheme.ink2)
          .lineLimit(1)
      }

      Spacer(minLength: 8)

      if showsRisk { RiskBadge(risk: item.risk) }
      explainChip(item)

      Text(ByteFormatter.string(item.size))
        .font(AppTheme.number(13, weight: .semibold)).monospacedDigit()
        .foregroundStyle(AppTheme.ink)
        .frame(width: 80, alignment: .trailing)

      Menu {
        Button("Reveal in Finder") { model.reveal(item.url) }
        Button("Exclude from future scans") { model.ignore(item.url) }
        ExplainMenuItem(target: model.aiTarget(for: item))
      } label: {
        Image(systemName: "ellipsis.circle")
          .accessibilityLabel("More actions")
      }
      .menuStyle(.borderlessButton)
      .menuIndicator(.hidden)
      .frame(width: 28)
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 8)
    .frame(minHeight: 50)
    .background(item.isSelected ? AppTheme.selection.opacity(0.35) : Color.clear)
  }

  /// The iris "Explain" chip. It shows only when Ask MacMint can explain this item, and it
  /// calls the same action as the Explain menu item.
  @ViewBuilder
  private func explainChip(_ item: CleanupTarget) -> some View {
    if account.aiStatus.allows("explain"), let target = model.aiTarget(for: item) {
      Button {
        model.explain(target)
      } label: {
        HStack(spacing: 4) {
          Image(systemName: "sparkles").font(.system(size: 10, weight: .bold))
          Text("Explain")
        }
        .font(.system(size: 11.5, weight: .semibold))
        .foregroundStyle(AppTheme.Swatch.iris.text)
        .padding(.horizontal, 8)
        .frame(height: 24)
        .background(AppTheme.Swatch.iris.tint, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .help("Ask MacMint what this is")
      .accessibilityLabel("Explain \(item.displayName) with AI")
    }
  }

  private func icon(for category: CleanupCategory) -> String {
    switch category {
    case .userCaches: return "shippingbox"
    case .userLogs: return "doc.text.magnifyingglass"
    case .browserCaches: return "globe"
    case .developerJunk: return "hammer"
    case .deviceBackups: return "iphone.gen3"
    case .diagnostics: return "waveform.path.ecg"
    case .appLeftovers: return "app.badge"
    case .installers: return "shippingbox.and.arrow.backward"
    case .mailAttachments: return "paperclip"
    case .deviceFirmware: return "iphone.and.arrow.forward"
    }
  }

  private func swatch(for category: CleanupCategory) -> AppTheme.Swatch {
    switch category {
    case .userCaches: return .sky
    case .userLogs: return .slate
    case .browserCaches: return .indigo
    case .developerJunk: return .orange
    case .deviceBackups: return .violet
    case .diagnostics: return .amber
    case .appLeftovers: return .pink
    case .installers: return .teal
    case .mailAttachments: return .iris
    case .deviceFirmware: return .graphite
    }
  }
}
