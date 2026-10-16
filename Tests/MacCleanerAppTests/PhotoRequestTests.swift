import Foundation
import XCTest
@testable import MacCleanerApp

final class PhotoRequestTests: XCTestCase {
  func testPhotoDeletionRevalidatesAvailableKeepersAndTheCompleteSelection() {
    XCTAssertNil(PhotoDeletionPolicy.problem(selected: ["copy"], keepers: ["keeper"], available: ["copy", "keeper"]))
    XCTAssertTrue(PhotoDeletionPolicy.problem(selected: ["copy"], keepers: ["keeper"], available: ["copy"])?.contains("chose to keep") == true)
    XCTAssertTrue(PhotoDeletionPolicy.problem(selected: ["copy", "keeper"], keepers: ["keeper"], available: ["copy", "keeper"])?.contains("selection includes") == true)
    XCTAssertTrue(PhotoDeletionPolicy.problem(selected: ["copy", "missing"], keepers: ["keeper"], available: ["copy", "keeper"])?.contains("selected photos") == true)
  }

  func testCancelBeforeRegistrationFinishesAndCancelsLateRequestExactlyOnce() async {
    let calls = CancelledRequests()
    let bridge = PhotoThumbnailRequest(cancel: { calls.append($0) })
    let result: Data? = await withCheckedContinuation { continuation in
      XCTAssertTrue(bridge.begin(continuation))
      bridge.cancel()
      bridge.install(42)
      bridge.finish(Data([1]))
      bridge.cancel()
    }
    XCTAssertNil(result)
    XCTAssertEqual(calls.values, [42])
  }

  func testAlreadyCancelledTaskCannotStartAnotherRequest() async {
    let calls = CancelledRequests()
    let bridge = PhotoThumbnailRequest(cancel: { calls.append($0) })
    bridge.cancel()
    let result: Data? = await withCheckedContinuation { continuation in
      XCTAssertFalse(bridge.begin(continuation))
    }
    XCTAssertNil(result)
    XCTAssertTrue(calls.values.isEmpty)
  }

  func testSynchronousAndRepeatedCallbacksResumeOnceWithoutCancellingCompletedRequest() async {
    let calls = CancelledRequests()
    let bridge = PhotoThumbnailRequest(cancel: { calls.append($0) })
    let expected = Data([1, 2, 3])
    let result: Data? = await withCheckedContinuation { continuation in
      XCTAssertTrue(bridge.begin(continuation))
      bridge.finish(expected)
      bridge.install(42)
      bridge.finish(Data([4]))
      bridge.cancel()
    }
    XCTAssertEqual(result, expected)
    XCTAssertTrue(calls.values.isEmpty)
  }
}

private final class CancelledRequests: @unchecked Sendable {
  private let lock = NSLock()
  private var storage: [Int32] = []
  var values: [Int32] { lock.lock(); defer { lock.unlock() }; return storage }
  func append(_ id: Int32) { lock.lock(); defer { lock.unlock() }; storage.append(id) }
}
