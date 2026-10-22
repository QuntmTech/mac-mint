import MacCleanerCore
import SwiftUI

struct DeveloperView: View {
  @EnvironmentObject private var model: AppViewModel
  @Environment(\.areaSwatch) private var area

  /// One slice of the stacked bar: a group and what it holds.
  private struct Segment: Identifiable {
    let group: DevGroup
    let bytes: Int64
    var id: DevGroup { group }
  }

  private var grouped: [(DevGroup, [DevStorageItem])] {
    DevGroup.allCases.compactMap { group in
      let items = model.devItems.filter { $0.group == group }
      return items.isEmpty ? nil : (group, items)
    }
  }

  private var selectedBytes: Int64 { model.queuedDevItems.reduce(0) { $0 + $1.bytes } }

  private static func sum(_ items: [DevStorageItem]) -> Int64 {
    items.reduce(Int64(0)) { $0 + $1.bytes }
  }

  private var segments: [Segment] {
    grouped.map { entry in Segment(group: entry.0, bytes: Self.sum(entry.1)) }
  }

  private var totalBytes: Int64 { Self.sum(model.devItems) }

  private var rebuildableBytes: Int64 { Self.sum(model.devItems.filter { $0.rebuild == .rebuildable }) }

  private var toolCount: Int { Set(model.devItems.map(\.tool)).count }

  var body: some View {
    VStack(spacing: 0) {
      header
      projectBar
      if model.isScanning && (model.operationTitle == "Developer & AI" || (model.devItems.isEmpty && !model.developerScanned)) {
        let own = model.operationTitle == "Developer & AI" || model.operationTitle == "Quick Scan"
        LoadingState(title: own ? "Looking through your developer tools…" : "Developer data is next",
          detail: own
            ? "Measuring Xcode build data, simulators, package-manager caches and local AI models."
            : "\(model.operationTitle ?? "Another scan") is running. This page loads as soon as it finishes.",
          symbol: "hammer.fill", swatch: .orange,
          cancel: model.operationTitle == "Developer & AI" ? { model.cancelCurrentOperation() } : nil)
      } else if model.devItems.isEmpty {
        EmptyState(
          icon: "hammer", title: "Find developer and AI clutter",
          detail: "Xcode build data, simulators, package caches, project build folders, and local AI models — each with what it costs to remove.",
          actionTitle: "Scan developer data", action: { model.scanDeveloper() })
      } else {
        ScrollView {
          VStack(alignment: .leading, spacing: 14) {
            summary
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 420), spacing: 12, alignment: .top)], alignment: .leading, spacing: 12) {
              ForEach(grouped, id: \.0) { group, items in
                groupCard(group, items: items)
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
    .task(id: model.autoLoadKey) { model.autoLoadIfNeeded(.developer) }
  }

  // MARK: Header

  private var header: some View {
    PageHeader(title: "Developer", subtitle: "Build output, package caches, and local models. See the cost of rebuilding before you decide.") {
      if !model.selectedDevIDs.isEmpty {
        Button("Deselect") { model.keepQueuedFiles(model.queuedDevItems.compactMap(\.url)) }
          .buttonStyle(MintButtonStyle(.plain))
        Button {
          model.reviewDeveloper()
        } label: {
          Label("Review \(ByteFormatter.string(selectedBytes))", systemImage: "checklist")
        }
        .buttonStyle(MintButtonStyle(.commit))
        .disabled(model.isWorking || model.isScanning || selectedBytes == 0)
      }
      if model.devItems.isEmpty {
        Button { model.scanDeveloper() } label: { Label("Scan", systemImage: "magnifyingglass") }
          .buttonStyle(MintButtonStyle(.area))
          .disabled(model.isScanning || model.isWorking)
      } else {
        Button { model.scanDeveloper() } label: { Label("Rescan", systemImage: "arrow.clockwise") }
          .buttonStyle(MintButtonStyle(.area))
          .disabled(model.isScanning || model.isWorking)
      }
    }
    .padding(.horizontal, AppTheme.pagePadding)
    .padding(.top, AppTheme.pageTopPadding)
    .padding(.bottom, 14)
  }

  private var projectBar: some View {
    HStack(spacing: 10) {
      Image(systemName: "folder.badge.gearshape").font(.system(size: 14, weight: .semibold)).foregroundStyle(area.text)
        .accessibilityHidden(true)
      if model.devProjectRoots.isEmpty {
        Text("Add your code folder to find node_modules, .build, target, and other build output.")
          .font(.system(size: 12))
          .foregroundStyle(AppTheme.ink2)
          .lineLimit(2)
          .fixedSize(horizontal: false, vertical: true)
      } else {
        ScrollView(.horizontal, showsIndicators: false) {
          HStack(spacing: 6) {
            ForEach(model.devProjectRoots, id: \.self) { url in
              HStack(spacing: 4) {
                Text(url.lastPathComponent).font(.system(size: 11.5, weight: .semibold)).foregroundStyle(area.text)
                  .lineLimit(1)
                Button {
                  model.removeProjectFolder(url)
                } label: {
                  Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(area.text.opacity(0.7))
                    .accessibilityLabel("Stop scanning this folder")
                }
                .buttonStyle(.borderless)
                .help("Stop scanning \(url.path)")
              }
              .padding(.leading, 9)
              .padding(.trailing, 5)
              .frame(height: 22)
              .background(area.tint, in: Capsule())
            }
          }
        }
      }
      Spacer(minLength: 8)
      Button("Add Project Folder…") { model.addProjectFolder() }
        .buttonStyle(MintButtonStyle(.secondary))
        .controlSize(.small)
        .disabled(model.isScanning || model.isWorking)
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 10)
    .cardBackground(radius: 12)
    .frame(maxWidth: 1180)
    .padding(.horizontal, AppTheme.pagePadding)
    .padding(.bottom, 14)
    .frame(maxWidth: .infinity)
  }

  // MARK: Summary

  private var summary: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack(alignment: .firstTextBaseline, spacing: 10) {
        Text(ByteFormatter.string(totalBytes))
          .font(AppTheme.number(28)).tracking(-0.6).monospacedDigit().foregroundStyle(AppTheme.ink)
        HStack(spacing: 4) {
          Text("across \(toolCount) tool\(toolCount == 1 ? "" : "s")").foregroundStyle(AppTheme.ink2)
          if rebuildableBytes > 0 {
            Text("·").foregroundStyle(AppTheme.ink3)
            Text("\(ByteFormatter.string(rebuildableBytes)) rebuildable")
              .fontWeight(.semibold).foregroundStyle(AppTheme.accentText)
          }
        }
        .font(.system(size: 12.5))
        .monospacedDigit()
        .lineLimit(1)
      }
      .accessibilityElement(children: .combine)
      stackedBar
      LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 16, alignment: .leading)], alignment: .leading, spacing: 6) {
        ForEach(segments) { part in legendItem(part) }
      }
    }
    .padding(.horizontal, 18)
    .padding(.vertical, 16)
    .frame(maxWidth: .infinity, alignment: .leading)
    .cardBackground()
  }

  private var stackedBar: some View {
    let parts = segments
    let total = max(Int64(1), parts.reduce(Int64(0)) { $0 + $1.bytes })
    return GeometryReader { geometry in
      barRow(parts, total: total, width: geometry.size.width)
    }
    .frame(height: 14)
    .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("Space by tool")
    .accessibilityValue(parts.map { "\($0.group.rawValue) \(ByteFormatter.string($0.bytes))" }.joined(separator: ", "))
  }

  private func barRow(_ parts: [Segment], total: Int64, width: CGFloat) -> some View {
    let gaps = CGFloat(max(0, parts.count - 1)) * 2
    let available = max(0, width - gaps)
    return HStack(spacing: 2) {
      ForEach(parts) { part in
        Rectangle()
          .fill(groupSwatch(part.group).gradient)
          .frame(width: max(3, available * CGFloat(Double(part.bytes) / Double(total))))
      }
    }
    .frame(width: width, alignment: .leading)
  }

  private func legendItem(_ part: Segment) -> some View {
    HStack(spacing: 6) {
      RoundedRectangle(cornerRadius: 3, style: .continuous)
        .fill(groupSwatch(part.group).gradient)
        .frame(width: 9, height: 9)
      Text(part.group.rawValue).foregroundStyle(AppTheme.ink2).lineLimit(1)
      Text(ByteFormatter.string(part.bytes)).fontWeight(.semibold).foregroundStyle(AppTheme.ink).monospacedDigit()
    }
    .font(.system(size: 12))
    .accessibilityElement(children: .combine)
  }

  private func groupSwatch(_ group: DevGroup) -> AppTheme.Swatch {
    switch group {
    case .xcode: return .sky
    case .simulators: return .indigo
    case .packageCaches: return .amber
    case .projects: return .orange
    case .aiModels: return .violet
    case .containers: return .teal
    }
  }

  private func groupSymbol(_ group: DevGroup) -> String {
    switch group {
    case .xcode: return "hammer"
    case .simulators: return "iphone"
    case .packageCaches: return "shippingbox"
    case .projects: return "folder"
    case .aiModels: return "brain.head.profile"
    case .containers: return "cube.box"
    }
  }

  // MARK: Groups

  private func groupCard(_ group: DevGroup, items: [DevStorageItem]) -> some View {
    VStack(spacing: 0) {
      HStack(spacing: 10) {
        SwatchBadge(symbol: groupSymbol(group), swatch: groupSwatch(group), size: 30)
        VStack(alignment: .leading, spacing: 1) {
          Text(group.rawValue).font(.system(size: 13.5, weight: .bold)).foregroundStyle(AppTheme.ink)
            .accessibilityAddTraits(.isHeader)
          Text("\(items.count) item\(items.count == 1 ? "" : "s")").font(.system(size: 11)).foregroundStyle(AppTheme.ink3)
        }
        Spacer(minLength: 8)
        Text(ByteFormatter.string(Self.sum(items)))
          .font(AppTheme.number(13.5)).monospacedDigit().foregroundStyle(AppTheme.ink)
      }
      .padding(.horizontal, 14)
      .padding(.vertical, 12)
      ForEach(items) { item in
        Rectangle().fill(AppTheme.divider).frame(height: 1)
        row(item)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .cardBackground()
  }

  private func row(_ item: DevStorageItem) -> some View {
    HStack(alignment: .center, spacing: 10) {
      selector(item)

      OwnerIcon(
        hint: OwnerResolver.toolBundleIDs[item.tool].map { OwnerHint(bundleID: $0, displayName: item.tool) }
          ?? item.url.flatMap { OwnerResolver.hint(for: $0) },
        fallbackSymbol: "hammer", size: 24)

      VStack(alignment: .leading, spacing: 3) {
        HStack(spacing: 6) {
          Text(item.title).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(AppTheme.ink)
            .lineLimit(1).truncationMode(.middle)
          if item.isActive { inUseTag }
        }
        Text(detail(item)).font(.system(size: 11)).foregroundStyle(AppTheme.ink3).lineLimit(2)
          .fixedSize(horizontal: false, vertical: true)
        if let command = command(of: item) {
          commandChip(command, tool: item.tool)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)

      VStack(alignment: .trailing, spacing: 4) {
        Text(ByteFormatter.string(item.bytes))
          .font(AppTheme.number(12.5, weight: .semibold)).monospacedDigit().foregroundStyle(AppTheme.ink)
        costBadge(item.rebuild)
      }
      .fixedSize()

      trailingAction(item)
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 9)
    .frame(minHeight: 48)
  }

  private func detail(_ item: DevStorageItem) -> String {
    var parts = [item.tool]
    if !item.subtitle.isEmpty { parts.append(item.subtitle) }
    if let date = item.lastUsed {
      parts.append("Last changed \(date.formatted(.relative(presentation: .named)))")
    }
    return parts.joined(separator: " · ")
  }

  private func command(of item: DevStorageItem) -> String? {
    if case .command(let command) = item.removal { return command }
    return nil
  }

  @ViewBuilder
  private func selector(_ item: DevStorageItem) -> some View {
    if item.canTrash {
      Toggle(
        isOn: Binding(
          get: { model.selectedDevIDs.contains(item.id) },
          set: { isOn in
            if let url = item.url { model.setFileSelection(url, selected: isOn) }
          })
      ) { EmptyView() }
      .toggleStyle(MintCheckboxStyle())
      .labelsHidden()
      .accessibilityLabel("Select \(item.title)")
    } else {
      Color.clear.frame(width: 16, height: 16)
    }
  }

  private var inUseTag: some View {
    Text("IN USE")
      .font(.system(size: 10, weight: .bold))
      .tracking(0.4)
      .foregroundStyle(AppTheme.warning)
      .lineLimit(1)
      .padding(.horizontal, 6)
      .frame(height: 16)
      .background(AppTheme.warningTint, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
      .fixedSize()
      .help("Changed recently, so it may be in use. It is never selected for you.")
      .accessibilityLabel("In use")
  }

  private func commandChip(_ command: String, tool: String) -> some View {
    let shape = RoundedRectangle(cornerRadius: 6, style: .continuous)
    return Button {
      model.copyCommand(command)
    } label: {
      HStack(spacing: 5) {
        Image(systemName: "terminal").font(.system(size: 10, weight: .semibold))
        Text(command).font(.system(size: 11, design: .monospaced)).lineLimit(1).truncationMode(.middle)
        Image(systemName: "doc.on.doc").font(.system(size: 10, weight: .semibold))
      }
      .foregroundStyle(AppTheme.ink2)
      .padding(.horizontal, 7)
      .frame(height: 22)
      .background(AppTheme.panel, in: shape)
      .contentShape(shape)
    }
    .buttonStyle(.plain)
    .help("Managed by \(tool). Run “\(command)” in Terminal instead of deleting files.")
    .accessibilityLabel("Copy Command")
    .accessibilityValue(command)
  }

  @ViewBuilder
  private func trailingAction(_ item: DevStorageItem) -> some View {
    switch item.removal {
    case .command:
      // The command is copied from its chip under the title.
      Color.clear.frame(width: 28, height: 1)
    case .none(let reason):
      Image(systemName: "info.circle")
        .font(.system(size: 13))
        .foregroundStyle(AppTheme.ink3)
        .frame(width: 28)
        .help(reason)
    case .trash:
      Menu {
        if let url = item.url {
          Button("Reveal in Finder") { model.reveal(url) }
          Button("Exclude from Future Scans") { model.ignore(url) }
        }
        ExplainMenuItem(target: model.aiTarget(for: item))
      } label: {
        Image(systemName: "ellipsis.circle")
          .accessibilityLabel("More actions")
      }
      .menuStyle(.borderlessButton)
      .menuIndicator(.hidden)
      .frame(width: 28)
    }
  }

  private func costBadge(_ cost: RebuildCost) -> some View {
    rebuildChip(cost).help(cost.explanation)
  }

  private func rebuildChip(_ cost: RebuildCost) -> Chip {
    switch cost {
    case .rebuildable: return Chip(title: "Rebuildable", symbol: "arrow.triangle.2.circlepath", swatch: .mint)
    case .redownload: return Chip(title: "Re-downloads", symbol: "icloud.and.arrow.down", swatch: .sky)
    case .review: return Chip(title: "Review", symbol: "eye", swatch: .amber)
    }
  }
}
