import MacCleanerCore
import SwiftUI

struct CleanerView: View {
  @EnvironmentObject private var model: AppViewModel
  @State private var confirmClean = false
  @State private var search = ""
  @State private var riskFilter: RiskFilter = .all

  enum RiskFilter: String, CaseIterable, Identifiable {
    case all = "All"
    case safe = "Safe"
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
          title: search.isEmpty ? "Nothing reclaimable found" : "No matching cleanup items",
          detail: search.isEmpty
            ? "Run a scan again after using apps for a while." : "Try a different search or filter."
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
    .alert("Move selected items to Trash?", isPresented: $confirmClean) {
      Button("Cancel", role: .cancel) {}
      Button("Move to Trash") { model.cleanSelected() }
    } message: {
      Text(
        "\(ByteFormatter.string(model.selectedCleanupBytes)) is selected. Review-risk items account for \(ByteFormatter.string(model.selectedReviewBytes)). Everything is moved to Trash, not permanently erased."
      )
    }
  }

  private var header: some View {
    HStack(alignment: .center, spacing: 14) {
      VStack(alignment: .leading, spacing: 4) {
        Text("Cleaner")
          .font(.system(size: 30, weight: .bold, design: .rounded))
        Text(
          "Safe cleanup is preselected. Anything with possible long-term value requires an explicit opt-in."
        )
        .foregroundStyle(.secondary)
      }
      Spacer()
      if model.isScanning {
        Button("Cancel") { model.cancelCurrentOperation() }
      } else {
        Button("Rescan") { model.runSmartScan() }
      }
      Button {
        confirmClean = true
      } label: {
        Label("Clean \(ByteFormatter.string(model.selectedCleanupBytes))", systemImage: "trash")
      }
      .buttonStyle(.borderedProminent)
      .disabled(model.selectedCleanupBytes == 0 || model.isWorking || model.isScanning)
    }
    .padding(AppTheme.pagePadding)
  }

  private var filterBar: some View {
    HStack(spacing: 10) {
      TextField("Search cleanup items", text: $search)
        .textFieldStyle(.roundedBorder)
        .frame(maxWidth: 320)

      Picker("Risk", selection: $riskFilter) {
        ForEach(RiskFilter.allCases) { filter in
          Text(filter.rawValue).tag(filter)
        }
      }
      .pickerStyle(.segmented)
      .frame(width: 220)

      Spacer()

      Button("Safe only") { model.selectSafeCleanupOnly() }
      Button("Deselect all") { model.deselectAllCleanup() }

      StatusPill(
        title: "\(model.cleanupTargets.filter(\.isSelected).count) selected",
        icon: "checkmark.circle",
        tint: model.selectedCleanupBytes > 0 ? AppTheme.accent : .gray
      )
    }
    .padding(.horizontal, AppTheme.pagePadding)
    .padding(.vertical, 12)
    .background(.bar)
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
      .disabled(item.risk == .restricted)

      ZStack {
        RoundedRectangle(cornerRadius: 9, style: .continuous)
          .fill(AppTheme.accent.opacity(0.08))
          .frame(width: 34, height: 34)
        Image(systemName: icon(for: item.category))
          .foregroundStyle(AppTheme.accent)
      }

      VStack(alignment: .leading, spacing: 3) {
        HStack(spacing: 7) {
          Text(item.displayName).fontWeight(.medium)
          RiskBadge(risk: item.risk)
        }
        Text(item.reason)
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(1)
        Text(item.url.path)
          .font(.caption2)
          .foregroundStyle(.tertiary)
          .lineLimit(1)
      }

      Spacer()

      Text(ByteFormatter.string(item.size))
        .font(.callout.monospacedDigit())
        .frame(width: 92, alignment: .trailing)

      Menu {
        Button("Reveal in Finder") { model.reveal(item.url) }
        Button("Exclude from future scans") { model.ignore(item.url) }
      } label: {
        Image(systemName: "ellipsis.circle")
      }
      .menuStyle(.borderlessButton)
      .frame(width: 28)
    }
    .padding(.vertical, 5)
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
    }
  }
}
