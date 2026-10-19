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
  private let cache = PreviewImageCache(byteLimit: 8 * 1_024 * 1_024, countLimit: 48)
  private var generation = UUID()

  func removeAll() { generation = UUID(); cache.removeAll() }

  func thumbnail(for url: URL, size: CGFloat) async -> NSImage? {
    let token = generation
    guard !Task.isCancelled, !FileSystem.isCloudPlaceholder(url) else { return nil }
    let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
    let key = "\(url.path)#\(Int(size))#\(values?.contentModificationDate?.timeIntervalSince1970 ?? 0)#\(values?.fileSize ?? 0)"
    if let cached = cache.image(for: key) { return cached }
    let scale = NSScreen.main?.backingScaleFactor ?? 2
    let request = QLThumbnailGenerator.Request(
      fileAt: url, size: CGSize(width: size, height: size), scale: scale, representationTypes: .thumbnail)
    let generator = QLThumbnailGenerator.shared
    let work = ThumbnailRequest(generate: {
      try await generator.generateBestRepresentation(for: request).nsImage
    }, cancel: { generator.cancel(request) })
    guard let image = await work.image(), !Task.isCancelled else { return nil }
    if generation == token { cache.insert(image, for: key) }
    return image
  }
}

/// Forward Swift task cancellation to the native generator, rather than only
/// discarding its result. Cancelled work cannot populate the preview cache.
@MainActor
final class ThumbnailRequest {
  private let generate: @MainActor () async throws -> NSImage
  private let cancelRequest: @MainActor () -> Void
  private var started = false
  private var finished = false
  private var cancelled = false

  init(generate: @escaping @MainActor () async throws -> NSImage, cancel: @escaping @MainActor () -> Void) {
    self.generate = generate; cancelRequest = cancel
  }

  func image() async -> NSImage? {
    await withTaskCancellationHandler {
      guard !Task.isCancelled, !started else { return nil }
      started = true
      defer { finished = true }
      let result = try? await generate()
      guard !Task.isCancelled, !cancelled else { return nil }
      return result
    } onCancel: {
      Task { @MainActor in self.cancel() }
    }
  }

  private func cancel() {
    guard started, !finished, !cancelled else { return }
    cancelled = true; cancelRequest()
  }
}
