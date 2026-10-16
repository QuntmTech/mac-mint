import AppKit
import Foundation
import MacCleanerCore

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

  let deviceInfo: DeviceInfo
  private let client: AccountClient
  private let cacheURL: URL
  private var token: String?
  private var recheckTask: Task<Void, Never>?

  init(supportDirectory: URL, client: AccountClient = AccountClient()) {
    self.client = client
    self.cacheURL = supportDirectory.appendingPathComponent("account.json")
    self.deviceInfo = Self.currentDevice()
  }

  var isUnlocked: Bool {
    if case .active = phase { return true }
    return false
  }

  var isOffline: Bool { phase == .active(offline: true) }

  // MARK: Lifecycle

  func start() async {
    guard let stored = KeychainStore.loadToken() else {
      phase = .signedOut
      return
    }
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
    token = session.token
    KeychainStore.saveToken(session.token)
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
    saveCache(CachedAccess(snapshot: result, verifiedAt: Date()))
    phase = .active(offline: false)
  }

  /// `quiet` re-checks keep an unlocked app usable through transient network failures.
  private func verify(refreshToken: Bool, quiet: Bool) async {
    guard let current = token else {
      phase = .signedOut
      return
    }
    do {
      var active = current
      if refreshToken {
        let session = try await client.refresh(token: current)
        active = session.token
        token = active
        KeychainStore.saveToken(active)
      }
      try await activate(token: active)
    } catch let error as AccountAPIError {
      handle(error, quiet: quiet)
    } catch {
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
      AccessPolicy.allowsOffline(cached)
    {
      snapshot = cached.snapshot
      phase = .active(offline: true)
      return
    }
    if quiet, isUnlocked { return }
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
    recheckTask?.cancel()
    recheckTask = nil
    KeychainStore.deleteToken()
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
