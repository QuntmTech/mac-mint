import XCTest

@testable import MacCleanerCore

final class OwnerResolverTests: XCTestCase {
  private let home = URL(fileURLWithPath: "/Users/t")

  func testExplicitOwnerWins() {
    let hint = OwnerResolver.hint(
      for: home.appendingPathComponent("Library/Caches/BraveSoftware/Brave-Browser"),
      explicitBundleID: "com.brave.Browser")
    XCTAssertEqual(hint?.bundleID, "com.brave.Browser")
  }

  func testReverseDNSFolderNamesResolve() {
    XCTAssertEqual(
      OwnerResolver.hint(for: home.appendingPathComponent("Library/Caches/com.spotify.client/Data"))?.bundleID,
      "com.spotify.client")
    XCTAssertEqual(
      OwnerResolver.hint(for: home.appendingPathComponent("Library/Preferences/com.tinyspeck.slackmacgap.plist"))?.bundleID,
      "com.tinyspeck.slackmacgap")
    XCTAssertEqual(
      OwnerResolver.hint(for: home.appendingPathComponent("Library/Group Containers/ABCDE12345.com.vendor.app"))?.bundleID,
      "com.vendor.app")
  }

  func testWellKnownFolderNamesResolve() {
    XCTAssertEqual(
      OwnerResolver.hint(for: home.appendingPathComponent("Library/Caches/Google/Chrome/Default"))?.displayName,
      "Google Chrome")
    XCTAssertEqual(
      OwnerResolver.hint(for: home.appendingPathComponent("Library/Caches/Homebrew"))?.displayName, "Homebrew")
    XCTAssertEqual(
      OwnerResolver.hint(for: home.appendingPathComponent("Library/Application Support/Code/Cache"))?.bundleID,
      "com.microsoft.VSCode")
  }

  func testUnknownNamesStayUnknown() {
    XCTAssertNil(OwnerResolver.hint(for: home.appendingPathComponent("Library/Caches/SomethingRandom")))
    XCTAssertNil(OwnerResolver.hint(for: home.appendingPathComponent("Documents/report.pdf")))
  }
}

final class DiskInsightsTests: XCTestCase {
  func testSnapshotParsing() {
    let output = """
      Snapshots for disk /:
      com.apple.TimeMachine.2026-10-15-120000.local
      com.apple.TimeMachine.2026-10-14-090512.local
      garbage line
      """
    let dates = DiskInsights.snapshotDates(fromTmutil: output)
    XCTAssertEqual(dates.count, 2)
    XCTAssertLessThan(dates[0], dates[1])
  }

  func testDiskutilPlistParsing() throws {
    let plist: [String: Any] = ["FilesystemName": "APFS", "SMARTStatus": "Verified"]
    let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
    let info = DiskInsights.volumeInfo(fromDiskutilPlist: data)
    XCTAssertEqual(info.fileSystem, "APFS")
    XCTAssertEqual(info.health, .verified)
    let failing = try PropertyListSerialization.data(fromPropertyList: ["SMARTStatus": "Failing"], format: .xml, options: 0)
    XCTAssertEqual(DiskInsights.volumeInfo(fromDiskutilPlist: failing).health, .failing)
    let external = try PropertyListSerialization.data(fromPropertyList: ["SMARTStatus": "Not Supported"], format: .xml, options: 0)
    XCTAssertEqual(DiskInsights.volumeInfo(fromDiskutilPlist: external).health, .notSupported)
  }

  func testPurgeableNeverNegative() {
    XCTAssertEqual(DiskInsights.purgeable(important: 120, available: 100), 20)
    XCTAssertEqual(DiskInsights.purgeable(important: 90, available: 100), 0)
    XCTAssertNil(DiskInsights.purgeable(important: nil, available: 100))
  }
}
