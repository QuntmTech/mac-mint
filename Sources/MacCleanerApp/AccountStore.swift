import AppKit
import CryptoKit
import Foundation
import MacCleanerCore

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

/// Owns the signed-in session and decides whether the app is unlocked.
/// Flow: Keychain token -> refresh -> activate this Mac -> active / needs plan / device limit.
@MainActor
final class AccountStore: ObservableObject {
  enum Phase: Equatable {
    case checking
    case signedOut
    case needsPlan
    case deviceLimit(message: String, devices: [RegisteredDevice])
    case active(offline: Bool)
    case failed(String)
  }

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
  private let cacheURL: URL
  private(set) var token: String?
  private let now: @Sendable () -> Date
  private let tokenStorage: AccountTokenStorage
  private var cachedAccess: CachedAccess?
  private struct SessionCache: Codable {
    let tokenFingerprint: String
    let access: CachedAccess
  }
  private var sessionGeneration = UUID()
  private var isVerifying = false
  private var recheckTask: Task<Void, Never>?
  private var deviceReleaseTask: Task<Void, Never>?

  init(supportDirectory: URL, client: AccountClient = AccountClient(),
    deviceInfo: DeviceInfo? = nil, tokenStorage: AccountTokenStorage? = nil,
    now: @escaping @Sendable () -> Date = { Date() }) {
    self.now = now
    self.client = client
    self.cacheURL = supportDirectory.appendingPathComponent("account.json")
    self.deviceInfo = deviceInfo ?? Self.currentDevice()
    self.tokenStorage = tokenStorage ?? .keychain
  }

  var isUnlocked: Bool {
    if case .active = phase { return AccessPolicy.allowsOffline(cachedAccess, now: now()) }
    return false
  }

  var isOffline: Bool { phase == .active(offline: true) }

  // MARK: Lifecycle

  func start() async {
    guard !isBusy, token == nil else { return }
    guard let stored = tokenStorage.load() else {
      phase = .signedOut
      return
    }
    sessionGeneration = UUID()
    token = stored
    cachedAccess = loadCache(for: stored)
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
  func refreshAccess() async {
    guard token != nil, !isBusy else { return }
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
      let release = Task { [client, deviceInfo] in
        await previousRelease?.value
        try? await client.deactivate(deviceId: deviceInfo.deviceId, token: previousToken)
      }
      deviceReleaseTask = release
      await release.value
    }
  }

  // MARK: Plan + devices

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
      _ = try await self.client.redeem(code: trimmed, token: token)
      guard generation == self.sessionGeneration else { return }
      try await self.activate(token: token, generation: generation)
      guard generation == self.sessionGeneration else { return }
      if self.isUnlocked { self.infoMessage = "MacMint Pro is unlocked. Enjoy!" }
    }
  }

  func removeDevice(_ device: RegisteredDevice) async {
    guard let token else { return }
    await perform { generation in
      try await self.client.deactivate(deviceId: device.deviceId, token: token)
      guard generation == self.sessionGeneration else { return }
      try await self.activate(token: token, generation: generation)
    }
  }

  func openPurchasePage() { NSWorkspace.shared.open(Self.purchaseURL) }
  func openAccountPage() { NSWorkspace.shared.open(Self.accountURL) }

  // MARK: Internals

  private func adopt(_ session: AuthSession, generation: UUID) async throws {
    guard generation == sessionGeneration else { return }
    clearCache()
    snapshot = nil
    phase = .checking
    token = session.token
    saveToken(session.token)
    // An older sign-out must finish releasing the device before a newer sign-in
    // registers it again, or the late server response could deactivate the new session.
    await deviceReleaseTask?.value
    guard generation == sessionGeneration else { return }
    try await activate(token: session.token, generation: generation)
    guard generation == sessionGeneration else { return }
    scheduleRecheck()
  }

  /// Registers this Mac and maps the server's answer to a phase.
  private func activate(token: String, generation: UUID) async throws {
    do {
      let result = try await client.activate(deviceInfo, token: token)
      guard generation == sessionGeneration else { return }
      apply(result)
    } catch let error as AccountAPIError where error.code == "no_active_plan" {
      let result = try? await client.me(token: token)
      guard generation == sessionGeneration else { return }
      snapshot = result
      clearCache()
      phase = .needsPlan
    } catch let error as AccountAPIError where error.code == "device_limit" {
      let result = try? await client.me(token: token)
      guard generation == sessionGeneration else { return }
      snapshot = result
      clearCache()
      phase = .deviceLimit(message: error.message, devices: error.devices)
    }
  }

  private func apply(_ result: AccountSnapshot) {
    snapshot = result
    cachedAccess = CachedAccess(snapshot: result, verifiedAt: now())
    saveCache()
    phase = .active(offline: false)
  }

  /// `quiet` re-checks keep an unlocked app usable through transient network failures.
  private func verify(refreshToken: Bool, quiet: Bool) async {
    guard !isVerifying, !isBusy else { return }
    isVerifying = true
    defer { isVerifying = false }
    let generation = sessionGeneration
    guard let current = token else {
      phase = .signedOut
      return
    }
    do {
      var active = current
      if refreshToken {
        let session = try await client.refresh(token: current)
        guard generation == sessionGeneration else { return }
        active = session.token
        token = active
        saveToken(active)
        // A refreshed token belongs to the same account, but offline evidence keeps its
        // original verification date. Rebind it without extending the grace period.
        if cachedAccess?.snapshot.user.id != session.user.id { clearCache() }
        saveCache()
      }
      // Verification must not silently reactivate a device removed through the portal.
      let result = try await client.me(token: active)
      guard generation == sessionGeneration else { return }
      guard result.entitlement.active else {
        snapshot = result
        clearCache()
        phase = .needsPlan
        return
      }
      guard result.devices.contains(where: { $0.deviceId == deviceInfo.deviceId }) else {
        clearCache()
        phase = .failed("This Mac was deactivated. Sign in again to activate it explicitly.")
        return
      }
      apply(result)
    } catch let error as AccountAPIError {
      guard generation == sessionGeneration else { return }
      handle(error, quiet: quiet)
    } catch {
      guard generation == sessionGeneration else { return }
      handle(
        AccountAPIError(status: 0, code: "network", message: error.localizedDescription),
        quiet: quiet)
    }
  }

  private func handle(_ error: AccountAPIError, quiet: Bool) {
    if error.isUnauthorized {
      signOutLocally(message: "Your session expired. Please sign in again.")
      return
    }
    if error.isNetwork || error.status >= 500, let cached = cachedAccess,
      AccessPolicy.allowsOffline(cached, now: now())
    {
      snapshot = cached.snapshot
      phase = .active(offline: true)
      return
    }
    _ = quiet
    phase = .failed(error.message)
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
      if error.isUnauthorized, token != nil, phase != .signedOut {
        signOutLocally(message: "Your session expired. Please sign in again.")
      } else {
        errorMessage = error.message
      }
    } catch {
      guard generation == sessionGeneration else { return }
      errorMessage = error.localizedDescription
    }
  }

  private func signOutLocally(message: String?) {
    sessionGeneration = UUID()
    isBusy = false
    recheckTask?.cancel()
    recheckTask = nil
    tokenStorage.delete()
    clearCache()
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

  private func loadCache(for token: String) -> CachedAccess? {
    guard let data = try? Data(contentsOf: cacheURL) else { return nil }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    guard let record = try? decoder.decode(SessionCache.self, from: data),
      record.tokenFingerprint == Self.fingerprint(token) else { return nil }
    return record.access
  }

  private func saveToken(_ value: String) {
    if !tokenStorage.save(value) {
      infoMessage = "This session could not be saved to Keychain. You may need to sign in again after restarting MacMint."
    }
  }

  private static func fingerprint(_ token: String) -> String {
    SHA256.hash(data: Data(token.utf8)).map { String(format: "%02x", $0) }.joined()
  }

  private func saveCache() {
    guard let cachedAccess, let token else { return }
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    do {
      let data = try encoder.encode(SessionCache(tokenFingerprint: Self.fingerprint(token), access: cachedAccess))
      try FileManager.default.createDirectory(
        at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
      try data.write(to: cacheURL, options: .atomic)
    } catch {
      infoMessage = "Access is verified for this session, but offline access could not be saved. Free some space or check permissions before restarting MacMint."
    }
  }

  private func clearCache() {
    cachedAccess = nil
    try? FileManager.default.removeItem(at: cacheURL)
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
      name: Host.current().localizedName ?? "Mac",
      model: hardwareModel(),
      osVersion: ProcessInfo.processInfo.operatingSystemVersionString,
      appVersion: version
    )
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
