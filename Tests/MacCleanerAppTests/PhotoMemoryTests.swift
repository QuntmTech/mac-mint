import AppKit
import Foundation
import MacCleanerCore
import XCTest
@testable import MacCleanerApp

@MainActor
final class PhotoMemoryTests: XCTestCase {
  func testLargeFolderScanKeepsDecodedImagesTransient() async throws {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("macmint-photo-memory-" + UUID().uuidString)
    defer { try? fm.removeItem(at: root) }
    try fm.createDirectory(at: root, withIntermediateDirectories: true)
    let data: Data = try autoreleasepool {
      let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 256, pixelsHigh: 256,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 1024, bitsPerPixel: 32))
      let pixels = try XCTUnwrap(bitmap.bitmapData)
      for index in 0..<(256 * 256) {
        pixels[index * 4] = UInt8(index % 255); pixels[index * 4 + 1] = UInt8((index / 256) % 255)
        pixels[index * 4 + 2] = 100; pixels[index * 4 + 3] = 255
      }
      return try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
    }
    let first = root.appendingPathComponent("0.png"); try data.write(to: first)
    // Warm decoding, metadata and analysis before measuring the large scan's incremental cost.
    _ = await PhotoScanner().scan([root])
    for index in 1..<2000 {
      try autoreleasepool { try data.write(to: root.appendingPathComponent("\(index).png")) }
    }
    let pid = ProcessInfo.processInfo.processIdentifier
    let baseline = try XCTUnwrap(ResourceSampler.usage(pid)?.ri_phys_footprint)
    let peak = ResultBox<UInt64>(); peak.set(baseline)
    let result = await PhotoScanner().scan([root], progress: { _, _ in
      if let bytes = ResourceSampler.usage(pid)?.ri_phys_footprint { peak.set(max(peak.value ?? 0, bytes)) }
    })
    XCTAssertEqual(result.photos.count, 2000)
    let after = try XCTUnwrap(ResourceSampler.usage(pid)?.ri_phys_footprint)
    let peakDelta = max(peak.value ?? baseline, max(baseline, after)) - baseline
    let retainedDelta = after - min(baseline, after)
    print("PHOTO MEMORY: 2000 decoded images; incremental peak \(peakDelta / 1_048_576) MiB; retained \(retainedDelta / 1_048_576) MiB")
    XCTAssertLessThan(peakDelta, 128 * 1_048_576, "Decoded pixels must not accumulate across the scan")
    XCTAssertLessThan(retainedDelta, 96 * 1_048_576, "Retained metadata must not retain 2000 decoded images")
  }
  func testPreviewReleaseDropsPixelCacheWithoutDiscardingPhotoChoices() {
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 32, pixelsHigh: 32,
      bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
      colorSpaceName: .deviceRGB, bytesPerRow: 128, bitsPerPixel: 32)!
    let image = NSImage(size: NSSize(width: 32, height: 32)); image.addRepresentation(bitmap)
    let oldGeneration = PreviewCaches.photos.generation
    PreviewCaches.photos.insert(image, for: "fixture")
    XCTAssertGreaterThan(PreviewCaches.photos.storedCost, 0)
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let model = AppViewModel(supportDirectory: root); model.selectedPhotoIDs = ["photos:keep-my-choice"]
    PreviewCaches.release()
    XCTAssertEqual(PreviewCaches.photos.storedCost, 0)
    XCTAssertNotEqual(PreviewCaches.photos.generation, oldGeneration)
    XCTAssertEqual(model.selectedPhotoIDs, ["photos:keep-my-choice"])
    XCTAssertEqual(PreviewCaches.photos.byteLimit, 8 * 1_048_576)
  }
}
