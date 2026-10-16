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
  struct FingerprintReport: Sendable { let photos: [PhotoFingerprint]; let total: Int }

  static func fingerprints(progress: @escaping @Sendable (Int, Int) -> Void) async -> FingerprintReport {
    let work = Task.detached(priority: .userInitiated) { () -> FingerprintReport in
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
            // Supported PhotoKit APIs on macOS 14-26 do not expose resource byte sizes.
            // Never use undocumented KVC or download originals just to estimate savings.
            url: url(for: asset.localIdentifier), bytes: 0,
            hash: measured.hash, sharpness: measured.sharpness,
            pixelWidth: asset.pixelWidth, pixelHeight: asset.pixelHeight,
            captured: asset.creationDate, assetID: asset.localIdentifier))
      }
      progress(total, total)
      return FingerprintReport(photos: results, total: total)
    }
    return await withTaskCancellationHandler(operation: { await work.value }, onCancel: { work.cancel() })
  }

  /// Asks Photos to delete the assets. Photos shows its own confirmation; deleted items stay
  /// in Recently Deleted. Returns false when the user cancels in that dialog.
  static func delete(assetIDs: [String]) async throws -> Bool {
    let unique = Set(assetIDs)
    guard !unique.isEmpty else { return false }
    let assets = PHAsset.fetchAssets(withLocalIdentifiers: Array(unique), options: nil)
    guard assets.count == unique.count else {
      throw NSError(domain: "MacMintPhotos", code: 1,
        userInfo: [NSLocalizedDescriptionKey: "Some selected photos are no longer available. Rescan the library before deleting."])
    }
    do {
      try await PHPhotoLibrary.shared().performChanges {
        PHAssetChangeRequest.deleteAssets(assets)
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
    let bridge = PhotoThumbnailRequest(cancel: { PHImageManager.default().cancelImageRequest($0) })
    return await withTaskCancellationHandler {
      await withCheckedContinuation { continuation in
        guard bridge.begin(continuation) else { return }
        let requestID = PHImageManager.default().requestImage(
          for: asset, targetSize: target, contentMode: .aspectFill, options: options
        ) { image, info in
          if info?[PHImageResultIsDegradedKey] as? Bool == true { return }
          bridge.finish(image?.tiffRepresentation)
        }
        bridge.install(requestID)
      }
    } onCancel: { bridge.cancel() }
  }

  static func showInPhotos() {
    NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Photos.app"))
  }

}

/// Handles cancellation before request registration, synchronous callbacks, and repeated
/// PhotoKit callbacks. Canceling a view also cancels an explicitly requested cloud preview.
final class PhotoThumbnailRequest: @unchecked Sendable {
  private let lock = NSLock()
  private let cancelRequest: @Sendable (PHImageRequestID) -> Void
  private var continuation: CheckedContinuation<Data?, Never>?
  private var requestID: PHImageRequestID?
  private var finished = false
  private var cancelled = false

  init(cancel: @escaping @Sendable (PHImageRequestID) -> Void) { cancelRequest = cancel }

  func begin(_ continuation: CheckedContinuation<Data?, Never>) -> Bool {
    lock.lock()
    if finished { lock.unlock(); continuation.resume(returning: nil); return false }
    self.continuation = continuation
    lock.unlock()
    return true
  }

  func install(_ id: PHImageRequestID) {
    lock.lock(); requestID = id; let mustCancel = cancelled; lock.unlock()
    if mustCancel { cancelRequest(id) }
  }

  func finish(_ data: Data?) {
    lock.lock()
    guard !finished else { lock.unlock(); return }
    finished = true
    let pending = continuation
    continuation = nil
    lock.unlock()
    pending?.resume(returning: data)
  }

  func cancel() {
    lock.lock()
    guard !finished else { lock.unlock(); return }
    cancelled = true; finished = true
    let id = requestID, pending = continuation
    continuation = nil
    lock.unlock()
    if let id { cancelRequest(id) }
    pending?.resume(returning: nil)
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
