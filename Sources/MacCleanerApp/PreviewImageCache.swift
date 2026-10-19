import AppKit
import ImageIO
import MacCleanerCore

/// An explicit LRU budget: NSCache's cost limit alone does not guarantee eviction.
@MainActor
final class PreviewImageCache {
  private struct Entry { let image: NSImage; let cost: Int; var lastUse: UInt64 }
  let byteLimit: Int
  let countLimit: Int
  private var entries: [String: Entry] = [:]
  private var clock: UInt64 = 0
  private(set) var storedCost = 0
  private(set) var generation: UInt64 = 0
  var count: Int { entries.count }

  init(byteLimit: Int, countLimit: Int) {
    self.byteLimit = max(0, byteLimit); self.countLimit = max(0, countLimit)
  }

  func image(for key: String) -> NSImage? {
    guard var entry = entries[key] else { return nil }
    clock &+= 1; entry.lastUse = clock; entries[key] = entry
    return entry.image
  }

  func insert(_ image: NSImage, for key: String) {
    let pixels = image.representations.reduce(0.0) {
      $0 + Double(max(0, $1.pixelsWide)) * Double(max(0, $1.pixelsHigh))
    }
    // Account for compressed backing data as well as decoded RGBA storage.
    let estimate = max(1, pixels > 0 ? pixels * 5 : image.size.width * image.size.height * 20)
    guard estimate.isFinite, estimate <= Double(byteLimit), estimate < Double(Int.max), countLimit > 0 else { return }
    let cost = Int(estimate)
    if let previous = entries.removeValue(forKey: key) { storedCost -= previous.cost }
    while storedCost > byteLimit - cost || entries.count >= countLimit {
      guard let oldest = entries.min(by: { $0.value.lastUse < $1.value.lastUse }) else { break }
      entries.removeValue(forKey: oldest.key); storedCost -= oldest.value.cost
    }
    clock &+= 1
    entries[key] = Entry(image: image, cost: cost, lastUse: clock); storedCost += cost
  }

  func removeAll() { generation &+= 1; entries.removeAll(); storedCost = 0 }
}

/// ImageIO decoding stays off the UI thread. A serial actor bounds concurrent decodes;
/// canceled queued requests return before opening a file. Original image data isn't cached.
actor LocalPreviewDecoder {
  static let shared = LocalPreviewDecoder()
  func decode(_ url: URL, pixels: Int) -> Data? {
    autoreleasepool { decodeInPool(url, pixels: pixels) }
  }
  private func decodeInPool(_ url: URL, pixels: Int) -> Data? {
    guard !Task.isCancelled, !FileSystem.isCloudPlaceholder(url),
      let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
      let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceCreateThumbnailWithTransform: true,
        kCGImageSourceThumbnailMaxPixelSize: min(1_400, max(64, pixels)),
      ] as CFDictionary), !Task.isCancelled else { return nil }
    return NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
  }
}

/// Preview pixels are disposable; scan findings and selections are retained separately.
@MainActor
enum PreviewCaches {
  static let photos = PreviewImageCache(byteLimit: 8 * 1_024 * 1_024, countLimit: 32)
  /// Memory pressure, closing the window and time in the background all release previews.
  static func startMemoryPressureHandling() { MemoryRelief.shared.start() }
  static func release() {
    photos.removeAll(); ThumbnailCache.shared.removeAll(); PerformanceIconCache.shared.removeAll()
    FileIcons.removeAll(); OwnerDirectory.removeAll()
  }
}

/// Finder icons for list rows. `NSWorkspace.icon(forFile:)` asks Icon Services each time,
/// and rows call it on every render; this keeps the last 128 paths.
@MainActor
enum FileIcons {
  private static var icons: [String: (image: NSImage, lastUse: UInt64)] = [:]
  private static var clock: UInt64 = 0
  static let countLimit = 128
  static var count: Int { icons.count }

  static func icon(forPath path: String) -> NSImage {
    clock &+= 1
    if let hit = icons[path] { icons[path] = (hit.image, clock); return hit.image }
    let image = NSWorkspace.shared.icon(forFile: path)
    if icons.count >= countLimit, let oldest = icons.min(by: { $0.value.lastUse < $1.value.lastUse }) {
      icons.removeValue(forKey: oldest.key)
    }
    icons[path] = (image, clock)
    return image
  }

  static func removeAll() { icons.removeAll() }
}
