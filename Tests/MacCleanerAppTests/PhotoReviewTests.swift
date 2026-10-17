import AppKit
import MacCleanerCore
import XCTest
@testable import MacCleanerApp

@MainActor
final class PhotoReviewTests: XCTestCase {
  func testPreviewCacheEvictsLeastRecentlyUsedAndRejectsOversizedImages() {
    let cache = PreviewImageCache(byteLimit: 1_000, countLimit: 2)
    func image(_ side: Int = 10) -> NSImage {
      let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: side * 4, bitsPerPixel: 32)!
      let image = NSImage(size: NSSize(width: side, height: side)); image.addRepresentation(rep); return image
    }
    cache.insert(image(), for: "a"); cache.insert(image(), for: "b")
    XCTAssertNotNil(cache.image(for: "a"))
    cache.insert(image(), for: "c")
    XCTAssertNil(cache.image(for: "b")); XCTAssertNotNil(cache.image(for: "a"))
    cache.insert(image(100), for: "large")
    XCTAssertNil(cache.image(for: "large")); XCTAssertLessThanOrEqual(cache.storedCost, 1_000)
    cache.insert(image(), for: "a")
    XCTAssertEqual(cache.count, 2); XCTAssertEqual(cache.storedCost, 1_000)
    cache.removeAll(); XCTAssertEqual(cache.count, 0); XCTAssertEqual(cache.storedCost, 0)
  }

  func testDeckChoicesCannotSelectKeeperAndUndoCanUnqueueAnotherCopy() throws {
    let support = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: support) }
    let model = AppViewModel(supportDirectory: support)
    let keeper = photo("best.jpg"), copy = photo("copy.jpg")
    let group = SimilarPhotoGroup(id: "set", photos: [keeper, copy], keeperIndex: 0)
    model.photoScan = PhotoScanResult(photos: [keeper, copy], similarGroups: [group], blurry: [],
      screenshots: [], skippedLibraries: [], issues: [], wasCancelled: false)
    model.togglePhoto(keeper); XCTAssertTrue(model.selectedPhotoIDs.isEmpty)
    model.togglePhoto(copy); XCTAssertEqual(model.selectedPhotoIDs, [copy.id])
    model.togglePhoto(copy); XCTAssertTrue(model.selectedPhotoIDs.isEmpty)
    model.keepInstead(copy)
    model.togglePhoto(keeper); XCTAssertEqual(model.selectedPhotoIDs, [keeper.id])
    model.togglePhoto(copy); XCTAssertEqual(model.selectedPhotoIDs, [keeper.id])
  }

  func testDeckResumesAfterNavigationAndUndoRestoresTheSharedQueue() {
    let (model, support) = reviewModel()
    defer { try? FileManager.default.removeItem(at: support) }
    let keeper = photo("best.jpg"), copy = photo("copy.jpg")
    model.photoScan = scan([keeper, copy], keeper: keeper)

    XCTAssertNil(model.decidePhotoReview(removing: false))
    XCTAssertNil(model.decidePhotoReview(removing: true))
    XCTAssertEqual(model.photoReviewSession.cursor, 2)
    XCTAssertEqual(model.selectedPhotoIDs, [copy.id])
    model.selectedSection = .storage
    model.selectedSection = .photos
    XCTAssertEqual(model.photoReviewSession.cursor, 2, "Navigation must not restart the deck")
    XCTAssertNil(model.undoPhotoReview())
    XCTAssertEqual(model.photoReviewSession.cursor, 1)
    XCTAssertTrue(model.selectedPhotoIDs.isEmpty)
    XCTAssertEqual(model.photoReviewSession.choices.count, 1)
  }

  func testNewScanResetsWhileRemovalsAndCancelledScanningPreservePosition() {
    let (model, support) = reviewModel()
    defer { try? FileManager.default.removeItem(at: support) }
    let keeper = photo("best.jpg"), copy = photo("copy.jpg")
    model.photoScan = scan([keeper, copy], keeper: keeper)
    let generation = model.photoScan?.generation
    _ = model.decidePhotoReview(removing: false)
    model.isScanning = true
    _ = model.decidePhotoReview(removing: true)
    XCTAssertEqual(model.photoReviewSession.cursor, 1)
    model.isScanning = false // Cancelled scans retain the last completed scan.
    XCTAssertEqual(model.photoReviewSession.cursor, 1)
    _ = model.decidePhotoReview(removing: true)

    model.removePhotos { $0.id == copy.id }
    XCTAssertEqual(model.photoScan?.generation, generation, "Pruning keeps the scan's identity")
    XCTAssertEqual(model.photoReviewSession.cursor, 1, "Every remaining photo was already reviewed")
    XCTAssertEqual(model.photoReviewSession.choices.map(\.photoID), [keeper.id], "Removed photos leave Undo")
    XCTAssertNil(model.undoPhotoReview())
    XCTAssertEqual(model.photoReviewSession.cursor, 0)
    XCTAssertFalse(model.selectedPhotoIDs.contains(copy.id), "Undo cannot requeue a removed finding")

    _ = model.decidePhotoReview(removing: false)
    model.photoScan = scan([keeper, copy], keeper: keeper)
    XCTAssertEqual(model.photoReviewSession.cursor, 0, "Even a rescan with the same paths starts a new review")
    XCTAssertTrue(model.photoReviewSession.choices.isEmpty)
  }

  func testDeletingReviewedPhotosContinuesAtTheNextUnreviewedPhoto() {
    let (model, support) = reviewModel()
    defer { try? FileManager.default.removeItem(at: support) }
    let photos = ["a.jpg", "b.jpg", "c.jpg", "d.jpg", "e.jpg"].map(photo)
    model.photoScan = PhotoScanResult(photos: photos, similarGroups: [], blurry: [], screenshots: [],
      skippedLibraries: [], issues: [], wasCancelled: false)
    let generation = model.photoScan?.generation
    XCTAssertNil(model.decidePhotoReview(removing: true))  // a queued
    XCTAssertNil(model.decidePhotoReview(removing: false)) // b kept
    XCTAssertEqual(model.photoReviewSession.cursor, 2)

    // The reviewed photo is deleted (as after the review sheet or Photos confirmation).
    model.removePhotos { $0.id == photos[0].id }
    XCTAssertEqual(model.photoScan?.generation, generation)
    XCTAssertEqual(model.allScannedPhotos[model.photoReviewSession.cursor].id, photos[2].id, "The deck stays on c")
    XCTAssertEqual(model.photoReviewSession.choices.map(\.photoID), [photos[1].id])

    // The photo under the cursor disappears: continue with the next one.
    model.removePhotos { $0.id == photos[2].id }
    XCTAssertEqual(model.allScannedPhotos[model.photoReviewSession.cursor].id, photos[3].id)
    XCTAssertNil(model.undoPhotoReview())
    XCTAssertEqual(model.allScannedPhotos[model.photoReviewSession.cursor].id, photos[1].id, "Undo follows photo IDs")
    XCTAssertTrue(model.photoReviewSession.choices.isEmpty)
  }

  func testUndoCannotQueueANewKeeperAndRestartLeavesSelectionsAlone() {
    let (model, support) = reviewModel()
    defer { try? FileManager.default.removeItem(at: support) }
    let keeper = photo("best.jpg"), copy = photo("copy.jpg")
    model.photoScan = scan([copy, keeper], keeper: keeper)
    model.togglePhoto(copy)
    _ = model.decidePhotoReview(removing: false)
    model.keepInstead(copy)
    XCTAssertNotNil(model.undoPhotoReview())
    XCTAssertTrue(model.selectedPhotoIDs.isEmpty)
    XCTAssertEqual(model.photoReviewSession.cursor, 1)

    model.togglePhoto(keeper)
    model.restartPhotoReview()
    XCTAssertEqual(model.photoReviewSession.cursor, 0)
    XCTAssertTrue(model.photoReviewSession.choices.isEmpty)
    XCTAssertEqual(model.selectedPhotoIDs, [keeper.id], "Restart changes browsing, never the removal queue")
    XCTAssertNotNil(model.decidePhotoReview(removing: true))
    XCTAssertEqual(model.photoReviewSession.cursor, 0)
  }

  private func reviewModel() -> (AppViewModel, URL) {
    let support = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    return (AppViewModel(supportDirectory: support), support)
  }

  private func scan(_ photos: [PhotoFingerprint], keeper: PhotoFingerprint) -> PhotoScanResult {
    PhotoScanResult(photos: photos,
      similarGroups: [.init(id: "set", photos: photos, keeperIndex: photos.firstIndex { $0.id == keeper.id }!)],
      blurry: [], screenshots: [], skippedLibraries: [], issues: [], wasCancelled: false)
  }

  private func photo(_ name: String) -> PhotoFingerprint {
    PhotoFingerprint(url: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Pictures/" + name),
      bytes: 100, hash: 1, sharpness: 100, pixelWidth: 100, pixelHeight: 100)
  }
}
