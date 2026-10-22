import MacCleanerCore
import SwiftUI

struct StartupItemsView: View {
  @EnvironmentObject private var model: AppViewModel
  @EnvironmentObject private var account: AccountStore
  @SceneStorage("startup.search") private var search = ""

  /// Items that need a look come first; the rest keep the scanner's alphabetical order.
  private var filtered: [StartupItem] {
    let matching = search.isEmpty
      ? model.startupItems
      : model.startupItems.filter {
        $0.label.localizedCaseInsensitiveContains(search)
          || ($0.program?.localizedCaseInsensitiveContains(search) ?? false)
          || ($0.targetPath?.localizedCaseInsensitiveContains(search) ?? false)
          || $0.scope.localizedCaseInsensitiveContains(search)
      }
    return matching.filter(\.needsAttention) + matching.filter { !$0.needsAttention }
  }

  private var attentionCount: Int { model.startupItems.filter(\.needsAttention).count }

  var body: some View {
    VStack(spacing: 0) {
      PageHeader(title: "Startup Items", subtitle: "See what each item asks for, whether its program still exists and what launchd says now. Open Login Items to manage what starts with your Mac.") {
        HStack(spacing: 8) {
        StatusPill(
          title: "\(model.startupItems.count) items", icon: "bolt.horizontal.circle",
          tint: AppTheme.accentText)
        if attentionCount > 0 {
          StatusPill(title: "\(attentionCount) need a look", icon: "exclamationmark.triangle", tint: AppTheme.warning)
            .help("Their program is missing, in the Trash or on a disk that isn't connected, or their last run ended with an error.")
        }
        Button("Open System Settings") { model.openLoginItemsSettings() }
        Button("Refresh") { model.scanStartupItems() }
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

      if model.startupItems.isEmpty && (model.isScanning || !model.startupScanned) {
        let own = model.operationTitle == "Startup Items" || model.operationTitle == "Quick Scan"
        if model.isScanning {
          LoadingState(title: own ? "Reading startup items…" : "Startup items are next",
            detail: own
              ? "Checking launch agents and daemons, whether each program still exists, and what launchd reports."
              : "\(model.operationTitle ?? "Another scan") is running. Startup items load as soon as it finishes.",
            symbol: "bolt.horizontal.circle", swatch: .violet)
        } else {
          EmptyState(icon: "bolt.horizontal.circle", title: "See what starts with your Mac",
            detail: "Lists launch agents and daemons, whether their programs still exist, and what launchd says about them. It only reads.",
            actionTitle: "Read Startup Items") { model.scanStartupItems() }
        }
      } else if filtered.isEmpty {
        EmptyState(
          icon: "bolt.horizontal.circle", title: search.isEmpty ? "No startup items found" : "No matching startup items",
          detail: search.isEmpty ? "No launch agents or daemons are installed for this Mac's users." : "Try a different search.")
      } else {
        List(filtered) { item in
          HStack(spacing: 12) {
            ZStack {
              RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill((item.isDisabled ? Color.secondary : AppTheme.accent).opacity(0.10))
                .frame(width: 36, height: 36)
              Image(systemName: item.isDisabled ? "pause.fill" : "bolt.fill")
                .foregroundStyle(item.isDisabled ? .secondary : AppTheme.accentText)
            }
            VStack(alignment: .leading, spacing: 3) {
              Text(item.label).fontWeight(.medium)
              Text(([possibleOwner(item.label)] + Self.requests(item)).joined(separator: " · "))
                .font(.caption2).foregroundStyle(.secondary)
              Text(item.targetPath ?? item.program ?? item.url.path)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            }
            Spacer()
            if let target = Self.targetPill(item) {
              StatusPill(title: target.title, icon: target.icon, tint: target.tint).help(target.help)
            }
            if item.isDisabled {
              StatusPill(title: "Turned off", icon: "pause.circle")
                .help(item.disabledOverride == true ? "Turned off with a launchd override (for example from Login Items)."
                  : "Its settings file marks it disabled.")
            } else {
              let state = Self.statePill(item)
              StatusPill(title: state.title, icon: state.icon, tint: state.tint).help(state.help)
            }
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
    .task(id: model.autoLoadKey) { model.autoLoadIfNeeded(.startup) }
  }
  private struct Pill {
    let title: String
    let icon: String
    var tint: Color = .secondary
    let help: String
  }

  private static func requests(_ item: StartupItem) -> [String] {
    (item.runAtLoad ? ["starts at login"] : []) + (item.keepAlive ? ["restarted if it quits"] : [])
  }

  /// Only problems with the declared program get a pill; a program that exists needs none.
  private static func targetPill(_ item: StartupItem) -> Pill? {
    switch item.target {
    case .missing:
      return Pill(title: "Program missing", icon: "questionmark.app.dashed", tint: AppTheme.danger,
        help: "Nothing exists at the program path, so this item can't run. The app may have been deleted or moved.")
    case .inTrash:
      return Pill(title: "Program in Trash", icon: "trash", tint: AppTheme.danger,
        help: "The program is in a Trash folder. It stops working when the Trash is emptied.")
    case .volumeNotMounted:
      return Pill(title: "Disk not connected", icon: "externaldrive.badge.xmark", tint: AppTheme.warning,
        help: "The program is on a disk that isn't connected, often an installer disk image that was ejected.")
    case .otherVolume:
      return Pill(title: "On another disk", icon: "externaldrive",
        help: "The program is on another disk and runs only while that disk is connected.")
    case .present, .unresolved, nil:
      return nil
    }
  }

  private static func statePill(_ item: StartupItem) -> Pill {
    guard let live = item.live else {
      return Pill(title: "State unknown", icon: "questionmark.circle",
        help: item.scope.contains("Daemon") ? "macOS shows system daemons' live state only to administrators."
          : "launchd's state couldn't be read.")
    }
    switch live.kind {
    case .running:
      return Pill(title: "Running", icon: "play.circle", tint: AppTheme.accentText,
        help: live.pid.map { "Running now as process \($0)." } ?? "Running now.")
    case .waiting:
      return Pill(title: "Waiting to run", icon: "clock",
        help: "Loaded. launchd starts it when it is needed; an idle helper is normal.")
    case .failed:
      return Pill(title: "Last run failed", icon: "exclamationmark.triangle", tint: AppTheme.warning,
        help: "Its last run ended with error code \(live.lastExitStatus ?? 0).")
    case .notLoaded:
      return Pill(title: "Not loaded", icon: "moon.zzz",
        help: "Not loaded in this session, so it isn't running now. It may load at the next login or only for other sessions.")
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
