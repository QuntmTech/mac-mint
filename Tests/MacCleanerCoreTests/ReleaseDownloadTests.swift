import XCTest

@testable import MacCleanerCore

final class ReleaseDownloadTests: XCTestCase {
  func testOnlyFirstPartyHTTPSDownloadsAreTrusted() {
    for url in [
      "https://github.com/QuntmTech/mac-mint/releases/download/v1.2.0/MacMint.zip",
      "https://macmint.co/download/MacMint.zip", "https://macmint.co/account",
    ] {
      XCTAssertEqual(ReleaseChecker.trustedDownloadURL(url)?.absoluteString, url, url)
    }
    for url in [
      nil, "", "http://macmint.co/MacMint.zip", "https://github.com/evil/mac-mint/releases/download/v1/MacMint.zip",
      "https://github.com/QuntmTech/mac-mint/archive/main.zip", "https://objects.githubusercontent.com/x/MacMint.zip",
      "https://release-assets.githubusercontent.com/x/MacMint.zip", "https://macmint.co.evil.test/x",
      "https://macmint.co@evil.test/x", "https://user:pass@macmint.co/x", "https://evil.test/macmint.co", "https://macmint.co:8443/x",
      "https://github.com/QuntmTech/../evil/releases/download/v1/x.zip", "https://macmint.co/%2e%2e/x",
      "https://macmint.co/x?redirect=evil", "https://macmint.co/x#y", "https://macmint.co", "javascript:alert(1)",
      "file:///Applications/MacMint.app", "macmint://update", " https://macmint.co/x",
      "https://github.com/QuntmTech/other-repo/releases/download/v1/MacMint.zip", "https://%6dacmint.co/x",
    ] as [String?] {
      XCTAssertNil(ReleaseChecker.trustedDownloadURL(url), url ?? "nil")
    }
    XCTAssertEqual(ReleaseChecker.fallbackDownloadURL.absoluteString, "https://macmint.co/account")
  }

  func testExpectedChecksumRequiresAWellFormedDigest() {
    let digest = String(repeating: "a1", count: 32)
    XCTAssertEqual(ReleaseInfo(version: "1.0", sha256: digest).expectedSHA256, digest)
    for value in [nil, "", String(repeating: "A1", count: 32), String(repeating: "a", count: 63), String(repeating: "g", count: 64)] as [String?] {
      XCTAssertNil(ReleaseInfo(version: "1.0", sha256: value).expectedSHA256)
    }
  }
}
