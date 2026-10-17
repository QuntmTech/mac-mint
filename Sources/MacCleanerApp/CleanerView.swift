import MacCleanerCore
import SwiftUI

struct CleanerView: View {
  @EnvironmentObject private var model: AppViewModel
  @SceneStorage("cleanup.search") private var search = ""
  @State private var riskFilter: RiskFilter = .all

  enum RiskFilter: String, CaseIterable, Identifiable {
    case all = "All"
    case safe = "Rebuildable"
    case review = "Review"
    var id: String { rawValue }
  }

  private var filteredTargets: [CleanupTarget] {
    model.cleanupTargets.filter { item in
      let matchesRisk: Bool = {
        switch riskFilter {
        case .all: return true
        case .safe: return item.risk == .safe
        case .review: return item.risk == .review
        }
      }()
      let matchesSearch =
        search.isEmpty
        || item.displayName.localizedCaseInsensitiveContains(search)
        || item.detail.localizedCaseInsensitiveContains(search)
        || item.url.path.localizedCaseInsensitiveContains(search)
      return matchesRisk && matchesSearch
    }
  }

  private var grouped: [(CleanupCategory, [CleanupTarget])] {
    CleanupCategory.allCases.compactMap { category in
      let items = filteredTargets.filter { $0.category == category }
      return items.isEmpty ? nil : (category, items)
    }
  }

  var body: some View {
    VStack(spacing: 0) {
      header
      Divider()
      filterBar
      Divider()

      if filteredTargets.isEmpty && !model.isScanning {
        EmptyState(
          icon: search.isEmpty ? "checkmark.seal" : "magnifyingglass",
          title: !search.isEmpty || riskFilter != .all ? "No matching cleanup items" : model.lastScanDate == nil ? "Start with a Quick Scan" : "Nothing found in this scan",
          detail: !search.isEmpty || riskFilter != .all ? "Try a different search or filter." : model.lastScanDate == nil ? "Find caches, logs, and generated data. Nothing moves until you review it." : "Check scan coverage for any locations that could not be inspected.",
          actionTitle: model.lastScanDate == nil ? "Run Quick Scan" : "Scan again",
          action: { model.runSmartScan() }
        )
      } else {
        List {
          ForEach(grouped, id: \.0) { category, items in
            Section {
              ForEach(items) { item in
                cleanupRow(item)
              }
            } header: {
              HStack {
                Text(category.rawValue)
                Spacer()
                Text(ByteFormatter.string(items.reduce(0) { $0 + $1.size }))
                  .font(.caption.monospacedDigit())
                  .foregroundStyle(.secondary)
              }
            }
          }
        }
        .listStyle(.inset)
      }
    }
  }

  private var header: some View {
    PageHeader(title: "Cleanup", subtitle: "Inspect caches and generated data. Keep anything you still need.") {
      HStack(spacing: 8) {
        Button(model.isScanning ? "Cancel" : "Rescan", systemImage: model.isScanning ? "xmark" : "arrow.clockwise") {
          if model.isScanning { model.cancelCurrentOperation() } else { model.runSmartScan() }
        }.buttonStyle(MintButtonStyle(prominent: false)).disabled(model.isWorking)
        Button { model.reviewCleanup() } label: {
          Label("Review \(ByteFormatter.string(model.selectedCleanupBytes))", systemImage: "checklist")
        }.buttonStyle(MintButtonStyle())
          .disabled(model.selectedCleanupBytes == 0 || model.isWorking || model.isScanning)
      }
    }.padding(AppTheme.pagePadding)
  }

  private var filterBar: some View {
    VStack(spacing: 12) {
      HStack(spacing: 14) {
        SearchField(prompt: "Search cleanup items", text: $search)
        Picker("Risk", selection: $riskFilter) {
          ForEach(RiskFilter.allCases) { filter in Text(filter.rawValue).tag(filter) }
        }.pickerStyle(.segmented).frame(width: 230)
      }
      HStack {
        Text("\(filteredTargets.count) items").font(.caption).foregroundStyle(.secondary)
        Spacer()
        Text("\(model.cleanupTargets.filter(\.isSelected).count) selected · \(ByteFormatter.string(model.selectedCleanupBytes))")
          .font(.caption.weight(.medium)).foregroundStyle(AppTheme.accentText)
        Menu("Select") {
          Button("Rebuildable items") { model.selectSafeCleanupOnly() }
          Button("Deselect all") { model.deselectAllCleanup() }
        }.fixedSize().menuStyle(.borderlessButton)
      }
    }.padding(.horizontal, AppTheme.pagePadding).padding(.vertical, 14)
  }

  private func cleanupRow(_ item: CleanupTarget) -> some View {
    HStack(spacing: 12) {
      Toggle(
        "",
        isOn: Binding(
          get: { model.cleanupTargets.first(where: { $0.id == item.id })?.isSelected ?? false },
          set: { model.toggleCleanup(item.id, selected: $0) }
        )
      )
      .labelsHidden()
      .accessibilityLabel("Clean \(item.displayName), \(ByteFormatter.string(item.size))")
      .disabled(item.risk == .restricted)

      let owner = OwnerResolver.hint(for: item.url, explicitBundleID: item.ownerBundleID)
      OwnerIcon(hint: owner, fallbackSymbol: icon(for: item.category))

      VStack(alignment: .leading, spacing: 3) {
        HStack(spacing: 7) {
          Text(item.displayName).fontWeight(.medium)
          RiskBadge(risk: item.risk)
        }
        Text(
          OwnerDirectory.owner(for: owner).map { "Used by \($0.name) — \(item.reason)" } ?? item.reason
        )
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(1)
        Text(item.url.path)
          .font(.caption2)
          .foregroundStyle(.secondary)
          .lineLimit(1).truncationMode(.middle)
      }

      Spacer()

      Text(ByteFormatter.string(item.size))
        .font(.callout.monospacedDigit())
        .frame(width: 92, alignment: .trailing)

      Menu {
        Button("Reveal in Finder") { model.reveal(item.url) }
        Button("Exclude from future scans") { model.ignore(item.url) }
        ExplainMenuItem(target: model.aiTarget(for: item))
      } label: {
        Image(systemName: "ellipsis.circle")
          .accessibilityLabel("More actions")
      }
      .menuStyle(.borderlessButton)
      .frame(width: 28)
    }
    .padding(.vertical, 10)
    .listRowBackground(item.isSelected ? AppTheme.selection.opacity(0.45) : AppTheme.surface)
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
}
