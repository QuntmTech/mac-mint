import AppKit
import XCTest
@testable import MacCleanerApp

@MainActor
final class ThumbnailRequestTests: XCTestCase {
  func testAlreadyCancelledTaskDoesNotStartNativeGeneration() async {
    var started = false, cancelled = false
    let request = ThumbnailRequest(generate: { started = true; return NSImage(size: .init(width: 10, height: 10)) },
      cancel: { cancelled = true })
    var result: NSImage?
    let task = Task { result = await request.image() }
    task.cancel()
    await task.value
    XCTAssertNil(result)
    XCTAssertFalse(started)
    XCTAssertFalse(cancelled, "There is no native request to cancel")
  }

  func testCancellationStopsNativeWorkOnceAndDiscardsALateImage() async {
    let generator = DelayedThumbnail()
    var cancellations = 0
    let request = ThumbnailRequest(generate: { await generator.image() },
      cancel: { cancellations += 1; generator.cancel() })
    var result: NSImage?
    let task = Task { result = await request.image() }
    await generator.waitUntilStarted()
    task.cancel(); task.cancel()
    await generator.waitUntilCancelled()
    generator.finish()
    await task.value
    XCTAssertNil(result, "A native provider may return an image after cancellation")
    XCTAssertEqual(cancellations, 1)
  }

  func testCompletedRequestReturnsItsImageWithoutCancellingNativeWork() async {
    let expected = NSImage(size: .init(width: 10, height: 10))
    var cancellations = 0
    let request = ThumbnailRequest(generate: { expected }, cancel: { cancellations += 1 })
    var result: NSImage?
    let task = Task { result = await request.image() }
    await task.value
    task.cancel()
    XCTAssertTrue(result === expected)
    XCTAssertEqual(cancellations, 0)
  }
}

@MainActor
private final class DelayedThumbnail {
  private var reply: CheckedContinuation<NSImage, Never>?
  private var started: CheckedContinuation<Void, Never>?
  private var cancellation: CheckedContinuation<Void, Never>?
  private var cancelled = false
  func image() async -> NSImage {
    await withCheckedContinuation {
      reply = $0; started?.resume(); started = nil
    }
  }
  func waitUntilStarted() async {
    if reply != nil { return }
    await withCheckedContinuation { started = $0 }
  }
  func waitUntilCancelled() async {
    if cancelled { return }
    await withCheckedContinuation { cancellation = $0 }
  }
  func cancel() {
    cancelled = true; cancellation?.resume(); cancellation = nil
  }
  func finish() {
    reply?.resume(returning: NSImage(size: .init(width: 10, height: 10))); reply = nil
  }
}
