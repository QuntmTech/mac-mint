import XCTest

@testable import MacCleanerCore

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

final class AppUpdateCheckerTests: XCTestCase {
  private let fm = FileManager.default

  func testAppcastParsingIgnoresBetaChannelAndReadsBothFormats() {
    let xml = """
      <?xml version="1.0"?>
      <rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" version="2.0"><channel>
        <item><title>1.4</title><enclosure url="https://x/1.4.zip" sparkle:version="140" sparkle:shortVersionString="1.4.0"/></item>
        <item><title>1.10</title><sparkle:version>1100</sparkle:version><sparkle:shortVersionString>1.10.2</sparkle:shortVersionString>
          <sparkle:minimumSystemVersion>13.0</sparkle:minimumSystemVersion><enclosure url="https://x/1.10.zip"/></item>
        <item><title>2.0b</title><sparkle:channel>beta</sparkle:channel><enclosure url="https://x/2.zip" sparkle:shortVersionString="2.0.0"/></item>
      </channel></rss>
      """
    let items = AppUpdateChecker.parseAppcast(Data(xml.utf8))
    XCTAssertEqual(items.count, 3)
    let latest = AppUpdateChecker.latest(in: items)
    XCTAssertEqual(latest?.version, "1.10.2")
    XCTAssertEqual(latest?.minimumSystem, "13.0")
  }

  func testCheckFindsSparkleAppStoreAndHomebrewApps() async throws {
    let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? fm.removeItem(at: root) }
    let sparkleApp = try makeApp(root, "Writer.app", id: "com.indie.writer", version: "1.4.0", feed: "https://indie.example/appcast.xml")
    let storeApp = try makeApp(root, "Notes Pro.app", id: "com.shop.notes", version: "2.0", feed: nil)
    try fm.createDirectory(at: storeApp.appendingPathComponent("Contents/_MASReceipt"), withIntermediateDirectories: true)
    try Data("r".utf8).write(to: storeApp.appendingPathComponent("Contents/_MASReceipt/receipt"))
    let brewApp = try makeApp(root, "Tool.app", id: "org.tool", version: "3.0", feed: "https://tool.example/feed.xml")
    let caskroom = root.appendingPathComponent("Caskroom")
    try fm.createDirectory(at: caskroom.appendingPathComponent("tool/3.0/Tool.app"), withIntermediateDirectories: true)
    let plain = try makeApp(root, "Plain.app", id: "com.plain", version: "1.0", feed: nil)

    let checker = AppUpdateChecker(
      transport: { request in
        let url = request.url!.absoluteString
        let body: String
        if url.contains("itunes.apple.com") {
          body = #"{"resultCount":1,"results":[{"version":"2.1","trackViewUrl":"https://apps.apple.com/app/id1","minimumOsVersion":"14.0"}]}"#
        } else if url.contains("indie.example") {
          body = #"<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel><item><enclosure url="https://x" sparkle:shortVersionString="1.5.0"/></item></channel></rss>"#
        } else {
          throw URLError(.badURL)
        }
        return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
      }, caskroots: [caskroom])

    let records = [sparkleApp, storeApp, brewApp, plain].map {
      AppRecord(url: $0, name: $0.deletingPathExtension().lastPathComponent, bundleIdentifier: Bundle(url: $0)?.bundleIdentifier, version: nil, bundleSize: 1, lastModified: nil)
    }
    let updates = await checker.check(records)
    let byName = Dictionary(uniqueKeysWithValues: updates.map { ($0.appName, $0) })

    XCTAssertEqual(byName["Writer"]?.availableVersion, "1.5.0")
    XCTAssertEqual(byName["Writer"]?.hasUpdate, true)
    XCTAssertEqual(byName["Notes Pro"]?.availableVersion, "2.1")
    XCTAssertEqual(byName["Notes Pro"]?.source, .appStore(pageURL: URL(string: "https://apps.apple.com/app/id1")))
    XCTAssertEqual(byName["Tool"]?.source, .homebrew(token: "tool"), "Homebrew wins over the app's own feed")
    XCTAssertEqual(byName["Plain"]?.checkState, .unsupported, "Unsupported sources are distinct from up to date")
    XCTAssertEqual(updates.first?.hasUpdate, true, "apps with updates sort first")
  }

  private func makeApp(_ root: URL, _ name: String, id: String, version: String, feed: String?) throws -> URL {
    let app = root.appendingPathComponent(name)
    try fm.createDirectory(at: app.appendingPathComponent("Contents"), withIntermediateDirectories: true)
    var info: [String: Any] = ["CFBundleIdentifier": id, "CFBundleShortVersionString": version, "CFBundlePackageType": "APPL"]
    if let feed { info["SUFeedURL"] = feed }
    let data = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
    try data.write(to: app.appendingPathComponent("Contents/Info.plist"))
    return app
  }
}

final class DuplicateKeeperTests: XCTestCase {
  private func file(_ path: String, days: Double, identity: String? = nil) -> LargeFile {
    LargeFile(
      url: URL(fileURLWithPath: path), size: 10,
      modifiedAt: Date(timeIntervalSince1970: 1_700_000_000 + days * 86_400), accessedAt: nil,
      identity: identity ?? UUID().uuidString)
  }

  func testRulesPickTheExpectedKeeper() {
    let a = file("/Users/t/Pictures/Trip/a.jpg", days: 1)
    let b = file("/Users/t/Downloads/a copy.jpg", days: 5)
    let c = file("/Users/t/Desktop/old/backup/a.jpg", days: 0)
    let group = DuplicateGroup(fingerprint: "x", files: [a, b, c])

    XCTAssertEqual(DuplicateKeeper.keeper(in: group, rule: .newest)?.id, b.id)
    XCTAssertEqual(DuplicateKeeper.keeper(in: group, rule: .oldest)?.id, c.id)
    XCTAssertEqual(DuplicateKeeper.keeper(in: group, rule: .shortestPath)?.id, a.id)
    XCTAssertEqual(
      DuplicateKeeper.keeper(in: group, rule: .preferredFolder, preferredFolders: [URL(fileURLWithPath: "/Users/t/Desktop")])?.id,
      c.id)
    XCTAssertEqual(
      DuplicateKeeper.keeper(in: group, rule: .preferredFolder, preferredFolders: [URL(fileURLWithPath: "/Users/t/Music")])?.id,
      a.id, "falls back to the shortest path")
  }

  func testSelectionNeverIncludesKeeperOrItsHardLinks() {
    let keeper = file("/Users/t/a.bin", days: 9, identity: "1:1")
    let link = file("/Users/t/links/a.bin", days: 1, identity: "1:1")
    let copy = file("/Users/t/copies/a.bin", days: 2, identity: "1:2")
    let selected = DuplicateKeeper.copiesToSelect(
      in: [DuplicateGroup(fingerprint: "x", files: [keeper, link, copy])], rule: .newest)
    XCTAssertEqual(selected, [copy.id])
  }
}
