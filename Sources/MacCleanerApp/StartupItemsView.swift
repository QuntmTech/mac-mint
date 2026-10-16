import MacCleanerCore
import SwiftUI

struct StartupItemsView: View {
  @EnvironmentObject private var model: AppViewModel
  @State private var search = ""

  private var filtered: [StartupItem] {
    search.isEmpty
      ? model.startupItems
      : model.startupItems.filter {
        $0.label.localizedCaseInsensitiveContains(search)
          || ($0.program?.localizedCaseInsensitiveContains(search) ?? false)
          || $0.scope.localizedCaseInsensitiveContains(search)
      }
  }

  var body: some View {
    VStack(spacing: 0) {
      HStack {
        VStack(alignment: .leading, spacing: 4) {
          Text("Startup Items").font(.system(size: 30, weight: .bold, design: .rounded))
          Text(
            "A read-only inventory of launch agents and daemons. System changes remain outside the base app's trust boundary."
          )
          .foregroundStyle(.secondary)
        }
        Spacer()
        StatusPill(
          title: "\(model.startupItems.count) items", icon: "bolt.horizontal.circle",
          tint: AppTheme.accentText)
        Button("Open System Settings") { model.openSystemSettings() }
        Button("Refresh") { model.runSmartScan() }
          .disabled(model.isScanning || model.isWorking)
      }
      .padding(AppTheme.pagePadding)

      Divider()

      HStack {
        TextField("Search startup items", text: $search)
          .textFieldStyle(.roundedBorder)
          .frame(maxWidth: 340)
        Spacer()
        Text("Read-only")
          .font(.caption.weight(.semibold))
          .foregroundStyle(.secondary)
      }
      .padding(.horizontal, AppTheme.pagePadding)
      .padding(.vertical, 12)
      .background(.bar)

      Divider()

      if filtered.isEmpty {
        EmptyState(
          icon: "bolt.horizontal.circle", title: "No startup items found",
          detail: "Launch agents and daemons detected by the base app appear here.")
      } else {
        List(filtered) { item in
          HStack(spacing: 12) {
            ZStack {
              RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill((item.disabled ? Color.secondary : AppTheme.accent).opacity(0.10))
                .frame(width: 36, height: 36)
              Image(systemName: item.disabled ? "pause.fill" : "bolt.fill")
                .foregroundStyle(item.disabled ? .secondary : AppTheme.accentText)
            }
            VStack(alignment: .leading, spacing: 3) {
              Text(item.label).fontWeight(.medium)
              Text(item.program ?? item.url.path)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
            Spacer()
            if item.disabled { StatusPill(title: "Disabled", icon: "pause.circle") }
            if item.runAtLoad {
              StatusPill(title: "Run at load", icon: "arrow.clockwise", tint: .orange)
            }
            if item.keepAlive { StatusPill(title: "Keep alive", icon: "heart.fill", tint: .red) }
            Text(item.scope)
              .font(.caption)
              .foregroundStyle(.secondary)
              .frame(width: 135, alignment: .trailing)
            Button {
              model.reveal(item.url)
            } label: {
              Image(systemName: "folder")
                .accessibilityLabel("Reveal in Finder")
            }
            .buttonStyle(.plain)
            .help("Reveal property list in Finder")
          }
          .padding(.vertical, 5)
        }
        .listStyle(.inset)
      }
    }
  }
}
