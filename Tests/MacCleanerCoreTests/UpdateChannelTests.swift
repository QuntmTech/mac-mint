import XCTest

@testable import MacCleanerCore

final class UpdateChannelTests: XCTestCase {
  func testChannelDefaultsToStableAndPersistsTheDeveloperChoice() throws {
    let suite = "MacMint-Updates-\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    XCTAssertEqual(UpdateChannel.saved(in: defaults), .stable)
    defaults.set("nightly", forKey: UpdateChannel.storageKey)
    XCTAssertEqual(UpdateChannel.saved(in: defaults), .stable, "Unknown values fall back to stable")
    UpdateChannel.developer.save(in: defaults)
    XCTAssertEqual(defaults.string(forKey: "co.macmint.updates.channel"), "developer")
    XCTAssertEqual(UpdateChannel.saved(in: defaults), .developer)
    UpdateChannel.stable.save(in: defaults)
    XCTAssertEqual(UpdateChannel.saved(in: defaults), .stable)
  }

  func testEachChannelHasItsOwnTrustedFeed() {
    XCTAssertEqual(UpdateChannel.stable.feedURL.absoluteString,
      "https://github.com/QuntmTech/mac-mint/releases/latest/download/appcast.xml")
    XCTAssertEqual(UpdateChannel.developer.feedURL.absoluteString,
      "https://github.com/QuntmTech/mac-mint/releases/download/dev-feed/appcast-dev.xml")
    for channel in UpdateChannel.allCases {
      XCTAssertNotNil(ReleaseChecker.trustedUpdateURL(channel.feedURL.absoluteString), channel.rawValue)
    }
  }

  func testUpdateURLsMustBeThisRepositorysReleaseAssets() {
    for url in [
      "https://github.com/QuntmTech/mac-mint/releases/download/dev-build-312/MacMint.zip",
      "https://github.com/QuntmTech/mac-mint/releases/download/v1.0.0/MacMint.zip",
      "https://github.com/QuntmTech/mac-mint/releases/latest/download/appcast.xml",
    ] {
      XCTAssertEqual(ReleaseChecker.trustedUpdateURL(url)?.absoluteString, url, url)
    }
    for url in [
      nil, "", "http://github.com/QuntmTech/mac-mint/releases/download/v1/MacMint.zip",
      "https://github.com/QuntmTech/other/releases/download/v1/MacMint.zip",
      "https://github.com/evil/mac-mint/releases/latest/download/appcast.xml",
      "https://github.com/QuntmTech/mac-mint/releases/latest/appcast.xml",
      "https://github.com/QuntmTech/mac-mint/releases/latest/download/",
      "https://github.com/QuntmTech/mac-mint/releases/tag/v1/MacMint.zip",
      "https://github.com/QuntmTech/mac-mint/releases/download/v1/x/MacMint.zip",
      "https://github.com/QuntmTech/mac-mint/releases/download/v1/MacMint.zip?raw=1",
      "https://github.com/QuntmTech/mac-mint/releases/download/v1/MacMint.zip#x",
      "https://github.com:444/QuntmTech/mac-mint/releases/download/v1/MacMint.zip",
      "https://github.com/QuntmTech/mac-mint/releases/download/../download/MacMint.zip",
      "https://macmint.co/download/MacMint.zip",
      "https://objects.githubusercontent.com/github-production-release-asset/MacMint.zip",
    ] as [String?] {
      XCTAssertNil(ReleaseChecker.trustedUpdateURL(url), url ?? "nil")
    }
    XCTAssertNil(ReleaseChecker.trustedDownloadURL("https://github.com/QuntmTech/mac-mint/releases/latest/download/MacMint.dmg"),
      "Feed download links keep naming an exact release")
  }

  func testBuildInfoShowsVersionBuildAndShortCommit() {
    let info = BuildInfo(infoDictionary: [
      "CFBundleShortVersionString": "0.9.0", "CFBundleVersion": "312",
      "MacMintGitCommit": "ABC1234DEF5678ABC1234DEF5678ABC1234DEF56",
    ])
    XCTAssertEqual(info.displayString, "Version 0.9.0 (build 312 · abc1234)")
    XCTAssertEqual(info.versionAndBuild, "0.9.0 (build 312)")
    XCTAssertEqual(info.commit, "abc1234def5678abc1234def5678abc1234def56")
    XCTAssertEqual(BuildInfo(version: "0.9.0", build: "312", commit: nil).displayString, "Version 0.9.0 (build 312)")
    XCTAssertEqual(BuildInfo(version: "0.9.0", build: "9a", commit: "not-a-sha").displayString, "Version 0.9.0")
    XCTAssertEqual(BuildInfo(version: "0.9.0", build: nil, commit: nil).versionAndBuild, "0.9.0")
    XCTAssertEqual(BuildInfo(infoDictionary: nil).displayString, "Version 0.0.0")
  }
}
