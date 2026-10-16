import MacCleanerCore
import SwiftUI

struct StartupItemsView: View {
  @EnvironmentObject private var model: AppViewModel
  @EnvironmentObject private var account: AccountStore
  @SceneStorage("startup.search") private var search = ""

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
      PageHeader(title: "Startup Items", subtitle: "Inspect declared launch settings. Open Login Items to manage what starts with your Mac.") {
        HStack(spacing: 8) {
        StatusPill(
          title: "\(model.startupItems.count) items", icon: "bolt.horizontal.circle",
          tint: AppTheme.accentText)
        Button("Open System Settings") { model.openLoginItemsSettings() }
        Button("Refresh") { model.runSmartScan() }
          .disabled(model.isScanning || model.isWorking)
      }
      }
      .padding(AppTheme.pagePadding)

      Divider()

      HStack {
        SearchField(prompt: "Search startup items", text: $search)
          .frame(maxWidth: 340)
        Spacer()
        Text("Read-only")
          .font(.caption.weight(.semibold))
          .foregroundStyle(.secondary)
      }
      .padding(.horizontal, AppTheme.pagePadding)
      .padding(.vertical, 12)
      .background(AppTheme.surface)

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
              Text(possibleOwner(item.label)).font(.caption2).foregroundStyle(.secondary)
              Text(item.program ?? item.url.path)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
            Spacer()
            if item.disabled { StatusPill(title: "Declared disabled", icon: "pause.circle") }
            if item.runAtLoad {
              StatusPill(title: "Requests run at load", icon: "arrow.clockwise", tint: AppTheme.warning)
            }
            if item.keepAlive { StatusPill(title: "Requests keep alive", icon: "heart.fill", tint: .red) }
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
            if account.aiStatus.allows("explain") {
              Button {
                model.explain(model.aiTarget(for: item))
              } label: {
                Image(systemName: "sparkles")
                  .accessibilityLabel("Explain with AI")
              }
              .buttonStyle(.plain)
              .help("Explain with AI")
            }
          }
          .padding(.vertical, 5)
        }
        .listStyle(.inset)
      }
    }
  }
  private func possibleOwner(_ label: String) -> String {
    let matches = model.apps.filter { app in
      guard let id = app.bundleIdentifier else { return false }
      return label == id || label.hasPrefix(id + ".")
    }
    return matches.first.map { "Possible owner: " + $0.name } ?? "Owner not identified"
  }

}
