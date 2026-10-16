import ImageIO
import MacCleanerCore
import SwiftUI

struct PhotosView: View {
  @EnvironmentObject private var model: AppViewModel
  @State private var comparing: SimilarPhotoGroup?
  @SceneStorage("photos.tab") private var tab: PhotoTab = .similar

  private var isLibrary: Bool { model.photoSource == .library }

  var body: some View {
    VStack(spacing: 0) {
      header
      Divider()
      if model.isScanning && model.operationTitle == "Photos" {
        progress
      } else if let scan = model.photoScan {
        Picker("", selection: $tab) {
          ForEach(isLibrary ? [PhotoTab.similar, .blurry] : PhotoTab.allCases) { tab in
            Text(label(for: tab, scan: scan)).tag(tab)
          }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(maxWidth: 420)
        .padding(.vertical, 10)
        Divider()
        content(scan)
      } else {
        EmptyState(
          icon: "photo.on.rectangle.angled", title: "Find similar shots, blurry photos, and old screenshots",
          detail:
            "Check your Photos library or any folder. Nothing is selected for you. Compare each set and choose the copy to keep.")
      }
    }
    .sheet(item: $comparing) { group in PhotoComparisonSheet(group: group) }
  }

  // MARK: Header

  private var header: some View {
    HStack(spacing: 12) {
      VStack(alignment: .leading, spacing: 4) {
        Text("Photos").font(.system(size: 30, weight: .bold, design: .rounded))
        Text(
          isLibrary
            ? "Deleting in Photos also deletes from iCloud and synced devices. Recover through Photos while available in Recently Deleted."
            : "Folder photos go to the Trash and can be restored from History."
        )
        .foregroundStyle(.secondary)
      }
      Spacer()
      if !model.selectedPhotoIDs.isEmpty {
        Button("Deselect") { model.keepQueuedFiles(model.selectedPhotos.filter { !$0.isLibraryAsset }.map(\.url)); model.selectedPhotoIDs = [] }
        Button {
          model.reviewPhotos()
        } label: {
          Label(
            isLibrary
              ? "Delete \(model.selectedPhotoIDs.count) in Photos (\(ByteFormatter.string(model.selectedPhotoBytes)))"
              : "Review \(model.selectedPhotoIDs.count) (\(ByteFormatter.string(model.selectedPhotoBytes)))",
            systemImage: "trash")
        }
        .buttonStyle(.borderedProminent)
        .disabled(model.isWorking || model.isScanning)
      }
      Menu {
        Button("Photos Library") {
          model.photoSource = .library
          model.scanPhotos()
        }
        Button("Choose Folder…") { model.choosePhotoFolder() }
      } label: {
        Label(model.photoSource.title, systemImage: isLibrary ? "photo.stack" : "folder")
      }
      .fixedSize()
      Button(model.photoScan == nil ? "Scan" : "Rescan") { model.scanPhotos() }
        .buttonStyle(.borderedProminent)
        .disabled(model.isScanning || model.isWorking)
    }
    .padding(AppTheme.pagePadding)
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
      Text("Everything is analysed on this Mac. Nothing is uploaded or downloaded from iCloud.")
        .font(.caption)
        .foregroundStyle(.tertiary)
      Button("Cancel") { model.cancelCurrentOperation() }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  private func label(for tab: PhotoTab, scan: PhotoScanResult) -> String {
    switch tab {
    case .similar: return "Similar (\(scan.similarGroups.reduce(0) { $0 + $1.others.count }))"
    case .blurry: return "Blurry (\(scan.blurry.count))"
    case .screenshots: return "Screenshots (\(scan.screenshots.count))"
    }
  }

  // MARK: Content

  @ViewBuilder
  private func content(_ scan: PhotoScanResult) -> some View {
    switch tab {
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
        HStack {
          Text("\(group.photos.count) similar photos").font(.headline)
          Text("• \(ByteFormatter.string(group.photos.filter { $0.id != kept.id }.reduce(0) { $0 + $1.bytes })) in the others")
            .foregroundStyle(.secondary)
          Spacer()
          Button("Compare") { comparing = group }
          Button("Select All but Kept") { model.selectAllButKeeper(in: group) }
            .controlSize(.small)
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
      Text("\(ByteFormatter.string(photo.bytes)) • \(photo.pixelWidth)×\(photo.pixelHeight)")
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
  @State private var finished = false
  @State private var image: NSImage?

  private static let cache = NSCache<NSString, NSImage>()

  var body: some View {
    ZStack {
      Rectangle().fill(Color.primary.opacity(0.06))
      if let image {
        Image(nsImage: image).resizable().scaledToFill()
      } else if finished {
        Label("Preview unavailable locally", systemImage: "icloud").font(.caption).multilineTextAlignment(.center)
      } else {
        ProgressView().controlSize(.small)
      }
    }
    .task(id: photo.id + String(allowCloud)) { finished = false; image = await load(); finished = true }
  }

  private func load() async -> NSImage? {
    let key = "\(photo.id)#\(Int(side))#\(allowCloud)" as NSString
    if let cached = Self.cache.object(forKey: key) { return cached }
    let loaded: NSImage?
    if let assetID = photo.assetID {
      loaded = await PhotoLibraryService.thumbnailData(assetID: assetID, side: side, allowNetwork: allowCloud)
        .flatMap(NSImage.init(data:))
    } else {
      let url = photo.url
      let pixels = side * 2
      let data: Data? = await Task.detached(priority: .utility) {
        guard !FileSystem.isCloudPlaceholder(url), let source = CGImageSourceCreateWithURL(url as CFURL, nil),
          let cgImage = CGImageSourceCreateThumbnailAtIndex(
            source, 0,
            [
              kCGImageSourceCreateThumbnailFromImageAlways: true,
              kCGImageSourceCreateThumbnailWithTransform: true,
              kCGImageSourceThumbnailMaxPixelSize: pixels,
            ] as CFDictionary)
        else { return nil }
        return NSBitmapImageRep(cgImage: cgImage).representation(using: .png, properties: [:])
      }.value
      loaded = data.flatMap(NSImage.init(data:))
    }
    if let loaded { Self.cache.setObject(loaded, forKey: key) }
    return loaded
  }
}
