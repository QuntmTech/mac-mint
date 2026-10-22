import MacCleanerCore
import SwiftUI

/// A gesture changes the review queue only. Existing folder/PhotoKit review executes removal.
struct PhotoReviewDeck: View {
  @EnvironmentObject private var model: AppViewModel
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var drag: CGFloat = 0
  @State private var comparing: SimilarPhotoGroup?
  @State private var cloudPreview = false
  @State private var message: String?
  @State private var previewID: String?
  @FocusState private var keyboardFocus: Bool

  /// The deck keeps the Photos color, also when it is shown on its own.
  private let swatch = AppTheme.Swatch.pink

  private var photos: [PhotoFingerprint] { model.allScannedPhotos }
  private var cursor: Int { model.photoReviewSession.cursor }
  private var busy: Bool { model.isWorking || model.isScanning || model.isPreparingPlan }
  private var current: PhotoFingerprint? { photos.indices.contains(cursor) ? photos[cursor] : nil }
  private var previewReady: Bool { current != nil && previewID == current?.id }
  private var group: SimilarPhotoGroup? { current.flatMap { model.group(containing: $0) } }
  private var isKeeper: Bool { current.map { photo in group.map { model.keeper(of: $0).id == photo.id } ?? false } ?? false }

  var body: some View {
    VStack(spacing: 0) {
      GeometryReader { geometry in
        deckBody(roomy: geometry.size.height >= 360)
          .frame(width: geometry.size.width, height: geometry.size.height, alignment: .top)
      }
      controls
    }
    .focusable()
    .focusEffectDisabled()
    .focused($keyboardFocus)
    .onAppear { keyboardFocus = true }
    .onChange(of: current?.id) { _, _ in drag = 0; cloudPreview = false; keyboardFocus = true }
    .onKeyPress(.leftArrow) { guard !busy else { return .ignored }; decide(remove: true); return .handled }
    .onKeyPress(.rightArrow) { guard !busy else { return .ignored }; decide(remove: false); return .handled }
    .onKeyPress("z") { guard !busy else { return .ignored }; undo(); return .handled }
    .sheet(item: $comparing) { PhotoComparisonSheet(group: $0) }
  }

  /// `roomy` adds the filmstrip when there is height for it.
  private func deckBody(roomy: Bool) -> some View {
    VStack(spacing: 10) {
      topBar
      progressBar
      if let photo = current {
        stage(photo)
        details(photo)
        if roomy && photos.count > 1 { filmstrip }
      } else {
        finished
      }
      if let message {
        Label(message, systemImage: "exclamationmark.triangle.fill")
          .font(.system(size: 12)).foregroundStyle(AppTheme.warning)
          .fixedSize(horizontal: false, vertical: true)
          .accessibilityAddTraits(.updatesFrequently)
      }
    }
    .padding(.horizontal, 16)
    .padding(.top, 14)
    .padding(.bottom, 10)
  }

  // MARK: Top

  private var topBar: some View {
    HStack(spacing: 10) {
      SwatchBadge(symbol: "rectangle.stack", swatch: swatch, size: 24)
      Text("One photo at a time").font(.system(size: 13, weight: .semibold)).foregroundStyle(AppTheme.ink)
        .accessibilityAddTraits(.isHeader)
      Spacer(minLength: 8)
      if cursor > 0 {
        Button("Review from start") { model.restartPhotoReview(); cloudPreview = false; message = nil }
          .buttonStyle(MintButtonStyle(.secondary))
          .controlSize(.small).disabled(busy)
          .help("Restart browsing and clear Undo choices. Your queued photos stay selected.")
      }
      Text("\(min(cursor + 1, photos.count)) of \(photos.count.formatted())")
        .font(AppTheme.number(12.5, weight: .semibold)).monospacedDigit().foregroundStyle(AppTheme.ink2)
    }
  }

  private var progressFraction: Double {
    guard !photos.isEmpty else { return 0 }
    return min(1, max(0, Double(cursor) / Double(photos.count)))
  }

  private var progressBar: some View {
    let fraction = progressFraction
    return GeometryReader { geometry in
      Capsule().fill(AppTheme.track).overlay(alignment: .leading) {
        Capsule().fill(swatch.gradient).frame(width: fraction > 0 ? max(5, geometry.size.width * fraction) : 0)
      }
    }
    .frame(height: 5)
    .accessibilityElement()
    .accessibilityLabel("Review progress")
    .accessibilityValue("\(Int(fraction * 100)) percent")
  }

  // MARK: Photo

  private func stage(_ photo: PhotoFingerprint) -> some View {
    GeometryReader { geometry in
      PhotoThumbnail(photo: photo, side: min(600, max(100, geometry.size.width)), allowCloud: cloudPreview, fit: true,
        onAvailability: { available in
          if current?.id == photo.id { previewID = available ? photo.id : nil }
        })
        .id(photo.id)
        .frame(width: geometry.size.width, height: geometry.size.height)
        .clipped()
        .background(AppTheme.panel)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(alignment: .bottomLeading) { statusTag.padding(10) }
        .offset(x: reduceMotion ? 0 : drag * 0.25)
        .overlay(alignment: .topLeading) {
          if abs(drag) > 35 {
            Label(drag < 0 ? (isKeeper ? "Keeper protected" : "Queue removal") : "Keep",
              systemImage: drag < 0 ? (isKeeper ? "star.fill" : "tray") : "heart")
              .font(.system(size: 13, weight: .semibold))
              .padding(.horizontal, 12).frame(height: 30)
              .background(AppTheme.elevated, in: Capsule())
              .elevation(.floating)
              .padding(12)
              .foregroundStyle(drag < 0 ? (isKeeper ? AppTheme.warning : AppTheme.danger) : swatch.text)
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
  }

  @ViewBuilder
  private var statusTag: some View {
    if isKeeper {
      tag("Protected keeper", symbol: "star.fill", fill: AppTheme.accent)
    } else if let photo = current, model.selectedPhotoIDs.contains(photo.id) {
      tag("Already queued for removal", symbol: "tray.full.fill", fill: AppTheme.Swatch.amber.color)
    }
  }

  private func tag(_ title: String, symbol: String, fill: Color) -> some View {
    Label(title, systemImage: symbol)
      .font(.system(size: 11, weight: .semibold))
      .foregroundStyle(.white)
      .lineLimit(1)
      .padding(.horizontal, 9)
      .frame(height: 22)
      .background(fill, in: Capsule())
      .shadow(color: .black.opacity(0.2), radius: 3, y: 1)
  }

  private func details(_ photo: PhotoFingerprint) -> some View {
    ViewThatFits(in: .horizontal) {
      HStack(spacing: 12) {
        info(photo)
        Spacer(minLength: 8)
        photoActions(photo)
      }
      VStack(alignment: .leading, spacing: 6) {
        info(photo)
        photoActions(photo)
      }
    }
  }

  private func info(_ photo: PhotoFingerprint) -> some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(photo.isLibraryAsset ? (photo.captured?.formatted(date: .abbreviated, time: .shortened) ?? "Library photo") : photo.url.lastPathComponent)
        .font(.system(size: 13, weight: .semibold)).foregroundStyle(AppTheme.ink)
        .lineLimit(1).truncationMode(.middle)
        .help(photo.isLibraryAsset ? "Photos library asset" : photo.url.path)
      Text("\(photo.pixelWidth) × \(photo.pixelHeight) · \(photo.isLibraryAsset ? "Library size unavailable" : ByteFormatter.string(photo.bytes))")
        .font(.system(size: 11.5)).foregroundStyle(AppTheme.ink3).monospacedDigit().lineLimit(1)
    }
  }

  private func photoActions(_ photo: PhotoFingerprint) -> some View {
    HStack(spacing: 6) {
      if let group { Button("Compare \(group.photos.count) shots") { comparing = group } }
      if photo.isLibraryAsset && !cloudPreview {
        Button("Load cloud preview") { cloudPreview = true }
      }
      if photo.isLibraryAsset && !previewReady {
        Button("Open Photos") { PhotoLibraryService.showInPhotos() }
      }
      if !photo.isLibraryAsset {
        Button("Reveal in Finder") { model.reveal(photo.url) }
      }
    }
    .buttonStyle(MintButtonStyle(.secondary))
    .controlSize(.small)
  }

  // MARK: Filmstrip

  /// Up to seven neighbours around the current photo. Display only; the arrows move through it.
  private var filmstripIndices: [Int] {
    let count = photos.count
    guard count > 0 else { return [] }
    let lower = max(0, min(cursor - 3, count - 7))
    let upper = min(count, lower + 7)
    return Array(lower..<upper)
  }

  private var filmstrip: some View {
    HStack(spacing: 6) {
      ForEach(filmstripIndices, id: \.self) { index in
        filmFrame(index)
      }
    }
    .frame(maxWidth: .infinity)
    .frame(height: 32)
    .accessibilityHidden(true)
  }

  private func filmFrame(_ index: Int) -> some View {
    let photo = photos[index]
    let shape = RoundedRectangle(cornerRadius: 6, style: .continuous)
    let isCurrent = index == cursor
    return PhotoThumbnail(photo: photo, side: 64, quiet: true)
      .frame(width: 44, height: 32)
      .clipShape(shape)
      .overlay { shape.strokeBorder(isCurrent ? swatch.color : AppTheme.border, lineWidth: isCurrent ? 2 : 0.5) }
      .overlay(alignment: .topTrailing) {
        if model.selectedPhotoIDs.contains(photo.id) {
          Circle().fill(AppTheme.Swatch.amber.color)
            .overlay(Circle().strokeBorder(Color.white, lineWidth: 1))
            .frame(width: 8, height: 8)
            .padding(3)
        }
      }
      .opacity(index < cursor ? 0.5 : 1)
  }

  // MARK: Finished

  private var finished: some View {
    VStack(spacing: 10) {
      SwatchBadge(symbol: photos.isEmpty ? "photo.on.rectangle.angled" : "checkmark.circle", swatch: swatch, size: 56, glow: true)
        .padding(.bottom, 4)
      Text(photos.isEmpty ? "No photos to review" : "You've reached the end")
        .font(.system(size: 19, weight: .bold)).tracking(-0.3).foregroundStyle(AppTheme.ink)
        .multilineTextAlignment(.center)
        .accessibilityAddTraits(.isHeader)
      Text(model.selectedPhotoIDs.isEmpty
        ? "No photos are queued for removal. Your kept photos stay where they are."
        : "Your choices are in the review queue. Inspect them before anything is removed.")
        .font(.system(size: 13)).foregroundStyle(AppTheme.ink2)
        .multilineTextAlignment(.center)
        .frame(maxWidth: 400)
        .fixedSize(horizontal: false, vertical: true)
      if !model.selectedPhotoIDs.isEmpty {
        Button {
          model.reviewPhotos()
        } label: {
          Label("Review \(model.selectedPhotoIDs.count) queued photos", systemImage: "checklist")
        }
        .buttonStyle(MintButtonStyle(.commit))
        .disabled(busy)
        .padding(.top, 4)
      }
    }
    .padding(16)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  // MARK: Controls

  private var controls: some View {
    VStack(spacing: 6) {
      HStack(spacing: 10) {
        Button { undo() } label: { Label("Undo choice", systemImage: "arrow.uturn.backward") }
          .buttonStyle(MintButtonStyle(.secondary))
          .disabled(model.photoReviewSession.choices.isEmpty || busy)
          .help("Undo the last review choice · Z")
        if current != nil {
          Button { decide(remove: true) } label: { bigLabel("Remove", symbol: "trash", key: "←") }
            .buttonStyle(DeckButtonStyle(prominent: false, swatch: swatch))
            .disabled(current == nil || isKeeper || busy || !previewReady)
            .help(isKeeper ? "Choose another keeper in Compare first" : "Queue this photo for review · ←")
            .accessibilityLabel("Queue removal")
          Button { decide(remove: false) } label: {
            bigLabel(previewReady ? "Keep" : "Skip", symbol: previewReady ? "heart.fill" : "forward.fill", key: "→")
          }
          .buttonStyle(DeckButtonStyle(prominent: true, swatch: swatch))
          .disabled(current == nil || busy)
        } else {
          Spacer(minLength: 0)
        }
      }
      Text(current == nil
        ? "Press Z to undo your last choice. Nothing is removed until you review and confirm."
        : "Swipe or use ← to queue, → to keep, and Z to undo. Review and confirm before removal.")
        .font(.system(size: 11.5)).foregroundStyle(AppTheme.ink3).multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 12)
    .frame(maxWidth: .infinity)
    .background(AppTheme.surface)
    .overlay(alignment: .top) { Rectangle().fill(AppTheme.divider).frame(height: 1) }
    .background(GeometryReader { geometry in Color.clear.preference(key: WorkspaceLayoutFrames.self,
      value: ["photo choices": geometry.frame(in: .global)]) })
  }

  private func bigLabel(_ title: String, symbol: String, key: String) -> some View {
    HStack(spacing: 8) {
      Image(systemName: symbol).font(.system(size: 15, weight: .semibold))
      Text(title)
      Text(key).font(.system(size: 11, weight: .medium)).opacity(0.7)
    }
  }

  private func decide(remove: Bool) {
    if remove && !previewReady { message = "Load a preview before queuing removal, or Skip to the next photo."; return }
    let before = cursor
    message = model.decidePhotoReview(removing: remove)
    if cursor != before { cloudPreview = false }
  }

  private func undo() {
    let before = cursor
    message = model.undoPhotoReview()
    if cursor != before { cloudPreview = false }
  }
}

/// The deck's two big choices: Remove (white with a border) and Keep (Photos pink).
private struct DeckButtonStyle: ButtonStyle {
  let prominent: Bool
  let swatch: AppTheme.Swatch

  func makeBody(configuration: Configuration) -> some View {
    DeckButtonFace(prominent: prominent, swatch: swatch, configuration: configuration)
  }
}

private struct DeckButtonFace: View {
  let prominent: Bool
  let swatch: AppTheme.Swatch
  let configuration: ButtonStyleConfiguration
  @Environment(\.isEnabled) private var isEnabled
  @Environment(\.colorSchemeContrast) private var contrast
  @State private var hovering = false

  var body: some View {
    let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
    configuration.label
      .font(.system(size: 14, weight: .semibold))
      .lineLimit(1)
      .foregroundStyle(prominent ? Color.white : AppTheme.ink)
      .frame(maxWidth: .infinity)
      .frame(height: 44)
      .background {
        if prominent {
          shape.fill(swatch.fill)
        } else {
          shape.fill(hovering && isEnabled ? AppTheme.panel : AppTheme.surface)
        }
      }
      .overlay {
        if prominent {
          shape.strokeBorder(Color.white.opacity(0.16), lineWidth: 0.5)
        } else {
          shape.strokeBorder(contrast == .increased ? AppTheme.ink.opacity(0.6) : AppTheme.border,
            lineWidth: contrast == .increased ? 2 : 1)
        }
      }
      .contentShape(shape)
      .brightness(configuration.isPressed ? -0.06 : (hovering && isEnabled && prominent ? 0.05 : 0))
      .scaleEffect(configuration.isPressed ? 0.99 : 1)
      .opacity(isEnabled ? 1 : 0.4)
      .onHover { hovering = $0 }
  }
}
