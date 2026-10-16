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
  }

  private var entries: [Entry] {
    var list: [Entry] = []
    list.append(Entry(id: "action:care", title: "Run Quick Scan", subtitle: "Action", icon: "sparkles") {
      $0.selectedSection = .dashboard
      $0.runSmartCare()
    })
    list.append(Entry(id: "action:scan", title: "Run Quick Scan (caches only)", subtitle: "Action", icon: "sparkle") {
      $0.selectedSection = .dashboard
      $0.runSmartScan()
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

  private var results: [Entry] {
    let tokens = query.lowercased().split(separator: " ").map(String.init)
    let all = entries
    guard !tokens.isEmpty else { return Array(all.prefix(12)) }
    return Array(
      all.filter { entry in
        let haystack = (entry.title + " " + entry.subtitle).lowercased()
        return tokens.allSatisfy { haystack.contains($0) }
      }
      .prefix(40))
  }

  var body: some View {
    let current = results
    VStack(spacing: 0) {
      HStack(spacing: 10) {
        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
        TextField("Go to a screen, run an action, or find an item…", text: $query)
          .textFieldStyle(.plain)
          .font(.title3)
          .focused($focused)
          .onSubmit { run(current) }
          .accessibilityLabel("Command palette search")
      }
      .padding(16)
      Divider()
      ScrollViewReader { proxy in
        List(Array(current.enumerated()), id: \.element.id) { index, entry in
          HStack(spacing: 10) {
            Image(systemName: entry.icon).frame(width: 20).foregroundStyle(AppTheme.accentText)
            Text(entry.title).lineLimit(1)
            Spacer()
            Text(entry.subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
          }
          .padding(.vertical, 3)
          .contentShape(Rectangle())
          .listRowBackground(index == highlighted ? AppTheme.selection : Color.clear)
          .onTapGesture {
            highlighted = index
            run(current)
          }
          .id(index)
        }
        .listStyle(.plain)
        .onChange(of: highlighted) { _, value in proxy.scrollTo(value) }
      }
      if current.isEmpty {
        Text("No matches").foregroundStyle(.secondary).padding()
      }
    }
    .frame(width: 600, height: 420)
    .scrollContentBackground(.hidden).background(AppTheme.surface)
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

  private func run(_ current: [Entry]) {
    guard current.indices.contains(highlighted) else { return }
    let entry = current[highlighted]
    dismiss()
    entry.perform(model)
  }
}
