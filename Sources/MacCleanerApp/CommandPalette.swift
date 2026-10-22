import MacCleanerCore
import SwiftUI

/// ⌘K: jump to any screen, run common actions, or find something from the current results.
struct CommandPalette: View {
  @EnvironmentObject private var model: AppViewModel
  @Environment(\.dismiss) private var dismiss
  @State private var query = ""
  @State private var highlighted = 0
  @FocusState private var focused: Bool

  struct Entry: Identifiable {
    let id: String
    let title: String
    let subtitle: String
    let icon: String
    let perform: @MainActor (AppViewModel) -> Void

    enum Kind: Int {
      case page, action, item

      var title: String {
        switch self {
        case .page: return "Pages"
        case .action: return "Actions"
        case .item: return "Items"
        }
      }
    }

    var kind: Kind {
      if id.hasPrefix("section:") { return .page }
      if id.hasPrefix("action:") { return .action }
      return .item
    }

    /// The page this entry opens, for "Go to" entries.
    var section: AppViewModel.Section? {
      guard id.hasPrefix("section:") else { return nil }
      return AppViewModel.Section(rawValue: String(id.dropFirst("section:".count)))
    }
  }

  private var entries: [Entry] {
    var list: [Entry] = []
    list.append(Entry(id: "action:care", title: "Run Quick Scan", subtitle: "Action", icon: "sparkles") {
      $0.selectedSection = .dashboard
      $0.runSmartCare()
    })
    list += model.recommendations.map { recommendation in
      Entry(
        id: "rec:\(recommendation.id)", title: recommendation.title,
        subtitle: "Recommendation • ≈ \(ByteFormatter.string(recommendation.bytes))",
        icon: recommendation.symbol
      ) { $0.review(recommendation) }
    }
    list += model.downloadItems.prefix(200).map { item in
      Entry(
        id: "download:\(item.id)", title: item.url.lastPathComponent,
        subtitle: "Downloads • \(ByteFormatter.string(item.bytes))", icon: "arrow.down.circle"
      ) { $0.selectedSection = .downloads }
    }
    list.append(Entry(id: "action:storage", title: "Map Storage", subtitle: "Action", icon: "chart.pie") {
      $0.selectedSection = .storage
      $0.scanStorage()
    })
    list.append(Entry(id: "action:tour", title: "Take the Quick Tour", subtitle: "Help", icon: "signpost.right") {
      $0.startTour()
    })
    list.append(Entry(id: "action:review", title: "Review Everything Selected", subtitle: "Action", icon: "checklist") {
      $0.selectedSection = .review
      $0.reviewEverything()
    })
    list += AppViewModel.Section.allCases.map { section in
      Entry(id: "section:\(section.rawValue)", title: section.rawValue, subtitle: "Go to", icon: section.icon) {
        $0.selectedSection = section
      }
    }
    list += model.cleanupTargets.prefix(300).map { target in
      Entry(
        id: "cleanup:\(target.id)", title: target.displayName,
        subtitle: "Cleaner • \(ByteFormatter.string(target.size))", icon: "trash.circle"
      ) { $0.selectedSection = .cleaner }
    }
    list += model.apps.map { app in
      Entry(id: "app:\(app.id)", title: app.name, subtitle: "Application", icon: "app") {
        $0.selectedSection = .applications
        $0.loadLeftovers(for: app)
      }
    }
    list += model.largeFiles.prefix(300).map { file in
      Entry(
        id: "large:\(file.id)", title: file.url.lastPathComponent,
        subtitle: "Large file • \(ByteFormatter.string(file.size))", icon: "doc"
      ) { $0.selectedSection = .largeFiles }
    }
    if let root = model.storageScan?.root {
      list += root.children.filter { $0.kind == .folder || $0.kind == .package }.prefix(100).map { node in
        Entry(
          id: "storage:\(node.id)", title: node.name,
          subtitle: "Storage • \(ByteFormatter.string(node.allocatedBytes))", icon: "folder"
        ) {
          $0.selectedSection = .storage
          $0.openStorageNode(node)
        }
      }
    }
    list += model.devItems.prefix(200).map { item in
      Entry(
        id: "dev:\(item.id)", title: "\(item.tool): \(item.title)",
        subtitle: "Developer & AI • \(ByteFormatter.string(item.bytes))", icon: "hammer"
      ) { $0.selectedSection = .developer }
    }
    list += model.duplicateGroups.prefix(200).compactMap { group in
      guard let first = group.files.first else { return nil }
      return Entry(
        id: "dup:\(group.id)", title: first.url.lastPathComponent,
        subtitle: "Duplicates • \(group.files.count) copies", icon: "square.on.square"
      ) { $0.selectedSection = .duplicates }
    }
    return list
  }

  /// The same matches as before, shown in groups: pages, then actions, then items.
  private var results: [Entry] {
    let tokens = query.lowercased().split(separator: " ").map(String.init)
    let all = entries
    guard !tokens.isEmpty else { return Self.grouped(Array(all.prefix(12))) }
    return Self.grouped(Array(
      all.filter { entry in
        let haystack = (entry.title + " " + entry.subtitle).lowercased()
        return tokens.allSatisfy { haystack.contains($0) }
      }
      .prefix(40)))
  }

  /// Orders entries by group and keeps their order inside each group.
  private static func grouped(_ entries: [Entry]) -> [Entry] {
    let indexed = Array(entries.enumerated())
    let ordered = indexed.sorted { lhs, rhs -> Bool in
      let left = lhs.element.kind.rawValue
      let right = rhs.element.kind.rawValue
      if left != right { return left < right }
      return lhs.offset < rhs.offset
    }
    return ordered.map { $0.element }
  }

  var body: some View {
    let current = results
    VStack(spacing: 0) {
      HStack(spacing: 12) {
        Image(systemName: "magnifyingglass")
          .font(.system(size: 17, weight: .medium))
          .foregroundStyle(AppTheme.ink3)
          .accessibilityHidden(true)
        TextField("Go to a screen, run an action, or find an item…", text: $query)
          .textFieldStyle(.plain)
          .font(.system(size: 18))
          .focused($focused)
          .onSubmit { run(current) }
          .accessibilityLabel("Command palette search")
        PaletteKeycap("esc")
      }
      .padding(.horizontal, 18)
      .frame(height: 58)
      Rectangle().fill(AppTheme.divider).frame(height: 1)
      if current.isEmpty {
        VStack(spacing: 8) {
          Image(systemName: "magnifyingglass")
            .font(.system(size: 22, weight: .semibold))
            .foregroundStyle(AppTheme.ink3)
            .accessibilityHidden(true)
          Text("No matches. Try a screen name, app, or file from your latest scan.")
            .font(.system(size: 13))
            .foregroundStyle(AppTheme.ink2)
            .multilineTextAlignment(.center)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else {
        ScrollViewReader { proxy in
          ScrollView {
            VStack(alignment: .leading, spacing: 0) {
              ForEach(Array(current.enumerated()), id: \.element.id) { index, entry in
                if index == 0 || current[index - 1].kind != entry.kind {
                  Eyebrow(entry.kind.title)
                    .padding(.horizontal, 10)
                    .padding(.top, index == 0 ? 4 : 12)
                    .padding(.bottom, 4)
                    .accessibilityAddTraits(.isHeader)
                }
                row(entry, index: index, current: current)
              }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
          }
          .onChange(of: highlighted) { _, value in proxy.scrollTo(value) }
        }
      }
      HStack(spacing: 14) {
        hint(["↑", "↓"], "Navigate")
        hint(["↵"], "Open")
        hint(["esc"], "Close")
        Spacer()
        Text(current.isEmpty ? "0 results" : "\(current.count) shown")
          .font(AppTheme.number(11.5, weight: .medium))
          .monospacedDigit()
          .foregroundStyle(AppTheme.ink2)
      }
      .padding(.horizontal, 16)
      .frame(height: 36)
      .background(AppTheme.panel)
      .overlay(alignment: .top) { Rectangle().fill(AppTheme.divider).frame(height: 1) }
    }
    .frame(width: 600, height: 440)
    .background(AppTheme.elevated)
    .onAppear { focused = true }
    .onChange(of: query) { _, _ in highlighted = 0 }
    .onKeyPress(.downArrow) {
      highlighted = min(highlighted + 1, max(0, current.count - 1))
      return .handled
    }
    .onKeyPress(.upArrow) {
      highlighted = max(highlighted - 1, 0)
      return .handled
    }
    .onExitCommand { dismiss() }
  }

  // MARK: Rows

  private func row(_ entry: Entry, index: Int, current: [Entry]) -> some View {
    let selected = index == highlighted
    let shape = RoundedRectangle(cornerRadius: 9, style: .continuous)
    return Button {
      highlighted = index
      run(current)
    } label: {
      HStack(spacing: 11) {
        SwatchBadge(symbol: entry.icon, swatch: swatch(for: entry), size: 26)
        VStack(alignment: .leading, spacing: 1) {
          Text(entry.title)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(AppTheme.ink)
            .lineLimit(1)
          Text(entry.subtitle)
            .font(.system(size: 11.5))
            .foregroundStyle(AppTheme.ink2)
            .lineLimit(1)
        }
        Spacer(minLength: 8)
        if let key = shortcut(for: entry) { PaletteKeycap(key) }
        if selected { PaletteKeycap("↵") }
      }
      .padding(.horizontal, 10)
      .frame(height: 44)
      .background(selected ? AppTheme.selection : Color.clear, in: shape)
      .contentShape(shape)
    }
    .buttonStyle(.plain)
    .accessibilityLabel(entry.title)
    .accessibilityValue(entry.subtitle)
    .accessibilityAddTraits(selected ? .isSelected : [])
    .help(entry.title + " · " + entry.subtitle)
    .id(index)
  }

  /// Pages use their own area color; actions and items use the color of where they lead.
  private func swatch(for entry: Entry) -> AppTheme.Swatch {
    if let section = entry.section { return section.swatch }
    let prefix = String(entry.id.prefix(while: { $0 != ":" }))
    switch prefix {
    case "action":
      if entry.id == "action:storage" { return AppViewModel.Section.storage.swatch }
      if entry.id == "action:tour" { return .iris }
      return .mint
    case "download": return AppViewModel.Section.downloads.swatch
    case "cleanup": return AppViewModel.Section.cleaner.swatch
    case "app": return AppViewModel.Section.applications.swatch
    case "large", "storage", "dup": return AppViewModel.Section.storage.swatch
    case "dev": return AppViewModel.Section.developer.swatch
    default: return .mint
    }
  }

  /// The menu shortcuts (View and Scan menus), shown as keycaps.
  private var pageShortcutOrder: [AppViewModel.Section] {
    [.dashboard, .cleaner, .storage, .applications, .photos, .developer, .history, .performance, .review]
  }

  private func shortcut(for entry: Entry) -> String? {
    if let section = entry.section {
      if section == .settings { return "⌘," }
      guard let index = pageShortcutOrder.firstIndex(of: section) else { return nil }
      return "⌘\(index + 1)"
    }
    switch entry.id {
    case "action:care": return "⌘R"
    case "action:storage": return "⇧⌘M"
    default: return nil
    }
  }

  private func hint(_ keys: [String], _ title: String) -> some View {
    HStack(spacing: 4) {
      ForEach(keys, id: \.self) { key in PaletteKeycap(key) }
      Text(title)
        .font(.system(size: 11.5))
        .foregroundStyle(AppTheme.ink2)
    }
    .accessibilityElement(children: .combine)
  }

  private func run(_ current: [Entry]) {
    guard current.indices.contains(highlighted) else { return }
    let entry = current[highlighted]
    dismiss()
    entry.perform(model)
  }
}

/// A small keycap: ⌘1, ↵, esc.
private struct PaletteKeycap: View {
  let text: String
  init(_ text: String) { self.text = text }

  var body: some View {
    Text(text)
      .font(.system(size: 10.5, weight: .semibold))
      .foregroundStyle(AppTheme.ink2)
      .padding(.horizontal, 5)
      .frame(minWidth: 18, minHeight: 18)
      .background(AppTheme.surface, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
      .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(AppTheme.border))
      .accessibilityHidden(true)
  }
}
