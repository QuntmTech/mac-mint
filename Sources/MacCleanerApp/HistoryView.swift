import MacCleanerCore
import SwiftUI

struct HistoryView: View {
  @EnvironmentObject private var model: AppViewModel
  @State private var expanded: Set<UUID> = []

  private var totalBytes: Int64 { model.history.reduce(0) { $0 + $1.bytes } }

  var body: some View {
    VStack(spacing: 0) {
      HStack {
        VStack(alignment: .leading, spacing: 4) {
          Text("History").font(.system(size: 30, weight: .bold, design: .rounded))
          Text("Everything MacMint moved to the Trash — restore any item while it's still there.")
            .foregroundStyle(.secondary)
        }
        Spacer()
        if !model.history.isEmpty {
          StatusPill(
            title: ByteFormatter.string(totalBytes) + " handled", icon: "clock.arrow.circlepath",
            tint: AppTheme.accentText)
        }
      }
      .padding(AppTheme.pagePadding)
      Divider()

      if model.history.isEmpty {
        EmptyState(
          icon: "clock.arrow.circlepath", title: "No cleanup history",
          detail: "Trash and uninstall actions appear here after they complete.")
      } else {
        List(model.history) { entry in
          entryRow(entry)
        }
        .listStyle(.inset)
      }
    }
  }

  private func entryRow(_ entry: HistoryEntry) -> some View {
    let receipts = entry.receipts ?? []
    let pending = entry.pendingReceipts.filter { model.canRestore($0) }
    return DisclosureGroup(
      isExpanded: Binding(
        get: { expanded.contains(entry.id) },
        set: { isOpen in
          if isOpen { expanded.insert(entry.id) } else { expanded.remove(entry.id) }
        })
    ) {
      if receipts.isEmpty {
        Text(
          entry.receipts == nil
            ? "Recorded before MacMint tracked Trash locations. Use Finder to restore these items from the Trash."
            : entry.notes
        )
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.vertical, 4)
        ForEach(entry.paths, id: \.self) { path in
          Text(path).font(.caption2).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.middle)
        }
      } else {
        ForEach(receipts, id: \.originalPath) { receipt in
          receiptRow(receipt, entry: entry)
        }
      }
    } label: {
      HStack(alignment: .top, spacing: 12) {
        ZStack {
          Circle().fill(AppTheme.accent.opacity(0.10)).frame(width: 34, height: 34)
          Image(
            systemName: entry.action.localizedCaseInsensitiveContains("uninstall") ? "app.badge" : "trash"
          )
          .foregroundStyle(AppTheme.accentText)
        }
        VStack(alignment: .leading, spacing: 4) {
          HStack {
            Text(entry.action).fontWeight(.semibold)
            Text(entry.date.formatted(date: .abbreviated, time: .shortened))
              .font(.caption)
              .foregroundStyle(.secondary)
          }
          Text(entry.notes).font(.caption).foregroundStyle(.secondary).lineLimit(2)
          if let restored = entry.restoredPaths, !restored.isEmpty {
            Label("\(restored.count) restored", systemImage: "arrow.uturn.backward.circle.fill")
              .font(.caption2)
              .foregroundStyle(.green)
          }
        }
        Spacer()
        if pending.count > 1 {
          Button("Restore All") { model.restore(pending, entryID: entry.id) }
            .controlSize(.small)
        }
        Text(ByteFormatter.string(entry.bytes))
          .font(.callout.monospacedDigit())
          .frame(width: 92, alignment: .trailing)
      }
      .padding(.vertical, 4)
    }
  }

  private func receiptRow(_ receipt: TrashReceipt, entry: HistoryEntry) -> some View {
    let url = URL(fileURLWithPath: receipt.originalPath)
    let restored = entry.isRestored(receipt)
    let available = model.canRestore(receipt)
    return HStack(spacing: 10) {
      VStack(alignment: .leading, spacing: 2) {
        Text(url.lastPathComponent).font(.callout.weight(.medium)).lineLimit(1)
        Text(url.deletingLastPathComponent().path)
          .font(.caption2).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.middle)
      }
      Spacer()
      Text(ByteFormatter.string(receipt.bytes))
        .font(.caption.monospacedDigit())
        .foregroundStyle(.secondary)
      if restored {
        StatusPill(title: "Restored", icon: "checkmark", tint: .green)
      } else if available {
        Button("Restore") { model.restore([receipt], entryID: entry.id) }
          .controlSize(.small)
      } else {
        Menu {
          Button("Restore to Another Folder…") {
            model.restoreElsewhere(
              .init(entryID: entry.id, receipt: receipt, message: ""))
          }
          Button("Show in Trash") { model.revealInTrash(receipt) }
        } label: {
          Text(restoreUnavailableReason(receipt)).font(.caption)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
      }
    }
    .padding(.leading, 46)
    .padding(.vertical, 2)
  }

  private func restoreUnavailableReason(_ receipt: TrashReceipt) -> String {
    guard let trashPath = receipt.trashPath else { return "Not restorable" }
    if !FileManager.default.fileExists(atPath: trashPath) { return "Not in Trash" }
    return "Location in use"
  }
}
