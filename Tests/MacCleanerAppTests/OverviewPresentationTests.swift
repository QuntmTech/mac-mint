import Foundation
import MacCleanerCore
import XCTest
@testable import MacCleanerApp

final class OverviewPresentationTests: XCTestCase {
  private let megabyte: Int64 = 1_048_576

  private func cache(_ name: String, _ megabytes: Int64) -> CleanupTarget {
    CleanupTarget(category: .userCaches, url: URL(fileURLWithPath: "/Users/test/Library/Caches/\(name)"),
      displayName: name, size: megabytes * megabyte, risk: .safe, reason: "Rebuildable")
  }

  func testCategoriesGroupQuickScanFindingsByAreaLargestFirst() {
    var inputs = RecommendationEngine.Inputs()
    inputs.cleanupTargets = [cache("com.example.one", 30), cache("com.example.two", 45)]
    inputs.trashBytes = 400 * megabyte
    let categories = OverviewPresentation.categories(RecommendationEngine.recommend(inputs))

    XCTAssertEqual(categories.map(\.destination), [.trash, .cleaner])
    XCTAssertEqual(categories.map(\.bytes), [400 * megabyte, 75 * megabyte])
    XCTAssertEqual(categories[1].title, "App caches")
    XCTAssertEqual(categories[1].detail, "2 items · rebuildable")
    XCTAssertEqual(categories[0].detail, "Empty the Trash to free this space")
    XCTAssertEqual(categories[1].swatch, AppTheme.Swatch.sky)
    XCTAssertTrue(OverviewPresentation.categories([]).isEmpty)
  }

  private func category(_ destination: Recommendation.Destination, _ bytes: Int64) -> OverviewPresentation.Category {
    let style = OverviewPresentation.style(destination)
    return .init(destination: destination, title: style.title, symbol: style.symbol, swatch: style.swatch,
      bytes: bytes, detail: "")
  }

  func testBarSharesAddUpToTheWholeDisk() throws {
    let found = [category(.developer, 20), category(.cleaner, 10)]
    let bar = try XCTUnwrap(OverviewPresentation.bar(found, used: 60, total: 100))
    XCTAssertEqual(bar.segments.map(\.fraction), [0.2, 0.1])
    XCTAssertEqual(bar.rest, 0.3, accuracy: 1e-9)
    XCTAssertEqual(bar.free, 0.4, accuracy: 1e-9)
    XCTAssertEqual(bar.segments.reduce(0) { $0 + $1.fraction } + bar.rest + bar.free, 1, accuracy: 1e-9)
  }

  func testBarNeverDrawsMoreThanTheUsedSpaceOrAnUnmeasuredDisk() throws {
    let bar = try XCTUnwrap(OverviewPresentation.bar([category(.developer, 90), category(.cleaner, 30)], used: 60, total: 100))
    XCTAssertEqual(bar.segments.reduce(0) { $0 + $1.fraction }, 0.6, accuracy: 1e-9,
      "Findings larger than the used space are scaled to fit it")
    XCTAssertEqual(bar.rest, 0, accuracy: 1e-9)
    XCTAssertEqual(bar.free, 0.4, accuracy: 1e-9)
    XCTAssertNil(OverviewPresentation.bar([], used: 0, total: 0), "No capacity reading, no bar")
    let full = try XCTUnwrap(OverviewPresentation.bar([], used: 120, total: 100))
    XCTAssertEqual(full.free, 0)
    XCTAssertEqual(OverviewPresentation.add(.max - 1, 5), .max)
  }
}
