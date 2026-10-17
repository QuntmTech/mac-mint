import AppKit
import ImageIO
import MacCleanerCore
import SwiftUI

struct PhotosView: View {
  @EnvironmentObject private var model: AppViewModel
  @State private var comparing: SimilarPhotoGroup?
  @StateObject private var permissions = PermissionsService()
  @SceneStorage("photos.tab") private var tab: PhotoTab = .similar

  private var isLibrary: Bool { model.photoSource == .library }

  var body: some View {
    VStack(spacing: 0) {
      header
      if isLibrary && permissions.photos == .limited {
        Label("Only the Photos assets you shared are included in this scan.", systemImage: "photo.badge.checkmark")
          .font(.caption).foregroundStyle(.secondary).padding(.horizontal, AppTheme.pagePadding).padding(.bottom, 10)
      }
      if let error = model.photoDeletionError {
        Label(error, systemImage: "exclamationmark.triangle")
          .font(.callout).foregroundStyle(AppTheme.warning).fixedSize(horizontal: false, vertical: true)
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(.horizontal, AppTheme.pagePadding).padding(.bottom, 10)
      }
      Divider()
      if model.isScanning && model.operationTitle == "Photos" {
        progress
      } else if isLibrary && (permissions.photos == .notRequested || permissions.photos.requiresSettings) {
        libraryAccess
      } else if let scan = model.photoScan {
        Picker("", selection: $tab) {
          ForEach(isLibrary ? [PhotoTab.deck, .similar, .blurry] : PhotoTab.allCases) { tab in
            Text(label(for: tab, scan: scan)).tag(tab)
          }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(maxWidth: 540)
        .padding(.vertical, 10)
        Divider()
        content(scan)
      } else {
        EmptyState(
          icon: "photo.on.rectangle.angled", title: "Make room for your best shots",
          detail:
            "Check your Photos library or any folder. Nothing is selected for you. Compare each set and choose the copy to keep.",
          actionTitle: "Scan photos", action: startScan)
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

  private var header: some View {
    PageHeader(title: "Photos", subtitle: isLibrary
      ? "Compare your library. Deletion syncs to iCloud and other devices; recovery is through Photos."
      : "Compare folder photos. Reviewed removals go to Trash, with recovery in History.") {
      HStack(spacing: 8) {
      if !model.selectedPhotoIDs.isEmpty {
        Button("Deselect") { model.keepQueuedFiles(model.selectedPhotos.filter { !$0.isLibraryAsset }.map(\.url)); model.selectedPhotoIDs = [] }
        Button {
          model.reviewPhotos()
        } label: {
          Label(
            isLibrary
              ? "Review \(model.selectedPhotoIDs.count) photos"
              : "Review \(model.selectedPhotoIDs.count) (\(ByteFormatter.string(model.selectedPhotoBytes)))",
            systemImage: "checklist")
        }
        .buttonStyle(MintButtonStyle())
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
      Button(isLibrary && permissions.photos.requiresSettings ? "Photos Settings" : model.photoScan == nil ? "Scan" : "Rescan", action: startScan)
        .buttonStyle(MintButtonStyle())
        .disabled(model.isScanning || model.isWorking)
    }
    }
    .padding(AppTheme.pagePadding)
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
      VStack(alignment: .leading, spacing: 16) {
        Image(systemName: "photo.badge.checkmark").font(.system(size: 36)).foregroundStyle(AppTheme.accentText)
        Text(permissions.photos == .notRequested ? "Choose access to your Photos library" : permissions.photos.title)
          .font(.title2.bold())
        Text(permissions.photos.detail).foregroundStyle(.secondary)
        Text("Analysis uses local thumbnails. Photos deletions require your review and Photos confirmation, sync to other iCloud devices, and are recovered in Photos.")
          .font(.callout).foregroundStyle(.secondary)
        HStack {
          Button(permissions.photos == .notRequested ? "Continue & Scan" : "Open Photos Settings", action: startScan)
            .buttonStyle(MintButtonStyle())
          Button("Choose a Photo Folder…") { model.choosePhotoFolder() }
        }
        .disabled(model.isWorking || model.isScanning)
        Text(PermissionSettingsPane.photos.path).font(.caption).foregroundStyle(.secondary)
        if let error = permissions.settingsError {
          Text(error).font(.callout).foregroundStyle(AppTheme.warning)
        }
      }
      .fixedSize(horizontal: false, vertical: true)
      .frame(maxWidth: 620, alignment: .leading)
      .padding(AppTheme.pagePadding)
      .frame(maxWidth: .infinity, alignment: .center)
    }
  }

  private var progress: some View {
    VStack(spacing: 12) {
      if let progress = model.photoProgress, progress.total > 0 {
        ProgressView(value: Double(progress.done), total: Double(progress.total))
          .frame(width: 320)
        Text("\(progress.done.formatted()) of \(progress.total.formatted()) photos")
          .font(.callout.monospacedDigit())
          .foregroundStyle(.secondary)
      } else {
        ProgressView().controlSize(.large)
      }
      Text("Analysis uses local thumbnails. Default previews stay local; a cloud preview downloads only when you request it.")
        .font(.caption)
        .foregroundStyle(.secondary)
      Button("Cancel") { model.cancelCurrentOperation() }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  private func label(for tab: PhotoTab, scan: PhotoScanResult) -> String {
    switch tab {
    case .deck: return "Review deck"
    case .similar: return "Similar (\(scan.similarGroups.reduce(0) { $0 + $1.others.count }))"
    case .blurry: return "Blurry (\(scan.blurry.count))"
    case .screenshots: return "Screenshots (\(scan.screenshots.count))"
    }
  }

  // MARK: Content

  @ViewBuilder
  private func content(_ scan: PhotoScanResult) -> some View {
    switch tab {
    case .deck: PhotoReviewDeck().id(scan.generation)
    case .similar:
      if scan.similarGroups.isEmpty {
        EmptyState(icon: "checkmark.seal", title: "No similar shots", detail: "Every photo here looks distinct.")
      } else {
        ScrollView {
          LazyVStack(alignment: .leading, spacing: 18) {
            ForEach(scan.similarGroups) { group in groupCard(group) }
          }
          .padding(AppTheme.pagePadding)
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

  private func groupCard(_ group: SimilarPhotoGroup) -> some View {
    let kept = model.keeper(of: group)
    return SurfaceCard {
      VStack(alignment: .leading, spacing: 12) {
        VStack(alignment: .leading, spacing: 12) {
          HStack {
            VStack(alignment: .leading, spacing: 4) {
              Text("\(group.photos.count) similar photos").font(.headline)
              Text(kept.isLibraryAsset ? "Size unavailable" : "\(ByteFormatter.string(group.photos.filter { $0.id != kept.id }.reduce(0) { $0 + $1.bytes })) in other copies")
                .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button { comparing = group } label: { Label("Compare", systemImage: "rectangle.split.2x1") }
              .buttonStyle(MintButtonStyle(prominent: false))
          }
          HStack {
            Label("Suggested keeper · You can change it", systemImage: "star")
              .font(.caption).foregroundStyle(AppTheme.accentText)
            Spacer()
            Button("Select other copies") { model.selectAllButKeeper(in: group) }.controlSize(.small)
          }
        }
        ScrollView(.horizontal, showsIndicators: false) {
          HStack(spacing: 12) {
            ForEach(group.photos) { photo in
              PhotoTile(photo: photo, isKeeper: photo.id == kept.id)
            }
          }
        }
      }
    }

  }

  @ViewBuilder
  private func grid(_ photos: [PhotoFingerprint], empty: String, detail: String) -> some View {
    if photos.isEmpty {
      EmptyState(icon: "checkmark.seal", title: empty, detail: detail)
    } else {
      ScrollView {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 160), spacing: 12)], spacing: 12) {
          ForEach(photos) { PhotoTile(photo: $0, isKeeper: false) }
        }
        .padding(AppTheme.pagePadding)
      }
    }
  }
}

private struct PhotoTile: View {
  let photo: PhotoFingerprint
  let isKeeper: Bool
  @EnvironmentObject private var model: AppViewModel

  private var isSelected: Bool { model.selectedPhotoIDs.contains(photo.id) }

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      ZStack(alignment: .topLeading) {
        PhotoThumbnail(photo: photo, side: 150)
          .frame(width: 150, height: 150)
          .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
          .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
              .strokeBorder(
                isKeeper ? AppTheme.accent : (isSelected ? Color.red : Color.primary.opacity(0.1)),
                lineWidth: isKeeper || isSelected ? 3 : 1)
          }
        if isKeeper {
          Label("Suggested keeper", systemImage: "star.fill")
            .font(.caption2.weight(.bold))
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(AppTheme.accent, in: Capsule())
            .foregroundStyle(.white)
            .padding(6)
        } else {
          Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
            .font(.title3)
            .foregroundStyle(isSelected ? Color.red : Color.white)
            .shadow(radius: 2)
            .padding(6)
        }
      }
      .onTapGesture { if !isKeeper { model.togglePhoto(photo) } }
      Text(photo.isLibraryAsset ? (photo.captured?.formatted(date: .abbreviated, time: .shortened) ?? "Photo") : photo.url.lastPathComponent)
        .font(.caption.weight(.medium))
        .lineLimit(1)
        .frame(width: 150, alignment: .leading)
      Text("\(photo.isLibraryAsset ? "Size unavailable" : ByteFormatter.string(photo.bytes)) • \(photo.pixelWidth)×\(photo.pixelHeight)")
        .font(.caption2)
        .foregroundStyle(.secondary)
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
}

/// Async thumbnail for a file or a Photos library asset.
struct PhotoThumbnail: View {
  let photo: PhotoFingerprint
  let side: CGFloat
  var allowCloud = false
  var fit = false
  @State private var finished = false
  @State private var image: NSImage?

  private static let cache = PreviewImageCache(byteLimit: 32 * 1_024 * 1_024, countLimit: 64)
  private var loadKey: String { "\(photo.id)#\(photo.modified?.timeIntervalSince1970 ?? 0)#\(photo.identity ?? "unknown")#\(Int(side))#\(allowCloud)" }

  var body: some View {
    ZStack {
      Rectangle().fill(Color.primary.opacity(0.06))
      if let image {
        Image(nsImage: image).resizable().aspectRatio(contentMode: fit ? .fit : .fill)
      } else if finished {
        Label("Preview unavailable locally", systemImage: "icloud").font(.caption).multilineTextAlignment(.center)
      } else {
        ProgressView().controlSize(.small)
      }
    }
    .task(id: loadKey) {
      finished = false; image = nil
      let loaded = await load()
      guard !Task.isCancelled else { return }
      image = loaded; finished = true
    }
    .onDisappear { image = nil; finished = false }
  }

  private func load() async -> NSImage? {
    let key = loadKey
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
    if let loaded { Self.cache.insert(loaded, for: key) }
    return loaded
  }
}
