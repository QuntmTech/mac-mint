import MacCleanerCore
import SwiftUI

/// Data left in ~/Library by apps that are no longer installed. Review-only: nothing is
/// preselected, and every row shows the evidence (the unclaimed bundle identifier).
struct RemovedAppsView: View {
  @EnvironmentObject private var model: AppViewModel

  private var grouped: [(String, [OrphanedItem])] {
    var order: [String] = []
    var buckets: [String: [OrphanedItem]] = [:]
    for item in model.orphans {
      if buckets[item.bundleID] == nil { order.append(item.bundleID) }
      buckets[item.bundleID, default: []].append(item)
    }
    return order.map { ($0, buckets[$0] ?? []) }
  }

  private var selectedBytes: Int64 { model.queuedOrphans.reduce(0) { $0 + $1.bytes } }

  var body: some View {
    VStack(spacing: 0) {
      PageHeader(title: "Removed Apps", subtitle: "Settings, caches, and containers left behind by apps you’ve removed.") {
        HStack(spacing: 8) {
          if !model.selectedOrphanIDs.isEmpty {
            Button("Deselect") { model.keepQueuedFiles(model.queuedOrphans.map(\.url)) }
              .buttonStyle(MintButtonStyle(.plain))
            Button {
              model.reviewOrphans()
            } label: {
              Label("Review \(ByteFormatter.string(selectedBytes))", systemImage: "trash")
            }
            .buttonStyle(MintButtonStyle(.commit))
            .disabled(model.isWorking || model.isScanning)
          }
          Button {
            model.scanOrphans()
          } label: {
            Label(model.orphansScanned ? "Rescan" : "Scan", systemImage: "arrow.clockwise")
          }
          .buttonStyle(MintButtonStyle(.area))
          .disabled(model.isScanning || model.isWorking)
        }
      }
      .frame(maxWidth: 1180)
      .padding(.horizontal, AppTheme.pagePadding)
      .padding(.top, AppTheme.pageTopPadding)
      .padding(.bottom, 14)
      .frame(maxWidth: .infinity)

      if model.isScanning && (model.operationTitle == "Removed Apps" || (model.orphans.isEmpty && !model.orphansScanned)) {
        let own = model.operationTitle == "Removed Apps" || model.operationTitle == "Quick Scan"
        LoadingState(title: own ? "Looking for app leftovers…" : "Removed-app data is next",
          detail: own
            ? "Comparing your Library with the apps you have installed. Only data no installed app claims is listed."
            : "\(model.operationTitle ?? "Another scan") is running. This page loads as soon as it finishes.",
          symbol: "folder.badge.questionmark", swatch: .violet,
          cancel: model.operationTitle == "Removed Apps" ? { model.cancelCurrentOperation() } : nil)
      } else if model.orphans.isEmpty {
        EmptyState(
          icon: model.orphansScanned ? "checkmark.seal" : "folder.badge.questionmark",
          title: model.orphansScanned ? "No leftovers found" : "Find leftovers from apps you've deleted",
          detail:
            "Only data whose app identifier no installed app claims is listed. macOS's own data is never included.",
          actionTitle: model.orphansScanned ? nil : "Find Leftovers",
          action: model.orphansScanned ? nil : { model.scanOrphans() })
      } else {
        ScrollView {
          VStack(alignment: .leading, spacing: 14) {
            tip
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 300), spacing: 12, alignment: .top)], alignment: .leading, spacing: 12) {
              ForEach(grouped, id: \.0) { bundleID, items in
                card(bundleID, items)
              }
            }
          }
          .frame(maxWidth: 1180)
          .padding(.horizontal, AppTheme.pagePadding)
          .padding(.top, 2)
          .padding(.bottom, 24)
          .frame(maxWidth: .infinity)
        }
      }
    }
    .task(id: model.autoLoadKey) { model.autoLoadIfNeeded(.removedApps) }
  }

  /// Settings stay useful if the app comes back.
  private var tip: some View {
    HStack(spacing: 10) {
      Image(systemName: "lightbulb.fill")
        .font(.system(size: 14, weight: .semibold))
        .foregroundStyle(AppTheme.Swatch.amber.text)
        .accessibilityHidden(true)
      Text("Plan to reinstall one of these apps? Keep its settings, and the app picks up where you left off.")
        .font(.system(size: 12.5)).foregroundStyle(AppTheme.ink)
        .fixedSize(horizontal: false, vertical: true)
      Spacer(minLength: 0)
    }
    .padding(.horizontal, 14).padding(.vertical, 12)
    .background(AppTheme.Swatch.amber.tint, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
  }

  /// The app is gone, so there is no icon to show: a dashed placeholder with its initial.
  private func placeholderIcon(_ bundleID: String) -> some View {
    let letter = bundleID.split(separator: ".").last.map { String($0.prefix(1)).uppercased() } ?? "?"
    let shape = RoundedRectangle(cornerRadius: 9, style: .continuous)
    return Text(letter.isEmpty ? "?" : letter)
      .font(.system(size: 15, weight: .bold))
      .foregroundStyle(AppTheme.ink2)
      .frame(width: 36, height: 36)
      .background(AppTheme.panel, in: shape)
      .overlay(shape.strokeBorder(AppTheme.borderStrong, style: StrokeStyle(lineWidth: 1.5, dash: [3, 2.5])))
      .accessibilityHidden(true)
  }

  private func riskChip(_ confidence: MatchConfidence) -> Chip {
    confidence == .medium
      ? Chip(title: "Likely unused", symbol: "clock.fill", swatch: .sky)
      : Chip(title: "Check first", symbol: "eye.fill", swatch: .amber)
  }

  private func card(_ bundleID: String, _ items: [OrphanedItem]) -> some View {
    let total = items.reduce(Int64(0)) { $0 + $1.bytes }
    let mixed = Set(items.map(\.confidence)).count > 1
    // The card shows the most careful level among its items.
    let level: MatchConfidence = items.allSatisfy { $0.confidence == .medium } ? .medium : .low
    let shape = RoundedRectangle(cornerRadius: AppTheme.corner, style: .continuous)
    return VStack(alignment: .leading, spacing: 0) {
      HStack(spacing: 11) {
        placeholderIcon(bundleID)
        VStack(alignment: .leading, spacing: 2) {
          Text(bundleID).font(.system(size: 13.5, weight: .bold)).foregroundStyle(AppTheme.ink)
            .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
          Text(items.count == 1 ? "1 item" : "\(items.count) items")
            .font(.system(size: 11.5)).foregroundStyle(AppTheme.ink3)
        }
        Spacer(minLength: 8)
        Text(ByteFormatter.string(total)).font(AppTheme.number(16)).monospacedDigit().foregroundStyle(AppTheme.ink)
          .fixedSize()
      }
      .padding(.horizontal, 14).padding(.vertical, 13)

      ForEach(items) { item in
        Rectangle().fill(AppTheme.divider).frame(height: 1)
        row(item, showsRisk: mixed)
      }

      HStack(spacing: 6) {
        riskChip(level)
        Text("No installed app claims this").font(.system(size: 11)).foregroundStyle(AppTheme.ink2).lineLimit(1)
        Spacer(minLength: 4)
        Button("Select All") {
          model.selectedOrphanIDs.formUnion(items.map(\.id))
        }
        .buttonStyle(MintButtonStyle(.plain))
        .controlSize(.small)
      }
      .padding(.horizontal, 14).padding(.vertical, 8)
      .background(AppTheme.panel)
      .overlay(alignment: .top) { Rectangle().fill(AppTheme.divider).frame(height: 1) }
    }
    .background(AppTheme.surface)
    .clipShape(shape)
    .cardBackground()
  }

  private func row(_ item: OrphanedItem, showsRisk: Bool) -> some View {
    HStack(alignment: .top, spacing: 10) {
      Toggle(
        "",
        isOn: Binding(
          get: { model.selectedOrphanIDs.contains(item.id) },
          set: { isOn in
            model.setFileSelection(item.url, selected: isOn)
          })
      )
      .toggleStyle(MintCheckboxStyle())
      .labelsHidden()
      .fixedSize()
      .padding(.top, 1)
      .accessibilityLabel("Select \(item.url.lastPathComponent)")
      VStack(alignment: .leading, spacing: 3) {
        HStack(spacing: 6) {
          Text(item.location).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(AppTheme.ink).lineLimit(1)
          if showsRisk { riskChip(item.confidence) }
          Spacer(minLength: 4)
          Text(ByteFormatter.string(item.bytes))
            .font(AppTheme.number(12.5, weight: .semibold)).monospacedDigit().foregroundStyle(AppTheme.ink)
            .fixedSize()
        }
        Text(item.url.path).font(.system(size: 11, design: .monospaced)).foregroundStyle(AppTheme.ink2)
          .lineLimit(1).truncationMode(.middle).help(item.url.path)
        Text(item.reason).font(.system(size: 11.5)).foregroundStyle(AppTheme.ink2).lineLimit(2)
          .fixedSize(horizontal: false, vertical: true)
        if let modified = item.modified {
          Text("Last changed \(modified.formatted(.relative(presentation: .named)))")
            .font(.system(size: 11)).foregroundStyle(AppTheme.ink3)
        }
      }
      Menu {
        Button("Reveal in Finder") { model.reveal(item.url) }
        Button("Exclude from Future Scans") { model.ignore(item.url) }
        ExplainMenuItem(target: model.aiTarget(for: item))
      } label: {
        Image(systemName: "ellipsis.circle")
          .accessibilityLabel("More actions")
      }
      .menuStyle(.borderlessButton)
      .fixedSize()
    }
    .padding(.horizontal, 14).padding(.vertical, 10)
  }
}
