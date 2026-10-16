import AppKit
import MacCleanerCore
@preconcurrency import QuickLookThumbnailing
import SwiftUI

/// Quick Look thumbnail for a file (image, video, PDF…), falling back to the Finder icon.
struct FileThumbnail: View {
  let url: URL
  var size: CGFloat = 44

  @State private var image: NSImage?

  var body: some View {
    Group {
      if let image {
        Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
      } else {
        Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable()
      }
    }
    .frame(width: size, height: size)
    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).stroke(Color.primary.opacity(0.08)))
    .task(id: url) {
      image = nil
      let loaded = await ThumbnailCache.shared.thumbnail(for: url, size: size)
      guard !Task.isCancelled else { return }
      image = loaded
    }
    .onDisappear { image = nil }
    .accessibilityHidden(true)
  }
}

@MainActor
final class ThumbnailCache {
  static let shared = ThumbnailCache()
  private let cache = PreviewImageCache(byteLimit: 16 * 1_024 * 1_024, countLimit: 96)

  func thumbnail(for url: URL, size: CGFloat) async -> NSImage? {
    guard !FileSystem.isCloudPlaceholder(url) else { return nil }
    let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
    let key = "\(url.path)#\(Int(size))#\(values?.contentModificationDate?.timeIntervalSince1970 ?? 0)#\(values?.fileSize ?? 0)"
    if let cached = cache.image(for: key) { return cached }
    let scale = NSScreen.main?.backingScaleFactor ?? 2
    let request = QLThumbnailGenerator.Request(
      fileAt: url, size: CGSize(width: size, height: size), scale: scale, representationTypes: .thumbnail)
    guard let representation = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request)
    else { return nil }
    let image = representation.nsImage
    guard !Task.isCancelled else { return nil }
    cache.insert(image, for: key)
    return image
  }
}
