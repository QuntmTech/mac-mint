import MacCleanerCore
import QuickLook
import SwiftUI

struct DuplicateComparisonSheet: View {
  let group: DuplicateGroup
  @EnvironmentObject private var model: AppViewModel
  @Environment(\.dismiss) private var dismiss
  @State private var preview: URL?
  @FocusState private var focusedFile: UUID?

  private var title: String {
    let name = group.files.first?.url.lastPathComponent ?? "Identical files"
    return "\(name) — \(group.files.count) identical copies"
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      SheetHeader(
        symbol: "square.on.square.fill", swatch: .indigo, eyebrow: "Compare identical copies", title: title,
        subtitle: "Content matches by SHA-256. Hard links share one physical file; APFS clones may share storage too, so eventual savings can be lower than file sizes.")
      ScrollView(.horizontal) {
        LazyHStack(alignment: .top, spacing: 14) {
          ForEach(group.files) { file in
            copyCard(file)
          }
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 14)
      }
      .frame(maxHeight: .infinity, alignment: .top)
      SheetFooter {
        Label("Click a copy, then press Space to preview it.", systemImage: "eye")
          .font(.system(size: 11.5))
          .foregroundStyle(AppTheme.ink2)
        Spacer()
        Button("Done") { dismiss() }
          .buttonStyle(MintButtonStyle(.commit))
          .keyboardShortcut(.cancelAction)
      }
    }
    .frame(width: 820, height: 550)
    .background(AppTheme.elevated)
    .quickLookPreview($preview, in: group.files.map(\.url))
  }

  private func copyCard(_ file: LargeFile) -> some View {
    let selected = model.selectedDuplicateIDs.contains(file.id)
    let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
    return VStack(alignment: .leading, spacing: 0) {
      ZStack {
        AppTheme.panel
        FileThumbnail(url: file.url, size: 120)
      }
      .frame(height: 140)
      .frame(maxWidth: .infinity)
      .overlay(alignment: .topLeading) {
        Group {
          if selected {
            Chip(title: "Selected for removal", symbol: "checkmark.circle.fill", swatch: .slate)
          } else {
            Chip(title: "KEEP", symbol: "checkmark.seal.fill", swatch: .mint)
          }
        }
        .padding(10)
      }
      VStack(alignment: .leading, spacing: 6) {
        Text(file.url.path)
          .font(.system(size: 11.5, design: .monospaced))
          .foregroundStyle(AppTheme.ink2)
          .lineLimit(2)
          .truncationMode(.middle)
          .textSelection(.enabled)
        metaRow("Last changed", value: file.modifiedAt.map { $0.formatted() } ?? "Unknown")
        metaRow("Size", value: ByteFormatter.string(file.size), number: true)
        metaRow("Status", value: selected ? "Selected for removal" : "Kept: not selected", emphasized: true)
        Button("Keep this copy") {
          model.keepDuplicate(file, in: group)
        }
        .buttonStyle(selected ? MintButtonStyle(.commit) : MintButtonStyle(.secondary))
        .padding(.top, 4)
        HStack(spacing: 4) {
          Button("Preview (Space)") { preview = file.url }
            .buttonStyle(MintButtonStyle(.plain))
            .controlSize(.small)
          Button("Reveal in Finder") { model.reveal(file.url) }
            .buttonStyle(MintButtonStyle(.plain))
            .controlSize(.small)
        }
      }
      .padding(12)
    }
    .frame(width: 260, alignment: .leading)
    .clipShape(shape)
    .cardBackground(radius: 14)
    .overlay(shape.strokeBorder(selected ? Color.clear : AppTheme.accentText, lineWidth: 2))
    .focusable().focused($focusedFile, equals: file.id)
    .onKeyPress(.space) { preview = file.url; return .handled }
  }

  private func metaRow(_ key: String, value: String, number: Bool = false, emphasized: Bool = false) -> some View {
    HStack(spacing: 8) {
      Text(key)
        .foregroundStyle(AppTheme.ink3)
      Spacer(minLength: 6)
      Text(value)
        .font(number ? AppTheme.number(12, weight: .semibold) : .system(size: 12, weight: emphasized ? .semibold : .regular))
        .monospacedDigit()
        .foregroundStyle(AppTheme.ink)
        .lineLimit(1)
    }
    .font(.system(size: 12))
  }
}

struct PhotoComparisonSheet: View {
  let group: SimilarPhotoGroup
  @EnvironmentObject private var model: AppViewModel
  @Environment(\.dismiss) private var dismiss
  @State private var cloudPreviews: Set<String> = []

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      SheetHeader(
        symbol: "photo.on.rectangle.angled", swatch: .pink, eyebrow: "Compare similar photos",
        title: "Which one stays?",
        subtitle: "Each photo resembles the suggested keeper; similarity is not proof that a photo is unwanted. Library deletion syncs to your other devices. Restore library assets through Photos → Recently Deleted.")
      ScrollView(.horizontal) {
        LazyHStack(alignment: .top, spacing: 16) {
          ForEach(group.photos) { photo in
            photoCard(photo)
          }
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 14)
      }
      .frame(maxHeight: .infinity, alignment: .top)
      SheetFooter {
        Label("Removed library photos go to Photos' Recently Deleted.", systemImage: "arrow.uturn.backward.circle")
          .font(.system(size: 11.5))
          .foregroundStyle(AppTheme.ink2)
        Spacer()
        Button("Done") { dismiss() }
          .buttonStyle(MintButtonStyle(.commit))
          .keyboardShortcut(.cancelAction)
      }
    }
    .frame(width: 820, height: 620)
    .background(AppTheme.elevated)
  }

  private func photoCard(_ photo: PhotoFingerprint) -> some View {
    let isKeeper = model.keeper(of: group).id == photo.id
    let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
    return VStack(alignment: .leading, spacing: 8) {
      PhotoThumbnail(photo: photo, side: 320, allowCloud: cloudPreviews.contains(photo.id))
        .frame(width: 320, height: 240).clipped()
        .clipShape(shape)
        .overlay(shape.strokeBorder(isKeeper ? AppTheme.accentText : Color.clear, lineWidth: 3))
        .overlay(alignment: .topLeading) {
          if isKeeper {
            Chip(title: "KEEP", symbol: "star.fill", swatch: .mint)
              .padding(10)
          }
        }
      Text(photo.isLibraryAsset ? "Photos library asset" : photo.url.path)
        .font(.system(size: 11.5, design: .monospaced))
        .foregroundStyle(AppTheme.ink2)
        .lineLimit(2)
        .truncationMode(.middle)
        .textSelection(.enabled)
      Text("\(photo.pixelWidth) × \(photo.pixelHeight)")
        .font(AppTheme.number(12, weight: .semibold))
        .monospacedDigit()
        .foregroundStyle(AppTheme.ink3)
      if isKeeper {
        Label("Suggested keeper", systemImage: "star")
          .font(.system(size: 12.5, weight: .semibold))
          .foregroundStyle(AppTheme.accentText)
      } else {
        HStack(spacing: 12) {
          Button("Keep this photo") { model.keepInstead(photo) }
            .buttonStyle(MintButtonStyle(.secondary))
          Toggle("Select for removal", isOn: Binding(
            get: { model.selectedPhotoIDs.contains(photo.id) },
            set: { _ in model.togglePhoto(photo) }))
            .toggleStyle(MintCheckboxStyle())
            .font(.system(size: 12.5))
            .foregroundStyle(AppTheme.ink)
        }
      }
      if photo.isLibraryAsset && !cloudPreviews.contains(photo.id) {
        Button("Allow iCloud download for this preview") { cloudPreviews.insert(photo.id) }
          .buttonStyle(MintButtonStyle(.plain))
          .controlSize(.small)
      }
    }
    .frame(width: 320, alignment: .leading)
  }
}
