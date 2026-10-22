import MacCleanerCore
import SwiftUI

struct LargeFilesView: View {
  @EnvironmentObject private var model: AppViewModel

  private var selectedBytes: Int64 { model.queuedLargeFiles.reduce(0) { $0 + $1.size } }

  private func selection(_ file: LargeFile) -> Binding<Bool> {
    Binding(get: { model.selectedLargeFileIDs.contains(file.id) },
      set: { model.setFileSelection(file.url, selected: $0) })
  }

  /// Another module's scan leaves these results visible.
  private var scanningHere: Bool { model.isScanning && model.operationTitle == "Large Files" }

  var body: some View {
    VStack(spacing: 0) {
      header
      controls

      if scanningHere || (model.largeFiles.isEmpty && model.isScanning && !model.largeFilesScanned) {
        LoadingState(title: scanningHere ? "Looking for large files…" : "Large files are next",
          detail: scanningHere
            ? "Finding files over \(ByteFormatter.string(model.largeFileMinimum)) in \(model.largeFileRoot.lastPathComponent). Spotlight usually answers in a few seconds."
            : "\(model.operationTitle ?? "Another scan") is running. Large files load as soon as it finishes.",
          symbol: "externaldrive.fill", swatch: .indigo,
          cancel: scanningHere ? { model.cancelCurrentOperation() } : nil)
      } else if model.largeFiles.isEmpty {
        EmptyState(
          icon: "externaldrive", title: model.largeFilesScanned ? "No large files found" : "Find your biggest files",
          detail: model.largeFilesScanned
            ? "Nothing in \(model.largeFileRoot.lastPathComponent) is over \(ByteFormatter.string(model.largeFileMinimum)). Choose another folder or a smaller size above."
            : "Lists files over \(ByteFormatter.string(model.largeFileMinimum)) in your home folder. Large files are always review-only.",
          actionTitle: model.largeFilesScanned ? nil : "Find Large Files",
          action: model.largeFilesScanned ? nil : { model.scanLargeFiles() },
          secondaryTitle: "Choose Folder…", secondaryAction: { model.chooseLargeFileFolder() })
      } else {
        if model.isScanning { OtherScanNote() }
        ScrollView {
          LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 12, alignment: .top)], spacing: 12) {
            ForEach(model.largeFiles) { file in
              card(file)
            }
          }
          .frame(maxWidth: 1180)
          .padding(.horizontal, AppTheme.pagePadding)
          .padding(.top, 4)
          .padding(.bottom, 24)
          .frame(maxWidth: .infinity)
        }
        if !model.selectedLargeFileIDs.isEmpty {
          SelectionBar(
            count: model.queuedLargeFiles.count, bytes: selectedBytes,
            message: "Nothing is removed yet. Personal files always need your decision.",
            clear: { model.keepQueuedFiles(model.queuedLargeFiles.map(\.url)) },
            commitTitle: "Review \(ByteFormatter.string(selectedBytes))",
            commitDisabled: model.isWorking || model.isScanning,
            commit: { model.reviewLargeFiles() })
        }
      }
    }
    .task(id: model.autoLoadKey) { model.autoLoadIfNeeded(.largeFiles) }
  }

  // MARK: Header

  private var header: some View {
    PageHeader(title: "Large Files", subtitle: "The biggest single files, wherever they're hiding. What stays is always your decision.") {
      HStack(spacing: 8) {
        if !model.largeFiles.isEmpty {
          StatusPill(
            title: "\(model.largeFiles.count) found", icon: "doc.on.doc", tint: AppTheme.Swatch.indigo.text)
          if model.selectedLargeFileIDs.isEmpty {
            Button("Select All") { model.selectedLargeFileIDs = Set(model.largeFiles.map(\.id)) }
              .buttonStyle(MintButtonStyle(.secondary))
          }
        }
        Picker("Bigger than", selection: $model.largeFileMinimum) {
          Text("100 MB").tag(Int64(100 * 1_048_576))
          Text("500 MB").tag(Int64(500 * 1_048_576))
          Text("1 GB").tag(Int64(1_073_741_824))
          Text("5 GB").tag(Int64(5 * 1_073_741_824))
        }
        .fixedSize()
        .help("Minimum size")
        Button {
          model.scanLargeFiles()
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
        Text(model.largeFileRoot.path)
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
      .accessibilityLabel("Folder: \(model.largeFileRoot.path)")
      Button("Choose Folder…") { model.chooseLargeFileFolder() }
        .buttonStyle(MintButtonStyle(.secondary))
        .controlSize(.small)
      Spacer(minLength: 8)
      if model.largeFilesViaSpotlight, !model.largeFiles.isEmpty {
        StatusPill(title: "From Spotlight", icon: "bolt.fill", tint: AppTheme.Swatch.indigo.text)
          .help("Instant results from the Spotlight index, each re-checked on disk. Run a full scan to include unindexed folders.")
        Button("Full Scan") { model.scanLargeFiles(fullScan: true) }
          .buttonStyle(MintButtonStyle(.secondary))
          .controlSize(.small)
          .disabled(model.isScanning || model.isWorking)
      }
    }
    .frame(maxWidth: 1180)
    .padding(.horizontal, AppTheme.pagePadding)
    .padding(.bottom, 14)
    .frame(maxWidth: .infinity)
  }

  // MARK: Cards

  private func card(_ file: LargeFile) -> some View {
    let selected = model.selectedLargeFileIDs.contains(file.id)
    let shape = RoundedRectangle(cornerRadius: AppTheme.corner, style: .continuous)
    return VStack(alignment: .leading, spacing: 0) {
      preview(file)
      VStack(alignment: .leading, spacing: 2) {
        Text(file.url.lastPathComponent)
          .font(.system(size: 13, weight: .semibold))
          .foregroundStyle(AppTheme.ink)
          .lineLimit(1)
          .truncationMode(.middle)
          .help(file.url.lastPathComponent)
        Text(file.url.deletingLastPathComponent().path)
          .font(.system(size: 11, design: .monospaced))
          .foregroundStyle(AppTheme.ink3)
          .lineLimit(1)
          .truncationMode(.middle)
        HStack(spacing: 6) {
          Image(systemName: "clock")
            .font(.system(size: 11))
            .accessibilityHidden(true)
          Text(dateLine(file))
            .lineLimit(1)
          Spacer(minLength: 4)
          Button {
            model.reveal(file.url)
          } label: {
            Image(systemName: "folder")
              .font(.system(size: 11.5))
              .frame(width: 22, height: 22)
              .background(AppTheme.panel, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
              .contentShape(Rectangle())
          }
          .buttonStyle(.plain)
          .help("Reveal in Finder")
          .accessibilityLabel("Reveal \(file.url.lastPathComponent) in Finder")
          Menu {
            Button("Reveal in Finder") { model.reveal(file.url) }
            Button("Exclude from future scans") { model.ignore(file.url) }
            Divider()
            Button("Move to Trash…", role: .destructive) { model.reviewLargeFiles([file]) }
          } label: {
            Image(systemName: "ellipsis.circle")
              .accessibilityLabel("More actions")
          }
          .menuStyle(.borderlessButton)
          .menuIndicator(.hidden)
          .fixedSize()
        }
        .font(.system(size: 11.5))
        .foregroundStyle(AppTheme.ink2)
        .padding(.top, 6)
      }
      .padding(.horizontal, 13)
      .padding(.top, 11)
      .padding(.bottom, 12)
    }
    .clipShape(shape)
    .cardBackground()
    .overlay(shape.strokeBorder(selected ? AppTheme.accentText : Color.clear, lineWidth: 2))
  }

  private func preview(_ file: LargeFile) -> some View {
    let swatch = StorageStyle.fileSwatch(file.url)
    return ZStack {
      Rectangle().fill(swatch.gradient)
      Image(systemName: StorageStyle.fileSymbol(file.url))
        .font(.system(size: 36, weight: .semibold))
        .foregroundStyle(Color.white.opacity(0.92))
        .accessibilityHidden(true)
    }
    .frame(maxWidth: .infinity)
    .frame(height: 96)
    .overlay(alignment: .topLeading) {
      Toggle(isOn: selection(file)) { EmptyView() }
        .toggleStyle(MintCheckboxStyle())
        .accessibilityLabel("Select \(file.url.lastPathComponent)")
        .padding(10)
    }
    .overlay(alignment: .bottomTrailing) {
      Text(ByteFormatter.string(file.size))
        .font(AppTheme.number(13))
        .monospacedDigit()
        .foregroundStyle(.white)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Color.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .padding(10)
    }
  }

  private func dateLine(_ file: LargeFile) -> String {
    if let opened = file.accessedAt {
      return "Opened " + opened.formatted(.relative(presentation: .named))
    }
    if let changed = file.modifiedAt {
      return "Changed " + changed.formatted(.relative(presentation: .named))
    }
    return "Date unknown"
  }
}
