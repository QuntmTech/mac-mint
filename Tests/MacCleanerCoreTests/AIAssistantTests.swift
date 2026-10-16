import XCTest

@testable import MacCleanerCore

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

final class AIAssistantTests: XCTestCase {
  private let home = URL(fileURLWithPath: "/Users/coltonwood")

  // MARK: Anonymization

  func testSanitizeStripsAccountNameAndEmailsAndDropsOutsidePaths() {
    XCTAssertNil(AIContextBuilder.sanitize("/Users/coltonwood/Documents/coltonwood-taxes", home: home))
    XCTAssertNil(AIContextBuilder.sanitize("/Users/coltonwood/Library/Mail/jane.doe@example.com/INBOX", home: home))
    XCTAssertNil(AIContextBuilder.sanitize("/Applications/Xcode.app", home: home))
    XCTAssertNil(AIContextBuilder.sanitize("/Library/Application Support/X", home: home))
    XCTAssertNil(AIContextBuilder.sanitize("/Volumes/Backup/coltonwood", home: home))
    XCTAssertNil(AIContextBuilder.sanitize("/Users/someoneelse/Desktop", home: home))
    XCTAssertEqual(AIContextBuilder.sanitize("/Users/coltonwood", home: home), "~")
  }

  func testContextNeverContainsPersonalFileNamesOrRawPaths() throws {
    var inputs = AIContextBuilder.Inputs(homeDirectory: home)
    inputs.totalBytes = 500 * 1_073_741_824
    inputs.freeBytes = 20 * 1_073_741_824
    let secretFile = StorageNode(
      url: home.appendingPathComponent("Documents/Passport scan jane@example.com.pdf"), kind: .file,
      allocatedBytes: 10, logicalBytes: 10, itemCount: 1)
    let documents = StorageNode(
      url: home.appendingPathComponent("Documents"), kind: .folder, allocatedBytes: 5 * 1_073_741_824,
      logicalBytes: 0, itemCount: 1, children: [secretFile])
    let caches = StorageNode(
      url: home.appendingPathComponent("Library/Caches"), kind: .folder, allocatedBytes: 3 * 1_073_741_824,
      logicalBytes: 0, itemCount: 1)
    let library = StorageNode(
      url: home.appendingPathComponent("Library"), kind: .folder, allocatedBytes: 9 * 1_073_741_824,
      logicalBytes: 0, itemCount: 1, children: [caches])
    let rootFile = StorageNode(
      url: home.appendingPathComponent("my-private-notes.txt"), kind: .file, allocatedBytes: 4 * 1_073_741_824,
      logicalBytes: 0, itemCount: 1)
    inputs.storageRoot = StorageNode(
      url: home, kind: .folder, allocatedBytes: 18 * 1_073_741_824, logicalBytes: 0, itemCount: 3,
      children: [documents, library, rootFile])
    inputs.downloads = [
      DownloadItem(
        url: home.appendingPathComponent("Downloads/Bank statement Oct.pdf"), kind: .document,
        bytes: 1_073_741_824, usage: .unknown, modified: nil, logicalSize: nil, identity: nil, idleDays: 200)
    ]
    inputs.apps = [
      AppRecord(
        url: URL(fileURLWithPath: "/Applications/Old.app"), name: "Old Editor", bundleIdentifier: "com.x.old",
        version: "1", bundleSize: 1_073_741_824, lastModified: nil,
        lastUsed: Date().addingTimeInterval(-200 * 86_400))
    ]

    let context = AIContextBuilder.build(inputs)
    let json = String(decoding: try JSONEncoder().encode(context), as: UTF8.self)
    XCTAssertFalse(json.contains("coltonwood"))
    XCTAssertFalse(json.contains("Passport"))
    XCTAssertFalse(json.contains("Bank statement"))
    XCTAssertFalse(json.contains("my-private-notes"), "files are never listed, only folders")
    XCTAssertFalse(json.contains("@example.com"))
    XCTAssertEqual(Set(context.biggestFolders.map(\.path)), ["~/Library", "~/Documents", "~/Library/Caches"])
    XCTAssertEqual(context.downloadsGB["Documents"], 1.0)
    XCTAssertTrue(context.unusedApps.isEmpty, "Unrecognized display names are omitted")
    XCTAssertEqual(context.disk["freeGB"], 20)
  }

  func testReviewRequestMapsConfidenceAndSanitizesGrowth() {
    let rec = Recommendation(
      id: "caches", symbol: "x", title: "Caches", detail: "d", bytes: 5, count: 2, confidence: .likely,
      items: [], destination: .cleaner)
    let request = AIContextBuilder.reviewRequest(
      recommendations: [rec], totalBytes: 10, freeBytes: 2,
      growth: [
        StorageGrowth(path: "/Users/coltonwood/Movies", before: 0, after: 9),
        StorageGrowth(path: "/Volumes/X", before: 0, after: 9),
      ], home: home)
    XCTAssertEqual(request.recommendations.first?.confidence, "likely")
    XCTAssertEqual(request.growth.map(\.path), ["~/Movies"])
  }

  func testTurnsEncodeOnlyRoleAndTruncatedText() throws {
    let turn = AITurn(role: .assistant, text: String(repeating: "a", count: 3000), actions: [AIAction(destination: "cleaner", label: "x")])
    let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(turn)) as? [String: Any]
    XCTAssertEqual(Set(object?.keys ?? [:].keys), ["role", "text"])
    XCTAssertEqual((object?["text"] as? String)?.count, 1500)
  }

  // MARK: Client

  func testExplainDecodesAndSendsOnlyTheName() async throws {
    let box = RequestBox()
    let client = AccountClient(baseURL: URL(string: "https://example.test")!) { request in
      box.set(request)
      let json = """
        {"explanation":{"summary":"Spotify cache","owner":"Spotify AB","category":"cache","verdict":"safe","whatHappens":"Rebuilt","confidence":"high"},"cached":true,"model":"claude-haiku-4-5-20251001"}
        """
      return (Data(json.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
    let response = try await client.explain(
      AIExplainRequest(kind: .libraryItem, identifier: "com.spotify.client", location: "Caches"), token: "t")
    XCTAssertEqual(response.explanation.verdict, .safe)
    XCTAssertEqual(response.cached, true)
    let sent = try XCTUnwrap(box.request?.httpBody).flatMap { try JSONSerialization.jsonObject(with: $0) as? [String: String] }
    XCTAssertEqual(sent, ["kind": "library-item", "identifier": "com.spotify.client", "location": "Caches"])
    XCTAssertEqual(box.request?.url?.path, "/api/macmint/ai/explain")
  }

  func testDisabledOrDailyLimitErrorsSurfaceServerMessage() async {
    let client = AccountClient(baseURL: URL(string: "https://example.test")!) { request in
      (Data(#"{"error":"ai_daily_limit","message":"You've reached today's limit."}"#.utf8),
       HTTPURLResponse(url: request.url!, statusCode: 429, httpVersion: nil, headerFields: nil)!)
    }
    do {
      _ = try await client.ask(question: "hi", history: [], context: AIContextBuilder.build(.init(homeDirectory: home)), token: "t")
      XCTFail("expected error")
    } catch let error as AccountAPIError {
      XCTAssertEqual(error.code, "ai_daily_limit")
      XCTAssertEqual(error.message, "You've reached today's limit.")
    } catch {
      XCTFail("unexpected \(error)")
    }
  }

  func testKillSwitchReadsPublicConfigAndFailsClosed() async {
    let on = AccountClient(baseURL: URL(string: "https://example.test")!) { request in
      XCTAssertTrue(request.url?.query?.contains("filter=key") == true)
      return (Data(#"{"items":[{"value":{"enabled":true}}]}"#.utf8),
              HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
    let status = await on.aiStatus()
    XCTAssertTrue(status.enabled)
    let offline = AccountClient(baseURL: URL(string: "https://example.test")!) { _ in throw URLError(.notConnectedToInternet) }
    let offlineStatus = await offline.aiStatus()
    XCTAssertFalse(offlineStatus.enabled)
  }
}
