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
        let fingerprint: PhotoFingerprint? = autoreleasepool {
          let asset = assets.object(at: index)
          let box = ResultBox<CGImage>()
          PHImageManager.default().requestImage(
            for: asset, targetSize: CGSize(width: 256, height: 256), contentMode: .aspectFit,
            options: request
          ) { image, _ in
            box.set(image?.cgImage(forProposedRect: nil, context: nil, hints: nil))
          }
          guard let image = box.value, let measured = PhotoAnalysis.measure(image) else { return nil }
          return PhotoFingerprint(
            // Supported PhotoKit APIs on macOS 14-26 do not expose resource byte sizes.
            // Never use undocumented KVC or download originals just to estimate savings.
            url: url(for: asset.localIdentifier), bytes: 0,
            hash: measured.hash, sharpness: measured.sharpness,
            pixelWidth: asset.pixelWidth, pixelHeight: asset.pixelHeight,
            captured: asset.creationDate, assetID: asset.localIdentifier, modified: asset.modificationDate,
            isScreenshot: asset.mediaSubtypes.contains(.photoScreenshot))
        }
        if let fingerprint { results.append(fingerprint) }
      }
      progress(total, total)
      return FingerprintReport(photos: results, total: total)
    }
    return await withTaskCancellationHandler(operation: { await work.value }, onCancel: { work.cancel() })
  }

  /// Asks Photos to delete the assets. Photos shows its own confirmation; deleted items stay
  /// in Recently Deleted. Returns false when the user cancels in that dialog.
  static func delete(photos: [PhotoFingerprint], protecting keeperPhotos: [PhotoFingerprint] = []) async throws -> Bool {
    let unique = Set(photos.compactMap(\.assetID))
    let keepers = Set(keeperPhotos.compactMap(\.assetID))
    let expected = (photos + keeperPhotos).compactMap { photo in
      photo.assetID.map { PhotoDeletionPolicy.Snapshot(id: $0, modified: photo.modified) }
    }
    guard !unique.isEmpty else { return false }
    if let problem = PhotoDeletionPolicy.problem(selected: unique, keepers: keepers, expected: expected,
      observed: snapshots(for: unique.union(keepers))) {
      throw NSError(domain: "MacMintPhotos", code: 1,
        userInfo: [NSLocalizedDescriptionKey: problem])
    }
    let validation = ResultBox<String>()
    do {
      try await PHPhotoLibrary.shared().performChanges {
        if let problem = PhotoDeletionPolicy.problem(selected: unique, keepers: keepers, expected: expected,
          observed: snapshots(for: unique.union(keepers))) {
          validation.set(problem)
          return
        }
        PHAssetChangeRequest.deleteAssets(PHAsset.fetchAssets(withLocalIdentifiers: Array(unique), options: nil))
      }
      if let problem = validation.value {
        throw NSError(domain: "MacMintPhotos", code: 1, userInfo: [NSLocalizedDescriptionKey: problem])
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
    let pixels = min(1400, max(64, side * 2))
    if let data = await requestThumbnail(asset, pixels: pixels, allowNetwork: allowNetwork) { return data }
    guard !Task.isCancelled, !allowNetwork, pixels > 256 else { return nil }
    // A local 256px analysis thumbnail can exist while a 1200px preview requires iCloud.
    // Use that local representation instead of claiming the entire asset is unavailable.
    return await requestThumbnail(asset, pixels: 256, allowNetwork: false)
  }

  private static func requestThumbnail(_ asset: PHAsset, pixels: CGFloat, allowNetwork: Bool) async -> Data? {
    let options = PHImageRequestOptions()
    options.deliveryMode = .opportunistic
    options.isNetworkAccessAllowed = allowNetwork
    options.resizeMode = .fast
    let target = CGSize(width: pixels, height: pixels)
    let bridge = PhotoThumbnailRequest(cancel: { PHImageManager.default().cancelImageRequest($0) })
    return await withTaskCancellationHandler {
      await withCheckedContinuation { continuation in
        guard bridge.begin(continuation) else { return }
        bridge.scheduleTimeout(seconds: allowNetwork ? 45 : 10)
        let requestID = PHImageManager.default().requestImage(
          for: asset, targetSize: target, contentMode: .aspectFit, options: options
        ) { image, info in
          bridge.receive(image?.tiffRepresentation, degraded: info?[PHImageResultIsDegradedKey] as? Bool == true)
        }
        bridge.install(requestID)
      }
    } onCancel: { bridge.cancel() }
  }

  static func showInPhotos() {
    NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Photos.app"))
  }

  private static func snapshots(for identifiers: Set<String>) -> [PhotoDeletionPolicy.Snapshot] {
    let assets = PHAsset.fetchAssets(withLocalIdentifiers: Array(identifiers), options: nil)
    return (0..<assets.count).map {
      let asset = assets.object(at: $0)
      return PhotoDeletionPolicy.Snapshot(id: asset.localIdentifier, modified: asset.modificationDate)
    }
  }

}

enum PhotoDeletionPolicy {
  struct Snapshot: Hashable, Sendable { let id: String; let modified: Date? }

  static func problem(selected: Set<String>, keepers: Set<String>, expected: [Snapshot], observed: [Snapshot]) -> String? {
    if let problem = problem(selected: selected, keepers: keepers, available: Set(observed.map(\.id))) { return problem }
    let reviewed = Set(expected.map(\.id))
    guard reviewed == selected.union(keepers) else { return "The reviewed photo metadata is incomplete. Rescan before deleting." }
    let current = Dictionary(observed.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    guard expected.allSatisfy({ current[$0.id]?.modified == $0.modified }) else {
      return "A selected photo or keeper changed since this scan. Rescan and review the updated photos before deleting."
    }
    return nil
  }

  static func problem(selected: Set<String>, keepers: Set<String>, available: Set<String>) -> String? {
    guard selected.isDisjoint(with: keepers) else {
      return "The selection includes a photo you are keeping. Review the comparison before deleting."
    }
    guard keepers.isSubset(of: available) else {
      return "A photo you chose to keep is no longer available. Rescan the library before deleting other copies."
    }
    guard selected.isSubset(of: available) else {
      return "Some selected photos are no longer available. Rescan the library before deleting."
    }
    return nil
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
  private var fallback: Data?
  private var timeout: DispatchWorkItem?

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
    let result = data ?? fallback
    fallback = nil
    timeout?.cancel(); timeout = nil
    let pending = continuation
    continuation = nil
    lock.unlock()
    pending?.resume(returning: result)
  }

  func receive(_ data: Data?, degraded: Bool) {
    if !degraded { finish(data); return }
    lock.lock(); if !finished, let data { fallback = data }; lock.unlock()
  }

  func scheduleTimeout(seconds: TimeInterval) {
    let work = DispatchWorkItem { [weak self] in self?.expire() }
    lock.lock()
    guard !finished else { lock.unlock(); return }
    timeout = work
    lock.unlock()
    DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + seconds, execute: work)
  }

  func expire() {
    lock.lock()
    guard !finished else { lock.unlock(); return }
    cancelled = true; finished = true
    let id = requestID, pending = continuation, result = fallback
    continuation = nil; fallback = nil; timeout?.cancel(); timeout = nil
    lock.unlock()
    if let id { cancelRequest(id) }
    pending?.resume(returning: result)
  }

  func cancel() {
    lock.lock()
    guard !finished else { lock.unlock(); return }
    cancelled = true; finished = true
    fallback = nil; timeout?.cancel(); timeout = nil
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
