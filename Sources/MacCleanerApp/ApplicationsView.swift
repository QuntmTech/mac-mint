import AppKit
import MacCleanerCore
import SwiftUI
import UniformTypeIdentifiers

struct ApplicationsView: View {
  @EnvironmentObject private var model: AppViewModel
  @EnvironmentObject private var updates: AppUpdatesStore
  @SceneStorage("apps.search") private var search = ""
  @SceneStorage("apps.sort") private var sort: AppSort = .name
  @SceneStorage("apps.mode") private var mode: Mode = .uninstall

  enum Mode: String, CaseIterable, Identifiable {
    case uninstall = "Uninstall"
    case updates = "Updates"
    var id: String { rawValue }
  }

  enum AppSort: String, CaseIterable, Identifiable {
    case name = "Name"
    case size = "Size"
    case recent = "Modified"
    case lastOpened = "Last opened"
    var id: String { rawValue }
  }

  private var filteredApps: [AppRecord] {
    let filtered =
      search.isEmpty
      ? model.apps
      : model.apps.filter {
        $0.name.localizedCaseInsensitiveContains(search)
          || ($0.bundleIdentifier?.localizedCaseInsensitiveContains(search) ?? false)
      }
    switch sort {
    case .name:
      return filtered.sorted {
        $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
      }
    case .size:
      return filtered.sorted { $0.bundleSize > $1.bundleSize }
    case .recent:
      return filtered.sorted {
        ($0.lastModified ?? .distantPast) > ($1.lastModified ?? .distantPast)
      }
    case .lastOpened:
      // Longest unused first; unknown (no Spotlight record) last — unknown is never "unused".
      return filtered.sorted {
        ($0.lastUsed ?? .distantFuture) < ($1.lastUsed ?? .distantFuture)
      }
    }
  }

  private var selectedLeftoverBytes: Int64 {
    model.appLeftovers.filter { model.selectedLeftoverIDs.contains($0.id) }.reduce(0) {
      $0 + $1.size
    }
  }

  var body: some View {
    VStack(spacing: 0) {
      Picker("Mode", selection: $mode) {
        ForEach(Mode.allCases) { item in
          if item == .updates, !updates.available.isEmpty {
            Text("Updates (\(updates.available.count))").tag(item)
          } else {
            Text(item.rawValue).tag(item)
          }
        }
      }
      .pickerStyle(.segmented)
      .labelsHidden()
      .frame(width: 260)
      .padding(.vertical, 10)
      Divider()
      if mode == .updates {
        AppUpdatesView()
      } else {
        uninstaller
      }
    }
    .onDrop(of: [.fileURL], isTargeted: nil) { providers in
      guard let provider = providers.first else { return false }
      _ = provider.loadObject(ofClass: URL.self) { url, _ in
        guard let url else { return }
        Task { @MainActor in model.inspectDroppedApp(url) }
      }
      return true
    }
  }

  private var uninstaller: some View {
    HSplitView {
      VStack(spacing: 0) {
        HStack {
          VStack(alignment: .leading, spacing: 2) {
            Text("Applications").font(.title.bold())
            Text("\(model.apps.count) installed apps").font(.caption).foregroundStyle(.secondary)
          }
          Spacer()
          Button("Refresh") { model.runSmartScan() }
            .disabled(model.isScanning || model.isWorking)
        }
        .padding(18)

        HStack(spacing: 8) {
          TextField("Search apps or bundle IDs", text: $search)
            .textFieldStyle(.roundedBorder)
          Picker("Sort", selection: $sort) {
            ForEach(AppSort.allCases) { item in Text(item.rawValue).tag(item) }
          }
          .frame(width: 140)
          .onAppear {
            if model.applicationsSortByLastOpened {
              sort = .lastOpened
              model.applicationsSortByLastOpened = false
            }
          }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 10)

        Divider()

        List(
          filteredApps,
          selection: Binding(
            get: { model.selectedApp?.id },
            set: { id in
              if let id, let app = model.apps.first(where: { $0.id == id }) {
                model.loadLeftovers(for: app)
              }
            }
          )
        ) { app in
          HStack(spacing: 11) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: app.url.path))
              .resizable()
              .interpolation(.high)
              .frame(width: 38, height: 38)
            VStack(alignment: .leading, spacing: 3) {
              Text(app.name).fontWeight(.medium).lineLimit(1)
              HStack(spacing: 5) {
                if let version = app.version { Text("v\(version)") }
                Text(ByteFormatter.string(app.bundleSize))
              }
              .font(.caption2)
              .foregroundStyle(.secondary)
              if let lastUsed = app.lastUsed {
                let days = Int(Date().timeIntervalSince(lastUsed) / 86_400)
                Text(days < 1 ? "Opened today" : "Opened \(RelativeAge.describe(days: days)) ago")
                  .font(.caption2)
                  .foregroundStyle(days >= 180 ? Color.orange : Color.secondary)
              }
            }
            Spacer()
          }
          .padding(.vertical, 3)
          .tag(app.id)
        }
        .listStyle(.inset)
      }
      .frame(minWidth: 340, idealWidth: 380)

      detail
        .frame(minWidth: 520)
    }
  }

  @ViewBuilder
  private var detail: some View {
    if let app = model.selectedApp {
      VStack(alignment: .leading, spacing: 0) {
        HStack(spacing: 15) {
          Image(nsImage: NSWorkspace.shared.icon(forFile: app.url.path))
            .resizable()
            .interpolation(.high)
            .frame(width: 68, height: 68)
          VStack(alignment: .leading, spacing: 4) {
            Text(app.name).font(.system(size: 28, weight: .bold, design: .rounded))
            Text(app.bundleIdentifier ?? "No bundle identifier")
              .font(.callout)
              .foregroundStyle(.secondary)
              .textSelection(.enabled)
            HStack(spacing: 8) {
              StatusPill(
                title: ByteFormatter.string(app.bundleSize), icon: "externaldrive",
                tint: AppTheme.accentText)
              if let version = app.version {
                StatusPill(title: "Version \(version)", icon: "number")
              }
              if model.selectedAppIsRunning {
                StatusPill(title: "Running", icon: "play.circle.fill", tint: .orange)
              }
            }
          }
          Spacer()
          Button("Reveal App") { model.reveal(app.url) }
        }
        .padding(AppTheme.pagePadding)

        Divider()

        VStack(alignment: .leading, spacing: 12) {
          HStack {
            VStack(alignment: .leading, spacing: 3) {
              Text("Related files").font(.headline)
              Text(
                "Exact bundle-ID matches are selected automatically. Helpers, shared containers, and name matches stay review-only."
              )
              .font(.caption)
              .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Keep my settings") { model.selectedLeftoverIDs = [] }
              .help("Uninstall the app while leaving its settings and related data in place")
            StatusPill(
              title: "\(model.selectedLeftoverIDs.count) selected", icon: "checkmark.circle",
              tint: AppTheme.accentText)
          }

          if model.isScanning && model.operationTitle?.contains(app.name) == true {
            HStack(spacing: 10) {
              ProgressView().controlSize(.small)
              Text("Inspecting Library data…").foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
          } else if model.appLeftovers.isEmpty {
            EmptyState(
              icon: "checkmark.seal", title: "No related files found",
              detail: "No matching user-level leftovers were detected for this app.")
          } else {
            List(model.appLeftovers) { leftover in
              HStack(spacing: 11) {
                Toggle(
                  "",
                  isOn: Binding(
                    get: { model.selectedLeftoverIDs.contains(leftover.id) },
                    set: { value in
                      if value {
                        model.selectedLeftoverIDs.insert(leftover.id)
                      } else {
                        model.selectedLeftoverIDs.remove(leftover.id)
                      }
                    }
                  )
                )
                .labelsHidden()
                .accessibilityLabel("Remove \(leftover.url.lastPathComponent) with the app")

                VStack(alignment: .leading, spacing: 3) {
                  Text(leftover.url.lastPathComponent).fontWeight(.medium)
                  Text(leftover.reason).font(.caption).foregroundStyle(.secondary)
                  Text(leftover.url.path).font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
                }
                Spacer()
                if leftover.isShared {
                  StatusPill(title: "Shared", icon: "person.2", tint: .purple)
                }
                StatusPill(
                  title: leftover.confidence.rawValue.capitalized,
                  icon: leftover.confidence == .high ? "checkmark.shield" : "eye",
                  tint: leftover.confidence == .high ? .green : .orange
                )
                Text(ByteFormatter.string(leftover.size))
                  .font(.callout.monospacedDigit())
                  .frame(width: 86, alignment: .trailing)
                Menu {
                  Button("Reveal in Finder") { model.reveal(leftover.url) }
                  Button("Exclude from future scans") { model.ignore(leftover.url) }
                } label: {
                  Image(systemName: "ellipsis.circle")
                    .accessibilityLabel("More actions")
                }
                .menuStyle(.borderlessButton)
                .frame(width: 28)
              }
              .padding(.vertical, 4)
            }
            .listStyle(.inset)
          }
        }
        .padding(.horizontal, AppTheme.pagePadding)
        .padding(.top, 18)

        Spacer(minLength: 0)

        Divider()
        HStack {
          VStack(alignment: .leading, spacing: 2) {
            Text("Selected for uninstall").font(.caption).foregroundStyle(.secondary)
            Text(ByteFormatter.string(app.bundleSize + selectedLeftoverBytes))
              .font(.title3.bold())
              .monospacedDigit()
          }
          Spacer()
          if model.selectedAppIsRunning {
            Button {
              model.requestQuitSelectedApp()
            } label: {
              Label("Quit App First", systemImage: "power")
            }
            .buttonStyle(.borderedProminent)
            .tint(.orange)
            .disabled(model.isWorking || model.isScanning)
          } else {
            Button {
              model.reviewUninstall()
            } label: {
              Label("Review Uninstall…", systemImage: "trash")
            }
            .buttonStyle(.borderedProminent)
            .disabled(model.isWorking || model.isScanning)
          }
        }
        .padding(18)
      }
    } else {
      EmptyState(
        icon: "app.dashed", title: "Choose an application",
        detail:
          "Select an app to inspect its bundle and related Library files before uninstalling it.")
    }
  }
}
