import MacCleanerCore
import SwiftUI

/// Read-only: shows what starts with the Mac and what launchd says about it. Changes happen in
/// System Settings › General › Login Items.
struct StartupItemsView: View {
  @EnvironmentObject private var model: AppViewModel
  @EnvironmentObject private var account: AccountStore
  @Environment(\.areaSwatch) private var swatch
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

  private struct ItemGroup: Identifiable {
    let id: String
    let title: String
    let detail: String
    let items: [StartupItem]
  }

  /// Agents load when someone logs in; daemons load when the Mac starts. Order inside each
  /// group follows `filtered`, so items that need a look stay on top.
  private var groups: [ItemGroup] {
    let items = filtered
    let agents = items.filter { !$0.scope.contains("Daemon") }
    let daemons = items.filter { $0.scope.contains("Daemon") }
    var result: [ItemGroup] = []
    if !agents.isEmpty {
      result.append(ItemGroup(id: "agents", title: "Background agents", detail: "Load when you log in", items: agents))
    }
    if !daemons.isEmpty {
      result.append(ItemGroup(id: "daemons", title: "Background daemons", detail: "Load when your Mac starts, for all users", items: daemons))
    }
    return result
  }

  var body: some View {
    VStack(spacing: 0) {
      VStack(alignment: .leading, spacing: 14) {
        PageHeader(title: "Startup Items", subtitle: "What starts with your Mac, whether its program still exists, and what launchd says about it now.") {
          HStack(spacing: 8) {
            Chip(title: "\(model.startupItems.count) items", symbol: "bolt.horizontal.circle.fill", swatch: .violet)
            if attentionCount > 0 {
              Chip(title: "\(attentionCount) need a look", symbol: "exclamationmark.triangle.fill", swatch: .amber)
                .help("Their program is missing, in the Trash or on a disk that isn't connected, or their last run ended with an error.")
            }
            Button { model.openLoginItemsSettings() } label: {
              Label("Login Items Settings", systemImage: "arrow.up.forward.app")
            }
            .buttonStyle(MintButtonStyle(.secondary))
            Button { model.scanStartupItems() } label: {
              Label("Refresh", systemImage: "arrow.clockwise")
            }
            .buttonStyle(MintButtonStyle(.area))
            .disabled(model.isScanning || model.isWorking)
          }
        }
        readOnlyBanner
        SearchField(prompt: "Search startup items", text: $search)
          .frame(maxWidth: 340)
      }
      .frame(maxWidth: 1180)
      .padding(.horizontal, AppTheme.pagePadding)
      .padding(.top, AppTheme.pageTopPadding)
      .padding(.bottom, 14)
      .frame(maxWidth: .infinity)

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
        ScrollView {
          LazyVStack(alignment: .leading, spacing: 14) {
            ForEach(groups) { group in
              groupCard(group)
            }
          }
          .frame(maxWidth: 1180)
          .padding(.horizontal, AppTheme.pagePadding)
          .padding(.top, 2)
          .padding(.bottom, 24)
          .frame(maxWidth: .infinity)
        }
      }
    }
    .task(id: model.autoLoadKey) { model.autoLoadIfNeeded(.startup) }
  }

  /// Says plainly that this page only reads, and where changes are made instead.
  private var readOnlyBanner: some View {
    HStack(spacing: 10) {
      Image(systemName: "lock.fill")
        .font(.system(size: 13, weight: .semibold))
        .foregroundStyle(AppTheme.Swatch.slate.text)
        .frame(width: 28, height: 28)
        .background(AppTheme.Swatch.slate.tint, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 1) {
        Text("Read-only").font(.system(size: 12.5, weight: .semibold)).foregroundStyle(AppTheme.ink)
        Text("MacMint shows what's here and what it's doing. To turn something off, use System Settings › General › Login Items.")
          .font(.system(size: 12.5)).foregroundStyle(AppTheme.ink2)
          .fixedSize(horizontal: false, vertical: true)
      }
      .accessibilityElement(children: .combine)
      Spacer(minLength: 0)
    }
    .padding(.horizontal, 14).padding(.vertical, 11)
    .cardBackground(radius: 14)
  }

  private func groupCard(_ group: ItemGroup) -> some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack(alignment: .firstTextBaseline, spacing: 8) {
        Text(group.title).font(.system(size: 14, weight: .bold)).tracking(-0.2).foregroundStyle(AppTheme.ink)
          .accessibilityAddTraits(.isHeader)
        Text("\(group.items.count)").font(AppTheme.number(12, weight: .semibold)).monospacedDigit()
          .foregroundStyle(AppTheme.ink3)
        Text(group.detail).font(.system(size: 11.5)).foregroundStyle(AppTheme.ink3).lineLimit(1)
        Spacer(minLength: 0)
      }
      .padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 10)
      ForEach(group.items) { item in
        Rectangle().fill(AppTheme.divider).frame(height: 1)
        row(item)
      }
    }
    .cardBackground()
  }

  private func row(_ item: StartupItem) -> some View {
    HStack(spacing: 11) {
      Image(systemName: item.isDisabled ? "pause.fill" : "bolt.fill")
        .font(.system(size: 13, weight: .semibold))
        .foregroundStyle(item.isDisabled ? AppTheme.ink2 : swatch.text)
        .frame(width: 30, height: 30)
        .background(item.isDisabled ? AppTheme.panel : swatch.tint, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 2) {
        Text(item.label).font(.system(size: 13, weight: .semibold)).foregroundStyle(AppTheme.ink)
          .lineLimit(1).truncationMode(.middle)
        Text(([item.scope, possibleOwner(item.label)] + Self.requests(item)).joined(separator: " · "))
          .font(.system(size: 11.5)).foregroundStyle(AppTheme.ink2).lineLimit(2)
          .fixedSize(horizontal: false, vertical: true)
        Text(item.targetPath ?? item.program ?? item.url.path)
          .font(.system(size: 11, design: .monospaced))
          .foregroundStyle(AppTheme.ink3)
          .lineLimit(1)
          .truncationMode(.middle)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      if let target = Self.targetPill(item) {
        Chip(title: target.title, symbol: target.icon, swatch: target.swatch).help(target.help)
      }
      if item.isDisabled {
        Chip(title: "Turned off", symbol: "pause.circle.fill", swatch: .slate)
          .help(item.disabledOverride == true ? "Turned off with a launchd override (for example from Login Items)."
            : "Its settings file marks it disabled.")
      } else {
        let state = Self.statePill(item)
        Chip(title: state.title, symbol: state.icon, swatch: state.swatch).help(state.help)
      }
      Button {
        model.reveal(item.url)
      } label: {
        Image(systemName: "folder")
          .font(.system(size: 13))
          .foregroundStyle(AppTheme.ink3)
          .frame(width: 24, height: 24)
          .contentShape(Rectangle())
          .accessibilityLabel("Reveal in Finder")
      }
      .buttonStyle(.plain)
      .help("Reveal property list in Finder")
      if account.aiStatus.allows("explain") {
        Button {
          model.explain(model.aiTarget(for: item))
        } label: {
          Image(systemName: "sparkles")
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(AppTheme.Swatch.iris.text)
            .frame(width: 24, height: 24)
            .contentShape(Rectangle())
            .accessibilityLabel("Explain with AI")
        }
        .buttonStyle(.plain)
        .help("Explain with AI")
      }
    }
    .padding(.horizontal, 16).padding(.vertical, 10)
    .frame(minHeight: 50)
  }

  private struct Pill {
    let title: String
    let icon: String
    var swatch: AppTheme.Swatch = .graphite
    let help: String
  }

  private static func requests(_ item: StartupItem) -> [String] {
    (item.runAtLoad ? ["starts at login"] : []) + (item.keepAlive ? ["restarted if it quits"] : [])
  }

  /// Only problems with the declared program get a pill; a program that exists needs none.
  private static func targetPill(_ item: StartupItem) -> Pill? {
    switch item.target {
    case .missing:
      return Pill(title: "Program missing", icon: "questionmark.app.dashed", swatch: .rose,
        help: "Nothing exists at the program path, so this item can't run. The app may have been deleted or moved.")
    case .inTrash:
      return Pill(title: "Program in Trash", icon: "trash", swatch: .rose,
        help: "The program is in a Trash folder. It stops working when the Trash is emptied.")
    case .volumeNotMounted:
      return Pill(title: "Disk not connected", icon: "externaldrive.badge.xmark", swatch: .amber,
        help: "The program is on a disk that isn't connected, often an installer disk image that was ejected.")
    case .otherVolume:
      return Pill(title: "On another disk", icon: "externaldrive", swatch: .slate,
        help: "The program is on another disk and runs only while that disk is connected.")
    case .present, .unresolved, nil:
      return nil
    }
  }

  /// Running, Loaded (waiting for launchd to start it) or Not loaded, from launchd's live state.
  private static func statePill(_ item: StartupItem) -> Pill {
    guard let live = item.live else {
      return Pill(title: "State unknown", icon: "questionmark.circle",
        help: item.scope.contains("Daemon") ? "macOS shows system daemons' live state only to administrators."
          : "launchd's state couldn't be read.")
    }
    switch live.kind {
    case .running:
      return Pill(title: "Running", icon: "play.circle", swatch: .mint,
        help: live.pid.map { "Running now as process \($0)." } ?? "Running now.")
    case .waiting:
      return Pill(title: "Loaded", icon: "clock", swatch: .sky,
        help: "Loaded. launchd starts it when it is needed; an idle helper is normal.")
    case .failed:
      return Pill(title: "Last run failed", icon: "exclamationmark.triangle", swatch: .amber,
        help: "Its last run ended with error code \(live.lastExitStatus ?? 0).")
    case .notLoaded:
      return Pill(title: "Not loaded", icon: "moon.zzz", swatch: .slate,
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
