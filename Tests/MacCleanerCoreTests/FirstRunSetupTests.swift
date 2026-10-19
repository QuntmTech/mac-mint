import Foundation
import XCTest
@testable import MacCleanerCore

final class FirstRunSetupTests: XCTestCase {
  private let home = URL(fileURLWithPath: "/Users/SetupFixture")

  func testInstallationGuidanceSeparatesTemporaryAndInstalledCopies() {
    XCTAssertEqual(InstallationLocation.evaluate(bundleURL: URL(fileURLWithPath: "/Applications/MacMint.app"), homeDirectory: home), .installed)
    XCTAssertEqual(InstallationLocation.evaluate(bundleURL: home.appendingPathComponent("Applications/MacMint.app"), homeDirectory: home), .installed)
    XCTAssertEqual(InstallationLocation.evaluate(bundleURL: URL(fileURLWithPath: "/Applications/MacMint.app"), homeDirectory: home, volumeIsReadOnly: true), .installed, "Installation advice must not guess writability on a sealed system volume")
    XCTAssertEqual(InstallationLocation.evaluate(bundleURL: home.appendingPathComponent("Downloads/MacMint.app"), homeDirectory: home), .downloads)
    XCTAssertEqual(InstallationLocation.evaluate(bundleURL: URL(fileURLWithPath: "/Volumes/MacMint/MacMint.app"), homeDirectory: home, volumeIsReadOnly: true), .readOnlyVolume)
    XCTAssertEqual(InstallationLocation.evaluate(bundleURL: URL(fileURLWithPath: "/private/var/folders/fixture/AppTranslocation/id/d/MacMint.app"), homeDirectory: home), .translocated)
    XCTAssertEqual(InstallationLocation.evaluate(bundleURL: URL(fileURLWithPath: "/build/release/MacMint"), homeDirectory: home), .development)
  }

  func testApplicationsLookalikesAreNotAnInstalledCopy() {
    for path in ["/Applications-old/MacMint.app", "/Users/SetupFixture/Applications-old/MacMint.app", "/Volumes/Backup/Applications/MacMint.app"] {
      XCTAssertEqual(InstallationLocation.evaluate(bundleURL: URL(fileURLWithPath: path), homeDirectory: home), .elsewhere)
    }
    XCTAssertEqual(InstallationLocation.evaluate(bundleURL: home.appendingPathComponent("Downloads/../Applications/MacMint.app"), homeDirectory: home), .installed)
  }

  func testSetupResumesAfterRestartButCompletedSetupStartsAtWelcome() throws {
    let suite = "MacMint-Setup-\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let firstLaunch = SetupProgressStore(defaults: defaults)
    XCTAssertEqual(firstLaunch.initialStep, 0)
    firstLaunch.record(step: 1)
    let afterPermissionRestart = SetupProgressStore(defaults: defaults)
    XCTAssertEqual(afterPermissionRestart.initialStep, 1)
    XCTAssertFalse(defaults.bool(forKey: SetupProgressStore.completedKey))
    afterPermissionRestart.complete()
    XCTAssertTrue(defaults.bool(forKey: "care.onboardingDone"), "Keep existing installations compatible")
    XCTAssertNil(defaults.object(forKey: SetupProgressStore.stepKey))
    XCTAssertEqual(SetupProgressStore(defaults: defaults).initialStep, 0)
    // Replaying setup must not cause an old step to resume on the next normal launch.
    firstLaunch.record(step: 2)
    XCTAssertEqual(SetupProgressStore(defaults: defaults).initialStep, 0)
  }

  func testInvalidSavedStepsRecoverWithoutCompletingSetup() throws {
    let suite = "MacMint-Setup-\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let store = SetupProgressStore(defaults: defaults)
    defaults.set(999, forKey: SetupProgressStore.stepKey)
    XCTAssertEqual(store.initialStep, 0)
    store.record(step: 1)
    store.record(step: -1)
    XCTAssertEqual(store.initialStep, 1)
    XCTAssertFalse(defaults.bool(forKey: SetupProgressStore.completedKey))
  }
}
