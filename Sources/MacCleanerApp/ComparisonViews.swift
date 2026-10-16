import MacCleanerCore
import QuickLook
import SwiftUI

struct DuplicateComparisonSheet: View {
  let group: DuplicateGroup
  @EnvironmentObject private var model: AppViewModel
  @Environment(\.dismiss) private var dismiss
  @State private var preview: URL?
  @FocusState private var focusedFile: UUID?

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      Text("Compare identical copies").font(.title2.bold())
      Text("Content matches by SHA-256. Hard links share one physical file; APFS clones may share storage too, so eventual savings can be lower than file sizes.")
        .font(.callout).foregroundStyle(.secondary)
      ScrollView(.horizontal) {
        HStack(alignment: .top, spacing: 20) {
          ForEach(group.files) { file in
            VStack(alignment: .leading, spacing: 8) {
              FileThumbnail(url: file.url, size: 180)
              Text(file.url.path).font(.caption).textSelection(.enabled)
              Text(file.modifiedAt.map { "Last changed: " + $0.formatted() } ?? "Last change unknown").font(.caption)
              Text(model.selectedDuplicateIDs.contains(file.id) ? "Selected for removal" : "Kept: not selected").font(.callout.weight(.medium))
              Button("Keep this copy") {
                model.selectedDuplicateIDs.subtract(group.files.map(\.id))
                model.selectedDuplicateIDs.formUnion(group.files.filter {
                  $0.id != file.id && (file.identity == nil || $0.identity != file.identity)
                }.map(\.id))
              }
              Button("Preview (Space)") { preview = file.url }
              Button("Reveal in Finder") { model.reveal(file.url) }
            }.frame(width: 260, alignment: .leading)
              .focusable().focused($focusedFile, equals: file.id)
              .onKeyPress(.space) { preview = file.url; return .handled }
          }
        }.padding(.vertical, 8)
      }
      Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
    }.padding(24).frame(width: 820, height: 550)
      .quickLookPreview($preview, in: group.files.map(\.url))
  }
}

struct PhotoComparisonSheet: View {
  let group: SimilarPhotoGroup
  @EnvironmentObject private var model: AppViewModel
  @Environment(\.dismiss) private var dismiss
  @State private var cloudPreviews: Set<String> = []

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      Text("Compare similar photos").font(.title2.bold())
      Text("Each photo resembles the suggested keeper; similarity is not proof that a photo is unwanted. Library deletion syncs to your other devices. Restore library assets through Photos → Recently Deleted.")
        .font(.callout).foregroundStyle(.secondary)
      ScrollView(.horizontal) {
        HStack(alignment: .top, spacing: 20) {
          ForEach(group.photos) { photo in
            VStack(alignment: .leading, spacing: 8) {
              PhotoThumbnail(photo: photo, side: 320, allowCloud: cloudPreviews.contains(photo.id))
                .frame(width: 320, height: 300).clipped()
              Text(photo.isLibraryAsset ? "Photos library asset" : photo.url.path).font(.caption).textSelection(.enabled)
              Text("\(photo.pixelWidth) × \(photo.pixelHeight)").font(.caption)
              if model.keeper(of: group).id == photo.id {
                Label("Suggested keeper", systemImage: "star").foregroundStyle(AppTheme.accentText)
              } else {
                Button("Keep this photo") { model.keepInstead(photo) }
                Toggle("Select for removal", isOn: Binding(
                  get: { model.selectedPhotoIDs.contains(photo.id) },
                  set: { _ in model.togglePhoto(photo) }))
              }
              if photo.isLibraryAsset && !cloudPreviews.contains(photo.id) {
                Button("Allow iCloud download for this preview") { cloudPreviews.insert(photo.id) }
                  .font(.caption)
              }
            }.frame(width: 320, alignment: .leading)
          }
        }.padding(.vertical, 8)
      }
      Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
    }.padding(24).frame(width: 820, height: 590)
  }
}
