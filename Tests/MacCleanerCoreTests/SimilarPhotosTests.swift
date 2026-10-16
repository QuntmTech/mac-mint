import XCTest

@testable import MacCleanerCore

final class SimilarPhotosTests: XCTestCase {
  private func gradient(_ seed: Int, noise: Int = 0) -> [UInt8] {
    (0..<72).map { i in
      let base = (i % 9) * 25 + (i / 9) * seed
      return UInt8(clamping: base + ((i * 7 + noise) % 5) * (noise > 0 ? 1 : 0))
    }
  }

  func testDifferenceHashIsStableAndSensitive() {
    let a = PhotoAnalysis.differenceHash(gray9x8: gradient(3))
    let same = PhotoAnalysis.differenceHash(gray9x8: gradient(3))
    let reversed = PhotoAnalysis.differenceHash(gray9x8: gradient(3).reversed())
    XCTAssertEqual(a, same)
    XCTAssertGreaterThan(PhotoAnalysis.distance(a, reversed), 20)
  }

  func testSharpnessSeparatesDetailFromFlat() {
    let flat = [UInt8](repeating: 128, count: 64 * 64)
    let checker = (0..<(64 * 64)).map { i in UInt8(((i % 64) + (i / 64)) % 2 == 0 ? 0 : 255) }
    XCTAssertEqual(PhotoAnalysis.sharpness(gray: flat, width: 64, height: 64), 0, accuracy: 0.001)
    XCTAssertGreaterThan(PhotoAnalysis.sharpness(gray: checker, width: 64, height: 64), 10_000)
  }

  func testGroupingClustersNearHashesAndPicksSharpestKeeper() {
    let base: UInt64 = 0xF0F0_F0F0_0F0F_0F0F
    let photos = [
      photo("a.jpg", hash: base, sharpness: 100, bytes: 3_000_000),
      photo("b.jpg", hash: base ^ 0b111, sharpness: 900, bytes: 2_000_000),  // 3 bits away, sharpest
      photo("c.jpg", hash: base ^ 0b1_0000_0001, sharpness: 300, bytes: 1_000_000),
      photo("far.jpg", hash: ~base, sharpness: 500, bytes: 5_000_000),
    ]
    let groups = PhotoAnalysis.group(photos, threshold: 6)
    XCTAssertEqual(groups.count, 1)
    let group = groups[0]
    XCTAssertEqual(Set(group.photos.map(\.url.lastPathComponent)), ["a.jpg", "b.jpg", "c.jpg"])
    XCTAssertEqual(group.keeper.url.lastPathComponent, "b.jpg")
    XCTAssertEqual(group.reclaimableBytes, 4_000_000)
  }

  func testComparableSharpnessPrefersHigherResolution() {
    let photos = [
      photo("small.jpg", hash: 1, sharpness: 500, width: 1000, height: 800),
      photo("large.jpg", hash: 1, sharpness: 480, width: 4000, height: 3000),
    ]
    XCTAssertEqual(PhotoAnalysis.group(photos).first?.keeper.url.lastPathComponent, "large.jpg")
  }

  func testHardLinksAreNotSimilarPhotos() {
    let photos = [
      photo("one.jpg", hash: 7, sharpness: 1, identity: "1:42"),
      photo("link.jpg", hash: 7, sharpness: 1, identity: "1:42"),
    ]
    XCTAssertTrue(PhotoAnalysis.group(photos).isEmpty)
  }

  func testBlurryIsRelativeAndIgnoresScreenshots() {
    var photos = (0..<10).map { photo("p\($0).jpg", hash: UInt64($0) << 20, sharpness: 1000) }
    photos.append(photo("soft.jpg", hash: 99 << 40, sharpness: 20))
    photos.append(photo("Screenshot 2026-10-01.png", hash: 98 << 40, sharpness: 5))
    XCTAssertEqual(PhotoAnalysis.blurry(photos).map(\.url.lastPathComponent), ["soft.jpg"])
    XCTAssertTrue(PhotoAnalysis.blurry(Array(photos.prefix(5))).isEmpty, "too few photos to judge")
  }

  func testLibraryPackagesAreRecognised() {
    XCTAssertTrue(
      PhotoAnalysis.isInsideLibraryPackage(
        URL(fileURLWithPath: "/Users/u/Pictures/Photos Library.photoslibrary/originals/A/x.heic")))
    XCTAssertFalse(PhotoAnalysis.isInsideLibraryPackage(URL(fileURLWithPath: "/Users/u/Pictures/trip/x.heic")))
  }

  func testScannerSkipsPhotoLibraryPackages() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let library = root.appendingPathComponent("Photos Library.photoslibrary/originals")
    try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
    try Data([1, 2, 3]).write(to: library.appendingPathComponent("a.jpg"))

    let result = await PhotoScanner().scan([root])
    XCTAssertEqual(result.skippedLibraries.map { URL(fileURLWithPath: $0).lastPathComponent }, ["Photos Library.photoslibrary"])
    XCTAssertTrue(result.photos.isEmpty)
  }

  private func photo(
    _ name: String, hash: UInt64, sharpness: Double, bytes: Int64 = 1_000_000, width: Int = 3000,
    height: Int = 2000, identity: String? = nil
  ) -> PhotoFingerprint {
    PhotoFingerprint(
      url: URL(fileURLWithPath: "/Users/u/Pictures/\(name)"), bytes: bytes, hash: hash,
      sharpness: sharpness, pixelWidth: width, pixelHeight: height, identity: identity)
  }
}

final class PhotoPlanTests: XCTestCase {
  func testLibraryAssetsNeverBecomeFilePlanItems() {
    let asset = PhotoFingerprint(
      url: URL(string: "photos-asset:///ABC")!, bytes: 10, hash: 1, sharpness: 1, pixelWidth: 100,
      pixelHeight: 100, assetID: "ABC")
    XCTAssertNil(PlanItem.photo(asset, keeper: nil, reason: ""))
    let inLibrary = PhotoFingerprint(
      url: URL(fileURLWithPath: "/Users/u/Pictures/P.photoslibrary/originals/x.jpg"), bytes: 10,
      hash: 1, sharpness: 1, pixelWidth: 100, pixelHeight: 100)
    XCTAssertNil(PlanItem.photo(inLibrary, keeper: nil, reason: ""))
  }

  func testPlannerRefusesToRemoveTheKeptPhoto() {
    let a = PhotoFingerprint(
      url: URL(fileURLWithPath: "/Users/u/Pictures/a.jpg"), bytes: 10, hash: 1, sharpness: 9,
      pixelWidth: 100, pixelHeight: 100)
    let b = PhotoFingerprint(
      url: URL(fileURLWithPath: "/Users/u/Pictures/b.jpg"), bytes: 10, hash: 1, sharpness: 1,
      pixelWidth: 100, pixelHeight: 100)
    // b keeps a, and a is also selected (as a large file, say) — b must be rejected.
    let items = [
      PlanItem.photo(b, keeper: a, reason: "similar")!,
      PlanItem.photo(a, keeper: nil, reason: "selected elsewhere")!,
    ]
    let plan = OperationPlanner.plan(title: "Photos", items: items)
    XCTAssertEqual(plan.items.map(\.url.lastPathComponent), ["a.jpg"])
    XCTAssertEqual(plan.excluded.map(\.url.lastPathComponent), ["b.jpg"])
  }
}
