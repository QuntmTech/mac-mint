import AppKit
import MacCleanerCore
import SwiftUI
import UniformTypeIdentifiers

struct ApplicationsView: View {
  @EnvironmentObject private var model: AppViewModel
  @EnvironmentObject private var updates: AppUpdatesStore
  @Environment(\.areaSwatch) private var swatch
  @SceneStorage("apps.search") private var search = ""
  @SceneStorage("apps.sort") private var sort: AppSort = .name
  @SceneStorage("apps.mode") private var mode: Mode = .uninstall
  @FocusState private var listFocused: Bool

  enum Mode: String, CaseIterable, Identifiable {
    case uninstall = "Uninstall"
    case updates = "Updates"
    var id: String { rawValue }
  }

  enum AppSort: String, CaseIterable, Identifiable {
    case name = "Name"
    case size = "Size"
    case recent = "Modified"
    case lastOpened = "Last opened"
    var id: String { rawValue }
  }

  private var filteredApps: [AppRecord] {
    let filtered =
      search.isEmpty
      ? model.apps
      : model.apps.filter {
        $0.name.localizedCaseInsensitiveContains(search)
          || ($0.bundleIdentifier?.localizedCaseInsensitiveContains(search) ?? false)
      }
    switch sort {
    case .name:
      return filtered.sorted {
        $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
      }
    case .size:
      return filtered.sorted { $0.bundleSize > $1.bundleSize }
    case .recent:
      return filtered.sorted {
        ($0.lastModified ?? .distantPast) > ($1.lastModified ?? .distantPast)
      }
    case .lastOpened:
      // Longest unused first; unknown (no Spotlight record) last — unknown is never "unused".
      return filtered.sorted {
        ($0.lastUsed ?? .distantFuture) < ($1.lastUsed ?? .distantFuture)
      }
    }
  }

  /// Planned off the main actor with the rest of the queue summary.
  private var selectedLeftoverBytes: Int64 { model.queueSummary.selectedLeftoverBytes }

  /// Whole days since Spotlight last saw the app opened; nil when unknown (never counted as unused).
  private static func daysSinceOpened(_ app: AppRecord) -> Int? {
    guard let lastUsed = app.lastUsed else { return nil }
    return Int(Date().timeIntervalSince(lastUsed) / 86_400)
  }

  var body: some View {
    VStack(spacing: 0) {
      PageHeader(title: "Apps", subtitle: "Uninstall apps with their caches, settings and related data. Review every change first.") {
        HStack(spacing: 8) {
          modePicker
          Button { mode = .uninstall; model.chooseAppForUninstall() } label: { Label("Choose App…", systemImage: "plus.app") }
            .buttonStyle(MintButtonStyle(.secondary)).disabled(model.isScanning || model.isWorking)
          Button { model.scanInstalledApps() } label: { Label(model.apps.isEmpty ? "Find Apps" : "Refresh Apps", systemImage: "arrow.clockwise") }
            .buttonStyle(MintButtonStyle(.area)).disabled(model.isScanning || model.isWorking)
        }
      }
      .padding(.horizontal, AppTheme.pagePadding)
      .padding(.top, AppTheme.pageTopPadding)
      .padding(.bottom, 14)
      if mode == .updates {
        AppUpdatesView()
      } else {
        uninstaller
      }
    }
    .task(id: model.autoLoadKey) { model.autoLoadIfNeeded(.applications) }
    .onDrop(of: [.fileURL], isTargeted: nil) { providers in
      mode = .uninstall
      guard let provider = providers.first else { return false }
      _ = provider.loadObject(ofClass: URL.self) { url, _ in
        guard let url else { return }
        Task { @MainActor in model.inspectDroppedApp(url) }
      }
      return true
    }
  }

  /// "All Apps / Updates", with the number of available updates once a check has found some.
  private var modePicker: some View {
    let count: Int? = updates.available.isEmpty ? nil : updates.available.count
    let options: [SegmentedPills<Mode>.Option] = [
      SegmentedPills<Mode>.Option(value: Mode.uninstall, title: "All Apps"),
      SegmentedPills<Mode>.Option(value: Mode.updates, title: "Updates", count: count),
    ]
    return SegmentedPills<Mode>(selection: $mode, options: options)
      .accessibilityElement(children: .contain)
      .accessibilityLabel("Mode")
  }

  /// The app list fills itself the first time this page opens; until then it says what's happening.
  @ViewBuilder private var uninstaller: some View {
    if model.apps.isEmpty { firstLoad } else { appList }
  }

  @ViewBuilder private var firstLoad: some View {
    let own = model.operationTitle == "Installed apps" || model.operationTitle == "Quick Scan"
    if model.isScanning {
      LoadingState(title: own ? "Finding your apps…" : "Your apps are next",
        detail: own
          ? "Reading your Applications folders, each app's size and when you last opened it. This takes a few seconds."
          : "\(model.operationTitle ?? "Another scan") is running. Your apps load as soon as it finishes.",
        symbol: "square.grid.2x2", swatch: .violet,
        cancel: own ? { model.cancelCurrentOperation() } : nil)
    } else {
      EmptyState(icon: "square.grid.2x2", title: "Find your apps",
        detail: "See every app with its size and when you last opened it, then uninstall the ones you don't need along with their leftover files.",
        actionTitle: "Find Apps") { model.scanInstalledApps() }
    }
  }

  private var appList: some View {
    // Keep both panes in the same SwiftUI layout tree. NSSplitView's nested
    // hosting roots on macOS 26 can misplace safe-area/footer coordinates.
    GeometryReader { geometry in
      HStack(alignment: .top, spacing: 12) {
        listPane
          .frame(width: geometry.size.width < 820 ? 250 : 300)
          .frame(maxHeight: .infinity)
        detail
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      }
      .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
    }
    .padding(.horizontal, AppTheme.pagePadding)
    .padding(.bottom, 18)
  }

  // MARK: - App list

  private var listPane: some View {
    VStack(spacing: 0) {
      HStack(spacing: 6) {
        Text("Installed apps").font(.system(size: 13, weight: .bold)).foregroundStyle(AppTheme.ink)
        Text("\(model.apps.count)").font(AppTheme.number(12, weight: .semibold)).monospacedDigit()
          .foregroundStyle(AppTheme.ink3)
        Spacer()
        Menu {
          Picker("Sort apps", selection: $sort) {
            ForEach(AppSort.allCases) { item in Text(item.rawValue).tag(item) }
          }
        } label: { Image(systemName: "arrow.up.arrow.down").accessibilityLabel("Sort apps") }
          .menuStyle(.borderlessButton).fixedSize()
          .onAppear {
            if model.applicationsSortByLastOpened { sort = .lastOpened; model.applicationsSortByLastOpened = false }
          }
      }
      .padding(.horizontal, 14).padding(.top, 12).padding(.bottom, 8)
      SearchField(prompt: "Search apps or bundle IDs", text: $search)
        .padding(.horizontal, 10).padding(.bottom, 10)
      Rectangle().fill(AppTheme.divider).frame(height: 1)
      appRows
      Rectangle().fill(AppTheme.divider).frame(height: 1)
      Label("Drop an app here to inspect", systemImage: "square.and.arrow.down")
        .font(.system(size: 11.5)).foregroundStyle(AppTheme.ink3)
        .lineLimit(1)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14).padding(.vertical, 9)
    }
    .cardBackground()
  }

  private var appRows: some View {
    ScrollViewReader { proxy in
      ScrollView {
        LazyVStack(spacing: 2) {
          ForEach(filteredApps) { app in
            appRow(app).id(app.id)
          }
        }
        .padding(6)
      }
      // Arrow keys move through the list, as they did in the system list.
      .focusable()
      .focused($listFocused)
      .focusEffectDisabled()
      .onMoveCommand { direction in moveSelection(direction, proxy: proxy) }
    }
  }

  private func select(_ app: AppRecord) {
    guard model.selectedApp?.id != app.id else { return }
    model.loadLeftovers(for: app)
  }

  private func moveSelection(_ direction: MoveCommandDirection, proxy: ScrollViewProxy) {
    let apps = filteredApps
    guard !apps.isEmpty else { return }
    let current = apps.firstIndex { $0.id == model.selectedApp?.id }
    let next: Int
    switch direction {
    case .up: next = max(0, (current ?? 1) - 1)
    case .down: next = min(apps.count - 1, (current ?? -1) + 1)
    default: return
    }
    guard next != current else { return }
    select(apps[next])
    proxy.scrollTo(apps[next].id)
  }

  private func appRow(_ app: AppRecord) -> some View {
    let selected = model.selectedApp?.id == app.id
    let days = Self.daysSinceOpened(app)
    return Button {
      listFocused = true
      select(app)
    } label: {
      HStack(spacing: 10) {
        Image(nsImage: FileIcons.icon(forPath: app.url.path))
          .resizable()
          .interpolation(.high)
          .frame(width: 32, height: 32)
          .accessibilityHidden(true)
        VStack(alignment: .leading, spacing: 2) {
          Text(app.name).font(.system(size: 13, weight: .semibold)).foregroundStyle(AppTheme.ink).lineLimit(1)
          Text(openedLine(app, days: days)).font(.system(size: 11)).foregroundStyle(AppTheme.ink2).lineLimit(1)
        }
        Spacer(minLength: 4)
        VStack(alignment: .trailing, spacing: 3) {
          Text(ByteFormatter.string(app.bundleSize))
            .font(AppTheme.number(12, weight: .semibold)).monospacedDigit().foregroundStyle(AppTheme.ink2)
            .lineLimit(1).fixedSize()
          if let days, days >= 180 {
            Chip(title: "UNUSED", swatch: .amber)
              .help("Not opened in \(RelativeAge.describe(days: days))")
          }
        }
      }
      .padding(.horizontal, 8).padding(.vertical, 7)
      .frame(minHeight: 48)
    }
    .buttonStyle(SelectableRowStyle(selected: selected))
    .accessibilityAddTraits(selected ? .isSelected : [])
  }

  private func openedLine(_ app: AppRecord, days: Int?) -> String {
    if let days { return days < 1 ? "Opened today" : "Opened \(RelativeAge.describe(days: days)) ago" }
    if let version = app.version { return "Version " + version }
    return "Last opened unknown"
  }

  // MARK: - Detail

  private func isInspecting(_ app: AppRecord) -> Bool {
    model.isScanning && model.operationTitle?.contains(app.name) == true
  }

  @ViewBuilder
  private var detail: some View {
    if let app = model.selectedApp {
      VStack(alignment: .leading, spacing: 0) {
        detailHeader(app)
        statTiles(app)
          .padding(.horizontal, 20).padding(.bottom, 14)
        relatedHeader
        ScrollView {
          relatedFiles(app)
        }
      }
      .safeAreaInset(edge: .bottom, spacing: 0) {
        footer(app)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
      .background(AppTheme.surface)
      .clipShape(RoundedRectangle(cornerRadius: AppTheme.corner, style: .continuous))
      .cardBackground()
    } else {
      EmptyState(
        icon: "square.stack.3d.up", title: "Get to know your apps",
        detail:
          "Choose an app from the list, or drop an app into this window to inspect its related files before uninstalling.")
        .cardBackground()
    }
  }

  private func subline(_ app: AppRecord) -> String {
    var parts: [String] = []
    if let version = app.version { parts.append("Version " + version) }
    parts.append(app.bundleIdentifier ?? "No bundle identifier")
    return parts.joined(separator: " · ")
  }

  private func detailHeader(_ app: AppRecord) -> some View {
    HStack(alignment: .center, spacing: 14) {
      Image(nsImage: FileIcons.icon(forPath: app.url.path))
        .resizable().interpolation(.high).frame(width: 60, height: 60)
        .shadow(color: .black.opacity(0.18), radius: 6, y: 4)
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 4) {
        HStack(spacing: 8) {
          Text(app.name).font(.system(size: 20, weight: .bold)).tracking(-0.4).foregroundStyle(AppTheme.ink)
            .lineLimit(2).fixedSize(horizontal: false, vertical: true)
          if model.selectedAppIsRunning { Chip(title: "Running", symbol: "play.circle.fill", swatch: .amber) }
        }
        Text(subline(app)).font(.system(size: 12)).foregroundStyle(AppTheme.ink3)
          .textSelection(.enabled).lineLimit(1).truncationMode(.middle)
      }
      Spacer(minLength: 0)
      Button { model.reveal(app.url) } label: { Image(systemName: "arrow.up.right.square") }
        .buttonStyle(MintButtonStyle(.secondary)).controlSize(.small)
        .help("Reveal app in Finder").accessibilityLabel("Reveal app in Finder")
    }
    .padding(.horizontal, 20).padding(.top, 18).padding(.bottom, 14)
    .background(LinearGradient(colors: [swatch.tint, AppTheme.surface], startPoint: .top, endPoint: .bottom))
  }

  private func statTiles(_ app: AppRecord) -> some View {
    HStack(spacing: 8) {
      statTile("App size", ByteFormatter.string(app.bundleSize))
      statTile("Last opened", lastOpenedValue(app))
      statTile("Related data", relatedValue(app))
    }
  }

  private func statTile(_ label: String, _ value: String) -> some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(label).font(.system(size: 11)).foregroundStyle(AppTheme.ink2).lineLimit(1)
      Text(value).font(AppTheme.number(17)).monospacedDigit().foregroundStyle(AppTheme.ink)
        .lineLimit(1).minimumScaleFactor(0.7)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.horizontal, 12).padding(.vertical, 10)
    .background(AppTheme.panel, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
    .accessibilityElement(children: .combine)
  }

  private func lastOpenedValue(_ app: AppRecord) -> String {
    guard let days = Self.daysSinceOpened(app) else { return "Unknown" }
    return days < 1 ? "Today" : RelativeAge.describe(days: days) + " ago"
  }

  private func relatedValue(_ app: AppRecord) -> String {
    if isInspecting(app) { return "…" }
    if model.appLeftovers.isEmpty { return "None" }
    let total = model.appLeftovers.reduce(Int64(0)) { $0 + $1.size }
    return ByteFormatter.string(total)
  }

  private var relatedHeader: some View {
    HStack(spacing: 8) {
      Text("Related files").font(.system(size: 13, weight: .bold)).foregroundStyle(AppTheme.ink)
      Spacer(minLength: 8)
      if !model.appLeftovers.isEmpty {
        Text("\(model.selectedLeftoverIDs.count) of \(model.appLeftovers.count) selected")
          .font(AppTheme.number(11.5, weight: .medium)).monospacedDigit().foregroundStyle(AppTheme.ink3)
          .lineLimit(1)
      }
      Menu("Select") {
        Button("Suggested matches") { model.selectedLeftoverIDs = Set(model.appLeftovers.filter(\.isSuggested).map(\.id)) }
        Button("Keep settings & app data") { model.selectedLeftoverIDs = Set(model.appLeftovers.filter { $0.isSuggested && $0.isDisposableData }.map(\.id)) }
        Button("App only") { model.selectedLeftoverIDs = [] }
      }.menuStyle(.borderlessButton).fixedSize().controlSize(.small).disabled(model.isScanning || model.isWorking)
    }
    .padding(.horizontal, 20).padding(.vertical, 8)
    .overlay(alignment: .top) { Rectangle().fill(AppTheme.divider).frame(height: 1) }
    .overlay(alignment: .bottom) { Rectangle().fill(AppTheme.divider).frame(height: 1) }
  }

  private func relatedFiles(_ app: AppRecord) -> some View {
    LazyVStack(alignment: .leading, spacing: 0) {
      VStack(alignment: .leading, spacing: 4) {
        Text("Exact bundle-ID matches are selected. Shared data and uncertain matches stay yours to review.")
          .font(.system(size: 11.5)).foregroundStyle(AppTheme.ink2).fixedSize(horizontal: false, vertical: true)
        Text("App data can contain projects and local documents. System helpers, Keychain entries and data outside your Library are not automatically removed.")
          .font(.system(size: 11.5)).foregroundStyle(AppTheme.ink2).fixedSize(horizontal: false, vertical: true)
      }
      .padding(.horizontal, 20).padding(.vertical, 12)

      if isInspecting(app) {
        HStack(spacing: 10) {
          ProgressView().controlSize(.small)
          Text("Inspecting Library data…").font(.system(size: 13)).foregroundStyle(AppTheme.ink2)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
      } else if model.appLeftovers.isEmpty {
        HStack(spacing: 12) {
          Image(systemName: "checkmark.seal.fill").font(.system(size: 18, weight: .semibold))
            .foregroundStyle(AppTheme.accentText).accessibilityHidden(true)
          VStack(alignment: .leading, spacing: 2) {
            Text("No related files found").font(.system(size: 13, weight: .semibold)).foregroundStyle(AppTheme.ink)
            Text("No matching user-level leftovers were detected for this app.")
              .font(.system(size: 12)).foregroundStyle(AppTheme.ink2).fixedSize(horizontal: false, vertical: true)
          }
          Spacer(minLength: 0)
        }
        .padding(.horizontal, 20).padding(.vertical, 14)
        .overlay(alignment: .top) { Rectangle().fill(AppTheme.divider).frame(height: 1) }
      } else {
        ForEach(model.appLeftovers) { leftover in
          leftoverRow(leftover)
            .overlay(alignment: .top) { Rectangle().fill(AppTheme.divider).frame(height: 1) }
        }
      }
    }
  }

  private static func symbol(_ category: AppDataCategory) -> String {
    switch category {
    case .caches: return "archivebox.fill"
    case .logs: return "doc.text.fill"
    case .settings: return "gearshape.fill"
    case .state: return "macwindow"
    case .support: return "folder.fill"
    case .shared: return "person.2.fill"
    case .background: return "bolt.horizontal.circle.fill"
    }
  }

  private func leftoverRow(_ leftover: AppLeftover) -> some View {
    HStack(alignment: .top, spacing: 11) {
      Toggle(
        "",
        isOn: Binding(
          get: { model.selectedLeftoverIDs.contains(leftover.id) },
          set: { value in
            if value {
              model.selectedLeftoverIDs.insert(leftover.id)
            } else {
              model.selectedLeftoverIDs.remove(leftover.id)
            }
          }
        )
      )
      .toggleStyle(MintCheckboxStyle())
      .labelsHidden()
      .fixedSize()
      .padding(.top, 1)
      .accessibilityLabel("Remove \(leftover.url.lastPathComponent) with the app")

      Image(systemName: Self.symbol(leftover.category))
        .font(.system(size: 13, weight: .medium)).foregroundStyle(AppTheme.ink3)
        .frame(width: 18).padding(.top, 1)
        .accessibilityHidden(true)

      VStack(alignment: .leading, spacing: 4) {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
          Text(leftover.url.lastPathComponent).font(.system(size: 13, weight: .semibold)).foregroundStyle(AppTheme.ink)
            .lineLimit(2).truncationMode(.middle).layoutPriority(1)
          Spacer(minLength: 0)
          Text(ByteFormatter.string(leftover.size))
            .font(AppTheme.number(12.5, weight: .semibold)).monospacedDigit().foregroundStyle(AppTheme.ink).fixedSize()
          Menu {
            Button("Reveal in Finder") { model.reveal(leftover.url) }
            Button("Exclude from future scans") { model.ignore(leftover.url) }
          } label: {
            Image(systemName: "ellipsis.circle")
              .accessibilityLabel("More actions for " + leftover.url.lastPathComponent)
          }
          .menuStyle(.borderlessButton).fixedSize()
        }
        Text(leftover.url.path).font(.system(size: 11.5, design: .monospaced)).foregroundStyle(AppTheme.ink3)
          .lineLimit(1).truncationMode(.middle).help(leftover.url.path)
        Text(leftover.category.rawValue + " · " + leftover.category.consequence)
          .font(.system(size: 11.5)).foregroundStyle(AppTheme.ink2).fixedSize(horizontal: false, vertical: true)
        Text(leftover.reason).font(.system(size: 11.5)).foregroundStyle(AppTheme.ink2)
          .fixedSize(horizontal: false, vertical: true)
        HStack(spacing: 6) {
          matchChip(leftover.confidence)
          if leftover.isShared {
            Chip(title: "Shared", symbol: "person.2.fill", swatch: .violet)
          }
        }
        .padding(.top, 2)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .padding(.horizontal, 20).padding(.vertical, 10)
  }

  private func matchChip(_ confidence: MatchConfidence) -> Chip {
    confidence == .high
      ? Chip(title: "High match", symbol: "checkmark.shield.fill", swatch: .mint)
      : Chip(title: confidence.rawValue.capitalized + " match", symbol: "eye.fill", swatch: .amber)
  }

  private func footer(_ app: AppRecord) -> some View {
    HStack(spacing: 12) {
      VStack(alignment: .leading, spacing: 2) {
        Text("Selected for uninstall").font(.system(size: 11.5)).foregroundStyle(AppTheme.ink2)
        Text(ByteFormatter.string(app.bundleSize + selectedLeftoverBytes))
          .font(AppTheme.number(17)).monospacedDigit().foregroundStyle(AppTheme.ink)
        Text("App + \(model.selectedLeftoverIDs.count) related items · moved to Trash")
          .font(.system(size: 11)).foregroundStyle(AppTheme.ink2).lineLimit(2)
      }
      Spacer(minLength: 8)
      if model.selectedAppIsRunning {
        Button {
          model.requestQuitSelectedApp()
        } label: {
          Label("Quit App First", systemImage: "power")
        }
        .buttonStyle(MintButtonStyle(.commit))
        .disabled(model.isWorking || model.isScanning)
      } else {
        Button {
          model.reviewUninstall()
        } label: {
          Label("Review Uninstall…", systemImage: "trash")
        }
        .buttonStyle(MintButtonStyle(.commit))
        .disabled(model.isWorking || model.isScanning)
      }
    }
    .padding(.horizontal, 20).padding(.vertical, 12)
    .background(AppTheme.panel)
    .overlay(alignment: .top) { Rectangle().fill(AppTheme.divider).frame(height: 1) }
    .background(GeometryReader { geometry in Color.clear.preference(key: WorkspaceLayoutFrames.self, value: ["app review": geometry.frame(in: .global)]) })
  }
}

/// A list row you pick: the area's tint and a 1 pt area ring when selected, panel on hover.
private struct SelectableRowStyle: ButtonStyle {
  let selected: Bool
  func makeBody(configuration: Configuration) -> some View {
    SelectableRowFace(content: configuration.label, selected: selected, pressed: configuration.isPressed)
  }
}

private struct SelectableRowFace<Content: View>: View {
  let content: Content
  let selected: Bool
  let pressed: Bool
  @State private var hovering = false
  @Environment(\.areaSwatch) private var swatch

  private var fill: Color {
    if selected { return swatch.tint }
    return hovering || pressed ? AppTheme.panel : Color.clear
  }

  var body: some View {
    let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
    content
      .background(fill, in: shape)
      .overlay {
        if selected { shape.strokeBorder(swatch.color, lineWidth: 1) }
      }
      .contentShape(shape)
      .onHover { hovering = $0 }
  }
}
