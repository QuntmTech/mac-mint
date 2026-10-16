import MacCleanerCore
import SwiftUI

struct LargeFilesView: View {
  @EnvironmentObject private var model: AppViewModel

  private var selectedBytes: Int64 { model.queuedLargeFiles.reduce(0) { $0 + $1.size } }

  private func selection(_ file: LargeFile) -> Binding<Bool> {
    Binding(
      get: { model.selectedLargeFileIDs.contains(file.id) },
      set: { isOn in
        if isOn {
          model.selectedLargeFileIDs.insert(file.id)
        } else {
          model.selectedLargeFileIDs.remove(file.id)
        }
      })
  }

  var body: some View {
    VStack(spacing: 0) {
      header
      Divider()
      controls
      Divider()

      if model.largeFiles.isEmpty && !model.isScanning {
        EmptyState(
          icon: "externaldrive", title: "No large files found yet",
          detail: "Choose a folder or scan your home folder. Large files are always review-only.")
      } else if model.isScanning {
        VStack(spacing: 12) {
          ProgressView().controlSize(.large)
          Text("Scanning for files larger than \(ByteFormatter.string(model.largeFileMinimum))…")
            .foregroundStyle(.secondary)
          Button("Cancel") { model.cancelCurrentOperation() }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else {
        List(model.largeFiles) { file in
          HStack(spacing: 12) {
            Toggle("", isOn: selection(file))
              .labelsHidden()
              .accessibilityLabel("Select \(file.url.lastPathComponent)")
            Image(systemName: "doc.fill")
              .foregroundStyle(AppTheme.accentText)
              .frame(width: 24)
            VStack(alignment: .leading, spacing: 3) {
              Text(file.url.lastPathComponent).fontWeight(.medium)
              Text(file.url.deletingLastPathComponent().path)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
            Spacer()
            if let date = file.modifiedAt {
              Text(date, style: .date)
                .foregroundStyle(.secondary)
                .frame(width: 100)
            }
            Text(ByteFormatter.string(file.size))
              .font(.callout.monospacedDigit())
              .frame(width: 96, alignment: .trailing)
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
            .frame(width: 28)
          }
          .padding(.vertical, 5)
        }
        .listStyle(.inset)
      }
    }
  }

  private var header: some View {
    HStack {
      VStack(alignment: .leading, spacing: 4) {
        Text("Large Files").font(.system(size: 30, weight: .bold, design: .rounded))
        Text("Find space-hungry personal files without scanning protected Library data.")
          .foregroundStyle(.secondary)
      }
      Spacer()
      if !model.largeFiles.isEmpty {
        StatusPill(
          title: "\(model.largeFiles.count) found", icon: "doc.on.doc", tint: AppTheme.accentText)
        if model.selectedLargeFileIDs.isEmpty {
          Button("Select All") { model.selectedLargeFileIDs = Set(model.largeFiles.map(\.id)) }
        } else {
          Button("Deselect All") { model.selectedLargeFileIDs = [] }
          Button {
            model.reviewLargeFiles()
          } label: {
            Label("Review \(ByteFormatter.string(selectedBytes))", systemImage: "trash")
          }
          .buttonStyle(.borderedProminent)
          .disabled(model.isWorking || model.isScanning)
        }
      }
    }
    .padding(AppTheme.pagePadding)
  }

  private var controls: some View {
    HStack(spacing: 10) {
      Label(model.largeFileRoot.path, systemImage: "folder")
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .frame(maxWidth: 360, alignment: .leading)
      Button("Choose Folder…") { model.chooseLargeFileFolder() }

      Divider().frame(height: 22)

      Picker("Minimum size", selection: $model.largeFileMinimum) {
        Text("100 MB").tag(Int64(100 * 1_048_576))
        Text("500 MB").tag(Int64(500 * 1_048_576))
        Text("1 GB").tag(Int64(1_073_741_824))
        Text("5 GB").tag(Int64(5 * 1_073_741_824))
      }
      .frame(width: 150)

      Spacer()
      Button(model.isScanning ? "Scanning…" : "Scan") { model.scanLargeFiles() }
        .buttonStyle(.borderedProminent)
        .disabled(model.isScanning || model.isWorking)
    }
    .padding(.horizontal, AppTheme.pagePadding)
    .padding(.vertical, 12)
    .background(.bar)
  }
}
