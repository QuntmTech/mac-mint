import XCTest

@testable import MacCleanerCore

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

final class AIExplainLocalTests: XCTestCase {
  func testUnrecognizedNamesAreExplainedLocallyWithoutARequest() async throws {
    let box = RequestBox()
    let client = AccountClient(baseURL: URL(string: "https://example.test")!) { request in
      box.set(request)
      throw URLError(.badServerResponse)
    }
    for (kind, name) in [(AIExplainKind.libraryItem, "Jane's Project"), (.launchAgent, "com.jane.private"), (.developerTool, "Secret tool")] {
      let request = AIExplainRequest(kind: kind, identifier: name, location: "Caches")
      XCTAssertTrue(request.isPlaceholder)
      let response = try await client.explain(request, token: "t")
      XCTAssertEqual(response.model, "local")
      XCTAssertEqual(response.explanation.verdict, .unknown)
      XCTAssertEqual(response.explanation.confidence, "low")
      XCTAssertEqual(response.explanation.category, kind == .developerTool ? "developer" : "unknown")
    }
    XCTAssertNil(box.request, "Placeholder explanations must not reach the server")
    XCTAssertFalse(AIExplainRequest(kind: .libraryItem, identifier: "com.spotify.client", location: "Caches").isPlaceholder)
    XCTAssertFalse(AIExplainRequest(kind: .developerTool, identifier: "Xcode", location: "Developer").isPlaceholder)
  }
}
