import AppKit
import Foundation
import MacCleanerCore

/// Defaults to Keychain; injectable so lifecycle checks never touch a real session.
@MainActor
struct AccountTokenStorage {
  var load: () -> String?
  var save: (String) -> Void
  var delete: () -> Void

  static var keychain: Self {
    Self(load: { KeychainStore.loadToken() }, save: { _ = KeychainStore.saveToken($0) },
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
  private var sessionGeneration = UUID()
  private var isVerifying = false
  private var recheckTask: Task<Void, Never>?

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
    if case .active = phase { return AccessPolicy.allowsOffline(loadCache(), now: now()) }
    return false
  }

  var isOffline: Bool { phase == .active(offline: true) }

  // MARK: Lifecycle

  func start() async {
    guard let stored = tokenStorage.load() else {
      phase = .signedOut
      return
    }
    sessionGeneration = UUID()
    token = stored
    phase = .checking
    await verify(refreshToken: true, quiet: false)
    scheduleRecheck()
  }

  func retry() async {
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
    await perform {
      let session = try await self.client.signIn(email: email, password: password)
      try await self.adopt(session)
    }
  }

  func signUp(name: String, email: String, password: String) async {
    guard password.count >= 8 else {
      errorMessage = "Use at least 8 characters for your password."
      return
    }
    await perform {
      let session = try await self.client.signUp(email: email, password: password, name: name)
      try await self.adopt(session)
    }
  }

  func requestPasswordReset(email: String) async {
    guard email.contains("@") else {
      errorMessage = "Enter your account email first."
      return
    }
    await perform {
      try await self.client.requestPasswordReset(email: email)
      self.infoMessage = "If an account exists for \(email), a reset link is on its way."
    }
  }

  func signOut() async {
    if let token {
      try? await client.deactivate(deviceId: deviceInfo.deviceId, token: token)
    }
    signOutLocally(message: nil)
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
    await perform {
      _ = try await self.client.redeem(code: trimmed, token: token)
      try await self.activate(token: token)
      if self.isUnlocked { self.infoMessage = "MacMint Pro is unlocked. Enjoy!" }
    }
  }

  func removeDevice(_ device: RegisteredDevice) async {
    guard let token else { return }
    await perform {
      try await self.client.deactivate(deviceId: device.deviceId, token: token)
      try await self.activate(token: token)
    }
  }

  func openPurchasePage() { NSWorkspace.shared.open(Self.purchaseURL) }
  func openAccountPage() { NSWorkspace.shared.open(Self.accountURL) }

  // MARK: Internals

  private func adopt(_ session: AuthSession) async throws {
    sessionGeneration = UUID()
    token = session.token
    tokenStorage.save(session.token)
    try await activate(token: session.token)
    scheduleRecheck()
  }

  /// Registers this Mac and maps the server's answer to a phase.
  private func activate(token: String) async throws {
    do {
      let result = try await client.activate(deviceInfo, token: token)
      apply(result)
    } catch let error as AccountAPIError where error.code == "no_active_plan" {
      snapshot = try? await client.me(token: token)
      clearCache()
      phase = .needsPlan
    } catch let error as AccountAPIError where error.code == "device_limit" {
      snapshot = try? await client.me(token: token)
      phase = .deviceLimit(message: error.message, devices: error.devices)
    }
  }

  private func apply(_ result: AccountSnapshot) {
    snapshot = result
    saveCache(CachedAccess(snapshot: result, verifiedAt: now()))
    phase = .active(offline: false)
  }

  /// `quiet` re-checks keep an unlocked app usable through transient network failures.
  private func verify(refreshToken: Bool, quiet: Bool) async {
    guard !isVerifying else { return }
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
        tokenStorage.save(active)
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
    if error.isNetwork || error.status >= 500, let cached = loadCache(),
      AccessPolicy.allowsOffline(cached, now: now())
    {
      snapshot = cached.snapshot
      phase = .active(offline: true)
      return
    }
    _ = quiet
    phase = .failed(error.message)
  }

  private func perform(_ work: @escaping @MainActor () async throws -> Void) async {
    isBusy = true
    errorMessage = nil
    infoMessage = nil
    defer { isBusy = false }
    do {
      try await work()
    } catch let error as AccountAPIError {
      if error.isUnauthorized, token != nil, phase != .signedOut {
        signOutLocally(message: "Your session expired. Please sign in again.")
      } else {
        errorMessage = error.message
      }
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  private func signOutLocally(message: String?) {
    sessionGeneration = UUID()
    recheckTask?.cancel()
    recheckTask = nil
    tokenStorage.delete()
    clearCache()
    token = nil
    snapshot = nil
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

  private func loadCache() -> CachedAccess? {
    guard let data = try? Data(contentsOf: cacheURL) else { return nil }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try? decoder.decode(CachedAccess.self, from: data)
  }

  private func saveCache(_ cached: CachedAccess) {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    guard let data = try? encoder.encode(cached) else { return }
    try? FileManager.default.createDirectory(
      at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try? data.write(to: cacheURL, options: .atomic)
  }

  private func clearCache() {
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
