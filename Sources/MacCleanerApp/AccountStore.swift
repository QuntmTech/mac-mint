import AppKit
import Foundation
import MacCleanerCore
import SystemConfiguration

/// Defaults to Keychain; injectable so lifecycle checks never touch a real session.
@MainActor
struct AccountTokenStorage {
  var load: () -> String?
  var save: (String) -> Bool
  var delete: () -> Void

  static var keychain: Self {
    Self(load: { KeychainStore.loadToken() }, save: { KeychainStore.saveToken($0) },
      delete: { KeychainStore.deleteToken() })
  }
}

/// Signed offline evidence (`OfflineEntitlementRecord`). Keychain by default; tests that inject
/// token storage get an in-memory store unless they pass their own.
@MainActor
struct OfflineEntitlementStorage {
  var load: () -> Data?
  var save: (Data) -> Bool
  var delete: () -> Void

  static var keychain: Self {
    Self(load: { KeychainStore.loadEntitlement() }, save: { KeychainStore.saveEntitlement($0) },
      delete: { KeychainStore.deleteEntitlement() })
  }

  static func memory() -> Self {
    final class Box { var data: Data? }
    let box = Box()
    return Self(load: { box.data }, save: { box.data = $0; return true }, delete: { box.data = nil })
  }
}

/// Owns the signed-in session and decides whether the app is unlocked.
/// Flow: Keychain token -> refresh -> activate this Mac -> active / needs plan / device limit.
///
/// Online, a successful verification unlocks this run (for at most the offline grace period
/// without another check). Offline, and after any restart, only a server-signed assertion for
/// this account and Mac unlocks; nothing written to disk is trusted on its own.
@MainActor
final class AccountStore: ObservableObject {
  enum Phase: Equatable {
    case checking
    case signedOut
    case needsPlan
    case deviceLimit(message: String, devices: [RegisteredDevice])
    /// This Mac was removed from the account; only an explicit action activates it again.
    case deviceRemoved
    case active(offline: Bool)
    case failed(String)
  }

  /// Foreground checks run at most this often while access is valid. Retry, the periodic
  /// recheck and any check while access is not valid run immediately.
  static let minimumRefreshInterval: TimeInterval = 15 * 60

  static let purchaseURL = URL(string: "https://macmint.co/#pricing")!
  static let accountURL = URL(string: "https://macmint.co/account")!
  static let signUpURL = URL(string: "https://macmint.co/signup")!

  @Published private(set) var phase: Phase = .checking
  @Published private(set) var snapshot: AccountSnapshot?
  @Published private(set) var isBusy = false
  @Published var errorMessage: String?
  @Published var infoMessage: String?
  /// Server kill switch for AI features (app_config `ai`); off until confirmed.
  @Published var aiAvailable = false
  @Published var aiStatus = AIStatus(enabled: false)

  let deviceInfo: DeviceInfo
  let client: AccountClient
  /// account.json from earlier versions: removed on sight, never trusted.
  private let legacyCacheURL: URL
  private(set) var token: String?
  private let now: @Sendable () -> Date
  private let tokenStorage: AccountTokenStorage
  private let entitlementStorage: OfflineEntitlementStorage
  private let verifier: any EntitlementSignatureVerifier
  /// This run's last online verification. Memory only.
  private var cachedAccess: CachedAccess?
  /// Verified signed evidence for offline use, and the record it was loaded from or saved as.
  private var signedEntitlement: SignedEntitlement?
  private var offlineRecord: OfflineEntitlementRecord?
  /// Latest time this Mac has seen; blocks winding the clock back to stretch offline access.
  private var highWater: Date?
  /// Changes on every sign-in/out; late responses from an older session compare and drop out.
  private(set) var sessionGeneration = UUID()
  private var lastVerification: Date?
  private var isVerifying = false
  private var recheckTask: Task<Void, Never>?
  private var deviceReleaseTask: Task<Void, Never>?
  private var activationTask: Task<AccountSnapshot, Error>?

  init(supportDirectory: URL, client: AccountClient = AccountClient(),
    deviceInfo: DeviceInfo? = nil, tokenStorage: AccountTokenStorage? = nil,
    entitlementStorage: OfflineEntitlementStorage? = nil,
    verifier: (any EntitlementSignatureVerifier)? = nil,
    now: @escaping @Sendable () -> Date = { Date() }) {
    self.now = now
    self.client = client
    self.legacyCacheURL = supportDirectory.appendingPathComponent("account.json")
    self.deviceInfo = deviceInfo ?? Self.currentDevice()
    self.tokenStorage = tokenStorage ?? .keychain
    self.entitlementStorage = entitlementStorage ?? (tokenStorage == nil ? .keychain : .memory())
    self.verifier = verifier ?? CryptoKitEntitlementVerifier.production
  }

  var isUnlocked: Bool {
    guard case .active(let offline) = phase else { return false }
    return offline ? offlineAccessAllowed(at: now()) : AccessPolicy.allowsOffline(cachedAccess, now: now())
  }

  var isOffline: Bool { phase == .active(offline: true) }

  /// Access was granted earlier but its window has since passed (plan expiry or the offline
  /// window). The phase stays `.active` until the next check, so the UI must offer one.
  var accessLapsed: Bool {
    if case .active = phase { return !isUnlocked }
    return false
  }

  // MARK: Lifecycle

  func start() async {
    guard !isBusy, token == nil else { return }
    removeLegacyCache()
    guard let stored = tokenStorage.load() else {
      entitlementStorage.delete()
      phase = .signedOut
      return
    }
    sessionGeneration = UUID()
    token = stored
    restoreOfflineEvidence(for: stored)
    noteClock()
    phase = .checking
    let generation = sessionGeneration
    await verify(refreshToken: true, quiet: false)
    if generation == sessionGeneration { scheduleRecheck() }
  }

  func retry() async {
    guard !isBusy, token != nil else { return }
    errorMessage = nil
    phase = .checking
    await verify(refreshToken: true, quiet: false)
  }

  /// Foregrounding also enforces expiry and remote deactivation after a sleeping Mac wakes.
  /// Called on every app activation, so it is throttled while access is valid and online. While
  /// offline every activation tries to reach the server again.
  func refreshAccess(force: Bool = false) async {
    noteClock()
    guard token != nil, !isBusy else { return }
    if !force, isUnlocked, !isOffline, let last = lastVerification {
      let elapsed = now().timeIntervalSince(last)
      if elapsed >= 0, elapsed < Self.minimumRefreshInterval { return }
    }
    await verify(refreshToken: false, quiet: true)
  }

  // MARK: Auth

  func signIn(email: String, password: String) async {
    await perform(replacingSession: true) { generation in
      let session = try await self.client.signIn(email: email, password: password)
      try await self.adopt(session, generation: generation)
    }
  }

  func signUp(name: String, email: String, password: String) async {
    guard password.count >= 8 else {
      errorMessage = "Use at least 8 characters for your password."
      return
    }
    await perform(replacingSession: true) { generation in
      let session = try await self.client.signUp(email: email, password: password, name: name)
      try await self.adopt(session, generation: generation)
    }
  }

  func requestPasswordReset(email: String) async {
    guard email.contains("@") else {
      errorMessage = "Enter your account email first."
      return
    }
    await perform { generation in
      try await self.client.requestPasswordReset(email: email)
      guard generation == self.sessionGeneration else { return }
      self.infoMessage = "If an account exists for \(email), a reset link is on its way."
    }
  }

  func signOut() async {
    let previousToken = token
    signOutLocally(message: nil)
    if let previousToken {
      let previousRelease = deviceReleaseTask
      let pendingActivation = activationTask
      let release = Task { [client, deviceInfo] in
        await previousRelease?.value
        _ = try? await pendingActivation?.value
        try? await client.deactivate(deviceId: deviceInfo.deviceId, token: previousToken)
      }
      deviceReleaseTask = release
      await release.value
    }
  }

  // MARK: Plan + devices

  /// A browser purchase can grant access without a redemption code. Like Redeem and freeing a
  /// slot, this explicit action may bring back a Mac removed from the account; the server still
  /// enforces the device limit. Background checks never reactivate.
  func checkPurchase() async {
    guard let token else {
      phase = .signedOut
      return
    }
    // Supersede a quiet verification that may have read the account before the
    // purchase settled. Its late response must not replace this activation.
    await perform(replacingSession: true) { generation in
      try await self.activate(token: token, generation: generation, reactivate: true)
      guard generation == self.sessionGeneration else { return }
      if self.isUnlocked {
        self.infoMessage = "Purchase verified. This Mac is activated."
      } else if self.phase == .needsPlan {
        self.infoMessage = "No completed purchase is linked to this account yet. If you just paid, wait a moment and check again. Use the same account on the website."
      }
      self.scheduleRecheck()
    }
  }

  func redeem(code: String) async {
    let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
      errorMessage = "Enter the redemption code from your purchase email."
      return
    }
    guard let token else {
      phase = .signedOut
      return
    }
    await perform { generation in
      _ = try await self.client.redeem(code: trimmed, token: token, deviceId: self.deviceInfo.deviceId)
      guard generation == self.sessionGeneration else { return }
      try await self.activate(token: token, generation: generation, reactivate: true)
      guard generation == self.sessionGeneration else { return }
      if self.isUnlocked { self.infoMessage = "MacMint Pro is unlocked. Enjoy!" }
    }
  }

  /// The explicit "Activate this Mac" action for a Mac removed from the account.
  func activateThisMac() async {
    guard let token else {
      phase = .signedOut
      return
    }
    await perform(replacingSession: true) { generation in
      try await self.activate(token: token, generation: generation, reactivate: true)
      guard generation == self.sessionGeneration else { return }
      if self.isUnlocked { self.infoMessage = "This Mac is activated." }
      self.scheduleRecheck()
    }
  }

  func removeDevice(_ device: RegisteredDevice) async {
    guard let token else { return }
    await perform { generation in
      try await self.client.deactivate(deviceId: device.deviceId, token: token)
      guard generation == self.sessionGeneration else { return }
      try await self.activate(token: token, generation: generation, reactivate: true)
    }
  }

  func openPurchasePage() { NSWorkspace.shared.open(Self.purchaseURL) }
  func openAccountPage() { NSWorkspace.shared.open(Self.accountURL) }

  // MARK: Internals

  private func adopt(_ session: AuthSession, generation: UUID) async throws {
    guard generation == sessionGeneration else { return }
    clearAccess()
    snapshot = nil
    phase = .checking
    token = session.token
    saveToken(session.token)
    // An older sign-out must finish releasing the device before a newer sign-in
    // registers it again, or the late server response could deactivate the new session.
    await deviceReleaseTask?.value
    guard generation == sessionGeneration else { return }
    // Signing in is the explicit action that may bring back a Mac removed from the account.
    try await activate(token: session.token, generation: generation, reactivate: true)
    guard generation == sessionGeneration else { return }
    scheduleRecheck()
  }

  /// Registers this Mac and maps the server's answer to a phase. `reactivate` only from an
  /// explicit user action on this Mac (sign-in, Redeem, Check Purchase, freeing a slot, Activate
  /// this Mac); background paths pass false so a Mac removed from the account stays removed.
  private func activate(token: String, generation: UUID, reactivate: Bool) async throws {
    do {
      let activation = Task { [client, deviceInfo] in
        try await client.activate(deviceInfo, token: token, reactivate: reactivate)
      }
      activationTask = activation
      let result = try await activation.value
      guard generation == sessionGeneration else { return }
      try apply(result)
    } catch let error as AccountAPIError where error.code == "no_active_plan" {
      let result = try? await client.me(token: token)
      guard generation == sessionGeneration else { return }
      snapshot = result?.withoutAssertion
      clearAccess()
      phase = .needsPlan
    } catch let error as AccountAPIError where error.code == "device_limit" {
      let result = try? await client.me(token: token)
      guard generation == sessionGeneration else { return }
      snapshot = result?.withoutAssertion
      clearAccess()
      phase = .deviceLimit(message: error.message, devices: error.devices)
    } catch let error as AccountAPIError where error.code == "device_deactivated" {
      guard generation == sessionGeneration else { return }
      clearAccess()
      phase = .deviceRemoved
    }
  }

  static let invalidAssertion = AccountAPIError(
    status: 200, code: "invalid_assertion",
    message: "MacMint couldn't confirm this Mac's access with the server. Try again in a moment, or contact support@macmint.co if this continues.")

  /// Unlocks for an online answer that says this Mac is active on an active plan. A server that
  /// predates signed assertions unlocks this run only; a present assertion must verify.
  private func apply(_ result: AccountSnapshot) throws {
    let evaluation = OnlineEntitlement.evaluate(result, deviceId: deviceInfo.deviceId, verifier: verifier)
    if case .rejected = evaluation { throw Self.invalidAssertion }
    snapshot = result.withoutAssertion
    let verifiedAt = now()
    cachedAccess = CachedAccess(snapshot: result.withoutAssertion, verifiedAt: verifiedAt)
    if case .unsigned = evaluation, offlineRecord != nil || signedEntitlement != nil {
      // The server no longer vouches for offline use (billing trouble, no key, an older
      // server): stored evidence must not outlive that answer.
      clearOfflineEvidence()
    }
    if case .signed(let signed) = evaluation, let token {
      signedEntitlement = signed
      // The server's issue time is the trusted "now": re-anchor, so a Mac whose clock ran ahead
      // isn't locked out offline after the clock is corrected. Later checks advance it again.
      highWater = signed.claims.issuedAt
      persist(OfflineEntitlementRecord(token: token, userId: result.user.id, assertion: signed.compact,
        highWater: signed.claims.issuedAt, snapshot: result.withoutAssertion))
    }
    phase = .active(offline: false)
  }

  private func offlineAccessAllowed(at date: Date) -> Bool {
    if let signedEntitlement {
      return OfflineEntitlementPolicy.check(signedEntitlement, now: date, highWater: highWater) == nil
    }
    // Only a server without assertions leaves none: this run's online check, never a file.
    return AccessPolicy.allowsOffline(cachedAccess, now: date)
  }

  /// `quiet` re-checks keep an unlocked app usable through any failure that isn't definitive.
  private func verify(refreshToken: Bool, quiet: Bool) async {
    guard !isVerifying, !isBusy else { return }
    isVerifying = true
    defer { isVerifying = false }
    let generation = sessionGeneration
    guard let current = token else {
      phase = .signedOut
      return
    }
    noteClock()
    lastVerification = now()
    do {
      var active = current
      if refreshToken {
        let session = try await client.refresh(token: current)
        guard generation == sessionGeneration else { return }
        active = session.token
        token = active
        saveToken(active)
        // A refreshed token belongs to the same account; offline evidence keeps its signed
        // window and is only rebound to the new token.
        rebindAccess(to: session)
      }
      // Verification must not silently reactivate a device removed through the portal.
      let result = try await client.me(token: active, deviceId: deviceInfo.deviceId)
      guard generation == sessionGeneration else { return }
      guard result.entitlement.active else {
        snapshot = result.withoutAssertion
        clearAccess()
        phase = .needsPlan
        return
      }
      guard result.devices.contains(where: { $0.deviceId == deviceInfo.deviceId }) else {
        // Not an active device. A Mac that never had a row is registered; one removed from the
        // account gets 409 device_deactivated and waits for an explicit "Activate this Mac".
        snapshot = result.withoutAssertion
        clearAccess()
        try await activate(token: active, generation: generation, reactivate: false)
        return
      }
      try apply(result)
    } catch let error as AccountAPIError {
      guard generation == sessionGeneration else { return }
      handle(error, quiet: quiet)
    } catch {
      guard generation == sessionGeneration else { return }
      handle(AccountAPIError.transport(error), quiet: quiet)
    }
  }

  /// Only an expired session or a definitive account answer takes access away. Cancellation
  /// changes nothing; quiet re-checks keep valid access through any other failure, and a quiet
  /// network failure switches to offline so the signed window applies; transient failures fall
  /// back to signed offline evidence. TLS failures are never offline-eligible.
  private func handle(_ error: AccountAPIError, quiet: Bool) {
    if error.isCancellation {
      settleInterruptedCheck()
      return
    }
    if error.isUnauthorized {
      signOutLocally(message: "Your session expired. Please sign in again.")
      return
    }
    let current = now()
    if quiet, isUnlocked {
      if error.isNetwork { phase = .active(offline: true) }
      return
    }
    if error.isTransient, offlineAccessAllowed(at: current) {
      if snapshot == nil { snapshot = offlineRecord?.snapshot ?? cachedAccess?.snapshot }
      phase = .active(offline: true)
      return
    }
    phase = .failed(error.message)
  }

  /// A cancelled check says nothing about the account, but must not leave `.checking` behind.
  private func settleInterruptedCheck() {
    guard phase == .checking else { return }
    if offlineAccessAllowed(at: now()) {
      if snapshot == nil { snapshot = offlineRecord?.snapshot ?? cachedAccess?.snapshot }
      phase = .active(offline: true)
    } else {
      phase = .failed("The account check was interrupted. Try again.")
    }
  }

  private func perform(replacingSession: Bool = false,
    _ work: @escaping @MainActor (UUID) async throws -> Void) async {
    guard !isBusy else { return }
    if replacingSession { sessionGeneration = UUID() }
    let generation = sessionGeneration
    isBusy = true
    errorMessage = nil
    infoMessage = nil
    defer { if generation == sessionGeneration { isBusy = false } }
    do {
      try await work(generation)
    } catch let error as AccountAPIError {
      guard generation == sessionGeneration else { return }
      if error.isCancellation {
        settleInterruptedCheck()
      } else if error.isUnauthorized, token != nil, phase != .signedOut {
        signOutLocally(message: "Your session expired. Please sign in again.")
      } else if phase == .checking {
        // A failed activation after sign-in must not leave an endless spinner.
        phase = .failed(error.message)
      } else {
        errorMessage = error.message
      }
    } catch is CancellationError {
      guard generation == sessionGeneration else { return }
      settleInterruptedCheck()
    } catch {
      guard generation == sessionGeneration else { return }
      errorMessage = error.localizedDescription
    }
  }

  private func signOutLocally(message: String?) {
    sessionGeneration = UUID()
    lastVerification = nil
    isBusy = false
    recheckTask?.cancel()
    recheckTask = nil
    tokenStorage.delete()
    clearAccess()
    token = nil
    snapshot = nil
    aiAvailable = false
    aiStatus = AIStatus(enabled: false)
    infoMessage = nil
    phase = .signedOut
    errorMessage = message
  }

  private func scheduleRecheck() {
    recheckTask?.cancel()
    recheckTask = Task { [weak self] in
      while !Task.isCancelled {
        try? await Task.sleep(for: .seconds(6 * 60 * 60))
        guard !Task.isCancelled, let self else { return }
        await self.verify(refreshToken: true, quiet: true)
      }
    }
  }

  private func saveToken(_ value: String) {
    if !tokenStorage.save(value) {
      infoMessage = "This session could not be saved to Keychain. You may need to sign in again after restarting MacMint."
    }
  }

  /// Loads offline evidence for this session and Mac; anything that doesn't verify is discarded.
  private func restoreOfflineEvidence(for token: String) {
    guard let data = entitlementStorage.load() else { return }
    guard let record = OfflineEntitlementRecord.decode(data),
      let verified = record.verified(token: token, deviceId: deviceInfo.deviceId, verifier: verifier)
    else {
      entitlementStorage.delete()
      return
    }
    offlineRecord = record
    signedEntitlement = verified
    highWater = OfflineEntitlementPolicy.advance(highWater, to: record.highWater)
    snapshot = record.snapshot
  }

  /// Advances the high-water mark and persists it when it has moved meaningfully.
  private func noteClock() {
    let current = OfflineEntitlementPolicy.advance(highWater, to: now())
    highWater = current
    if let record = offlineRecord, current.timeIntervalSince(record.highWater) >= 60 {
      persist(record.with(highWater: current))
    }
  }

  private func rebindAccess(to session: AuthSession) {
    if cachedAccess?.snapshot.user.id != session.user.id { cachedAccess = nil }
    guard let record = offlineRecord else { return }
    if record.userId == session.user.id {
      persist(record.rebound(to: session.token))
    } else {
      clearOfflineEvidence()
    }
  }

  private func persist(_ record: OfflineEntitlementRecord) {
    offlineRecord = record
    guard let data = try? record.encoded(), entitlementStorage.save(data) else {
      infoMessage = "Access is verified for this session, but offline access could not be saved. Check Keychain access before restarting MacMint."
      return
    }
  }

  private func clearOfflineEvidence() {
    signedEntitlement = nil
    offlineRecord = nil
    entitlementStorage.delete()
  }

  private func clearAccess() {
    cachedAccess = nil
    clearOfflineEvidence()
    removeLegacyCache()
  }

  private func removeLegacyCache() {
    try? FileManager.default.removeItem(at: legacyCacheURL)
  }

  private static func currentDevice() -> DeviceInfo {
    let defaults = UserDefaults.standard
    let key = "co.macmint.deviceID"
    let deviceId: String
    if let stored = defaults.string(forKey: key), stored.count >= 16 {
      deviceId = stored
    } else {
      deviceId = UUID().uuidString
      defaults.set(deviceId, forKey: key)
    }
    let version =
      Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    return DeviceInfo(
      deviceId: deviceId,
      name: computerName(),
      model: hardwareModel(),
      osVersion: ProcessInfo.processInfo.operatingSystemVersionString,
      appVersion: version
    )
  }

  /// Runs during App init on the main thread. SCDynamicStore reads the local configuration;
  /// Host.current().localizedName can block on reverse DNS on some networks.
  private static func computerName() -> String {
    guard let name = SCDynamicStoreCopyComputerName(nil, nil) as String?, !name.isEmpty else { return "Mac" }
    return name
  }

  private static func hardwareModel() -> String {
    var size = 0
    guard sysctlbyname("hw.model", nil, &size, nil, 0) == 0, size > 0 else { return "Mac" }
    var buffer = [CChar](repeating: 0, count: size)
    guard sysctlbyname("hw.model", &buffer, &size, nil, 0) == 0 else { return "Mac" }
    let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
    return String(decoding: bytes, as: UTF8.self)
  }
}
