import CryptoKit
import Foundation
import MacCleanerCore
import XCTest
@testable import MacCleanerApp

@MainActor
final class AccountLifecycleTests: XCTestCase {
  private let device = DeviceInfo(deviceId: "native-integration-device", name: "Fixture", model: "Fixture",
    osVersion: "test", appVersion: "test")

  func testForegroundVerificationCannotExtendFourteenDayOfflineGrace() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let fixture = AccountFixture(), clock = TestClock()
    let tokens = TestTokens()
    let store = AccountStore(supportDirectory: folder, client: AccountClient(transport: { try await fixture.respond($0) }),
      deviceInfo: device, tokenStorage: tokens.storage, now: { clock.now })
    await store.signIn(email: "fixture@example.invalid", password: "fixture")
    XCTAssertTrue(store.isUnlocked)
    await fixture.goOffline()
    clock.advance(14 * 86_400 - 1)
    await store.refreshAccess()
    XCTAssertEqual(store.phase, .active(offline: true))
    XCTAssertTrue(store.isUnlocked)
    clock.advance(2)
    XCTAssertFalse(store.isUnlocked)
    await store.refreshAccess()
    if case .failed = store.phase {} else { XCTFail("Expired grace must leave the active phase") }
    XCTAssertFalse(store.isUnlocked)
  }

  func testForegroundVerificationDoesNotReactivateRemovedDevice() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let fixture = AccountFixture(), tokens = TestTokens()
    let store = AccountStore(supportDirectory: folder, client: AccountClient(transport: { try await fixture.respond($0) }),
      deviceInfo: device, tokenStorage: tokens.storage)
    await store.signIn(email: "fixture@example.invalid", password: "fixture")
    await fixture.removeDevice()
    await store.refreshAccess()
    XCTAssertFalse(store.isUnlocked)
    let firstCount = await fixture.activations
    XCTAssertEqual(firstCount, 1)
    await store.signIn(email: "fixture@example.invalid", password: "fixture")
    XCTAssertTrue(store.isUnlocked)
    let secondCount = await fixture.activations
    XCTAssertEqual(secondCount, 2)
    await store.signOut()
    XCTAssertFalse(store.isUnlocked)
    XCTAssertNil(tokens.value)
  }

  func testRemovedMacIsOnlyReactivatedByAnExplicitAction() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let signing = SigningFixture(), fixture = AccountFixture(signing: signing), tokens = TestTokens()
    let store = AccountStore(supportDirectory: folder, client: AccountClient(transport: { try await fixture.respond($0) }),
      deviceInfo: device, tokenStorage: tokens.storage, verifier: signing.verifier)
    await store.signIn(email: "fixture@example.invalid", password: "fixture")
    var flags = await fixture.reactivateFlags
    XCTAssertEqual(flags, [true], "Signing in is an explicit activation")
    await fixture.deactivateThisMac()
    await store.refreshAccess()
    XCTAssertEqual(store.phase, .deviceRemoved)
    XCTAssertFalse(store.isUnlocked)
    await store.checkPurchase()
    await store.redeem(code: "MINT-FIXTURE-CODE")
    flags = await fixture.reactivateFlags
    XCTAssertEqual(flags, [true, false, false], "Purchase and redemption never reactivate implicitly")
    XCTAssertEqual(store.phase, .deviceRemoved)
    XCTAssertFalse(store.isUnlocked)
    await store.activateThisMac()
    flags = await fixture.reactivateFlags
    XCTAssertEqual(flags.last, true)
    XCTAssertTrue(store.isUnlocked)
    XCTAssertEqual(store.infoMessage, "This Mac is activated.")
  }

  func testLateVerificationCannotRestoreAccessAfterSignOut() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let fixture = AccountFixture(), tokens = TestTokens()
    let store = AccountStore(supportDirectory: folder, client: AccountClient(transport: { try await fixture.respond($0) }),
      deviceInfo: device, tokenStorage: tokens.storage)
    await store.signIn(email: "fixture@example.invalid", password: "fixture")
    await fixture.holdNextVerification()
    let checking = Task { await store.refreshAccess() }
    for _ in 0..<100 {
      if await fixture.isPaused { break }
      try await Task.sleep(for: .milliseconds(10))
    }
    let paused = await fixture.isPaused
    XCTAssertTrue(paused)
    await store.signOut()
    await fixture.resumeVerification()
    await checking.value
    XCTAssertEqual(store.phase, .signedOut)
    XCTAssertNil(tokens.value)
    XCTAssertFalse(store.isUnlocked)
    XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("account.json").path))
  }

  func testSignOutDiscardsOfflineEvidence() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let signing = SigningFixture(), fixture = AccountFixture(signing: signing), tokens = TestTokens()
    let evidence = OfflineEntitlementStorage.memory()
    let store = AccountStore(supportDirectory: folder, client: AccountClient(transport: { try await fixture.respond($0) }),
      deviceInfo: device, tokenStorage: tokens.storage, entitlementStorage: evidence, verifier: signing.verifier)
    await store.signIn(email: "fixture@example.invalid", password: "fixture")
    XCTAssertNotNil(evidence.load())
    await store.signOut()
    XCTAssertNil(evidence.load())
  }

  func testDelayedAuthenticationAndActivationCannotUndoSignOut() async throws {
    for suffix in ["auth-with-password", "/activate"] {
      let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
      defer { try? FileManager.default.removeItem(at: folder) }
      let fixture = AccountFixture(), tokens = TestTokens()
      let store = AccountStore(supportDirectory: folder, client: AccountClient(transport: { try await fixture.respond($0) }),
        deviceInfo: device, tokenStorage: tokens.storage)
      await fixture.hold(suffix)
      let signingIn = Task { await store.signIn(email: "fixture@example.invalid", password: "fixture") }
      try await waitUntilPaused(fixture)
      let signingOut = Task { await store.signOut() }
      // Sign-out clears local access before waiting for an outstanding activation.
      for _ in 0..<100 {
        if store.phase == .signedOut { break }
        try await Task.sleep(for: .milliseconds(10))
      }
      XCTAssertEqual(store.phase, .signedOut)
      XCTAssertFalse(store.isBusy)
      await fixture.resumeVerification()
      await signingIn.value
      await signingOut.value
      XCTAssertEqual(store.phase, .signedOut, suffix)
      XCTAssertNil(tokens.value, suffix)
      XCTAssertFalse(store.isUnlocked, suffix)
    }
  }

  func testSlowRemoteSignOutDoesNotRetainAccessOrEraseANewerSignIn() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let fixture = AccountFixture(), tokens = TestTokens()
    let store = AccountStore(supportDirectory: folder, client: AccountClient(transport: { try await fixture.respond($0) }),
      deviceInfo: device, tokenStorage: tokens.storage)
    await store.signIn(email: "fixture@example.invalid", password: "fixture")
    await fixture.hold("/deactivate")
    let signingOut = Task { await store.signOut() }
    try await waitUntilPaused(fixture)
    XCTAssertEqual(store.phase, .signedOut)
    XCTAssertFalse(store.isUnlocked)
    XCTAssertNil(tokens.value)
    let newSignIn = Task { await store.signIn(email: "fixture@example.invalid", password: "fixture") }
    await fixture.resumeVerification()
    await signingOut.value
    await newSignIn.value
    XCTAssertTrue(store.isUnlocked)
    XCTAssertEqual(tokens.value, "fixture-token")
  }

  func testVerifiedAccessSurvivesCacheWriteFailureAndReportsIt() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let signing = SigningFixture(), fixture = AccountFixture(signing: signing), tokens = TestTokens()
    let failing = OfflineEntitlementStorage(load: { nil }, save: { _ in false }, delete: {})
    let store = AccountStore(supportDirectory: folder, client: AccountClient(transport: { try await fixture.respond($0) }),
      deviceInfo: device, tokenStorage: tokens.storage, entitlementStorage: failing, verifier: signing.verifier)
    await store.signIn(email: "fixture@example.invalid", password: "fixture")
    XCTAssertTrue(store.isUnlocked)
    XCTAssertTrue(store.infoMessage?.contains("offline access could not be saved") == true)
    await fixture.goOffline()
    await store.refreshAccess()
    XCTAssertTrue(store.isUnlocked)
    XCTAssertTrue(store.isOffline)
  }

  func testOfflineCacheIsBoundToTheStoredSession() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let signing = SigningFixture(), fixture = AccountFixture(signing: signing), tokens = TestTokens()
    let evidence = OfflineEntitlementStorage.memory()
    let client = AccountClient(transport: { try await fixture.respond($0) })
    func store() -> AccountStore {
      AccountStore(supportDirectory: folder, client: client, deviceInfo: device, tokenStorage: tokens.storage,
        entitlementStorage: evidence, verifier: signing.verifier)
    }
    await store().signIn(email: "fixture@example.invalid", password: "fixture")
    await fixture.goOffline()
    let restarted = store()
    await restarted.start()
    XCTAssertTrue(restarted.isUnlocked)
    XCTAssertTrue(restarted.isOffline)
    XCTAssertEqual(restarted.snapshot?.user.email, "fixture@example.invalid")
    tokens.value = "another-account-token"
    let different = store()
    await different.start()
    XCTAssertFalse(different.isUnlocked)
    XCTAssertNil(evidence.load(), "Evidence for another session is discarded")
  }

  func testSignedEvidenceUnlocksOfflineAfterRestartOnlyUntilItsWindowEnds() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let clock = TestClock(), signing = SigningFixture()
    let fixture = AccountFixture(signing: signing, now: { clock.now }), tokens = TestTokens()
    let evidence = OfflineEntitlementStorage.memory()
    let client = AccountClient(transport: { try await fixture.respond($0) })
    func store() -> AccountStore {
      AccountStore(supportDirectory: folder, client: client, deviceInfo: device, tokenStorage: tokens.storage,
        entitlementStorage: evidence, verifier: signing.verifier, now: { clock.now })
    }
    await store().signIn(email: "fixture@example.invalid", password: "fixture")
    let saved = try XCTUnwrap(evidence.load().flatMap(OfflineEntitlementRecord.decode))
    XCTAssertEqual(saved.userId, "fixture")
    XCTAssertNil(saved.snapshot?.entitlementAssertion, "The display copy is not evidence")
    await fixture.goOffline()
    clock.advance(14 * 86_400 - 2)
    let restarted = store()
    await restarted.start()
    XCTAssertEqual(restarted.phase, .active(offline: true))
    XCTAssertTrue(restarted.isUnlocked)
    clock.advance(3)
    XCTAssertFalse(restarted.isUnlocked)
    let later = store()
    await later.start()
    XCTAssertFalse(later.isUnlocked)
    if case .failed = later.phase {} else { XCTFail("Ended offline window must not unlock: \(later.phase)") }
  }

  func testEditedEvidenceAndOldAccountCacheNeverUnlockOffline() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let signing = SigningFixture(), fixture = AccountFixture(signing: signing), tokens = TestTokens()
    let evidence = OfflineEntitlementStorage.memory()
    let client = AccountClient(transport: { try await fixture.respond($0) })
    func store() -> AccountStore {
      AccountStore(supportDirectory: folder, client: client, deviceInfo: device, tokenStorage: tokens.storage,
        entitlementStorage: evidence, verifier: signing.verifier)
    }
    await store().signIn(email: "fixture@example.invalid", password: "fixture")
    await fixture.goOffline()
    // Stretch the signed window by editing the stored payload; the signature no longer matches.
    let record = try XCTUnwrap(evidence.load().flatMap(OfflineEntitlementRecord.decode))
    let parts = record.assertion.split(separator: ".").map(String.init)
    var claims = try XCTUnwrap(try JSONSerialization.jsonObject(with: XCTUnwrap(Base64URL.decode(parts[0]))) as? [String: Any])
    claims["offline_until"] = 4_000_000_000
    let edited = Base64URL.encode(try JSONSerialization.data(withJSONObject: claims, options: [.sortedKeys])) + "." + parts[1]
    XCTAssertTrue(evidence.save(try OfflineEntitlementRecord(token: "fixture-token", userId: "fixture", assertion: edited,
      highWater: record.highWater, snapshot: record.snapshot).encoded()))
    let tampered = store()
    await tampered.start()
    XCTAssertFalse(tampered.isUnlocked)
    XCTAssertNil(evidence.load())

    // The previous release's plain-JSON cache, edited to look fresh and lifetime, is ignored and removed.
    let fingerprint = OfflineEntitlementRecord.fingerprint("fixture-token")
    let legacy = """
      {"tokenFingerprint":"\(fingerprint)","access":{"verifiedAt":"\(ISO8601DateFormatter().string(from: Date()))",
       "snapshot":{"user":{"id":"fixture","email":"fixture@example.invalid"},"devices":[],
       "entitlement":{"plan":"pro","status":"active","active":true,"maxDevices":3}}}}
      """
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try Data(legacy.utf8).write(to: folder.appendingPathComponent("account.json"))
    let legacyRestart = store()
    await legacyRestart.start()
    XCTAssertFalse(legacyRestart.isUnlocked)
    XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("account.json").path))
  }

  func testWindingTheClockBackBelowTheHighWaterMarkLocksOfflineAccess() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let clock = TestClock(), signing = SigningFixture()
    let fixture = AccountFixture(signing: signing, now: { clock.now }), tokens = TestTokens()
    let evidence = OfflineEntitlementStorage.memory()
    let client = AccountClient(transport: { try await fixture.respond($0) })
    func store() -> AccountStore {
      AccountStore(supportDirectory: folder, client: client, deviceInfo: device, tokenStorage: tokens.storage,
        entitlementStorage: evidence, verifier: signing.verifier, now: { clock.now })
    }
    let first = store()
    await first.signIn(email: "fixture@example.invalid", password: "fixture")
    await fixture.goOffline()
    clock.advance(10 * 86_400)
    await first.refreshAccess()
    XCTAssertTrue(first.isUnlocked)
    clock.advance(-6 * 86_400)
    XCTAssertFalse(first.isUnlocked, "A running app notices the rollback")
    let restarted = store()
    await restarted.start()
    XCTAssertFalse(restarted.isUnlocked, "The persisted mark survives a restart")
    clock.advance(6 * 86_400)
    let corrected = store()
    await corrected.start()
    XCTAssertTrue(corrected.isUnlocked)
  }

  func testLegacyServerUnlocksOnlineButLeavesNothingForAnOfflineRestart() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let fixture = AccountFixture(), tokens = TestTokens(), evidence = OfflineEntitlementStorage.memory()
    let client = AccountClient(transport: { try await fixture.respond($0) })
    let first = AccountStore(supportDirectory: folder, client: client, deviceInfo: device, tokenStorage: tokens.storage,
      entitlementStorage: evidence, verifier: SigningFixture().verifier)
    await first.signIn(email: "fixture@example.invalid", password: "fixture")
    XCTAssertEqual(first.phase, .active(offline: false))
    XCTAssertTrue(first.isUnlocked)
    XCTAssertNil(evidence.load())
    await fixture.goOffline()
    let restarted = AccountStore(supportDirectory: folder, client: client, deviceInfo: device, tokenStorage: tokens.storage,
      entitlementStorage: evidence, verifier: SigningFixture().verifier)
    await restarted.start()
    XCTAssertFalse(restarted.isUnlocked)
  }

  func testAnAssertionThatFailsVerificationIsRejectedOnline() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let clock = TestClock(), signing = SigningFixture()
    let fixture = AccountFixture(signing: signing, now: { clock.now }), tokens = TestTokens()
    await fixture.forgeAssertions(true)
    let store = AccountStore(supportDirectory: folder, client: AccountClient(transport: { try await fixture.respond($0) }),
      deviceInfo: device, tokenStorage: tokens.storage, verifier: signing.verifier, now: { clock.now })
    await store.signIn(email: "fixture@example.invalid", password: "fixture")
    XCTAssertFalse(store.isUnlocked)
    if case .failed = store.phase {} else { XCTFail("A bad signature must not unlock: \(store.phase)") }
    await fixture.forgeAssertions(false)
    await store.retry()
    XCTAssertTrue(store.isUnlocked)
    await fixture.forgeAssertions(true)
    clock.advance(AccountStore.minimumRefreshInterval + 1)
    let before = await fixture.verifications
    await store.refreshAccess()
    let after = await fixture.verifications
    XCTAssertEqual(after, before + 1)
    XCTAssertTrue(store.isUnlocked, "A quiet check keeps verified access; only definitive answers remove it")
  }

  func testTransientFailuresDuringQuietChecksKeepPaidAccess() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let clock = TestClock(), signing = SigningFixture()
    let fixture = AccountFixture(signing: signing, now: { clock.now }), tokens = TestTokens()
    let store = AccountStore(supportDirectory: folder, client: AccountClient(transport: { try await fixture.respond($0) }),
      deviceInfo: device, tokenStorage: tokens.storage, verifier: signing.verifier, now: { clock.now })
    await store.signIn(email: "fixture@example.invalid", password: "fixture")
    for (index, status) in [429, 408, 404, 403, 503].enumerated() {
      await fixture.failVerification(status: status)
      clock.advance(AccountStore.minimumRefreshInterval + 1)
      await store.refreshAccess()
      let checks = await fixture.verifications
      XCTAssertEqual(checks, index + 1, "\(status) must actually reach the server")
      XCTAssertTrue(store.isUnlocked, "\(status)")
      XCTAssertEqual(store.phase, .active(offline: false), "\(status)")
    }
    await fixture.failVerification(status: 429)
    await store.retry()
    XCTAssertEqual(store.phase, .active(offline: true), "An explicit retry falls back to signed evidence")
    XCTAssertTrue(store.isUnlocked)
    await fixture.failVerification(status: nil)
    await fixture.cancelNextVerification()
    await store.refreshAccess(force: true)
    XCTAssertEqual(store.phase, .active(offline: true), "Cancellation changes nothing")
    await fixture.failVerification(status: 401)
    await store.refreshAccess(force: true)
    XCTAssertEqual(store.phase, .signedOut, "An expired session still signs out")
  }

  func testForegroundChecksAreThrottledOnlyWhileAccessIsValid() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let clock = TestClock(), signing = SigningFixture()
    let fixture = AccountFixture(signing: signing, now: { clock.now }), tokens = TestTokens()
    let store = AccountStore(supportDirectory: folder, client: AccountClient(transport: { try await fixture.respond($0) }),
      deviceInfo: device, tokenStorage: tokens.storage, verifier: signing.verifier, now: { clock.now })
    await store.signIn(email: "fixture@example.invalid", password: "fixture")
    func checks() async -> Int { await fixture.verifications }
    await store.refreshAccess()
    var count = await checks()
    XCTAssertEqual(count, 1)
    await store.refreshAccess()
    clock.advance(AccountStore.minimumRefreshInterval - 60)
    await store.refreshAccess()
    count = await checks()
    XCTAssertEqual(count, 1, "App activations within the interval reuse the last check")
    clock.advance(120)
    await store.refreshAccess()
    count = await checks()
    XCTAssertEqual(count, 2)
    await store.refreshAccess(force: true)
    count = await checks()
    XCTAssertEqual(count, 3)
    await fixture.deactivateThisMac()
    clock.advance(AccountStore.minimumRefreshInterval + 1)
    await store.refreshAccess()
    XCTAssertFalse(store.isUnlocked)
    await store.refreshAccess()
    count = await checks()
    XCTAssertEqual(count, 5, "Without valid access every activation checks again")
  }

  func testRepeatedSubmitDoesNotLaunchOverlappingAuthentication() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let fixture = AccountFixture(), tokens = TestTokens()
    let store = AccountStore(supportDirectory: folder, client: AccountClient(transport: { try await fixture.respond($0) }),
      deviceInfo: device, tokenStorage: tokens.storage)
    await fixture.hold("auth-with-password")
    let first = Task { await store.signIn(email: "fixture@example.invalid", password: "fixture") }
    try await waitUntilPaused(fixture)
    await store.signIn(email: "fixture@example.invalid", password: "fixture")
    let count = await fixture.authentications
    XCTAssertEqual(count, 1)
    await fixture.resumeVerification()
    await first.value
    XCTAssertTrue(store.isUnlocked)
  }

  func testExplicitPurchaseCheckActivatesThisMacWithoutARedemptionCode() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let fixture = AccountFixture(), tokens = TestTokens()
    await fixture.removePlan()
    let store = AccountStore(supportDirectory: folder, client: AccountClient(transport: { try await fixture.respond($0) }),
      deviceInfo: device, tokenStorage: tokens.storage)
    await store.signIn(email: "fixture@example.invalid", password: "fixture")
    XCTAssertEqual(store.phase, .needsPlan)
    await store.checkPurchase()
    XCTAssertEqual(store.phase, .needsPlan)
    XCTAssertTrue(store.infoMessage?.contains("No completed purchase") == true)
    XCTAssertNil(store.errorMessage)

    await fixture.completePurchase()
    await store.checkPurchase()
    XCTAssertTrue(store.isUnlocked)
    XCTAssertEqual(store.phase, .active(offline: false))
    XCTAssertEqual(store.snapshot?.devices.first?.deviceId, device.deviceId)
    XCTAssertEqual(store.infoMessage, "Purchase verified. This Mac is activated.")
  }

  func testPurchaseCheckSupersedesVerificationFromBeforeThePurchase() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let fixture = AccountFixture(), tokens = TestTokens()
    await fixture.removePlan()
    let store = AccountStore(supportDirectory: folder, client: AccountClient(transport: { try await fixture.respond($0) }),
      deviceInfo: device, tokenStorage: tokens.storage)
    await store.signIn(email: "fixture@example.invalid", password: "fixture")
    try await fixture.holdVerificationWithCurrentSnapshot()
    let checking = Task { await store.refreshAccess() }
    try await waitUntilPaused(fixture)
    await fixture.completePurchase()
    await store.checkPurchase()
    XCTAssertTrue(store.isUnlocked)
    await fixture.resumeVerification()
    await checking.value
    XCTAssertTrue(store.isUnlocked)
    XCTAssertEqual(store.phase, .active(offline: false))
  }

  func testRepeatedPurchaseCheckCannotOverlapOrUndoSignOut() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let fixture = AccountFixture(), tokens = TestTokens()
    await fixture.removePlan()
    let store = AccountStore(supportDirectory: folder, client: AccountClient(transport: { try await fixture.respond($0) }),
      deviceInfo: device, tokenStorage: tokens.storage)
    await store.signIn(email: "fixture@example.invalid", password: "fixture")
    await fixture.completePurchase()
    await fixture.hold("/activate")
    let checking = Task { await store.checkPurchase() }
    try await waitUntilPaused(fixture)
    let countBefore = await fixture.activations
    await store.checkPurchase()
    let countAfter = await fixture.activations
    XCTAssertEqual(countAfter, countBefore)
    let signingOut = Task { await store.signOut() }
    for _ in 0..<100 {
      if store.phase == .signedOut { break }
      try await Task.sleep(for: .milliseconds(10))
    }
    XCTAssertEqual(store.phase, .signedOut)
    await fixture.resumeVerification()
    await checking.value
    await signingOut.value
    XCTAssertEqual(store.phase, .signedOut)
    XCTAssertFalse(store.isUnlocked)
    XCTAssertNil(tokens.value)
    XCTAssertNil(store.infoMessage)
    await store.checkPurchase()
    XCTAssertEqual(store.phase, .signedOut)
  }

  private func waitUntilPaused(_ fixture: AccountFixture) async throws {
    for _ in 0..<200 {
      if await fixture.isPaused { return }
      try await Task.sleep(for: .milliseconds(10))
    }
    XCTFail("The intended network boundary was not reached")
  }

  func testAcceptedConsentSendsTheExactPreviewedRequestDespiteLaterChatChanges() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let previous = UserDefaults.standard.object(forKey: AppViewModel.aiEnabledKey)
    defer { UserDefaults.standard.set(previous, forKey: AppViewModel.aiEnabledKey) }
    UserDefaults.standard.set(false, forKey: AppViewModel.aiEnabledKey)
    let fixture = AccountFixture(), tokens = TestTokens()
    let store = AccountStore(supportDirectory: folder, client: AccountClient(transport: { try await fixture.respond($0) }),
      deviceInfo: device, tokenStorage: tokens.storage)
    await store.signIn(email: "fixture@example.invalid", password: "fixture")
    let model = AppViewModel(supportDirectory: folder.appendingPathComponent("Model"))
    model.ask("What can I inspect?", account: store)
    XCTAssertTrue(model.aiConsentPending)
    let preview = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(model.aiPayloadPreview.utf8)) as? NSDictionary)
    model.assistantTurns = [AITurn(role: .user, text: "A different later chat turn")]
    model.acceptAIConsent()
    for _ in 0..<200 {
      if await fixture.lastAsk != nil, !model.assistantBusy { break }
      try await Task.sleep(for: .milliseconds(10))
    }
    let captured = await fixture.lastAsk
    let payload = try XCTUnwrap(captured)
    let actual = try XCTUnwrap(try JSONSerialization.jsonObject(with: payload) as? NSDictionary)
    XCTAssertEqual(preview, actual)
    XCTAssertEqual(model.assistantTurns.last?.text, "Fixture answer")
  }

  func testScanInvalidationCancelsThePendingConsentContinuation() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let previous = UserDefaults.standard.object(forKey: AppViewModel.aiEnabledKey)
    defer { UserDefaults.standard.set(previous, forKey: AppViewModel.aiEnabledKey) }
    UserDefaults.standard.set(false, forKey: AppViewModel.aiEnabledKey)
    let fixture = AccountFixture(), tokens = TestTokens()
    let store = AccountStore(supportDirectory: folder, client: AccountClient(transport: { try await fixture.respond($0) }),
      deviceInfo: device, tokenStorage: tokens.storage)
    let model = AppViewModel(supportDirectory: folder.appendingPathComponent("Model"))
    model.assistantDraft = "Keep this question"
    model.ask(model.assistantDraft, account: store)
    XCTAssertTrue(model.aiConsentPending)
    model.invalidateAIReview()
    model.acceptAIConsent()
    await Task.yield()
    await Task.yield()
    XCTAssertFalse(model.aiConsentPending)
    XCTAssertFalse(model.assistantBusy)
    XCTAssertEqual(model.assistantDraft, "Keep this question")
    let sent = await fixture.lastAsk
    XCTAssertNil(sent)
  }

  func testUnreadableExclusionsBlockNewWorkButAllowControllerRestore() async throws {
    let fm = FileManager.default
    let folder = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? fm.removeItem(at: folder) }
    let source = folder.appendingPathComponent(".Trash/item.txt")
    let original = folder.appendingPathComponent("Documents/item.txt")
    try fm.createDirectory(at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("recover me".utf8).write(to: source)
    try Data("damaged exclusions".utf8).write(to: folder.appendingPathComponent("ignored-paths.json"))
    let receipt = TrashReceipt(originalPath: original.path, trashPath: source.path, bytes: 10,
      identity: FileSystem.fileIdentity(at: source))
    let entry = HistoryEntry(action: "Fixture", paths: [original.path], bytes: 10, notes: "Test", receipts: [receipt])
    try await HistoryStore(url: folder.appendingPathComponent("history.json")).append(entry)
    let model = AppViewModel(supportDirectory: folder)
    for _ in 0..<200 {
      if model.exclusionLoadError != nil, model.history.contains(where: { $0.id == entry.id }) { break }
      try await Task.sleep(for: .milliseconds(10))
    }
    XCTAssertNotNil(model.exclusionLoadError)
    XCTAssertFalse(model.beginScan(title: "Test", message: "Must not start"))
    XCTAssertFalse(model.requirePaidAccess())
    XCTAssertFalse(model.isScanning)
    XCTAssertTrue(model.canRestore(receipt))
    model.restore([receipt], entryID: entry.id)
    for _ in 0..<200 {
      if !model.isWorking { break }
      try await Task.sleep(for: .milliseconds(10))
    }
    XCTAssertFalse(model.isWorking)
    XCTAssertEqual(try Data(contentsOf: original), Data("recover me".utf8))
    XCTAssertTrue(model.history.first?.isRestored(receipt) == true)
  }
}

/// Disposable Ed25519 key standing in for the server's; the production key never appears in tests.
private struct SigningFixture: Sendable {
  let raw = Curve25519.Signing.PrivateKey().rawRepresentation

  var verifier: CryptoKitEntitlementVerifier {
    CryptoKitEntitlementVerifier(keys: ["fixture-kid": try! Curve25519.Signing.PrivateKey(rawRepresentation: raw).publicKey.rawRepresentation])
  }

  func assertion(user: String, device: String, issuedAt: Date, graceDays: Int = 14, forged: Bool = false) throws -> String {
    let issued = Int(issuedAt.timeIntervalSince1970)
    let claims: [String: Any] = ["v": 1, "kid": "fixture-kid", "user_id": user, "device_id": device, "plan": "pro",
      "active": true, "expires_at": NSNull(), "issued_at": issued, "offline_until": issued + graceDays * 86_400]
    let message = try JSONSerialization.data(withJSONObject: claims, options: [.sortedKeys])
    let signature = forged ? Data(repeating: 7, count: 64)
      : try Curve25519.Signing.PrivateKey(rawRepresentation: raw).signature(for: message)
    return Base64URL.encode(message) + "." + Base64URL.encode(signature)
  }
}

@MainActor
private final class TestTokens {
  var value: String?
  var storage: AccountTokenStorage {
    AccountTokenStorage(load: { self.value }, save: { self.value = $0; return true }, delete: { self.value = nil })
  }
}

private final class TestClock: @unchecked Sendable {
  private let lock = NSLock()
  private var date = Date()
  var now: Date { lock.lock(); defer { lock.unlock() }; return date }
  func advance(_ interval: TimeInterval) { lock.lock(); defer { lock.unlock() }; date.addTimeInterval(interval) }
}

private actor AccountFixture {
  var offline = false
  var removed = false
  private var planActive = true
  var activations = 0
  var authentications = 0
  var verifications = 0
  var reactivateFlags: [Bool] = []
  var lastAsk: Data?
  private var pauseSuffix: String?
  private var pending: CheckedContinuation<Void, Never>?
  private var nextVerificationBody: Data?
  private let signing: SigningFixture?
  private let now: @Sendable () -> Date
  private var forged = false
  private var verificationStatus: Int?
  private var cancelVerification = false
  private var deactivated = false
  init(signing: SigningFixture? = nil, now: @escaping @Sendable () -> Date = { Date() }) {
    self.signing = signing
    self.now = now
  }
  var isPaused: Bool { pending != nil }
  func forgeAssertions(_ value: Bool) { forged = value }
  func failVerification(status: Int?) { verificationStatus = status }
  func cancelNextVerification() { cancelVerification = true }
  /// Removal through the website: the server keeps a tombstone and requires explicit reactivation.
  func deactivateThisMac() { removed = true; deactivated = true }
  func goOffline() { offline = true }
  func removeDevice() { removed = true }
  func removePlan() { planActive = false; removed = true }
  func completePurchase() { planActive = true }
  func holdNextVerification() { hold("/me") }
  func holdVerificationWithCurrentSnapshot() throws {
    nextVerificationBody = try JSONSerialization.data(withJSONObject: snapshotBody)
    hold("/me")
  }
  func hold(_ suffix: String) { pauseSuffix = suffix }
  func resumeVerification() { pending?.resume(); pending = nil }
  func respond(_ request: URLRequest) async throws -> (Data, URLResponse) {
    if offline { throw URLError(.notConnectedToInternet) }
    let path = request.url!.path
    if path.hasSuffix("/me") {
      verifications += 1
      if cancelVerification { cancelVerification = false; throw URLError(.cancelled) }
      if let status = verificationStatus {
        let data = try JSONSerialization.data(withJSONObject: ["error": status == 401 ? "unauthorized" : "fixture_\(status)", "message": "Fixture \(status)"])
        return (data, HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
      }
    }
    let frozenBody = path.hasSuffix("/me") ? nextVerificationBody : nil
    if frozenBody != nil { nextVerificationBody = nil }
    if path.hasSuffix("auth-with-password") { authentications += 1 }
    if let suffix = pauseSuffix, path.hasSuffix(suffix) {
      pauseSuffix = nil
      await withCheckedContinuation { pending = $0 }
    }
    if let frozenBody {
      return (frozenBody, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
    var body: [String: Any] = [:]
    if path.hasSuffix("auth-with-password") || path.hasSuffix("auth-refresh") {
      body = ["token": "fixture-token", "record": ["id": "fixture", "email": "fixture@example.invalid", "verified": true]]
    } else if path.contains("app_config") {
      body = ["items": [["value": ["enabled": true]]]]
    } else if path.hasSuffix("/ask") {
      lastAsk = request.httpBody
      body = ["answer": "Fixture answer", "actions": []]
    } else if !path.hasSuffix("deactivate") {
      if path.hasSuffix("activate") {
        activations += 1
        let fields = request.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        let reactivate = fields["reactivate"] as? Bool == true
        reactivateFlags.append(reactivate)
        if !planActive {
          let data = try JSONSerialization.data(withJSONObject: ["error": "no_active_plan", "message": "No active plan."])
          return (data, HTTPURLResponse(url: request.url!, statusCode: 403, httpVersion: nil, headerFields: nil)!)
        }
        if deactivated && !reactivate {
          let data = try JSONSerialization.data(withJSONObject: ["error": "device_deactivated", "message": "This Mac was removed from your account."])
          return (data, HTTPURLResponse(url: request.url!, statusCode: 409, httpVersion: nil, headerFields: nil)!)
        }
        removed = false
        deactivated = false
      }
      body = snapshotBody
      let namesThisMac = path.hasSuffix("activate") || request.url?.query?.contains("device_id=native-integration-device") == true
      if let signing, namesThisMac, planActive, !removed {
        body["entitlement_assertion"] = try signing.assertion(
          user: "fixture", device: "native-integration-device", issuedAt: now(), forged: forged)
      }
    }
    return (try JSONSerialization.data(withJSONObject: body), HTTPURLResponse(url: request.url!,
      statusCode: 200, httpVersion: nil, headerFields: nil)!)
  }

  private var snapshotBody: [String: Any] {
    ["user": ["id": "fixture", "email": "fixture@example.invalid", "verified": true],
      "entitlement": ["plan": "pro", "status": planActive ? "active" : "inactive", "active": planActive, "max_devices": 1],
      "devices": removed ? [] : [["id": "device", "device_id": "native-integration-device", "name": "Fixture",
        "model": "Fixture", "os_version": "test", "app_version": "test", "last_seen": ""]]]
  }
}
