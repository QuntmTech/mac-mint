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
    .task(id: url) { image = await ThumbnailCache.shared.thumbnail(for: url, size: size) }
    .accessibilityHidden(true)
  }
}

@MainActor
final class ThumbnailCache {
  static let shared = ThumbnailCache()
  private let cache = NSCache<NSString, NSImage>()

  func thumbnail(for url: URL, size: CGFloat) async -> NSImage? {
    guard !FileSystem.isCloudPlaceholder(url) else { return nil }
    let key = "\(url.path)#\(Int(size))" as NSString
    if let cached = cache.object(forKey: key) { return cached }
    let scale = NSScreen.main?.backingScaleFactor ?? 2
    let request = QLThumbnailGenerator.Request(
      fileAt: url, size: CGSize(width: size, height: size), scale: scale, representationTypes: .thumbnail)
    guard let representation = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request)
    else { return nil }
    let image = representation.nsImage
    cache.setObject(image, forKey: key)
    return image
  }
}
