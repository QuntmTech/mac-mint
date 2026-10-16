import MacCleanerCore
import SwiftUI

/// A gesture changes the review queue only. Existing folder/PhotoKit review executes removal.
struct PhotoReviewDeck: View {
  let photos: [PhotoFingerprint]
  @EnvironmentObject private var model: AppViewModel
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var cursor = 0
  @State private var trail: [(index: Int, selected: Bool)] = []
  @State private var drag: CGFloat = 0
  @State private var comparing: SimilarPhotoGroup?
  @State private var cloudPreview = false
  @State private var message: String?

  private var current: PhotoFingerprint? { photos.indices.contains(cursor) ? photos[cursor] : nil }
  private var group: SimilarPhotoGroup? { current.flatMap { model.group(containing: $0) } }
  private var isKeeper: Bool { current.map { photo in group.map { model.keeper(of: $0).id == photo.id } ?? false } ?? false }

  var body: some View {
    VStack(spacing: 10) {
      HStack {
        Label("One photo at a time", systemImage: "rectangle.stack") .font(.headline)
        Spacer()
        Text("\(min(cursor + 1, photos.count)) of \(photos.count.formatted())")
          .font(.callout.monospacedDigit()).foregroundStyle(.secondary)
      }
      ProgressView(value: Double(cursor), total: Double(max(1, photos.count)))
        .tint(AppTheme.accent)
        .accessibilityLabel("Review progress")
      if let photo = current {
        GeometryReader { geometry in
          PhotoThumbnail(photo: photo, side: min(600, max(100, geometry.size.width)), allowCloud: cloudPreview, fit: true)
            .frame(width: geometry.size.width, height: geometry.size.height)
            .clipped()
            .background(AppTheme.panel)
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .offset(x: reduceMotion ? 0 : drag * 0.25)
            .overlay(alignment: .topLeading) {
              if abs(drag) > 35 {
                Label(drag < 0 ? "Queue removal" : "Keep", systemImage: drag < 0 ? "tray" : "heart")
                  .font(.headline).padding(12).background(AppTheme.surface, in: Capsule()).padding(12)
                  .foregroundStyle(drag < 0 ? AppTheme.danger : AppTheme.accentText)
              }
            }
            .gesture(DragGesture(minimumDistance: 20)
              .onChanged { drag = $0.translation.width }
              .onEnded { value in
                drag = 0
                if value.translation.width < -80 { decide(remove: true) }
                else if value.translation.width > 80 { decide(remove: false) }
              })
        }
        .frame(maxHeight: .infinity)
        VStack(spacing: 4) {
          Text(photo.isLibraryAsset ? (photo.captured?.formatted(date: .abbreviated, time: .shortened) ?? "Library photo") : photo.url.lastPathComponent)
            .font(.headline).lineLimit(1).help(photo.isLibraryAsset ? "Photos library asset" : photo.url.path)
          Text("\(photo.pixelWidth) × \(photo.pixelHeight) · \(photo.isLibraryAsset ? "Library size unavailable" : ByteFormatter.string(photo.bytes))")
            .font(.caption).foregroundStyle(.secondary)
          HStack {
            if isKeeper { Label("Protected keeper", systemImage: "star.fill").foregroundStyle(AppTheme.accentText) }
            if let group { Button("Compare \(group.photos.count) shots") { comparing = group }.controlSize(.small) }
            if photo.isLibraryAsset && !cloudPreview {
              Button("Load cloud preview") { cloudPreview = true }.controlSize(.small)
            }
          }.font(.caption)
        }
      } else {
        EmptyState(icon: "checkmark.circle", title: photos.isEmpty ? "No photos to review" : "You've reached the end",
          detail: "Your choices are in the review queue. Inspect them before anything is removed.")
      }
      if let message { Text(message).font(.caption).foregroundStyle(AppTheme.warning).accessibilityAddTraits(.updatesFrequently) }
    }
    .padding(16)
    .safeAreaInset(edge: .bottom, spacing: 0) { controls }
    .focusable()
    .onKeyPress(.leftArrow) { decide(remove: true); return .handled }
    .onKeyPress(.rightArrow) { decide(remove: false); return .handled }
    .onKeyPress("z") { undo(); return .handled }
    .sheet(item: $comparing) { PhotoComparisonSheet(group: $0) }
  }

  private var controls: some View {
    VStack(spacing: 8) {
      HStack(spacing: 10) {
        Button { undo() } label: { Label("Undo choice", systemImage: "arrow.uturn.backward") }
          .disabled(trail.isEmpty || model.isWorking || model.isScanning)
        Spacer(minLength: 0)
        Button { decide(remove: true) } label: { Label("Queue removal", systemImage: "arrow.left") }
          .disabled(current == nil || isKeeper || model.isWorking || model.isScanning)
        Button { decide(remove: false) } label: { Label("Keep", systemImage: "arrow.right") }
          .buttonStyle(MintButtonStyle()).disabled(current == nil || model.isWorking || model.isScanning)
      }
      Text("Swipe left to queue, right to keep. Nothing is removed until you review and confirm.")
        .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
    }
    .padding(14)
    .frame(maxWidth: .infinity)
    .background(AppTheme.surface)
    .overlay(alignment: .top) { Divider() }
    .background(GeometryReader { geometry in Color.clear.preference(key: WorkspaceLayoutFrames.self,
      value: ["photo choices": geometry.frame(in: .global)]) })
  }

  private func decide(remove: Bool) {
    guard let photo = current, !model.isWorking, !model.isScanning else { return }
    if remove && isKeeper { message = "Choose a different keeper in Compare before queuing this photo."; return }
    let before = model.selectedPhotoIDs.contains(photo.id)
    if before != remove { model.togglePhoto(photo) }
    guard model.selectedPhotoIDs.contains(photo.id) == remove else { message = model.statusMessage; return }
    trail.append((cursor, before)); cursor += 1; cloudPreview = false; message = nil
  }

  private func undo() {
    guard !model.isWorking, !model.isScanning, let previous = trail.last else { return }
    let photo = photos[previous.index]
    if model.selectedPhotoIDs.contains(photo.id) != previous.selected { model.togglePhoto(photo) }
    guard model.selectedPhotoIDs.contains(photo.id) == previous.selected else { message = model.statusMessage; return }
    trail.removeLast(); cursor = previous.index; cloudPreview = false; message = nil
  }
}
