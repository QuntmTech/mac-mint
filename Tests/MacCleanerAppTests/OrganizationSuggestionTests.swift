import Foundation
import MacCleanerCore
import XCTest
@testable import MacCleanerApp

@MainActor
final class OrganizationSuggestionTests: XCTestCase {
  func testLatePreparationCannotOverwriteNewerSuggestionsOrClearTheirBusyState() async {
    let session = OrganizationSuggestionSession()
    let first = DelayedSuggestions(), second = DelayedSuggestions()
    var received: [String] = [], errors: [String] = []
    let old = session.start(request: { try await first.request() },
      receive: { received += $0.map(\.name) }, reportError: { errors.append($0) })
    XCTAssertTrue(session.isBusy, "Preparation must block another folder/edit before its task starts")
    await first.waitUntilStarted()
    let current = session.start(request: { try await second.request() },
      receive: { received += $0.map(\.name) }, reportError: { errors.append($0) })
    await second.waitUntilStarted()

    first.finish(.success([proposal("old.pdf")])) // Simulates an operation that ignores cancellation.
    await old.value
    XCTAssertTrue(received.isEmpty)
    XCTAssertTrue(errors.isEmpty)
    XCTAssertTrue(session.isBusy, "The old completion cannot unlock the newer request")

    second.finish(.success([proposal("current.pdf")]))
    await current.value
    XCTAssertEqual(received, ["current.pdf"])
    XCTAssertFalse(session.isBusy)
  }

  func testDismissalDiscardsLateSuccessAndErrors() async {
    for fails in [false, true] {
      let session = OrganizationSuggestionSession(), delayed = DelayedSuggestions()
      var delivered = false
      let task = session.start(request: { try await delayed.request() },
        receive: { _ in delivered = true }, reportError: { _ in delivered = true })
      await delayed.waitUntilStarted()
      session.cancel()
      XCTAssertFalse(session.isBusy)
      delayed.finish(fails ? .failure(CocoaError(.fileReadNoPermission)) : .success([proposal("late.pdf")]))
      await task.value
      XCTAssertFalse(delivered, "Closing, changing folders, or withdrawing consent invalidates the request")
    }
  }

  func testCurrentFailureIsReportedAndAllowsRetry() async {
    let session = OrganizationSuggestionSession()
    var errors: [String] = [], received: [String] = []
    let failed = session.start(request: { throw CocoaError(.fileReadNoPermission) },
      receive: { _ in XCTFail("Failed preparation has no suggestions") }, reportError: { errors.append($0) })
    await failed.value
    XCTAssertEqual(errors.count, 1)
    XCTAssertFalse(session.isBusy)
    let retry = session.start(request: { [self.proposal("retry.pdf")] },
      receive: { received = $0.map(\.name) }, reportError: { _ in XCTFail("Retry should succeed") })
    await retry.value
    XCTAssertEqual(received, ["retry.pdf"])
    XCTAssertFalse(session.isBusy)
  }

  private func proposal(_ name: String) -> OrganizationProposal {
    .init(fileID: "f0", folderID: "root", name: name, reason: "Test suggestion")
  }
}

/// Suspends without honoring cancellation, to exercise real late-result races deterministically.
@MainActor
private final class DelayedSuggestions {
  private var reply: CheckedContinuation<[OrganizationProposal], Error>?
  private var started: CheckedContinuation<Void, Never>?
  func request() async throws -> [OrganizationProposal] {
    try await withCheckedThrowingContinuation {
      reply = $0
      started?.resume(); started = nil
    }
  }
  func waitUntilStarted() async {
    if reply != nil { return }
    await withCheckedContinuation { started = $0 }
  }
  func finish(_ result: Result<[OrganizationProposal], Error>) {
    reply?.resume(with: result); reply = nil
  }
}
