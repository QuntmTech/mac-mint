import MacCleanerCore
import SwiftUI

struct HistoryView: View {
  @EnvironmentObject private var model: AppViewModel

  private var totalBytes: Int64 { model.history.reduce(0) { $0 + $1.bytes } }

  var body: some View {
    VStack(spacing: 0) {
      HStack {
        VStack(alignment: .leading, spacing: 4) {
          Text("History").font(.system(size: 30, weight: .bold, design: .rounded))
          Text("A local audit trail of cleanup actions performed by this app.")
            .foregroundStyle(.secondary)
        }
        Spacer()
        if !model.history.isEmpty {
          StatusPill(
            title: ByteFormatter.string(totalBytes) + " handled", icon: "clock.arrow.circlepath",
            tint: AppTheme.accent)
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
          HStack(alignment: .top, spacing: 12) {
            ZStack {
              Circle().fill(AppTheme.accent.opacity(0.10)).frame(width: 34, height: 34)
              Image(
                systemName: entry.action.localizedCaseInsensitiveContains("uninstall")
                  ? "app.badge" : "trash"
              )
              .foregroundStyle(AppTheme.accent)
            }
            VStack(alignment: .leading, spacing: 5) {
              HStack {
                Text(entry.action).fontWeight(.semibold)
                Text(entry.date.formatted(date: .abbreviated, time: .shortened))
                  .font(.caption)
                  .foregroundStyle(.secondary)
              }
              Text(entry.notes).font(.caption).foregroundStyle(.secondary)
              if let first = entry.paths.first {
                Text(first).font(.caption2).foregroundStyle(.tertiary).lineLimit(1).textSelection(
                  .enabled)
              }
              if entry.paths.count > 1 {
                Text("+ \(entry.paths.count - 1) more item\(entry.paths.count == 2 ? "" : "s")")
                  .font(.caption2)
                  .foregroundStyle(.tertiary)
              }
            }
            Spacer()
            Text(ByteFormatter.string(entry.bytes))
              .font(.callout.monospacedDigit())
              .frame(width: 100, alignment: .trailing)
          }
          .padding(.vertical, 6)
        }
        .listStyle(.inset)
      }
    }
  }
}
