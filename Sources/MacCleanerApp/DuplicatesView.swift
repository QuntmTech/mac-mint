import MacCleanerCore
import QuickLook
import SwiftUI

struct DuplicatesView: View {
  @EnvironmentObject private var model: AppViewModel
  @State private var previewURL: URL?

  private var totalReclaimable: Int64 {
    model.duplicateGroups.reduce(0) { $0 + $1.reclaimableBytes }
  }

  var body: some View {
    VStack(spacing: 0) {
      header
      Divider()
      controls
      Divider()

      if model.duplicateGroups.isEmpty && !model.isScanning {
        EmptyState(
          icon: "square.on.square", title: "No exact duplicates found",
          detail:
            "Choose a folder and scan. Files are matched by size, sample hash, then full streaming SHA-256."
        )
      } else if model.isScanning {
        VStack(spacing: 12) {
          ProgressView().controlSize(.large)
          Text("Hashing candidate files…")
            .foregroundStyle(.secondary)
          Text("Large files are streamed in chunks to keep memory use bounded.")
            .font(.caption)
            .foregroundStyle(.tertiary)
          Button("Cancel") { model.cancelCurrentOperation() }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else {
        List {
          ForEach(model.duplicateGroups) { group in
            Section {
              ForEach(group.files) { file in
                duplicateRow(file, group: group)
              }
            } header: {
              HStack {
                Text("\(group.files.count) identical files")
                Text("•")
                Text(ByteFormatter.string(group.reclaimableBytes) + " reclaimable")
                Spacer()
                Button("Select copies") { model.selectDuplicateCopies(in: group.id) }
                  .buttonStyle(.link)
        .tint(AppTheme.accentText)
                Button("Clear") { model.clearDuplicateSelection(in: group.id) }
                  .buttonStyle(.link)
        .tint(AppTheme.accentText)
              }
            }
          }
        }
        .listStyle(.inset)
      }
    }
    .quickLookPreview($previewURL, in: model.duplicateGroups.flatMap { $0.files.map(\.url) })
  }

  private var header: some View {
    HStack {
      VStack(alignment: .leading, spacing: 4) {
        Text("Duplicates").font(.system(size: 30, weight: .bold, design: .rounded))
        Text("Exact content matching, with no filename-based deletion guesses.").foregroundStyle(
          .secondary)
      }
      Spacer()
      if totalReclaimable > 0 {
        StatusPill(
          title: ByteFormatter.string(totalReclaimable) + " possible", icon: "square.on.square",
          tint: AppTheme.accentText)
      }
      if model.duplicateSelectedBytes > 0 {
        Button {
          model.reviewDuplicates()
        } label: {
          if model.isPreparingPlan {
            ProgressView().controlSize(.small)
          } else {
            Label("Review \(ByteFormatter.string(model.duplicateSelectedBytes))", systemImage: "trash")
          }
        }
        .buttonStyle(.borderedProminent)
        .disabled(model.isWorking || model.isScanning || model.isPreparingPlan)
        .help("Each kept copy is re-verified before anything moves")
      }
    }
    .padding(AppTheme.pagePadding)
  }

  private var controls: some View {
    HStack(spacing: 10) {
      Label(model.duplicateRoot.path, systemImage: "folder")
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .frame(maxWidth: 360, alignment: .leading)
      Button("Choose Folder…") { model.chooseDuplicateFolder() }

      Divider().frame(height: 22)

      Picker("Minimum size", selection: $model.duplicateMinimum) {
        Text("1 MB").tag(Int64(1_048_576))
        Text("10 MB").tag(Int64(10 * 1_048_576))
        Text("100 MB").tag(Int64(100 * 1_048_576))
        Text("500 MB").tag(Int64(500 * 1_048_576))
      }
      .frame(width: 150)

      Spacer()
      Menu {
        ForEach(DuplicateKeeperRule.allCases) { rule in
          Button(rule.rawValue) { model.autoSelectDuplicates(rule) }
        }
        Divider()
        Button("Add Preferred Folder…") { model.choosePreferredDuplicateFolder() }
        if !model.duplicatePreferredFolders.isEmpty {
          Menu("Preferred Folders") {
            ForEach(model.duplicatePreferredFolders, id: \.self) { folder in
              Button("Remove \(folder.lastPathComponent)") {
                model.duplicatePreferredFolders.removeAll { $0 == folder }
              }
            }
          }
        }
      } label: {
        Label("Auto-select", systemImage: "wand.and.stars")
      }
      .fixedSize()
      .disabled(model.duplicateGroups.isEmpty)
      .help("Pick which copy to keep in every group; you still review before anything moves")
      Button("Clear selection") { model.clearDuplicateSelection() }
        .disabled(model.selectedDuplicateIDs.isEmpty)
      Button(model.isScanning ? "Scanning…" : "Scan") { model.scanDuplicates() }
        .buttonStyle(.borderedProminent)
        .disabled(model.isScanning || model.isWorking)
    }
    .padding(.horizontal, AppTheme.pagePadding)
    .padding(.vertical, 12)
    .background(.bar)
  }

  private func duplicateRow(_ file: LargeFile, group: DuplicateGroup) -> some View {
    let selected = model.selectedDuplicateIDs.contains(file.id)
    return HStack(spacing: 12) {
      Toggle(
        "",
        isOn: Binding(
          get: { model.selectedDuplicateIDs.contains(file.id) },
          set: { model.toggleDuplicate(file.id, in: group.id, selected: $0) }
        )
      )
      .labelsHidden()
      .accessibilityLabel("Remove copy \(file.url.lastPathComponent)")

      FileThumbnail(url: file.url, size: 46)
        .overlay(alignment: .bottomTrailing) {
          Image(systemName: selected ? "trash.circle.fill" : "checkmark.circle.fill")
            .foregroundStyle(.white, selected ? Color.red : Color.green)
            .font(.system(size: 14))
            .offset(x: 4, y: 4)
        }
        .onTapGesture(count: 2) { previewURL = file.url }

      VStack(alignment: .leading, spacing: 3) {
        Text(file.url.lastPathComponent).fontWeight(.medium)
        Text(file.url.deletingLastPathComponent().path)
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }
      Spacer()
      if !selected {
        StatusPill(title: "Keep", icon: "checkmark", tint: .green)
      }
      Text(ByteFormatter.string(file.size))
        .font(.callout.monospacedDigit())
        .frame(width: 92, alignment: .trailing)
      Button {
        previewURL = file.url
      } label: {
        Image(systemName: "eye")
          .accessibilityLabel("Preview")
      }
      .buttonStyle(.borderless)
      .help("Quick Look")
      .accessibilityLabel("Quick Look \(file.url.lastPathComponent)")
      Menu {
        Button("Quick Look") { previewURL = file.url }
        Button("Reveal in Finder") { model.reveal(file.url) }
        Button("Exclude from future scans") { model.ignore(file.url) }
      } label: {
        Image(systemName: "ellipsis.circle")
          .accessibilityLabel("More actions")
      }
      .menuStyle(.borderlessButton)
      .frame(width: 28)
    }
    .padding(.vertical, 5)
  }
}
