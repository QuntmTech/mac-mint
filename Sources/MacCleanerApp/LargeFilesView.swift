import MacCleanerCore
import SwiftUI

struct LargeFilesView: View {
  @EnvironmentObject private var model: AppViewModel
  @State private var pendingDelete: LargeFile?

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
            Image(systemName: "doc.fill")
              .foregroundStyle(AppTheme.accent)
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
              Button("Move to Trash", role: .destructive) { pendingDelete = file }
            } label: {
              Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .frame(width: 28)
          }
          .padding(.vertical, 5)
        }
        .listStyle(.inset)
      }
    }
    .alert(
      "Move this file to Trash?",
      isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } })
    ) {
      Button("Cancel", role: .cancel) { pendingDelete = nil }
      Button("Move to Trash", role: .destructive) {
        if let file = pendingDelete {
          model.trashReviewedFile(file.url, bytes: file.size, action: "Remove large file")
        }
        pendingDelete = nil
      }
    } message: {
      Text(pendingDelete.map { "\($0.url.path)\n\nSize: \(ByteFormatter.string($0.size))" } ?? "")
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
          title: "\(model.largeFiles.count) found", icon: "doc.on.doc", tint: AppTheme.accent)
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
