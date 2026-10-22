import MacCleanerCore
import SwiftUI

// MARK: - Risk levels shown in review

/// How careful to be with a planned item. Read only from the item itself: it never changes
/// which items are in a plan.
private enum PlanRiskLevel: Int, CaseIterable {
  case rebuildable, review, protected, other

  init(item: PlanItem) {
    if case .cleanupTarget(_, .restricted) = item.kind {
      self = .protected
    } else if item.needsAttention {
      self = .review
    } else if case .cleanupTarget(_, _) = item.kind {
      self = .rebuildable
    } else {
      self = .other
    }
  }

  var chip: Chip {
    switch self {
    case .rebuildable: return Chip(title: CleanupRisk.safe.title, symbol: CleanupRisk.safe.symbol, swatch: CleanupRisk.safe.swatch)
    case .review: return Chip(title: CleanupRisk.review.title, symbol: CleanupRisk.review.symbol, swatch: CleanupRisk.review.swatch)
    case .protected: return Chip(title: CleanupRisk.restricted.title, symbol: CleanupRisk.restricted.symbol, swatch: CleanupRisk.restricted.swatch)
    case .other: return Chip(title: "Your picks", symbol: "hand.tap.fill", swatch: .slate)
    }
  }

  var detail: String {
    switch self {
    case .rebuildable: return "caches and data that rebuild on their own"
    case .review: return "personal files, backups, or data that may not rebuild"
    case .protected: return "protected data, look closely before it moves"
    case .other: return "apps and files you chose"
    }
  }

  var needsCare: Bool { self == .review || self == .protected }
}

// MARK: - Shared row

struct PlanItemRow: View {
  let item: PlanItem
  var onRemove: (() -> Void)? = nil
  @EnvironmentObject private var model: AppViewModel
  @State private var expanded = false
  @State private var childNames: [String] = []
  @State private var hovering = false

  private var details: String {
    let owner = item.kind.label + " · " + (item.ownerBundleID ?? "Owner not identified")
    let changed = item.snapshot?.modified.map { "Last changed " + $0.formatted() } ?? "Change time not recorded"
    return owner + " · " + changed
  }

  var body: some View {
    let level = PlanRiskLevel(item: item)
    HStack(alignment: .top, spacing: 11) {
      IconTile(symbol: Self.icon(for: item.kind),
        tint: item.needsAttention ? AppTheme.warning : Self.swatch(source: item.source, kind: item.kind).text, size: 30)
      VStack(alignment: .leading, spacing: 3) {
        HStack(spacing: 6) {
          Text(item.displayName).font(.system(size: 13, weight: .semibold)).foregroundStyle(AppTheme.ink).lineLimit(1)
          if level != .other { level.chip.fixedSize() }
        }
        Text(item.url.path).font(.system(size: 11, design: .monospaced)).foregroundStyle(AppTheme.ink3)
          .lineLimit(1).truncationMode(.middle)
        Text(item.reason).font(.system(size: 12)).foregroundStyle(AppTheme.ink2)
          .fixedSize(horizontal: false, vertical: true)
        Text(details).font(.system(size: 11)).foregroundStyle(AppTheme.ink3).lineLimit(1).truncationMode(.middle)
        if (try? item.url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
          DisclosureGroup("Inspect folder contents", isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 3) {
              Text("First 100 direct children; use Finder for the complete folder.").foregroundStyle(AppTheme.ink2)
              ForEach(childNames, id: \.self) { Text($0).textSelection(.enabled) }
            }.font(.system(size: 11.5))
          }
          .font(.system(size: 11.5))
          .task(id: expanded) {
            guard expanded else { return }
            let url = item.url
            childNames = await Task.detached(priority: .utility) {
              do { return Array(try FileManager.default.contentsOfDirectory(atPath: url.path).sorted().prefix(100)) }
              catch { return ["Contents could not be read: " + error.localizedDescription] }
            }.value
          }
        }
      }
      Spacer(minLength: 8)
      HStack(spacing: 4) {
        Text(ByteFormatter.string(item.expectedBytes))
          .font(AppTheme.number(13, weight: .semibold)).monospacedDigit()
          .foregroundStyle(AppTheme.ink)
          .padding(.trailing, 4)
        Button {
          model.reveal(item.url)
        } label: {
          Image(systemName: "magnifyingglass")
            .font(.system(size: 12, weight: .semibold)).foregroundStyle(AppTheme.ink2)
            .frame(width: 24, height: 24).contentShape(Rectangle())
            .accessibilityLabel("Reveal in Finder")
        }
        .buttonStyle(.plain)
        .help("Reveal in Finder")
        if let onRemove {
          Button(action: onRemove) {
            Image(systemName: "xmark")
              .font(.system(size: 12, weight: .semibold)).foregroundStyle(AppTheme.ink3)
              .frame(width: 24, height: 24).contentShape(Rectangle())
              .accessibilityLabel("Remove \(item.displayName) from review")
          }
          .buttonStyle(.plain)
          .help("Remove from review")
        }
      }
      .frame(height: 30)
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 10)
    .background(hovering ? AppTheme.panel : Color.clear)
    .onHover { hovering = $0 }
    .accessibilityElement(children: .contain)
  }

  static func icon(for kind: PlanItemKind) -> String {
    switch kind {
    case .cleanupTarget(let category, _):
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
    case .appBundle: return "app.fill"
    case .appLeftover: return "folder.badge.gearshape"
    case .duplicateCopy: return "square.on.square"
    case .reviewedFile: return "doc.fill"
    case .developerArtifact: return "hammer.fill"
    }
  }

  /// The color of the area an item was picked in.
  static func swatch(source: String, kind: PlanItemKind) -> AppTheme.Swatch {
    switch source {
    case "Downloads": return .teal
    case "Photos": return .pink
    case "Large Files", "Duplicates", "Storage": return .indigo
    case "Cleaner": return .sky
    case "Removed apps", "Apps": return .violet
    default: break
    }
    if source.hasPrefix("Uninstall") { return .violet }
    switch kind {
    case .cleanupTarget: return .sky
    case .appBundle, .appLeftover: return .violet
    case .duplicateCopy, .reviewedFile: return .indigo
    case .developerArtifact: return .orange
    }
  }
}

/// The panel bar on top of a group of planned items: badge, source, count and total.
private struct PlanGroupHeader: View {
  let source: String
  let items: [PlanItem]

  var body: some View {
    let kind = items.first?.kind ?? .reviewedFile
    let bytes = items.reduce(Int64(0)) { $0 + $1.expectedBytes }
    HStack(spacing: 10) {
      SwatchBadge(symbol: PlanItemRow.icon(for: kind), swatch: PlanItemRow.swatch(source: source, kind: kind), size: 22)
      Text(source).font(.system(size: 13, weight: .bold)).foregroundStyle(AppTheme.ink).lineLimit(1)
      Text("\(items.count) item\(items.count == 1 ? "" : "s")").font(.system(size: 11.5)).foregroundStyle(AppTheme.ink2)
        .monospacedDigit()
      Spacer(minLength: 8)
      Text(ByteFormatter.string(bytes)).font(AppTheme.number(13)).monospacedDigit().foregroundStyle(AppTheme.ink)
    }
    .padding(.horizontal, 16).padding(.vertical, 11)
    .background(AppTheme.panel)
    .accessibilityElement(children: .combine)
    .accessibilityAddTraits(.isHeader)
  }
}

// MARK: - Review sheet (shown before anything moves)

struct PlanReviewSheet: View {
  @State private var plan: OperationPlan

  init(plan: OperationPlan) { _plan = State(initialValue: plan) }

  @EnvironmentObject private var model: AppViewModel
  @Environment(\.dismiss) private var dismiss
  @State private var showExcluded = false
  @State private var exclusionError: String?

  private var grouped: [(String, [PlanItem])] {
    plan.sources.map { source in (source, plan.items.filter { $0.source == source }) }
  }

  private var riskGroups: [(PlanRiskLevel, [PlanItem])] {
    var groups: [(PlanRiskLevel, [PlanItem])] = []
    for level in PlanRiskLevel.allCases {
      let items = plan.items.filter { PlanRiskLevel(item: $0) == level }
      if !items.isEmpty { groups.append((level, items)) }
    }
    return groups
  }

  private var itemCountText: String {
    "\(plan.items.count) item\(plan.items.count == 1 ? "" : "s")"
  }

  var body: some View {
    VStack(spacing: 0) {
      SheetHeader(
        symbol: "checklist", swatch: .mint, eyebrow: "Final check · " + plan.title,
        title: plan.isEmpty ? "Nothing can be moved" : "Move \(itemCountText) to the Trash?",
        subtitle: plan.isEmpty
          ? "Everything selected was skipped for the reasons below."
          : ByteFormatter.string(plan.totalBytes) + " · you can restore any of it from History while it's in the Trash.")
      Rectangle().fill(AppTheme.divider).frame(height: 1)
      ScrollView {
        VStack(alignment: .leading, spacing: 12) {
          if !plan.isEmpty {
            VStack(spacing: 8) {
              ForEach(riskGroups, id: \.0) { level, items in
                breakdownRow(level, items)
              }
            }
          }
          if !plan.excluded.isEmpty || !plan.covered.isEmpty {
            notes
          }
          if let exclusionError {
            Label(exclusionError, systemImage: "exclamationmark.triangle")
              .font(.system(size: 12.5)).foregroundStyle(AppTheme.warning).fixedSize(horizontal: false, vertical: true)
          }
          if !plan.isEmpty {
            Text("Remove anything you want to keep. Only the items below will move.")
              .font(.system(size: 12.5)).foregroundStyle(AppTheme.ink2)
              .padding(.top, 2)
            ForEach(grouped, id: \.0) { source, items in
              groupCard(source, items)
            }
          }
        }
        .padding(.horizontal, 22).padding(.vertical, 14)
      }
      .frame(minHeight: 240)
      promises
      SheetFooter {
        Label(
          "Files go to Trash. Restore is available while the recorded items remain there.",
          systemImage: "arrow.uturn.backward.circle"
        )
        .font(.system(size: 11.5))
        .foregroundStyle(AppTheme.ink2)
        .lineLimit(2)
        Spacer(minLength: 8)
        Button("Cancel", role: .cancel) { dismiss() }
          .buttonStyle(MintButtonStyle(.secondary))
          .keyboardShortcut(.cancelAction)
        Button {
          model.execute(plan)
        } label: {
          Label("Move \(plan.items.count) Item\(plan.items.count == 1 ? "" : "s") to Trash", systemImage: "trash")
        }
        .buttonStyle(MintButtonStyle(.commit))
        .keyboardShortcut(.defaultAction)
        .disabled(plan.isEmpty)
      }
    }
    .frame(width: 720)
    .frame(minHeight: 420, maxHeight: 680)
    .scrollContentBackground(.hidden)
    .background(AppTheme.elevated)
  }

  /// The row leaves the review only after the exclusion is saved; otherwise the error stays here.
  private func exclude(_ item: PlanItem) {
    Task {
      exclusionError = await model.addExclusion(item.url)
      if exclusionError == nil { remove(item) }
    }
  }

  private func remove(_ item: PlanItem) {
    let remaining = (plan.items + plan.covered).filter {
      !FileSystem.path($0.url, isInsideOrEqual: item.url)
    }
    for removed in (plan.items + plan.covered) where FileSystem.path(removed.url, isInsideOrEqual: item.url) {
      model.dequeue(removed)
    }
    plan = OperationPlanner.plan(title: plan.title, items: remaining,
      ignoredPaths: model.ignoredPaths, excluded: plan.excluded, protecting: plan.keeperConstraints, validationItems: plan.validationItems)
  }

  private func breakdownRow(_ level: PlanRiskLevel, _ items: [PlanItem]) -> some View {
    let bytes = items.reduce(Int64(0)) { $0 + $1.expectedBytes }
    let summary = "\(items.count) item\(items.count == 1 ? "" : "s") · " + level.detail
    return HStack(spacing: 10) {
      level.chip.fixedSize()
      Text(summary).font(.system(size: 12)).foregroundStyle(AppTheme.ink2).lineLimit(2)
        .fixedSize(horizontal: false, vertical: true)
      Spacer(minLength: 8)
      Text(ByteFormatter.string(bytes)).font(AppTheme.number(13)).monospacedDigit().foregroundStyle(AppTheme.ink)
    }
    .padding(.horizontal, 12).padding(.vertical, 9)
    .background(level.needsCare ? AppTheme.warningTint : AppTheme.panel,
      in: RoundedRectangle(cornerRadius: 11, style: .continuous))
    .accessibilityElement(children: .combine)
  }

  private func groupCard(_ source: String, _ items: [PlanItem]) -> some View {
    VStack(spacing: 0) {
      PlanGroupHeader(source: source, items: items)
      ForEach(items, id: \.url) { item in
        Rectangle().fill(AppTheme.divider).frame(height: 1)
        PlanItemRow(item: item, onRemove: { remove(item) })
          .contextMenu {
            Button("Keep this item") { remove(item) }
            Button("Exclude from Future Scans") { exclude(item) }
            Button("Show Folder Contents in Finder") { model.reveal(item.url) }
          }
      }
    }
    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    .cardBackground(radius: 14)
  }

  private var notes: some View {
    VStack(alignment: .leading, spacing: 6) {
      if !plan.covered.isEmpty {
        Label(
          "\(plan.covered.count) selected item\(plan.covered.count == 1 ? " is" : "s are") already inside a selected folder and counted once.",
          systemImage: "info.circle"
        )
        .font(.system(size: 11.5))
        .foregroundStyle(AppTheme.ink2)
      }
      if !plan.excluded.isEmpty {
        DisclosureGroup(isExpanded: $showExcluded) {
          VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(plan.excluded.enumerated()), id: \.offset) { _, failure in
              VStack(alignment: .leading, spacing: 1) {
                Text(failure.url.lastPathComponent).font(.system(size: 12, weight: .medium)).foregroundStyle(AppTheme.ink)
                Text(failure.message).font(.system(size: 11)).foregroundStyle(AppTheme.ink2)
                  .fixedSize(horizontal: false, vertical: true)
              }
            }
          }
          .padding(.top, 4)
        } label: {
          Label(
            "\(plan.excluded.count) item\(plan.excluded.count == 1 ? "" : "s") won't be moved",
            systemImage: "hand.raised.fill"
          )
          .font(.system(size: 12, weight: .semibold))
          .foregroundStyle(AppTheme.warning)
        }
      }
    }
    .padding(12)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(AppTheme.panel, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
  }

  private var promises: some View {
    HStack(alignment: .top, spacing: 6) {
      promise("trash", "Goes to the Trash, not deleted")
      promise("checkmark.shield", "Each item is checked again right before it moves")
      promise("doc.text", "A receipt is saved in History")
      promise("arrow.uturn.backward.circle", "Restore while it's in the Trash")
    }
    .padding(.horizontal, 22).padding(.vertical, 10)
    .overlay(alignment: .top) { Rectangle().fill(AppTheme.divider).frame(height: 1) }
  }

  private func promise(_ symbol: String, _ text: String) -> some View {
    VStack(spacing: 4) {
      Image(systemName: symbol).symbolVariant(.fill)
        .font(.system(size: 17)).foregroundStyle(AppTheme.Swatch.mint.text)
        .accessibilityHidden(true)
      Text(text).font(.system(size: 11)).foregroundStyle(AppTheme.ink2)
        .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
    }
    .frame(maxWidth: .infinity)
    .accessibilityElement(children: .combine)
  }
}

// MARK: - Result sheet (after an operation)

struct OperationReportSheet: View {
  let report: OperationReport
  @EnvironmentObject private var model: AppViewModel
  @Environment(\.dismiss) private var dismiss

  private var allGood: Bool { report.problems.isEmpty && !report.wasCancelled && report.persistenceError == nil }

  private var swatch: AppTheme.Swatch { allGood ? .mint : .amber }

  private var headline: String {
    let count = report.moved.count
    if count == 0 { return "Nothing was moved" }
    return count == 1 ? "1 item is in the Trash" : "\(count) items are in the Trash"
  }

  var body: some View {
    VStack(spacing: 0) {
      VStack(spacing: 8) {
        Image(systemName: allGood ? "checkmark" : "exclamationmark")
          .font(.system(size: 28, weight: .bold))
          .foregroundStyle(.white)
          .frame(width: 64, height: 64)
          .background(Circle().fill(swatch.gradient))
          .background(Circle().fill(swatch.tint).padding(-8))
          .padding(.bottom, 8)
          .accessibilityHidden(true)
        Eyebrow(allGood ? "Done" : "Finished with notes", color: swatch.text)
        Text(headline)
          .font(.system(size: 21, weight: .bold)).tracking(-0.4).foregroundStyle(AppTheme.ink)
          .multilineTextAlignment(.center)
          .accessibilityAddTraits(.isHeader)
        if !report.moved.isEmpty {
          Text(ByteFormatter.string(report.bytesMoved))
            .font(AppTheme.number(34)).tracking(-0.8).monospacedDigit()
            .foregroundStyle(AppTheme.Swatch.mint.text)
        }
        if !allGood || report.moved.isEmpty {
          Text(report.summary + ".")
            .font(.system(size: 12.5)).foregroundStyle(AppTheme.ink2)
            .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
        }
        if !report.moved.isEmpty {
          Text("That space comes back when you empty the Trash. Snapshots, clones, and cloud storage can change how much. Until then, you can restore these items from History.")
            .font(.system(size: 12.5)).foregroundStyle(AppTheme.ink2)
            .multilineTextAlignment(.center).frame(maxWidth: 440)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
      .frame(maxWidth: .infinity)
      .padding(.horizontal, 28).padding(.top, 28).padding(.bottom, 14)
      .background(RadialGradient(colors: [swatch.tint, AppTheme.elevated], center: .top, startRadius: 0, endRadius: 320))

      HStack(spacing: 8) {
        if !report.receipts.isEmpty {
          factPill("\(report.receipts.count) receipt\(report.receipts.count == 1 ? "" : "s") saved", symbol: "doc.text")
        }
        factPill("\(report.problems.count) problem\(report.problems.count == 1 ? "" : "s")", symbol: "exclamationmark.circle")
      }
      .padding(.bottom, 16)

      if !report.problems.isEmpty || !report.notAttempted.isEmpty {
        Rectangle().fill(AppTheme.divider).frame(height: 1)
        ScrollView {
          VStack(alignment: .leading, spacing: 8) {
            if !report.problems.isEmpty {
              Eyebrow("Items needing attention")
              ForEach(report.problems) { outcome in
                VStack(alignment: .leading, spacing: 2) {
                  Text(outcome.item.displayName).font(.system(size: 13, weight: .semibold)).foregroundStyle(AppTheme.ink)
                  Text(outcome.message ?? "Skipped").font(.system(size: 12)).foregroundStyle(AppTheme.ink2)
                    .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 12).padding(.vertical, 9)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(AppTheme.panel, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
              }
            }
            if !report.notAttempted.isEmpty {
              Eyebrow("Not started (operation was stopped)")
                .padding(.top, report.problems.isEmpty ? 0 : 6)
              ForEach(report.notAttempted) { outcome in
                Text(outcome.item.displayName).font(.system(size: 12.5)).foregroundStyle(AppTheme.ink)
                  .padding(.horizontal, 12).padding(.vertical, 8)
                  .frame(maxWidth: .infinity, alignment: .leading)
                  .background(AppTheme.panel, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
              }
            }
          }
          .padding(.horizontal, 22).padding(.vertical, 14)
        }
        .frame(minHeight: 160, maxHeight: 320)
      }

      SheetFooter {
        if !report.receipts.isEmpty {
          Button {
            model.undo(report)
          } label: {
            Label("Restore items", systemImage: "arrow.uturn.backward")
          }
          .buttonStyle(MintButtonStyle(.secondary))
          .help("Attempt to restore moved items to their original locations without overwriting existing files")
        }
        Button("Show History") {
          model.selectedSection = .history
          dismiss()
        }
        .buttonStyle(MintButtonStyle(.plain))
        Spacer()
        Button("Done") { dismiss() }
          .buttonStyle(MintButtonStyle(.commit))
          .keyboardShortcut(.defaultAction)
      }
    }
    .frame(width: 600)
    .background(AppTheme.elevated)
    .onExitCommand { dismiss() }
  }

  private func factPill(_ text: String, symbol: String) -> some View {
    Label(text, systemImage: symbol)
      .font(.system(size: 11.5)).foregroundStyle(AppTheme.ink2).monospacedDigit()
      .padding(.horizontal, 10).frame(height: 24)
      .background(AppTheme.panel, in: Capsule())
  }
}

// MARK: - Review queue screen

struct ReviewQueueView: View {
  @EnvironmentObject private var model: AppViewModel

  private var grouped: [(String, [PlanItem])] {
    let items = model.queuedItems
    var order: [String] = []
    for item in items where !order.contains(item.source) { order.append(item.source) }
    return order.map { source in (source, items.filter { $0.source == source }) }
  }

  private var reviewBusy: Bool { model.isWorking || model.isScanning || model.isPreparingPlan }

  var body: some View {
    if model.queuedCount == 0 {
      VStack(alignment: .leading, spacing: 14) {
        header
        steps
        EmptyState(
          icon: "checklist", title: "Your review tray is empty",
          detail: "Pick items in Cleanup, Storage, Developer, Duplicates, or Large Files. They collect here, and you check everything once before it moves to the Trash.",
          actionTitle: "Explore Cleanup", action: { model.selectedSection = .cleaner },
          trust: "You can restore anything from History while it's in the Trash.")
      }
      .padding(.horizontal, AppTheme.pagePadding)
      .padding(.top, AppTheme.pageTopPadding)
    } else {
      VStack(spacing: 0) {
        ScrollView {
          VStack(alignment: .leading, spacing: 14) {
            header
            steps
            if model.queuedLibraryPhotoCount > 0 {
              libraryPhotos
            }
            ForEach(grouped, id: \.0) { source, items in
              groupCard(source, items)
            }
          }
          .frame(maxWidth: 1040)
          .padding(.horizontal, AppTheme.pagePadding)
          .padding(.top, AppTheme.pageTopPadding)
          .padding(.bottom, 24)
          .frame(maxWidth: .infinity)
        }
        footer
      }
    }
  }

  private var header: some View {
    PageHeader("Review", subtitle: "Everything you picked, from every page. Nothing moves until you confirm.")
  }

  // MARK: We looked → You decide → You can undo

  private var steps: some View {
    HStack(spacing: 0) {
      step(1, icon: "checkmark", title: "We looked", detail: "Scans only read your disk")
      Rectangle().fill(AppTheme.divider).frame(width: 1)
      step(2, icon: "hand.tap.fill", title: "You decide", detail: "Remove anything you want to keep")
      Rectangle().fill(AppTheme.divider).frame(width: 1)
      step(3, icon: "arrow.uturn.backward", title: "You can undo", detail: "Restore from History while it's in the Trash")
    }
    .fixedSize(horizontal: false, vertical: true)
    .clipShape(RoundedRectangle(cornerRadius: AppTheme.corner, style: .continuous))
    .cardBackground()
  }

  private func step(_ number: Int, icon: String, title: String, detail: String) -> some View {
    let current = number == 2
    let done = number == 1
    let dotFill: AnyShapeStyle = current
      ? AnyShapeStyle(AppTheme.commitGradient)
      : AnyShapeStyle(done ? AppTheme.successTint : AppTheme.panel)
    let dotInk: Color = current ? Color.white : (done ? AppTheme.accentText : AppTheme.ink2)
    return HStack(spacing: 10) {
      Image(systemName: icon).font(.system(size: 12, weight: .bold))
        .foregroundStyle(dotInk)
        .frame(width: 28, height: 28)
        .background(Circle().fill(dotFill))
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 1) {
        Text(title).font(.system(size: 12.5, weight: .bold))
          .foregroundStyle(current ? AppTheme.Swatch.mint.text : AppTheme.ink)
        Text(detail).font(.system(size: 11))
          .foregroundStyle(current ? AppTheme.ink2 : AppTheme.ink3)
          .fixedSize(horizontal: false, vertical: true)
      }
      Spacer(minLength: 0)
    }
    .padding(.horizontal, 14).padding(.vertical, 12)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    .background(current ? AppTheme.Swatch.mint.tint : Color.clear)
    .accessibilityElement(children: .combine)
    .accessibilityLabel("Step \(number): \(title). \(detail)")
  }

  // MARK: Groups

  private func groupCard(_ source: String, _ items: [PlanItem]) -> some View {
    VStack(spacing: 0) {
      PlanGroupHeader(source: source, items: items)
      ForEach(items, id: \.url) { item in
        Rectangle().fill(AppTheme.divider).frame(height: 1)
        PlanItemRow(item: item) { model.dequeue(item) }
      }
    }
    .clipShape(RoundedRectangle(cornerRadius: AppTheme.corner, style: .continuous))
    .cardBackground()
  }

  /// Library assets never join the Trash plan. Photos asks for its own confirmation.
  private var libraryPhotos: some View {
    let count = model.queuedLibraryPhotoCount
    return VStack(alignment: .leading, spacing: 0) {
      HStack(spacing: 10) {
        SwatchBadge(symbol: "photo", swatch: .pink, size: 22)
        Text("Photos library").font(.system(size: 13, weight: .bold)).foregroundStyle(AppTheme.ink)
        Spacer(minLength: 8)
      }
      .padding(.horizontal, 16).padding(.vertical, 11)
      .background(AppTheme.panel)
      .accessibilityAddTraits(.isHeader)
      Rectangle().fill(AppTheme.divider).frame(height: 1)
      VStack(alignment: .leading, spacing: 8) {
        HStack(spacing: 11) {
          IconTile(symbol: "photo.stack", tint: AppTheme.Swatch.pink.text, size: 30)
          VStack(alignment: .leading, spacing: 2) {
            Text("\(count) Photos library item\(count == 1 ? "" : "s")")
              .font(.system(size: 13, weight: .semibold)).foregroundStyle(AppTheme.ink)
            Text("Photos asks you to confirm. Deleted items stay in Photos ▸ Recently Deleted for about 30 days, and deletion syncs to devices using iCloud Photos.")
              .font(.system(size: 12)).foregroundStyle(AppTheme.ink2).fixedSize(horizontal: false, vertical: true)
          }
          Spacer(minLength: 8)
          Button("Show in Photos") { model.selectedSection = .photos }
            .buttonStyle(MintButtonStyle(.secondary)).controlSize(.small)
          Button("Delete in Photos…") { Task { await model.deleteSelectedLibraryPhotos() } }
            .buttonStyle(MintButtonStyle(.secondary)).controlSize(.small)
            .disabled(reviewBusy)
        }
        if let error = model.photoDeletionError {
          Label(error, systemImage: "exclamationmark.triangle").font(.system(size: 11.5)).foregroundStyle(AppTheme.warning)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
      .padding(.horizontal, 16).padding(.vertical, 12)
    }
    .clipShape(RoundedRectangle(cornerRadius: AppTheme.corner, style: .continuous))
    .cardBackground()
  }

  // MARK: Sticky footer

  private var footer: some View {
    HStack(spacing: 14) {
      VStack(alignment: .leading, spacing: 1) {
        Text(ByteFormatter.string(model.queuedBytes))
          .font(AppTheme.number(22)).tracking(-0.4).monospacedDigit().foregroundStyle(AppTheme.ink)
        Text("\(model.queuedCount) item\(model.queuedCount == 1 ? "" : "s")")
          .font(.system(size: 11.5)).monospacedDigit().foregroundStyle(AppTheme.ink3)
      }
      .fixedSize()
      .accessibilityElement(children: .combine)
      Text("Items move to the Trash with a receipt in History. Space comes back when you empty the Trash.")
        .font(.system(size: 12)).foregroundStyle(AppTheme.ink2)
        .lineLimit(2)
        .frame(maxWidth: .infinity, alignment: .leading)
      Button("Clear All") { model.clearQueue() }
        .buttonStyle(MintButtonStyle(.secondary))
        .fixedSize()
      Button { model.reviewEverything() } label: {
        HStack(spacing: 6) {
          if model.isPreparingPlan {
            ProgressView().controlSize(.small)
          } else {
            Image(systemName: "checklist")
          }
          Text("Final Check…")
        }
      }
      .buttonStyle(MintButtonStyle(.commit))
      .fixedSize()
      .disabled(model.queuedItems.isEmpty || reviewBusy)
      .help("Check everything once more before anything moves · " + ByteFormatter.string(model.queuedBytes))
    }
    .padding(.horizontal, AppTheme.pagePadding).padding(.vertical, 12)
    .background(AppTheme.surface)
    .overlay(alignment: .top) { Rectangle().fill(AppTheme.divider).frame(height: 1) }
  }
}


struct RestoreConflictsSheet: View {
  @EnvironmentObject private var model: AppViewModel
  @Environment(\.dismiss) private var dismiss

  private var title: String {
    let count = model.restoreConflicts.count
    return count == 1 ? "1 item needs attention" : "\(count) items need attention"
  }

  var body: some View {
    VStack(spacing: 0) {
      SheetHeader(symbol: "arrow.uturn.backward.circle", swatch: .slate, eyebrow: "Restore needs attention",
        title: title,
        subtitle: "Choose what to do with each item. Existing files are never overwritten.")
      Rectangle().fill(AppTheme.divider).frame(height: 1)
      ScrollView {
        VStack(spacing: 8) {
          ForEach(model.restoreConflicts) { conflict in
            conflictRow(conflict)
          }
        }
        .padding(.horizontal, 22).padding(.vertical, 14)
      }
      SheetFooter {
        Spacer()
        Button("Close") { dismiss() }
          .buttonStyle(MintButtonStyle(.secondary))
          .keyboardShortcut(.cancelAction)
      }
    }
    .frame(width: 680, height: 460)
    .background(AppTheme.elevated)
  }

  private func conflictRow(_ conflict: AppViewModel.RestoreConflict) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(alignment: .top, spacing: 10) {
        Image(systemName: "folder.fill").font(.system(size: 17)).foregroundStyle(AppTheme.ink2)
          .frame(width: 20)
          .accessibilityHidden(true)
        VStack(alignment: .leading, spacing: 2) {
          Text(conflict.receipt.originalPath)
            .font(.system(size: 12, weight: .medium, design: .monospaced)).foregroundStyle(AppTheme.ink)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
          Text(conflict.message).font(.system(size: 11.5)).foregroundStyle(AppTheme.ink2)
            .fixedSize(horizontal: false, vertical: true)
        }
        Spacer(minLength: 0)
      }
      HStack(spacing: 8) {
        Button("Restore Elsewhere…") { model.restoreElsewhere(conflict) }
          .buttonStyle(MintButtonStyle(.commit))
        Button("Show in Trash") { model.revealInTrash(conflict.receipt) }
          .buttonStyle(MintButtonStyle(.secondary))
        Button("Skip") { model.skipRestoreConflict(conflict) }
          .buttonStyle(MintButtonStyle(.plain))
      }
      .controlSize(.small)
      .padding(.leading, 30)
      .disabled(model.isWorking)
    }
    .padding(12)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(AppTheme.panel, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
  }
}
