import Foundation
import MacCleanerCore
import XCTest
@testable import MacCleanerApp

@MainActor
final class UpdaterTests: XCTestCase {
  // MARK: Relaunch gate

  func testRelaunchWaitsForWorkAndContinuesOnce() {
    let gate = UpdateRelaunchGate()
    var working = true
    var resumed = 0
    gate.isWorking = { working }
    XCTAssertTrue(gate.postponeRelaunch { resumed += 1 })
    XCTAssertTrue(gate.isHolding)
    gate.workDidChange()
    XCTAssertEqual(resumed, 0, "Still working: the installer keeps waiting")
    working = false
    gate.workDidChange()
    gate.workDidChange()
    XCTAssertEqual(resumed, 1)
    XCTAssertFalse(gate.isHolding)
  }

  func testIdleRelaunchIsNotPostponed() {
    let gate = UpdateRelaunchGate()
    var resumed = false
    XCTAssertFalse(gate.postponeRelaunch { resumed = true })
    XCTAssertFalse(resumed, "Sparkle continues on its own when the gate declines")
    XCTAssertFalse(gate.isHolding)
  }

  func testQuitDuringRelaunchWaitsForNewWorkInsteadOfAsking() {
    let gate = UpdateRelaunchGate()
    var working = false
    var terminated = 0
    gate.isWorking = { working }
    XCTAssertFalse(gate.isRelaunching)
    gate.relaunchWillBegin()
    XCTAssertTrue(gate.isRelaunching)
    working = true
    gate.terminateWhenIdle { terminated += 1 }
    XCTAssertEqual(terminated, 0)
    working = false
    gate.workDidChange()
    XCTAssertEqual(terminated, 1)
    gate.terminateWhenIdle { terminated += 1 }
    XCTAssertEqual(terminated, 2, "Idle: quit immediately")
  }

  // MARK: Controller

  func testControllerFollowsTheSavedChannel() throws {
    let suite = "MacMint-Updater-\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let controller = UpdaterController(startingUpdater: false, defaults: defaults)
    XCTAssertEqual(controller.channel, .stable)
    XCTAssertFalse(controller.receivesDeveloperBuilds)
    controller.receivesDeveloperBuilds = true
    XCTAssertEqual(controller.channel, .developer)
    XCTAssertEqual(defaults.string(forKey: UpdateChannel.storageKey), "developer")
    XCTAssertEqual(UpdaterController(startingUpdater: false, defaults: defaults).channel, .developer, "The choice survives relaunch")
    XCTAssertEqual(UpdaterController.feedURLString(for: .developer),
      "https://github.com/QuntmTech/mac-mint/releases/download/dev-feed/appcast-dev.xml")
    XCTAssertEqual(UpdaterController.feedURLString(for: .stable),
      "https://github.com/QuntmTech/mac-mint/releases/latest/download/appcast.xml")
    controller.receivesDeveloperBuilds = false
    XCTAssertEqual(UpdateChannel.saved(in: defaults), .stable)
  }

  func testControllerHoldsTheRelaunchUntilTheModelFinishesWorking() async throws {
    let suite = "MacMint-Updater-\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("MacMintUpdater-" + UUID().uuidString)
    defer {
      defaults.removePersistentDomain(forName: suite)
      try? FileManager.default.removeItem(at: folder)
    }
    let model = AppViewModel(supportDirectory: folder)
    let controller = UpdaterController(startingUpdater: false, defaults: defaults)
    controller.bind(to: model)
    controller.bind(to: model)
    var installs = 0
    XCTAssertFalse(controller.postponeRelaunch { installs += 1 }, "Nothing running: relaunch now")
    XCTAssertFalse(controller.isWaitingForWork)

    model.isWorking = true
    XCTAssertTrue(controller.postponeRelaunch { installs += 1 })
    XCTAssertTrue(controller.isWaitingForWork)
    try await Task.sleep(for: .milliseconds(50))
    XCTAssertEqual(installs, 0)

    model.isWorking = false
    let deadline = Date().addingTimeInterval(3)
    while installs == 0, Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
    XCTAssertEqual(installs, 1, "The install continues once, after the operation ends")
    XCTAssertFalse(controller.isWaitingForWork)
  }

  func testCheckResultsFollowSparklesReasonAndSeparateAMissingFeed() {
    let domain = "SUSparkleErrorDomain"
    XCTAssertEqual(UpdaterController.checkResult(domain: domain, code: 1001, reason: 1), .newest)
    XCTAssertEqual(UpdaterController.checkResult(domain: domain, code: 1001, reason: 2), .newerThanChannel)
    XCTAssertEqual(UpdaterController.checkResult(domain: domain, code: 1001, reason: 3), .needsNewerMacOS)
    XCTAssertEqual(UpdaterController.checkResult(domain: domain, code: 1001, reason: 4), .unsupportedMacOS)
    XCTAssertNil(UpdaterController.checkResult(domain: domain, code: 1001, reason: 0), "An unknown reason claims nothing")
    XCTAssertNil(UpdaterController.checkResult(domain: domain, code: 1001, reason: nil))
    XCTAssertEqual(UpdaterController.checkResult(domain: domain, code: 1002, reason: nil), .failed)
    XCTAssertEqual(UpdaterController.checkResult(domain: domain, code: 1000, reason: nil), .failed)
    XCTAssertNil(UpdaterController.checkResult(domain: domain, code: 4007, reason: nil), "A cancelled install says nothing new")
    XCTAssertNil(UpdaterController.checkResult(domain: NSURLErrorDomain, code: -1009, reason: nil))
  }
}
