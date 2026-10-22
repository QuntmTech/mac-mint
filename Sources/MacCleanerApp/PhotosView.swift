import AppKit
import ImageIO
import MacCleanerCore
import SwiftUI

struct PhotosView: View {
  @EnvironmentObject private var model: AppViewModel
  @Environment(\.areaSwatch) private var swatch
  @State private var comparing: SimilarPhotoGroup?
  @StateObject private var permissions = PermissionsService()
  @SceneStorage("photos.tab") private var tab: PhotoTab = .similar

  private var isLibrary: Bool { model.photoSource == .library }

  private static let libraryFootnote = "Removed library photos go to Photos' Recently Deleted."
  private static let folderFootnote = "Removed photos go to the Trash. You can put them back from History."

  var body: some View {
    VStack(spacing: 0) {
      header
      notices
      if model.isScanning && model.operationTitle == "Photos" {
        progress
      } else if isLibrary && (permissions.photos == .notRequested || permissions.photos.requiresSettings) {
        libraryAccess
      } else if let scan = model.photoScan {
        results(scan)
      } else {
        EmptyState(
          icon: "photo.on.rectangle.angled", title: "Make room for your best shots",
          detail:
            "Check your Photos library or any folder. Nothing is selected for you. Compare each set and choose the copy to keep.",
          actionTitle: isLibrary ? "Scan Photos Library" : "Scan photos", action: startScan,
          secondaryTitle: "Choose Folder…", secondaryAction: { model.choosePhotoFolder() },
          trust: isLibrary ? Self.libraryFootnote : TrustLine.scanning)
      }
    }
    .sheet(item: $comparing) { group in PhotoComparisonSheet(group: group) }
    .onAppear { if isLibrary && tab == .screenshots { tab = .similar } }
    .task { await permissions.refresh() }
    .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
      Task { await permissions.refresh() }
    }
    .onChange(of: model.isScanning) { _, scanning in
      if !scanning { Task { await permissions.refresh() } }
    }
    .onChange(of: model.photoSource) { _, source in
      if source == .library && tab == .screenshots { tab = .similar }
    }
  }

  // MARK: Header

  private var scanTitle: String {
    isLibrary && permissions.photos.requiresSettings ? "Photos Settings" : model.photoScan == nil ? "Scan" : "Rescan"
  }

  private var header: some View {
    PageHeader(title: "Photos", subtitle: isLibrary
      ? "Compare your library. Deletion syncs to iCloud and other devices; recovery is through Photos."
      : "Compare folder photos. Reviewed removals go to Trash, with recovery in History.") {
      if !model.selectedPhotoIDs.isEmpty {
        Button {
          model.reviewPhotos()
        } label: {
          Label(
            isLibrary
              ? "Review \(model.selectedPhotoIDs.count) photos"
              : "Review \(model.selectedPhotoIDs.count) (\(ByteFormatter.string(model.selectedPhotoBytes)))",
            systemImage: "checklist")
        }
        .buttonStyle(MintButtonStyle(.commit))
        .disabled(model.isWorking || model.isScanning)
      }
      Menu {
        Button("Photos Library") {
          model.photoSource = .library
          startScan()
        }
        Button("Choose Folder…") { model.choosePhotoFolder() }
      } label: {
        Label(model.photoSource.title, systemImage: isLibrary ? "photo.stack" : "folder")
      }
      .fixedSize()
      .disabled(model.isScanning || model.isWorking)
      Button(action: startScan) {
        Label(scanTitle, systemImage: isLibrary && permissions.photos.requiresSettings ? "gearshape" : "magnifyingglass")
      }
      .buttonStyle(MintButtonStyle(.area))
      .disabled(model.isScanning || model.isWorking)
    }
    .padding(.horizontal, AppTheme.pagePadding)
    .padding(.top, AppTheme.pageTopPadding)
    .padding(.bottom, 14)
  }

  @ViewBuilder
  private var notices: some View {
    if isLibrary && permissions.photos == .limited {
      Label("Only the Photos assets you shared are included in this scan.", systemImage: "photo.badge.checkmark")
        .font(.system(size: 12)).foregroundStyle(AppTheme.ink2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, AppTheme.pagePadding).padding(.bottom, 10)
    }
    if let error = model.photoDeletionError {
      Label(error, systemImage: "exclamationmark.triangle.fill")
        .font(.system(size: 12.5)).foregroundStyle(AppTheme.warning)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12).padding(.vertical, 9)
        .background(AppTheme.warningTint, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .padding(.horizontal, AppTheme.pagePadding).padding(.bottom, 10)
    }
  }

  private func startScan() {
    if isLibrary && permissions.photos.requiresSettings {
      permissions.open(.photos)
    } else {
      model.scanPhotos()
    }
  }

  private var libraryAccess: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 14) {
        HStack(alignment: .top, spacing: 14) {
          SwatchBadge(symbol: "photo.badge.checkmark", swatch: swatch, size: 44, glow: true)
          VStack(alignment: .leading, spacing: 4) {
            Text(permissions.photos == .notRequested ? "Choose access to your Photos library" : permissions.photos.title)
              .font(.system(size: 17, weight: .bold)).tracking(-0.3).foregroundStyle(AppTheme.ink)
            Text(permissions.photos.detail).font(.system(size: 13)).foregroundStyle(AppTheme.ink2)
          }
        }
        Text("Analysis uses local thumbnails. Photos deletions require your review and Photos confirmation, sync to other iCloud devices, and are recovered in Photos.")
          .font(.system(size: 12.5)).foregroundStyle(AppTheme.ink2)
        HStack(spacing: 8) {
          Button(permissions.photos == .notRequested ? "Continue & Scan" : "Open Photos Settings", action: startScan)
            .buttonStyle(MintButtonStyle(.area))
          Button("Choose a Photo Folder…") { model.choosePhotoFolder() }
            .buttonStyle(MintButtonStyle(.secondary))
        }
        .disabled(model.isWorking || model.isScanning)
        Text(PermissionSettingsPane.photos.path).font(.system(size: 11.5)).foregroundStyle(AppTheme.ink3)
        if let error = permissions.settingsError {
          Text(error).font(.system(size: 12.5)).foregroundStyle(AppTheme.warning)
        }
      }
      .fixedSize(horizontal: false, vertical: true)
      .padding(AppTheme.cardPadding)
      .frame(maxWidth: 620, alignment: .leading)
      .cardBackground()
      .padding(AppTheme.pagePadding)
      .frame(maxWidth: .infinity, alignment: .center)
    }
  }

  private var progress: some View {
    let counts = model.photoProgress
    let known = (counts?.total ?? 0) > 0
    let fraction: Double? = known ? Double(counts?.done ?? 0) / Double(max(1, counts?.total ?? 1)) : nil
    let status: String? = known
      ? "\((counts?.done ?? 0).formatted()) of \((counts?.total ?? 0).formatted()) photos" : nil
    return LoadingState(
      title: "Looking at your photos…",
      detail: "Analysis uses local thumbnails. Default previews stay local; a cloud preview downloads only when you request it.",
      symbol: "photo.on.rectangle.angled",
      progress: fraction,
      status: status,
      cancel: { model.cancelCurrentOperation() })
  }

  // MARK: Results

  @ViewBuilder
  private func results(_ scan: PhotoScanResult) -> some View {
    if tab == .deck {
      VStack(alignment: .leading, spacing: 12) {
        kindTiles(scan, compact: true)
        sectionBar(scan)
      }
      .frame(maxWidth: 1180)
      .padding(.horizontal, AppTheme.pagePadding)
      .frame(maxWidth: .infinity)
      PhotoReviewDeck().id(scan.generation)
    } else {
      ScrollView {
        VStack(alignment: .leading, spacing: 14) {
          kindTiles(scan, compact: false)
          sectionBar(scan)
          content(scan)
          footnote
        }
        .frame(maxWidth: 1180)
        .padding(.horizontal, AppTheme.pagePadding)
        .padding(.top, 2)
        .padding(.bottom, 24)
        .frame(maxWidth: .infinity)
      }
    }
  }

  private var tileTabs: [PhotoTab] { isLibrary ? [.similar, .blurry] : [.similar, .screenshots, .blurry] }

  private func kindTiles(_ scan: PhotoScanResult, compact: Bool) -> some View {
    HStack(spacing: 12) {
      ForEach(tileTabs) { kind in
        PhotoKindTile(
          title: kindTitle(kind), detail: kindDetail(kind, scan: scan), count: kindCount(kind, scan: scan),
          symbol: kindSymbol(kind), swatch: kindSwatch(kind), selected: tab == kind, compact: compact
        ) { tab = kind }
      }
    }
  }

  private func kindTitle(_ kind: PhotoTab) -> String {
    switch kind {
    case .deck: return "Review deck"
    case .similar: return "Similar shots"
    case .blurry: return "Blurry"
    case .screenshots: return "Screenshots"
    }
  }

  private func kindCount(_ kind: PhotoTab, scan: PhotoScanResult) -> Int {
    switch kind {
    case .deck: return scan.photos.count
    case .similar: return scan.similarGroups.reduce(0) { $0 + $1.others.count }
    case .blurry: return scan.blurry.count
    case .screenshots: return scan.screenshots.count
    }
  }

  private func kindDetail(_ kind: PhotoTab, scan: PhotoScanResult) -> String {
    switch kind {
    case .deck:
      return "One at a time"
    case .similar:
      let groups = scan.similarGroups.count
      return "\(groups) group\(groups == 1 ? "" : "s") to compare"
    case .blurry:
      return "Judged against this set"
    case .screenshots:
      let bytes = scan.screenshots.reduce(Int64(0)) { $0 + $1.bytes }
      return "\(ByteFormatter.string(bytes)) in total"
    }
  }

  private func kindSymbol(_ kind: PhotoTab) -> String {
    switch kind {
    case .deck: return "rectangle.stack"
    case .similar: return "photo.stack"
    case .blurry: return "camera.aperture"
    case .screenshots: return "camera.viewfinder"
    }
  }

  private func kindSwatch(_ kind: PhotoTab) -> AppTheme.Swatch {
    switch kind {
    case .deck: return .pink
    case .similar: return .pink
    case .blurry: return .violet
    case .screenshots: return .indigo
    }
  }

  private func sectionName(_ scan: PhotoScanResult) -> String {
    switch tab {
    case .deck: return "All photos"
    case .similar: return "Similar shots"
    case .blurry: return "Blurry photos"
    case .screenshots: return "Screenshots"
    }
  }

  private func sectionDetail(_ scan: PhotoScanResult) -> String {
    switch tab {
    case .deck:
      return "\(scan.photos.count.formatted()) photos · one at a time"
    case .similar:
      let groups = scan.similarGroups.count
      return "\(groups) group\(groups == 1 ? "" : "s") · best shot picked by sharpness"
    case .blurry:
      return "\(scan.blurry.count) photo\(scan.blurry.count == 1 ? "" : "s") · blur is judged against this set"
    case .screenshots:
      return "\(scan.screenshots.count) screenshot\(scan.screenshots.count == 1 ? "" : "s")"
    }
  }

  private func sectionTitle(_ scan: PhotoScanResult) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 10) {
      Text(sectionName(scan)).font(.system(size: 16, weight: .bold)).tracking(-0.25).foregroundStyle(AppTheme.ink)
        .accessibilityAddTraits(.isHeader)
      Text(sectionDetail(scan)).font(.system(size: 12)).foregroundStyle(AppTheme.ink3).monospacedDigit().lineLimit(1)
    }
  }

  private func sectionBar(_ scan: PhotoScanResult) -> some View {
    ViewThatFits(in: .horizontal) {
      HStack(spacing: 10) {
        sectionTitle(scan)
        Spacer(minLength: 8)
        sectionActions(scan)
      }
      VStack(alignment: .leading, spacing: 8) {
        sectionTitle(scan)
        sectionActions(scan)
      }
    }
  }

  private func sectionActions(_ scan: PhotoScanResult) -> some View {
    HStack(spacing: 8) {
      bulkSelectionBar(scan)
      if tab != .deck {
        Button { tab = .deck } label: { Label("Review One by One", systemImage: "rectangle.stack") }
          .buttonStyle(SoftAreaButtonStyle())
          .controlSize(.small)
          .help("See every photo on its own. ← queues it for review, → keeps it.")
      }
    }
  }

  // MARK: Content

  private func photos(in scan: PhotoScanResult) -> [PhotoFingerprint] {
    switch tab {
    case .deck: return scan.photos
    case .similar: return scan.similarGroups.flatMap(\.photos)
    case .blurry: return scan.blurry
    case .screenshots: return scan.screenshots
    }
  }

  private func bulkSelectionBar(_ scan: PhotoScanResult) -> some View {
    let current = photos(in: scan)
    return HStack(spacing: 8) {
      Text("\(model.selectedPhotoIDs.count) selected").font(AppTheme.number(12, weight: .semibold)).monospacedDigit()
        .foregroundStyle(AppTheme.ink2)
      HStack(spacing: 6) {
        Button(tab == .similar ? "Select other copies" : "Select all in tab") { model.setPhotoSelection(current, selected: true) }
          .disabled(current.isEmpty)
        Button("Deselect tab") { model.setPhotoSelection(current, selected: false) }
          .disabled(!current.contains { model.selectedPhotoIDs.contains($0.id) })
        Button("Deselect all") { model.setPhotoSelection(scan.photos, selected: false) }
          .disabled(model.selectedPhotoIDs.isEmpty)
      }
      .buttonStyle(MintButtonStyle(.secondary))
    }
    .controlSize(.small)
    .disabled(model.isScanning || model.isWorking || model.isPreparingPlan)
    .help("Selection only. Protected keepers stay unselected; deletion always requires Review.")
  }

  @ViewBuilder
  private func content(_ scan: PhotoScanResult) -> some View {
    switch tab {
    case .deck:
      // The deck is shown outside the scroll view so it can fill the page.
      EmptyView()
    case .similar:
      if scan.similarGroups.isEmpty {
        EmptyState(icon: "checkmark.seal", title: "No similar shots", detail: "Every photo here looks distinct.", trust: nil)
      } else {
        LazyVStack(alignment: .leading, spacing: 12) {
          ForEach(scan.similarGroups) { group in groupCard(group) }
        }
      }
    case .blurry:
      grid(
        scan.blurry, empty: "No blurry photos",
        detail: "Blur is judged against the rest of this collection, so soft-focus styles aren't flagged.")
    case .screenshots:
      grid(scan.screenshots, empty: "No screenshots", detail: "Screenshots in this folder will appear here.")
    }
  }

  private var footnote: some View {
    HStack(spacing: 6) {
      Image(systemName: "checkmark.shield.fill").font(.system(size: 12)).foregroundStyle(AppTheme.accentText)
      Text(isLibrary ? Self.libraryFootnote : Self.folderFootnote)
        .font(.system(size: 11.5)).foregroundStyle(AppTheme.ink3)
    }
    .frame(maxWidth: .infinity, alignment: .center)
    .padding(.top, 4)
    .accessibilityElement(children: .combine)
  }

  /// "BEST · sharpest" only when the kept photo is the model's own pick and really the sharpest.
  private func keeperTag(_ group: SimilarPhotoGroup, kept: PhotoFingerprint) -> String {
    guard kept.id == group.keeper.id else { return "KEEP · your pick" }
    let sharpest = group.photos.allSatisfy { $0.sharpness <= kept.sharpness }
    return sharpest ? "BEST · sharpest" : "BEST"
  }

  private func groupCard(_ group: SimilarPhotoGroup) -> some View {
    let kept = model.keeper(of: group)
    let tag = keeperTag(group, kept: kept)
    return VStack(alignment: .leading, spacing: 10) {
      ViewThatFits(in: .horizontal) {
        HStack(spacing: 8) {
          groupInfo(group, kept: kept)
          Spacer(minLength: 8)
          groupButtons(group)
        }
        VStack(alignment: .leading, spacing: 8) {
          groupInfo(group, kept: kept)
          groupButtons(group)
        }
      }
      .padding(.horizontal, 4)
      LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: 8, alignment: .top)], alignment: .leading, spacing: 10) {
        ForEach(group.photos) { photo in
          PhotoTile(photo: photo, isKeeper: photo.id == kept.id, keeperTag: tag)
        }
      }
    }
    .padding(12)
    .cardBackground()
  }

  private func groupInfo(_ group: SimilarPhotoGroup, kept: PhotoFingerprint) -> some View {
    let others = group.photos.filter { $0.id != kept.id }.reduce(Int64(0)) { $0 + $1.bytes }
    let size = kept.isLibraryAsset ? "Size unavailable" : "\(ByteFormatter.string(others)) in other copies"
    return VStack(alignment: .leading, spacing: 2) {
      Text("\(group.photos.count) similar photos").font(.system(size: 13, weight: .semibold)).foregroundStyle(AppTheme.ink)
      Text(size + " · Suggested keeper · You can change it")
        .font(.system(size: 11.5)).foregroundStyle(AppTheme.ink3).monospacedDigit().lineLimit(1)
    }
  }

  private func groupButtons(_ group: SimilarPhotoGroup) -> some View {
    HStack(spacing: 6) {
      Button("Select other copies") { model.selectAllButKeeper(in: group) }
      Button("Deselect group") { model.setPhotoSelection(group.photos, selected: false) }
        .disabled(!group.photos.contains { model.selectedPhotoIDs.contains($0.id) })
      Button { comparing = group } label: { Label("Compare", systemImage: "rectangle.split.2x1") }
    }
    .buttonStyle(MintButtonStyle(.secondary))
    .controlSize(.small)
  }

  @ViewBuilder
  private func grid(_ photos: [PhotoFingerprint], empty: String, detail: String) -> some View {
    if photos.isEmpty {
      EmptyState(icon: "checkmark.seal", title: empty, detail: detail, trust: nil)
    } else {
      LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 12, alignment: .top)], alignment: .leading, spacing: 14) {
        ForEach(photos) { PhotoTile(photo: $0, isKeeper: false) }
      }
      .padding(12)
      .cardBackground()
    }
  }
}

/// One of the gradient tiles at the top of Photos (Similar, Screenshots, Blurry); picks the view below.
private struct PhotoKindTile: View {
  let title: String
  let detail: String
  let count: Int
  let symbol: String
  let swatch: AppTheme.Swatch
  let selected: Bool
  let compact: Bool
  let action: () -> Void
  @Environment(\.colorSchemeContrast) private var contrast

  private var ringColor: Color {
    if selected { return Color.white.opacity(0.95) }
    return Color.white.opacity(contrast == .increased ? 0.7 : 0.18)
  }

  private var ringWidth: CGFloat {
    if selected { return 2.5 }
    return contrast == .increased ? 2 : 0.5
  }

  var body: some View {
    let shape = RoundedRectangle(cornerRadius: compact ? 12 : AppTheme.corner, style: .continuous)
    Button(action: action) {
      label
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, compact ? 12 : 16)
        .padding(.vertical, compact ? 9 : 14)
        .background {
          ZStack(alignment: .bottomTrailing) {
            shape.fill(swatch.gradient)
            Image(systemName: symbol).font(.system(size: compact ? 44 : 84)).symbolVariant(.fill)
              .foregroundStyle(Color.white.opacity(0.1))
              .offset(x: 12, y: compact ? 14 : 24)
          }
          .clipShape(shape)
        }
        .overlay(shape.strokeBorder(ringColor, lineWidth: ringWidth))
        .shadow(color: swatch.color.opacity(selected ? 0.4 : 0.18), radius: selected ? 12 : 4, y: selected ? 8 : 2)
        .contentShape(shape)
    }
    .buttonStyle(TileButtonStyle())
    .accessibilityElement(children: .combine)
    .accessibilityLabel("\(title), \(count)")
    .accessibilityHint(detail)
    .accessibilityAddTraits(selected ? .isSelected : [])
  }

  @ViewBuilder
  private var label: some View {
    if compact {
      HStack(spacing: 8) {
        Image(systemName: symbol).font(.system(size: 13, weight: .semibold)).symbolVariant(.fill)
        Text(title).font(.system(size: 12.5, weight: .semibold)).lineLimit(1)
        Spacer(minLength: 4)
        Text("\(count)").font(AppTheme.number(15)).monospacedDigit().lineLimit(1)
      }
    } else {
      VStack(alignment: .leading, spacing: 2) {
        HStack(spacing: 6) {
          Image(systemName: symbol).font(.system(size: 18, weight: .semibold)).symbolVariant(.fill)
          Spacer(minLength: 4)
          if selected {
            Image(systemName: "checkmark.circle.fill").font(.system(size: 15, weight: .semibold))
          }
        }
        .padding(.bottom, 8)
        Text("\(count)").font(AppTheme.number(24)).tracking(-0.5).monospacedDigit().lineLimit(1)
        Text(title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
        Text(detail).font(.system(size: 11.5)).foregroundStyle(Color.white.opacity(0.88))
          .lineLimit(1).minimumScaleFactor(0.85)
      }
    }
  }
}

/// A quiet button on the area's tint: secondary explore actions such as Review One by One.
private struct SoftAreaButtonStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    SoftAreaButtonFace(configuration: configuration)
  }
}

private struct SoftAreaButtonFace: View {
  let configuration: ButtonStyleConfiguration
  @Environment(\.areaSwatch) private var swatch
  @Environment(\.isEnabled) private var isEnabled
  @Environment(\.controlSize) private var controlSize
  @State private var hovering = false

  var body: some View {
    let small = controlSize == .small || controlSize == .mini
    let shape = RoundedRectangle(cornerRadius: small ? 6 : 8, style: .continuous)
    configuration.label
      .font(.system(size: small ? 12 : 12.5, weight: .semibold))
      .lineLimit(1)
      .foregroundStyle(swatch.text)
      .padding(.horizontal, small ? 10 : 12)
      .frame(minHeight: small ? 24 : 28)
      .background(swatch.tint, in: shape)
      .overlay(shape.strokeBorder(swatch.text.opacity(0.18), lineWidth: 0.5))
      .contentShape(shape)
      .brightness(configuration.isPressed ? -0.05 : hovering && isEnabled ? -0.02 : 0)
      .opacity(isEnabled ? 1 : 0.4)
      .onHover { hovering = $0 }
  }
}

private struct PhotoTile: View {
  let photo: PhotoFingerprint
  let isKeeper: Bool
  /// The chip on the kept photo of a group, such as "BEST · sharpest".
  var keeperTag: String? = nil
  @EnvironmentObject private var model: AppViewModel

  private var isSelected: Bool { model.selectedPhotoIDs.contains(photo.id) }

  private var ringColor: Color {
    if isKeeper { return AppTheme.accent }
    if isSelected { return AppTheme.danger }
    return AppTheme.border
  }

  var body: some View {
    let shape = RoundedRectangle(cornerRadius: 11, style: .continuous)
    VStack(alignment: .leading, spacing: 6) {
      Color.clear
        .aspectRatio(4.0 / 3.0, contentMode: .fit)
        .overlay { PhotoThumbnail(photo: photo, side: 240) }
        .clipShape(shape)
        .overlay { shape.strokeBorder(ringColor, lineWidth: isKeeper || isSelected ? 2.5 : 1) }
        .overlay(alignment: .topLeading) { mark.padding(8) }
        .overlay(alignment: .bottomLeading) {
          if isKeeper {
            Text(keeperTag ?? "KEEP")
              .font(.system(size: 10.5, weight: .bold))
              .foregroundStyle(.white)
              .lineLimit(1)
              .padding(.horizontal, 7)
              .frame(height: 20)
              .background(AppTheme.accent, in: Capsule())
              .padding(8)
          }
        }
        .contentShape(shape)
        .onTapGesture { if !isKeeper { model.togglePhoto(photo) } }
      Text(photo.isLibraryAsset ? (photo.captured?.formatted(date: .abbreviated, time: .shortened) ?? "Photo") : photo.url.lastPathComponent)
        .font(.system(size: 11.5, weight: .semibold))
        .foregroundStyle(AppTheme.ink)
        .lineLimit(1)
        .truncationMode(.middle)
      Text("\(photo.isLibraryAsset ? "Size unavailable" : ByteFormatter.string(photo.bytes)) • \(photo.pixelWidth)×\(photo.pixelHeight)")
        .font(.system(size: 10.5))
        .foregroundStyle(AppTheme.ink3)
        .monospacedDigit()
        .lineLimit(1)
    }
    .contextMenu {
      if !isKeeper, model.group(containing: photo) != nil {
        Button("Keep This One Instead") { model.keepInstead(photo) }
      }
      if photo.isLibraryAsset {
        Button("Open Photos") { PhotoLibraryService.showInPhotos() }
      } else {
        Button("Reveal in Finder") { model.reveal(photo.url) }
      }
    }
    .accessibilityElement(children: .combine)
    .accessibilityLabel("\(photo.url.lastPathComponent)\(isKeeper ? ", kept" : isSelected ? ", selected" : "")")
    .accessibilityAddTraits(.isButton)
    .accessibilityAction { if !isKeeper { model.togglePhoto(photo) } }
    .focusable()
    .onKeyPress(.space) { if !isKeeper { model.togglePhoto(photo) }; return .handled }
  }

  /// The kept photo shows a keeper radio (a ring with a thick mint border); copies show a checkbox.
  @ViewBuilder
  private var mark: some View {
    if isKeeper {
      Circle()
        .strokeBorder(AppTheme.accent, lineWidth: 5)
        .background(Circle().fill(Color.white))
        .frame(width: 18, height: 18)
        .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
        .accessibilityHidden(true)
    } else {
      CheckboxMark(state: isSelected ? .on : .off)
        .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
    }
  }
}

/// Async thumbnail for a file or a Photos library asset.
struct PhotoThumbnail: View {
  let photo: PhotoFingerprint
  let side: CGFloat
  var allowCloud = false
  var fit = false
  var onAvailability: ((Bool) -> Void)? = nil
  /// Tiny previews (the deck's filmstrip) skip the spinner and the "no preview" text.
  var quiet = false
  @State private var finished = false
  @State private var image: NSImage?
  @State private var retry = 0

  private static var cache: PreviewImageCache { PreviewCaches.photos }
  private var loadKey: String { "\(photo.id)#\(photo.modified?.timeIntervalSince1970 ?? 0)#\(photo.identity ?? "unknown")#\(Int(side))#\(allowCloud)#\(retry)" }

  var body: some View {
    ZStack {
      Rectangle().fill(AppTheme.panel)
      if let image {
        Image(nsImage: image).resizable().aspectRatio(contentMode: fit ? .fit : .fill)
      } else if finished {
        if quiet {
          Image(systemName: "photo").font(.system(size: 11)).foregroundStyle(AppTheme.ink3)
        } else {
          VStack(spacing: 8) {
            Label(allowCloud ? "Preview could not be loaded" : "No local preview at this size", systemImage: "photo.badge.exclamationmark")
              .font(.system(size: 11.5)).foregroundStyle(AppTheme.ink2).multilineTextAlignment(.center)
            if fit {
              Button("Retry preview") { retry += 1 }
                .buttonStyle(MintButtonStyle(.secondary)).controlSize(.small)
            }
          }
          .padding(8)
        }
      } else if !quiet {
        ProgressView().controlSize(.small)
      }
    }
    .task(id: loadKey) {
      let cacheGeneration = Self.cache.generation
      finished = false; image = nil; onAvailability?(false)
      if fit, let assetID = photo.assetID {
        // Show the same local resolution used by analysis before requesting a larger image.
        let smallKey = "\(photo.id)#\(photo.modified?.timeIntervalSince1970 ?? 0)#local-256"
        var small = Self.cache.image(for: smallKey)
        if small == nil {
          small = await PhotoLibraryService.thumbnailData(assetID: assetID, side: 128, allowNetwork: false)
            .flatMap(NSImage.init(data:))
        }
        guard !Task.isCancelled else { return }
        if let small {
          if Self.cache.generation == cacheGeneration { Self.cache.insert(small, for: smallKey) }
          image = small; onAvailability?(true)
        }
      }
      let loaded = await load()
      guard !Task.isCancelled else { return }
      if let loaded { image = loaded }
      finished = true; onAvailability?(image != nil)
    }
    .onDisappear { image = nil; finished = false }
  }

  private func load() async -> NSImage? {
    let key = loadKey
    let cacheGeneration = Self.cache.generation
    if let cached = Self.cache.image(for: key) { return cached }
    let loaded: NSImage?
    if let assetID = photo.assetID {
      loaded = await PhotoLibraryService.thumbnailData(assetID: assetID, side: side, allowNetwork: allowCloud)
        .flatMap(NSImage.init(data:))
    } else {
      let url = photo.url
      let pixels = min(1_400, max(64, Int(side * 2)))
      let work = Task.detached(priority: .utility) { await LocalPreviewDecoder.shared.decode(url, pixels: pixels) }
      let data = await withTaskCancellationHandler { await work.value } onCancel: { work.cancel() }
      loaded = data.flatMap(NSImage.init(data:))
    }
    guard !Task.isCancelled else { return nil }
    if let loaded, Self.cache.generation == cacheGeneration { Self.cache.insert(loaded, for: key) }
    return loaded
  }
}
