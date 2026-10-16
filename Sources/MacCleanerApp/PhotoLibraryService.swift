import AppKit
import Foundation
import MacCleanerCore
import Photos

/// Apple Photos integration. Library photos are never touched as files: analysis uses
/// PhotoKit thumbnails (local only — nothing is downloaded from iCloud), and removal asks
/// Photos to delete the assets, which shows the system confirmation and keeps them in
/// Recently Deleted for 30 days.
enum PhotoLibraryService {
  static let urlScheme = "photos-asset"

  static var isAuthorized: Bool {
    let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
    return status == .authorized || status == .limited
  }

  static func requestAccess() async -> Bool {
    let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
    return status == .authorized || status == .limited
  }

  static func url(for assetID: String) -> URL {
    URL(string: "\(urlScheme):///\(assetID.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? assetID)")!
  }

  /// Fingerprints every still image in the library (videos and Live Photo motion are ignored).
  static func fingerprints(progress: @escaping @Sendable (Int, Int) -> Void) async -> [PhotoFingerprint] {
    await Task.detached(priority: .userInitiated) { () -> [PhotoFingerprint] in
      let options = PHFetchOptions()
      options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]
      options.predicate = NSPredicate(format: "mediaType == %d", PHAssetMediaType.image.rawValue)
      let assets = PHAsset.fetchAssets(with: options)

      let request = PHImageRequestOptions()
      request.isSynchronous = true
      request.deliveryMode = .highQualityFormat
      request.resizeMode = .fast
      request.isNetworkAccessAllowed = false

      var results: [PhotoFingerprint] = []
      results.reserveCapacity(assets.count)
      let total = assets.count
      for index in 0..<total {
        if Task.isCancelled { break }
        if index % 50 == 0 { progress(index, total) }
        let asset = assets.object(at: index)
        let box = ResultBox<CGImage>()
        PHImageManager.default().requestImage(
          for: asset, targetSize: CGSize(width: 256, height: 256), contentMode: .aspectFit,
          options: request
        ) { image, _ in
          box.set(image?.cgImage(forProposedRect: nil, context: nil, hints: nil))
        }
        guard let image = box.value, let measured = PhotoAnalysis.measure(image) else { continue }
        results.append(
          PhotoFingerprint(
            url: url(for: asset.localIdentifier), bytes: fileSize(of: asset),
            hash: measured.hash, sharpness: measured.sharpness,
            pixelWidth: asset.pixelWidth, pixelHeight: asset.pixelHeight,
            captured: asset.creationDate, assetID: asset.localIdentifier))
      }
      progress(total, total)
      return results
    }.value
  }

  /// Asks Photos to delete the assets. Photos shows its own confirmation; deleted items stay
  /// in Recently Deleted. Returns false when the user cancels in that dialog.
  static func delete(assetIDs: [String]) async throws -> Bool {
    guard PHAsset.fetchAssets(withLocalIdentifiers: assetIDs, options: nil).count > 0 else {
      return false
    }
    do {
      try await PHPhotoLibrary.shared().performChanges {
        PHAssetChangeRequest.deleteAssets(
          PHAsset.fetchAssets(withLocalIdentifiers: assetIDs, options: nil))
      }
      return true
    } catch let error as NSError where error.domain == "PHPhotosErrorDomain" && error.code == 3072 {
      return false  // user cancelled
    }
  }

  /// Image data rather than NSImage so it can cross actors; build the image on the main actor.
  static func thumbnailData(assetID: String, side: CGFloat, allowNetwork: Bool = false) async -> Data? {
    guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [assetID], options: nil).firstObject
    else { return nil }
    let options = PHImageRequestOptions()
    options.deliveryMode = .highQualityFormat
    options.isNetworkAccessAllowed = allowNetwork
    options.resizeMode = .fast
    let target = CGSize(width: side * 2, height: side * 2)
    let data: Data? = await withCheckedContinuation { continuation in
      let once = ResultBox<Bool>()
      PHImageManager.default().requestImage(
        for: asset, targetSize: target, contentMode: .aspectFill, options: options
      ) { image, info in
        if info?[PHImageResultIsDegradedKey] as? Bool == true { return }
        // The handler can fire more than once; resume exactly once.
        guard once.claim() else { return }
        continuation.resume(returning: image?.tiffRepresentation)
      }
    }
    return data
  }

  static func showInPhotos() {
    NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Photos.app"))
  }

  private static func fileSize(of asset: PHAsset) -> Int64 {
    PHAssetResource.assetResources(for: asset)
      .compactMap { ($0.value(forKey: "fileSize") as? NSNumber)?.int64Value }
      .max() ?? 0
  }
}

/// Thread-safe single-value holder for PhotoKit callbacks.
final class ResultBox<Value>: @unchecked Sendable {
  private let lock = NSLock()
  private var stored: Value?
  private var claimed = false

  var value: Value? {
    lock.lock()
    defer { lock.unlock() }
    return stored
  }

  func set(_ newValue: Value?) {
    lock.lock()
    stored = newValue
    lock.unlock()
  }

  /// True the first time only.
  func claim() -> Bool {
    lock.lock()
    defer { lock.unlock() }
    if claimed { return false }
    claimed = true
    return true
  }
}
