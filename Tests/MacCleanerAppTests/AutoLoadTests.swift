import Foundation
import MacCleanerCore
import XCTest
@testable import MacCleanerApp

@MainActor
final class AutoLoadTests: XCTestCase {
  private var folders: [URL] = []

  override func tearDown() {
    for folder in folders { try? FileManager.default.removeItem(at: folder) }
    folders = []
    super.tearDown()
  }

  /// A model whose exclusions have loaded, so automatic loads are allowed to start.
  private func readyModel() async throws -> AppViewModel {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    folders.append(folder)
    let model = AppViewModel(supportDirectory: folder)
    for _ in 0..<100 where !model.exclusionsReady { try await Task.sleep(for: .milliseconds(20)) }
    XCTAssertTrue(model.exclusionsReady)
    return model
  }

  private var app: AppRecord {
    AppRecord(url: URL(fileURLWithPath: "/Applications/Fixture.app"), name: "Fixture", bundleIdentifier: "com.example.fixture",
      version: "1.0", bundleSize: 1_024, lastModified: Date(), lastUsed: Date())
  }

  func testPagesKnowWhetherTheyHaveBeenFilled() async throws {
    let model = try await readyModel()
    for section in [AppViewModel.Section.applications, .cleaner, .startup, .removedApps, .downloads, .developer, .largeFiles] {
      XCTAssertTrue(model.needsFirstLoad(section), "\(section.rawValue) starts empty")
    }
    for section in [AppViewModel.Section.storage, .duplicates, .photos, .dashboard, .history, .settings, .performance] {
      XCTAssertFalse(model.needsFirstLoad(section), "\(section.rawValue) never starts a scan by itself")
    }
    model.apps = [app]
    model.startupScanned = true
    model.orphansScanned = true
    model.downloadsScanned = true
    model.developerScanned = true
    model.largeFilesScanned = true
    model.lastScanDate = Date()
    for section in [AppViewModel.Section.applications, .cleaner, .startup, .removedApps, .downloads, .developer, .largeFiles] {
      XCTAssertFalse(model.needsFirstLoad(section), "\(section.rawValue) filled, including an empty result")
    }
  }

  func testAFilledPageIsMarkedLoadedWithoutScanningAgain() async throws {
    let model = try await readyModel()
    model.apps = [app]
    model.autoLoadIfNeeded(.applications)
    XCTAssertFalse(model.isScanning)
    XCTAssertTrue(model.autoLoaded.contains(.applications))
  }

  func testNothingStartsDuringTheTourOrAnotherScanAndThePageRetriesAfterwards() async throws {
    let model = try await readyModel()
    model.apps = [app]
    model.tourStep = 0
    let touring = model.autoLoadKey
    model.autoLoadIfNeeded(.applications)
    XCTAssertFalse(model.autoLoaded.contains(.applications), "Waits until the tour closes")
    model.tourStep = nil
    XCTAssertNotEqual(model.autoLoadKey, touring, "Closing the tour re-runs the page's load")

    model.isScanning = true
    let busy = model.autoLoadKey
    model.autoLoadIfNeeded(.applications)
    XCTAssertFalse(model.autoLoaded.contains(.applications), "Waits for the running scan")
    model.isScanning = false
    XCTAssertNotEqual(model.autoLoadKey, busy)
    model.autoLoadIfNeeded(.applications)
    XCTAssertTrue(model.autoLoaded.contains(.applications))
  }

  func testTheLaunchScanFollowsTheSettingSetupAndWhetherMacMintIsInFront() async throws {
    let model = try await readyModel()
    let suite = "macmint-autoload-\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }

    model.runLaunchScanIfEnabled(defaults: defaults, inFront: true)
    XCTAssertFalse(model.launchScanStarted, "Not before setup is finished")

    defaults.set(true, forKey: CareService.Keys.onboardingDone)
    model.runLaunchScanIfEnabled(defaults: defaults, inFront: false)
    XCTAssertFalse(model.launchScanStarted, "Not while MacMint is hidden or behind other apps")

    defaults.set(false, forKey: CareService.Keys.scanOnLaunch)
    model.runLaunchScanIfEnabled(defaults: defaults, inFront: true)
    XCTAssertFalse(model.launchScanStarted, "Not when turned off in Settings")
    defaults.set("NO", forKey: CareService.Keys.scanOnLaunch)
    model.runLaunchScanIfEnabled(defaults: defaults, inFront: true)
    XCTAssertFalse(model.launchScanStarted, "Nor when a launch argument passes NO as text")

    defaults.set(true, forKey: CareService.Keys.scanOnLaunch)
    model.lastScanDate = Date()
    model.runLaunchScanIfEnabled(defaults: defaults, inFront: true)
    XCTAssertFalse(model.launchScanStarted, "Not when Quick Scan already ran this session")
    XCTAssertFalse(model.isScanning)
  }
}
