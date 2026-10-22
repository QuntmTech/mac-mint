import Foundation
import XCTest
@testable import MacCleanerApp

@MainActor
final class GuidedTourTests: XCTestCase {
  private let card = CGSize(width: 340, height: 214)
  private let window = CGSize(width: 1200, height: 800)

  func testTheCardSitsBesideSidebarItemsBelowTopControlsAndInsideTheWindow() {
    let sidebarItem = CGRect(x: 12, y: 200, width: 190, height: 40)
    let beside = TourLayout.cardOrigin(target: sidebarItem, card: card, bounds: window)
    XCTAssertEqual(beside, CGPoint(x: sidebarItem.maxX + TourLayout.gap, y: sidebarItem.midY - card.height / 2))

    let sidebar = CGRect(x: 0, y: 40, width: 228, height: 700)
    let map = TourLayout.cardOrigin(target: sidebar, card: card, bounds: window)
    XCTAssertEqual(map.x, sidebar.maxX + TourLayout.gap, "The whole sidebar keeps the card beside it")

    let reviewButton = CGRect(x: 1080, y: 10, width: 100, height: 32)
    let below = TourLayout.cardOrigin(target: reviewButton, card: card, bounds: window)
    XCTAssertEqual(below.y, reviewButton.maxY + TourLayout.gap, "No room to the right, so it goes below")
    XCTAssertEqual(below.x + card.width, window.width - TourLayout.margin, "Kept inside the window")

    let goTo = CGRect(x: 16, y: 760, width: 180, height: 30)
    let corner = TourLayout.cardOrigin(target: goTo, card: card, bounds: window)
    XCTAssertEqual(corner.y + card.height, window.height - TourLayout.margin, "Never past the bottom edge")

    XCTAssertEqual(TourLayout.cardOrigin(target: nil, card: card, bounds: window), CGPoint(x: 430, y: 293),
      "A target that isn't on screen centers the card")
    let tiny = TourLayout.cardOrigin(target: nil, card: card, bounds: CGSize(width: 200, height: 100))
    XCTAssertEqual(tiny, CGPoint(x: TourLayout.margin, y: TourLayout.margin))
  }

  func testTheTourWalksEveryStepShowsEachPageAndIsRememberedOnceSeen() throws {
    let defaults = UserDefaults.standard
    defaults.removeObject(forKey: AppViewModel.tourSeenKey)
    defer { defaults.removeObject(forKey: AppViewModel.tourSeenKey) }
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let model = AppViewModel(supportDirectory: folder)

    model.startTour()
    XCTAssertEqual(model.tourStep, 0)
    XCTAssertEqual(model.selectedSection, .dashboard)
    var visited: Set<AppViewModel.Section> = []
    for index in 1..<GuidedTour.steps.count {
      model.advanceTour()
      XCTAssertEqual(model.tourStep, index)
      if let section = GuidedTour.steps[index].section {
        XCTAssertEqual(model.selectedSection, section, "Step \(index) shows its page")
        visited.insert(section)
      }
    }
    XCTAssertTrue(visited.contains(.history), "History and Restore is shown on its own page")
    XCTAssertEqual(GuidedTour.steps.count, 6, "A one-minute tour")
    XCTAssertEqual(GuidedTour.steps.first?.target, .map, "It starts with the map of every area")
    model.retreatTour()
    XCTAssertEqual(model.tourStep, GuidedTour.steps.count - 2)
    model.advanceTour()
    model.advanceTour()
    XCTAssertNil(model.tourStep, "Next on the last step finishes")
    XCTAssertEqual(model.selectedSection, .dashboard, "Finishing returns to Overview")
    XCTAssertTrue(defaults.bool(forKey: AppViewModel.tourSeenKey))

    model.startTour()
    model.advanceTour()
    model.advanceTour()
    let page = model.selectedSection
    model.endTour(finished: false)
    XCTAssertNil(model.tourStep)
    XCTAssertEqual(model.selectedSection, page, "Skipping keeps the current page")
  }

  func testEveryStepHasAPlainExplanationAndTargetsAreUnique() {
    let targets = GuidedTour.steps.map(\.target)
    XCTAssertEqual(Set(targets).count, targets.count)
    for step in GuidedTour.steps {
      XCTAssertFalse(step.title.isEmpty)
      XCTAssertLessThanOrEqual(step.message.count, 200, "\(step.title) stays short enough for the card")
    }
  }
}
