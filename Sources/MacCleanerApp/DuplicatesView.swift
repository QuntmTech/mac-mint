import MacCleanerCore
import QuickLook
import SwiftUI

struct DuplicatesView: View {
  @EnvironmentObject private var model: AppViewModel
  @State private var previewURL: URL?
  @State private var comparing: DuplicateGroup?

  private var totalReclaimable: Int64 {
    model.duplicateGroups.reduce(0) { $0 + $1.reclaimableBytes }
  }

  private var extraCopies: Int {
    model.duplicateGroups.reduce(0) { $0 + max(0, $1.files.count - 1) }
  }

  /// Another module's scan leaves these results visible.
  private var scanningHere: Bool { model.isScanning && model.operationTitle == "Duplicate Finder" }

  var body: some View {
    VStack(spacing: 0) {
      header
      controls

      if scanningHere {
        LoadingState(title: "Comparing files…",
          detail: "Matching files in \(model.duplicateRoot.lastPathComponent) by size, then by content. Large files are read in chunks so memory stays low. This can take a few minutes.",
          symbol: "square.on.square.fill", swatch: .indigo, cancel: { model.cancelCurrentOperation() })
      } else if model.duplicateGroups.isEmpty {
        // Comparing every file is the heaviest scan, so it starts when you ask.
        EmptyState(
          icon: "square.on.square",
          title: model.duplicatesScanned ? "No exact duplicates found" : "Find exact duplicate files",
          detail: model.duplicatesScanned
            ? "Nothing in \(model.duplicateRoot.lastPathComponent) has an identical copy. Choose another folder above to look somewhere else."
            : "Compares files in \(model.duplicateRoot.lastPathComponent) byte for byte: same size, then a sample, then the whole file. It can take a few minutes, and nothing is removed.",
          actionTitle: model.duplicatesScanned ? "Scan Again" : "Find Duplicates",
          action: { model.scanDuplicates() },
          secondaryTitle: "Choose Folder…", secondaryAction: { model.chooseDuplicateFolder() })
      } else {
        if model.isScanning { OtherScanNote() }
        ScrollView {
          LazyVStack(alignment: .leading, spacing: 14) {
            summaryCard
            ForEach(model.duplicateGroups) { group in
              groupCard(group)
            }
          }
          .frame(maxWidth: 1180)
          .padding(.horizontal, AppTheme.pagePadding)
          .padding(.top, 4)
          .padding(.bottom, 24)
          .frame(maxWidth: .infinity)
        }
      }
    }
    .sheet(item: $comparing) { group in DuplicateComparisonSheet(group: group) }
    .quickLookPreview($previewURL, in: model.duplicateGroups.flatMap { $0.files.map(\.url) })
  }

  // MARK: Header

  private var header: some View {
    PageHeader(title: "Duplicates", subtitle: "Exact copies, matched byte for byte. Choose a keeper before reviewing the rest.") {
      HStack(spacing: 8) {
        if model.duplicateSelectedBytes > 0 {
          Button {
            model.reviewDuplicates()
          } label: {
            if model.isPreparingPlan {
              ProgressView().controlSize(.small)
            } else {
              Label("Review \(ByteFormatter.string(model.duplicateSelectedBytes))", systemImage: "checklist")
            }
          }
          .buttonStyle(MintButtonStyle())
          .disabled(model.isWorking || model.isScanning || model.isPreparingPlan)
          .help("Each kept copy is re-verified before anything moves")
        }
        Button {
          model.scanDuplicates()
        } label: {
          Label(model.isScanning ? "Scanning…" : "Scan", systemImage: "magnifyingglass")
        }
        .buttonStyle(MintButtonStyle(.area))
        .disabled(model.isScanning || model.isWorking)
      }
    }
    .frame(maxWidth: 1180)
    .padding(.horizontal, AppTheme.pagePadding)
    .padding(.top, AppTheme.pageTopPadding)
    .padding(.bottom, 12)
    .frame(maxWidth: .infinity)
  }

  private var controls: some View {
    HStack(spacing: 10) {
      HStack(spacing: 6) {
        Image(systemName: "folder.fill")
          .font(.system(size: 12))
          .foregroundStyle(AppTheme.Swatch.indigo.text)
        Text(model.duplicateRoot.path)
          .font(.system(size: 11.5, design: .monospaced))
          .foregroundStyle(AppTheme.ink2)
          .lineLimit(1)
          .truncationMode(.middle)
      }
      .padding(.horizontal, 10)
      .frame(height: 28)
      .frame(maxWidth: 360, alignment: .leading)
      .cardBackground(radius: 8)
      .accessibilityElement(children: .combine)
      .accessibilityLabel("Folder: \(model.duplicateRoot.path)")
      Button("Choose Folder…") { model.chooseDuplicateFolder() }
        .buttonStyle(MintButtonStyle(.secondary))
        .controlSize(.small)
      Picker("Bigger than", selection: $model.duplicateMinimum) {
        Text("1 MB").tag(Int64(1_048_576))
        Text("10 MB").tag(Int64(10 * 1_048_576))
        Text("100 MB").tag(Int64(100 * 1_048_576))
        Text("500 MB").tag(Int64(500 * 1_048_576))
      }
      .fixedSize()
      .help("Minimum size")
      Spacer(minLength: 8)
      Button("Clear selection") { model.clearDuplicateSelection() }
        .buttonStyle(MintButtonStyle(.plain))
        .controlSize(.small)
        .disabled(model.selectedDuplicateIDs.isEmpty)
    }
    .frame(maxWidth: 1180)
    .padding(.horizontal, AppTheme.pagePadding)
    .padding(.bottom, 14)
    .frame(maxWidth: .infinity)
  }

  // MARK: Summary

  private var summaryCard: some View {
    ViewThatFits(in: .horizontal) {
      HStack(spacing: 14) {
        summaryNumber
        summaryText
        Spacer(minLength: 8)
        keepRuleMenu
      }
      VStack(alignment: .leading, spacing: 10) {
        HStack(spacing: 14) {
          summaryNumber
          summaryText
        }
        keepRuleMenu
      }
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 14)
    .frame(maxWidth: .infinity, alignment: .leading)
    .cardBackground()
  }

  private var summaryNumber: some View {
    Text(ByteFormatter.string(totalReclaimable))
      .font(AppTheme.number(26))
      .tracking(-0.6)
      .monospacedDigit()
      .foregroundStyle(AppTheme.Swatch.indigo.text)
      .lineLimit(1)
      .fixedSize()
  }

  private var summaryText: some View {
    Text("in \(extraCopies.formatted()) extra cop\(extraCopies == 1 ? "y" : "ies") of \(model.duplicateGroups.count.formatted()) file\(model.duplicateGroups.count == 1 ? "" : "s"). Pick the copy that stays in each group, or let a keep rule pick for you.")
      .font(.system(size: 12.5))
      .foregroundStyle(AppTheme.ink2)
      .frame(minWidth: 200, alignment: .leading)
      .fixedSize(horizontal: false, vertical: true)
  }

  private var keepRuleMenu: some View {
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
      Label("Keep Rule", systemImage: "wand.and.stars")
    }
    .fixedSize()
    .disabled(model.duplicateGroups.isEmpty)
    .help("Pick which copy to keep in every group; you still review before anything moves")
  }

  // MARK: Groups

  private func groupCard(_ group: DuplicateGroup) -> some View {
    let first = group.files.first
    let swatch = first.map { StorageStyle.fileSwatch($0.url) } ?? AppTheme.Swatch.slate
    let symbol = first.map { StorageStyle.fileSymbol($0.url) } ?? "doc.fill"
    return VStack(spacing: 0) {
      HStack(spacing: 10) {
        Image(systemName: symbol)
          .font(.system(size: 13, weight: .semibold))
          .foregroundStyle(swatch.text)
          .frame(width: 30, height: 30)
          .background(swatch.tint, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
          .accessibilityHidden(true)
        VStack(alignment: .leading, spacing: 1) {
          Text(first?.url.lastPathComponent ?? "Identical files")
            .font(.system(size: 13, weight: .bold))
            .foregroundStyle(AppTheme.ink)
            .lineLimit(1)
            .truncationMode(.middle)
          Text("\(group.files.count) identical files · \(ByteFormatter.string(group.reclaimableBytes)) reclaimable")
            .font(.system(size: 11.5))
            .monospacedDigit()
            .foregroundStyle(AppTheme.ink3)
            .lineLimit(1)
        }
        Spacer(minLength: 8)
        Button("Select copies") { model.selectDuplicateCopies(in: group.id) }
          .buttonStyle(MintButtonStyle(.plain))
          .controlSize(.small)
        Button("Clear") { model.clearDuplicateSelection(in: group.id) }
          .buttonStyle(MintButtonStyle(.plain))
          .controlSize(.small)
        Button {
          comparing = group
        } label: {
          Label("Compare", systemImage: "rectangle.split.2x1")
        }
        .buttonStyle(MintButtonStyle(.secondary))
        .controlSize(.small)
      }
      .padding(.horizontal, 14)
      .padding(.vertical, 11)
      Rectangle().fill(AppTheme.divider).frame(height: 1)
      LazyVGrid(columns: [GridItem(.adaptive(minimum: 340), spacing: 8, alignment: .top)], spacing: 8) {
        ForEach(group.files) { file in
          duplicateRow(file, group: group)
        }
      }
      .padding(10)
    }
    .cardBackground()
  }

  private func duplicateRow(_ file: LargeFile, group: DuplicateGroup) -> some View {
    let selected = model.selectedDuplicateIDs.contains(file.id)
    let shape = RoundedRectangle(cornerRadius: 11, style: .continuous)
    return HStack(spacing: 10) {
      Toggle(
        isOn: Binding(
          get: { model.selectedDuplicateIDs.contains(file.id) },
          set: { model.toggleDuplicate(file.id, in: group.id, selected: $0) }
        )
      ) { EmptyView() }
      .toggleStyle(KeepOrRemoveToggleStyle())
      .accessibilityLabel("Remove copy \(file.url.lastPathComponent)")

      FileThumbnail(url: file.url, size: 38)
        .onTapGesture(count: 2) { previewURL = file.url }

      VStack(alignment: .leading, spacing: 2) {
        Text(file.url.lastPathComponent)
          .font(.system(size: 12.5, weight: .semibold))
          .foregroundStyle(AppTheme.ink)
          .lineLimit(1)
          .truncationMode(.middle)
        Text(file.url.deletingLastPathComponent().path)
          .font(.system(size: 11, design: .monospaced))
          .foregroundStyle(AppTheme.ink2)
          .lineLimit(1)
          .truncationMode(.middle)
        if let changed = file.modifiedAt {
          Text("Changed " + changed.formatted(.relative(presentation: .named)))
            .font(.system(size: 11))
            .foregroundStyle(AppTheme.ink3)
            .lineLimit(1)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)

      VStack(alignment: .trailing, spacing: 4) {
        if selected {
          Chip(title: "Copy", symbol: "doc.on.doc.fill", swatch: .slate)
        } else {
          Chip(title: "KEEP", symbol: "checkmark.seal.fill", swatch: .mint)
        }
        Text(ByteFormatter.string(file.size))
          .font(AppTheme.number(12, weight: .semibold))
          .monospacedDigit()
          .foregroundStyle(AppTheme.ink)
      }
      .fixedSize()

      Button {
        previewURL = file.url
      } label: {
        Image(systemName: "eye")
          .font(.system(size: 12))
          .frame(width: 22, height: 22)
          .contentShape(Rectangle())
          .accessibilityLabel("Preview")
      }
      .buttonStyle(.plain)
      .foregroundStyle(AppTheme.ink2)
      .help("Quick Look")
      .accessibilityLabel("Quick Look \(file.url.lastPathComponent)")
      Menu {
        Button("Keep this copy") {
          model.keepDuplicate(file, in: group)
        }
        Button("Quick Look") { previewURL = file.url }
        Button("Reveal in Finder") { model.reveal(file.url) }
        Button("Exclude from future scans") { model.ignore(file.url) }
      } label: {
        Image(systemName: "ellipsis.circle")
          .accessibilityLabel("More actions")
      }
      .menuStyle(.borderlessButton)
      .menuIndicator(.hidden)
      .fixedSize()
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 9)
    .background(selected ? AppTheme.panel : AppTheme.Swatch.mint.tint, in: shape)
    .overlay(shape.strokeBorder(selected ? Color.clear : AppTheme.accentText.opacity(0.45), lineWidth: 1.5))
  }
}

/// A copy that stays shows the keeper ring (a mint ring with a 5 pt border); a copy picked
/// for review shows a checked box. Tapping switches between them, through the same
/// selection rules as before (one copy always stays).
private struct KeepOrRemoveToggleStyle: ToggleStyle {
  func makeBody(configuration: Configuration) -> some View {
    ZStack {
      if configuration.isOn {
        CheckboxMark(state: .on)
      } else {
        Circle()
          .strokeBorder(AppTheme.accent, lineWidth: 5)
          .background(AppTheme.surface, in: Circle())
          .frame(width: 16, height: 16)
      }
    }
    .frame(width: 16, height: 16)
    .contentShape(Rectangle())
    .onTapGesture { configuration.isOn.toggle() }
    .accessibilityElement(children: .combine)
    .accessibilityAddTraits(.isButton)
    .accessibilityValue(configuration.isOn ? "Checked" : "Unchecked")
    .accessibilityAction { configuration.isOn.toggle() }
  }
}

/// Shown above existing results while a different scan is running.
struct OtherScanNote: View {
  @EnvironmentObject private var model: AppViewModel

  var body: some View {
    Label("\(model.operationTitle ?? "Another scan") is running. These are your previous results.", systemImage: "hourglass")
      .font(.system(size: 11.5)).foregroundStyle(AppTheme.ink2)
      .frame(maxWidth: 1180, alignment: .leading)
      .padding(.horizontal, AppTheme.pagePadding).padding(.bottom, 8)
      .frame(maxWidth: .infinity)
  }
}
