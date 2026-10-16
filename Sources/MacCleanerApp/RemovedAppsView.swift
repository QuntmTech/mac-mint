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
      HStack(spacing: 12) {
        VStack(alignment: .leading, spacing: 4) {
          Text("Removed Apps").font(.system(size: 30, weight: .bold, design: .rounded))
          Text("Settings, caches, and containers left behind by apps that are no longer installed.")
            .foregroundStyle(.secondary)
        }
        Spacer()
        if !model.selectedOrphanIDs.isEmpty {
          Button("Deselect") { model.selectedOrphanIDs = [] }
          Button {
            model.reviewOrphans()
          } label: {
            Label("Review \(ByteFormatter.string(selectedBytes))", systemImage: "trash")
          }
          .buttonStyle(.borderedProminent)
          .disabled(model.isWorking || model.isScanning)
        }
        Button(model.orphansScanned ? "Rescan" : "Scan") { model.scanOrphans() }
          .buttonStyle(.borderedProminent)
          .disabled(model.isScanning || model.isWorking)
      }
      .padding(AppTheme.pagePadding)
      Divider()

      if model.isScanning && model.operationTitle == "Removed Apps" {
        VStack(spacing: 12) {
          ProgressView().controlSize(.large)
          Text("Comparing your Library with installed apps…").foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else if model.orphans.isEmpty {
        EmptyState(
          icon: model.orphansScanned ? "checkmark.seal" : "folder.badge.questionmark",
          title: model.orphansScanned ? "No leftovers found" : "Find leftovers from apps you've deleted",
          detail:
            "Only data whose app identifier no installed app claims is listed. macOS's own data is never included.")
      } else {
        List {
          ForEach(grouped, id: \.0) { bundleID, items in
            Section {
              ForEach(items) { row($0) }
            } header: {
              HStack {
                Text(bundleID).textSelection(.enabled)
                Spacer()
                Button("Select All") {
                  model.selectedOrphanIDs.formUnion(items.map(\.id))
                }
                .buttonStyle(.link)
        .tint(AppTheme.accentText)
                Text(ByteFormatter.string(items.reduce(0) { $0 + $1.bytes })).monospacedDigit()
              }
            }
          }
        }
        .listStyle(.inset)
      }
    }
  }

  private func row(_ item: OrphanedItem) -> some View {
    HStack(spacing: 11) {
      Toggle(
        "",
        isOn: Binding(
          get: { model.selectedOrphanIDs.contains(item.id) },
          set: { isOn in
            if isOn { model.selectedOrphanIDs.insert(item.id) } else { model.selectedOrphanIDs.remove(item.id) }
          })
      )
      .labelsHidden()
      .accessibilityLabel("Select \(item.url.lastPathComponent)")
      VStack(alignment: .leading, spacing: 3) {
        HStack(spacing: 6) {
          Text(item.location).fontWeight(.medium)
          StatusPill(
            title: item.confidence == .medium ? "Likely unused" : "Check first",
            icon: item.confidence == .medium ? "checkmark.shield" : "eye",
            tint: item.confidence == .medium ? .green : .orange)
        }
        Text(item.reason).font(.caption).foregroundStyle(.secondary).lineLimit(2)
        Text(item.url.path).font(.caption2).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.middle)
        if let modified = item.modified {
          Text("Last changed \(modified.formatted(.relative(presentation: .named)))")
            .font(.caption2).foregroundStyle(.tertiary)
        }
      }
      Spacer()
      Text(ByteFormatter.string(item.bytes)).font(.callout.monospacedDigit()).frame(width: 86, alignment: .trailing)
      Menu {
        Button("Reveal in Finder") { model.reveal(item.url) }
        Button("Exclude from Future Scans") { model.ignore(item.url) }
      } label: {
        Image(systemName: "ellipsis.circle")
          .accessibilityLabel("More actions")
      }
      .menuStyle(.borderlessButton)
      .frame(width: 28)
    }
    .padding(.vertical, 4)
  }
}
