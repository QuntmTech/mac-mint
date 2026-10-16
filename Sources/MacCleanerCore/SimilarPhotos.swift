import Foundation

#if canImport(ImageIO)
  import CoreGraphics
  import ImageIO
#endif

/// Perceptual fingerprint of one image file. Never computed for files inside a Photos library
/// package — library photos are only ever handled through PhotoKit.
public struct PhotoFingerprint: Identifiable, Hashable, Sendable {
  public let id: String
  public let url: URL
  public let bytes: Int64
  /// 64-bit difference hash (dHash) of a 9×8 grayscale thumbnail.
  public let hash: UInt64
  /// Variance of the Laplacian on a 256px grayscale thumbnail; low = blurry.
  public let sharpness: Double
  public let pixelWidth: Int
  public let pixelHeight: Int
  public let captured: Date?
  public let identity: String?
  /// PhotoKit local identifier when this photo lives in the Photos library (url is then synthetic).
  public let assetID: String?
  /// File modification time at scan time (nil for library assets).
  public let modified: Date?

  public init(
    url: URL, bytes: Int64, hash: UInt64, sharpness: Double, pixelWidth: Int, pixelHeight: Int,
    captured: Date? = nil, identity: String? = nil, assetID: String? = nil, modified: Date? = nil
  ) {
    self.assetID = assetID
    self.modified = modified
    self.id = assetID.map { "photos:" + $0 } ?? url.standardizedFileURL.path
    self.url = url
    self.bytes = bytes
    self.hash = hash
    self.sharpness = sharpness
    self.pixelWidth = pixelWidth
    self.pixelHeight = pixelHeight
    self.captured = captured
    self.identity = identity
  }

  public var pixelCount: Int { pixelWidth * pixelHeight }
  public var isLibraryAsset: Bool { assetID != nil }
  public var isScreenshot: Bool { PhotoAnalysis.looksLikeScreenshot(url) }
}

/// Visually similar images. "Similar" is a judgement, not proof of identity: the suggested
/// keeper is a recommendation and nothing in a group is selected automatically.
public struct SimilarPhotoGroup: Identifiable, Hashable, Sendable {
  public let id: String
  public let photos: [PhotoFingerprint]
  /// Index into `photos` of the suggested best shot (sharpest, then largest).
  public let keeperIndex: Int

  public init(id: String, photos: [PhotoFingerprint], keeperIndex: Int) {
    self.id = id
    self.photos = photos
    self.keeperIndex = min(max(0, keeperIndex), max(0, photos.count - 1))
  }

  public var keeper: PhotoFingerprint { photos[keeperIndex] }
  public var others: [PhotoFingerprint] { photos.enumerated().filter { $0.offset != keeperIndex }.map(\.element) }
  public var reclaimableBytes: Int64 { others.reduce(0) { $0 + $1.bytes } }
}

public enum PhotoAnalysis {
  public static let imageExtensions: Set<String> = [
    "jpg", "jpeg", "png", "heic", "heif", "tif", "tiff", "gif", "bmp", "webp",
  ]

  /// Files inside these packages belong to an app's library and are never scanned as files.
  public static let libraryPackageExtensions: Set<String> = [
    "photoslibrary", "photolibrary", "aplibrary", "migratedphotolibrary", "lrlibrary",
  ]

  public static func isInsideLibraryPackage(_ url: URL) -> Bool {
    url.standardizedFileURL.pathComponents.contains { component in
      libraryPackageExtensions.contains((component as NSString).pathExtension.lowercased())
    }
  }

  public static func looksLikeScreenshot(_ url: URL) -> Bool {
    let name = url.deletingPathExtension().lastPathComponent.lowercased()
    return name.hasPrefix("screenshot") || name.hasPrefix("screen shot")
      || name.hasPrefix("cleanshot") || name.hasPrefix("simulator screenshot")
  }

  // MARK: Hashing

  /// dHash: compares each pixel with its right neighbour in a 9×8 grayscale image (row-major).
  public static func differenceHash(gray9x8 pixels: [UInt8]) -> UInt64 {
    precondition(pixels.count == 72, "expects a 9×8 grayscale buffer")
    var hash: UInt64 = 0
    var bit: UInt64 = 0
    for row in 0..<8 {
      for column in 0..<8 {
        if pixels[row * 9 + column] > pixels[row * 9 + column + 1] { hash |= 1 << bit }
        bit += 1
      }
    }
    return hash
  }

  public static func distance(_ a: UInt64, _ b: UInt64) -> Int { (a ^ b).nonzeroBitCount }

  /// Variance of a 4-neighbour Laplacian over a grayscale buffer. Higher = more fine detail.
  public static func sharpness(gray pixels: [UInt8], width: Int, height: Int) -> Double {
    guard width > 2, height > 2, pixels.count >= width * height else { return 0 }
    var sum = 0.0
    var sumSquares = 0.0
    var count = 0.0
    for y in 1..<(height - 1) {
      for x in 1..<(width - 1) {
        let center = Double(pixels[y * width + x])
        let laplacian =
          Double(pixels[(y - 1) * width + x]) + Double(pixels[(y + 1) * width + x])
          + Double(pixels[y * width + x - 1]) + Double(pixels[y * width + x + 1]) - 4 * center
        sum += laplacian
        sumSquares += laplacian * laplacian
        count += 1
      }
    }
    let mean = sum / count
    return sumSquares / count - mean * mean
  }

  // MARK: Grouping

  /// Groups photos whose hashes are within `threshold` bits (single-linkage). Exact duplicates
  /// (same physical file) are collapsed. Groups are sorted by reclaimable bytes.
  public static func group(_ photos: [PhotoFingerprint], threshold: Int = 6) -> [SimilarPhotoGroup] {
    var unique: [PhotoFingerprint] = []
    var seenIdentities: Set<String> = []
    for photo in photos {
      if let identity = photo.identity, !seenIdentities.insert(identity).inserted { continue }
      unique.append(photo)
    }
    guard unique.count > 1 else { return [] }

    var parent = Array(0..<unique.count)
    func root(_ i: Int) -> Int {
      var i = i
      while parent[i] != i {
        parent[i] = parent[parent[i]]
        i = parent[i]
      }
      return i
    }
    for i in 0..<unique.count {
      if i % 256 == 0, Task.isCancelled { return [] }
      for j in (i + 1)..<unique.count where distance(unique[i].hash, unique[j].hash) <= threshold {
        let (a, b) = (root(i), root(j))
        if a != b { parent[b] = a }
      }
    }

    var clusters: [Int: [PhotoFingerprint]] = [:]
    for (index, photo) in unique.enumerated() { clusters[root(index), default: []].append(photo) }
    return clusters.values.filter { $0.count > 1 }.map { members in
      let sorted = members.sorted { ($0.captured ?? .distantPast, $0.id) < ($1.captured ?? .distantPast, $1.id) }
      let keeper = sorted.indices.max { lhs, rhs in
        let l = sorted[lhs]
        let r = sorted[rhs]
        // Prefer clearly sharper shots; among comparable ones, prefer more pixels.
        if abs(l.sharpness - r.sharpness) > 0.15 * max(l.sharpness, r.sharpness) {
          return l.sharpness < r.sharpness
        }
        return l.pixelCount < r.pixelCount
      } ?? 0
      return SimilarPhotoGroup(id: sorted[0].id, photos: sorted, keeperIndex: keeper)
    }
    .sorted { $0.reclaimableBytes > $1.reclaimableBytes }
  }

  /// Photos that are much blurrier than the folder's typical sharpness (relative, not absolute,
  /// so a folder of soft-focus art isn't flagged wholesale). Screenshots are never "blurry".
  public static func blurry(_ photos: [PhotoFingerprint], factor: Double = 0.12) -> [PhotoFingerprint] {
    let candidates = photos.filter { !$0.isScreenshot && $0.sharpness > 0 }
    guard candidates.count >= 8 else { return [] }
    let sorted = candidates.map(\.sharpness).sorted()
    let median = sorted[sorted.count / 2]
    return candidates.filter { $0.sharpness < median * factor }.sorted { $0.sharpness < $1.sharpness }
  }
}


#if canImport(ImageIO)
  extension PhotoAnalysis {
    /// Hash + sharpness of an already-decoded thumbnail (Photos library assets use this).
    public static func measure(_ image: CGImage) -> (hash: UInt64, sharpness: Double)? {
      let side = 256
      let scale = min(1, Double(side) / Double(max(image.width, image.height)))
      let width = max(3, Int(Double(image.width) * scale))
      let height = max(3, Int(Double(image.height) * scale))
      guard let tiny = grayscale(image, width: 9, height: 8),
        let detail = grayscale(image, width: width, height: height)
      else { return nil }
      return (differenceHash(gray9x8: tiny), sharpness(gray: detail, width: width, height: height))
    }

    static func grayscale(_ image: CGImage, width: Int, height: Int) -> [UInt8]? {
      var pixels = [UInt8](repeating: 0, count: width * height)
      let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
        guard
          let context = CGContext(
            data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue)
        else { return false }
        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return true
      }
      return drawn ? pixels : nil
    }
  }
#endif

// MARK: - Scanner (macOS image decoding)

public struct PhotoScanResult: Sendable {
  public let photos: [PhotoFingerprint]
  public let similarGroups: [SimilarPhotoGroup]
  public let blurry: [PhotoFingerprint]
  public let screenshots: [PhotoFingerprint]
  public let skippedLibraries: [String]
  public let issues: [ScanIssue]
  public let wasCancelled: Bool

  public init(
    photos: [PhotoFingerprint], similarGroups: [SimilarPhotoGroup], blurry: [PhotoFingerprint],
    screenshots: [PhotoFingerprint], skippedLibraries: [String], issues: [ScanIssue],
    wasCancelled: Bool
  ) {
    self.photos = photos
    self.similarGroups = similarGroups
    self.blurry = blurry
    self.screenshots = screenshots
    self.skippedLibraries = skippedLibraries
    self.issues = issues
    self.wasCancelled = wasCancelled
  }
}

public actor PhotoScanner {
  public typealias ProgressHandler = @Sendable (Int, Int) -> Void

  private let fileManager: FileManager

  public init(fileManager: FileManager = .default) { self.fileManager = fileManager }

  public func scan(
    _ roots: [URL], ignoredPaths: Set<String> = [], progress: ProgressHandler? = nil
  ) async -> PhotoScanResult {
    var files: [URL] = []
    var skippedLibraries: [String] = []
    let collector = IssueCollector()
    for root in roots {
      guard
        let enumerator = fileManager.enumerator(
          at: root,
          includingPropertiesForKeys: [.isRegularFileKey, .isPackageKey, .isSymbolicLinkKey],
          options: [.skipsHiddenFiles],
          errorHandler: { url, error in
            collector.append(ScanIssue(area: "Photos", path: url.path, message: error.localizedDescription))
            return true
          })
      else { continue }
      FileSystem.walk(enumerator) { url in
        if Task.isCancelled { return .stop }
        if FileSystem.isIgnored(url, ignoredPaths: ignoredPaths) { return .skipDescendants }
        let ext = url.pathExtension.lowercased()
        if PhotoAnalysis.libraryPackageExtensions.contains(ext) {
          skippedLibraries.append(url.path)
          return .skipDescendants
        }
        if PhotoAnalysis.imageExtensions.contains(ext),
          (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
        {
          files.append(url)
        }
        return .continue
      }
    }

    var photos: [PhotoFingerprint] = []
    for (index, url) in files.enumerated() {
      if Task.isCancelled { break }
      if index % 25 == 0 { progress?(index, files.count) }
      if let fingerprint = Self.fingerprint(url) { photos.append(fingerprint) }
    }
    progress?(files.count, files.count)

    let cancelled = Task.isCancelled
    let groups = cancelled ? [] : PhotoAnalysis.group(photos)
    return PhotoScanResult(
      photos: photos, similarGroups: groups, blurry: cancelled ? [] : PhotoAnalysis.blurry(photos),
      screenshots: photos.filter(\.isScreenshot).sorted { $0.bytes > $1.bytes },
      skippedLibraries: skippedLibraries, issues: collector.issues, wasCancelled: cancelled)
  }

  static func fingerprint(_ url: URL) -> PhotoFingerprint? {
    #if canImport(ImageIO)
      guard !PhotoAnalysis.isInsideLibraryPackage(url),
        let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary)
      else { return nil }
      let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
      let width = properties?[kCGImagePropertyPixelWidth] as? Int ?? 0
      let height = properties?[kCGImagePropertyPixelHeight] as? Int ?? 0
      guard width >= 64, height >= 64,
        let thumbnail = CGImageSourceCreateThumbnailAtIndex(
          source, 0,
          [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 256,
            kCGImageSourceShouldCacheImmediately: false,
          ] as CFDictionary)
      else { return nil }
      guard let measured = PhotoAnalysis.measure(thumbnail) else { return nil }
      let exif = properties?[kCGImagePropertyExifDictionary] as? [CFString: Any]
      let captured = (exif?[kCGImagePropertyExifDateTimeOriginal] as? String).flatMap(exifDate)
      let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
      return PhotoFingerprint(
        url: url, bytes: Int64(values?.fileSize ?? 0),
        hash: measured.hash, sharpness: measured.sharpness,
        pixelWidth: width, pixelHeight: height,
        captured: captured ?? values?.contentModificationDate,
        identity: FileSystem.fileIdentity(at: url), modified: values?.contentModificationDate)
    #else
      return nil
    #endif
  }

  #if canImport(ImageIO)
    private static func exifDate(_ value: String) -> Date? {
      let formatter = DateFormatter()
      formatter.locale = Locale(identifier: "en_US_POSIX")
      formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
      return formatter.date(from: value)
    }
  #endif
}
