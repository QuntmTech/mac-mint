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

  private func photo(_ name: String) -> PhotoFingerprint {
    PhotoFingerprint(url: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Pictures/" + name),
      bytes: 100, hash: 1, sharpness: 100, pixelWidth: 100, pixelHeight: 100)
  }
}
