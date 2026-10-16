import MacCleanerCore
import SwiftUI

struct DeveloperView: View {
  @EnvironmentObject private var model: AppViewModel

  private var grouped: [(DevGroup, [DevStorageItem])] {
    DevGroup.allCases.compactMap { group in
      let items = model.devItems.filter { $0.group == group }
      return items.isEmpty ? nil : (group, items)
    }
  }

  private var selectedBytes: Int64 { model.queuedDevItems.reduce(0) { $0 + $1.bytes } }

  var body: some View {
    VStack(spacing: 0) {
      header
      Divider()
      projectBar
      Divider()
      if model.isScanning && model.operationTitle == "Developer & AI" {
        VStack(spacing: 12) {
          ProgressView().controlSize(.large)
          Text("Looking through Xcode, package managers, and model caches…").foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else if model.devItems.isEmpty {
        EmptyState(
          icon: "hammer", title: "Find developer and AI clutter",
          detail: "Xcode build data, simulators, package caches, project build folders, and local AI models — each with what it costs to remove.",
          actionTitle: "Scan developer data", action: { model.scanDeveloper() })
      } else {
        summary
        List {
          ForEach(grouped, id: \.0) { group, items in
            Section {
              ForEach(items) { row($0) }
            } header: {
              HStack {
                Text(group.rawValue)
                Spacer()
                Text(ByteFormatter.string(items.reduce(0) { $0 + $1.bytes })).monospacedDigit()
              }
            }
          }
        }
        .listStyle(.inset)
      }
    }
  }

  private var header: some View {
    PageHeader(title: "Developer", subtitle: "Build output, package caches, and local models. See the cost of rebuilding before you decide.") {
      HStack(spacing: 8) {
      if !model.selectedDevIDs.isEmpty {
        Button("Deselect") { model.keepQueuedFiles(model.queuedDevItems.compactMap(\.url)) }
        Button {
          model.reviewDeveloper()
        } label: {
          Label("Review \(ByteFormatter.string(selectedBytes))", systemImage: "checklist")
        }
        .buttonStyle(MintButtonStyle())
        .disabled(model.isWorking || model.isScanning || selectedBytes == 0)
      }
      if model.devItems.isEmpty {
        Button("Scan") { model.scanDeveloper() }
          .buttonStyle(MintButtonStyle())
          .disabled(model.isScanning || model.isWorking)
      } else {
        Button("Rescan") { model.scanDeveloper() }
          .disabled(model.isScanning || model.isWorking)
      }
    }
    }
    .padding(AppTheme.pagePadding)
  }

  private var projectBar: some View {
    HStack(spacing: 8) {
      Image(systemName: "folder.badge.gearshape").foregroundStyle(AppTheme.accentText)
      if model.devProjectRoots.isEmpty {
        Text("Add your code folder to find node_modules, .build, target, and other build output.")
          .font(.caption)
          .foregroundStyle(.secondary)
      } else {
        ScrollView(.horizontal, showsIndicators: false) {
          HStack(spacing: 6) {
            ForEach(model.devProjectRoots, id: \.self) { url in
              HStack(spacing: 4) {
                Text(url.lastPathComponent).font(.caption.weight(.medium))
                Button {
                  model.removeProjectFolder(url)
                } label: {
                  Image(systemName: "xmark.circle.fill")
                    .accessibilityLabel("Stop scanning this folder")
                }
                .buttonStyle(.borderless)
                .help("Stop scanning \(url.path)")
              }
              .padding(.horizontal, 8)
              .padding(.vertical, 4)
              .background(AppTheme.accent.opacity(0.1), in: Capsule())
            }
          }
        }
      }
      Spacer()
      Button("Add Project Folder…") { model.addProjectFolder() }
        .disabled(model.isScanning || model.isWorking)
    }
    .padding(.horizontal, AppTheme.pagePadding)
    .padding(.vertical, 10)
    .background(AppTheme.surface)
  }

  private var summary: some View {
    LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: 12)], spacing: 12) {
      ForEach(grouped, id: \.0) { group, items in
        VStack(alignment: .leading, spacing: 2) {
          Text(ByteFormatter.string(items.reduce(0) { $0 + $1.bytes }))
            .font(.system(.title3, design: .rounded).weight(.bold))
            .monospacedDigit()
          Text(group.rawValue).font(.caption).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(AppTheme.panel, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
      }
    }
    .padding(.horizontal, AppTheme.pagePadding)
    .padding(.vertical, 12)
  }

  private func row(_ item: DevStorageItem) -> some View {
    HStack(spacing: 11) {
      if item.canTrash {
        Toggle(
          "",
          isOn: Binding(
            get: { model.selectedDevIDs.contains(item.id) },
            set: { isOn in
              if let url = item.url { model.setFileSelection(url, selected: isOn) }
            })
        )
        .labelsHidden()
        .accessibilityLabel("Select \(item.title)")
      } else {
        Color.clear.frame(width: 20)
      }

      OwnerIcon(
        hint: OwnerResolver.toolBundleIDs[item.tool].map { OwnerHint(bundleID: $0, displayName: item.tool) }
          ?? item.url.flatMap { OwnerResolver.hint(for: $0) },
        fallbackSymbol: "hammer", size: 28)

      VStack(alignment: .leading, spacing: 3) {
        HStack(spacing: 6) {
          Text(item.title).fontWeight(.medium).lineLimit(1)
          Text(item.tool).font(.caption2).foregroundStyle(.secondary)
          costBadge(item.rebuild)
          if item.isActive {
            StatusPill(title: "In use", icon: "bolt.fill", tint: .blue)
          }
        }
        Text(item.subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(2)
        if let date = item.lastUsed {
          Text("Last changed \(date.formatted(.relative(presentation: .named)))")
            .font(.caption2).foregroundStyle(.tertiary)
        }
      }
      Spacer()
      Text(ByteFormatter.string(item.bytes))
        .font(.callout.monospacedDigit())
        .frame(width: 86, alignment: .trailing)
      actions(item)
    }
    .padding(.vertical, 4)
  }

  @ViewBuilder
  private func actions(_ item: DevStorageItem) -> some View {
    switch item.removal {
    case .command(let command):
      Button {
        model.copyCommand(command)
      } label: {
        Label("Copy Command", systemImage: "terminal")
      }
      .controlSize(.small)
      .help("Managed by \(item.tool). Run “\(command)” in Terminal instead of deleting files.")
    case .none(let reason):
      Image(systemName: "info.circle").help(reason)
    case .trash:
      Menu {
        if let url = item.url {
          Button("Reveal in Finder") { model.reveal(url) }
          Button("Exclude from Future Scans") { model.ignore(url) }
        }
        ExplainMenuItem(target: model.aiTarget(for: item))
      } label: {
        Image(systemName: "ellipsis.circle")
          .accessibilityLabel("More actions")
      }
      .menuStyle(.borderlessButton)
      .frame(width: 28)
    }
  }

  private func costBadge(_ cost: RebuildCost) -> some View {
    switch cost {
    case .rebuildable: return StatusPill(title: "Rebuilds", icon: "arrow.triangle.2.circlepath", tint: .green)
    case .redownload: return StatusPill(title: "Re-downloads", icon: "icloud.and.arrow.down", tint: .teal)
    case .review: return StatusPill(title: "Review", icon: "eye.fill", tint: .orange)
    }
  }
}
