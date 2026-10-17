import Foundation
import MacCleanerCore
import ServiceManagement
import UserNotifications

@MainActor
struct CareNotificationClient {
  var available: Bool
  var status: () async -> UNAuthorizationStatus?
  var request: () async throws -> Bool
  var add: @MainActor (UNNotificationRequest) async throws -> Void

  static var system: Self {
    Self(available: CareService.isBundledApp,
      status: { await PermissionsService.notificationAuthorizationStatus() },
      request: { try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) },
      add: { request in
        // Keep the request on its owning actor. The imported async overload
        // sends this non-Sendable object to a generic executor on older SDKs.
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
          let completion: @Sendable (Error?) -> Void = { error in
            if let error { continuation.resume(throwing: error) }
            else { continuation.resume(returning: ()) }
          }
          UNUserNotificationCenter.current().add(request, withCompletionHandler: completion)
        }
      })
  }
}

/// Opt-in reminders: low free space and "it's been a while since your last scan".
/// Checks run while MacMint (or its menu bar item) is running; nothing is ever removed
/// automatically — notifications only open the app for review.
@MainActor
final class CareService: ObservableObject {
  enum Keys {
    static let lowSpaceAlerts = "care.lowSpaceAlerts"
    static let lowSpaceThresholdGB = "care.lowSpaceThresholdGB"
    static let scanReminders = "care.scanReminders"
    static let lastScanDate = "care.lastScanDate"
    static let lastLowSpaceAlert = "care.lastLowSpaceAlert"
    static let lastScanReminder = "care.lastScanReminder"
    static let showMenuBar = "care.showMenuBar"
    static let onboardingDone = "care.onboardingDone"
  }

  @Published private(set) var notificationPermission: NotificationPermissionState = .unavailable
  @Published private(set) var notificationError: String?
  @Published var launchAtLoginError: String?

  private let defaults: UserDefaults
  private let notifications: CareNotificationClient
  private var timer: Timer?
  private var authorizationGeneration = UUID()
  private var isRequestingAuthorization = false
  private var pendingNotifications: Set<String> = []

  init(defaults: UserDefaults = .standard, notifications: CareNotificationClient? = nil) {
    self.defaults = defaults
    self.notifications = notifications ?? .system
  }

  var notificationsDenied: Bool { notificationPermission == .denied }

  /// UserNotifications and SMAppService only work from a bundled app, not `swift run`.
  static var isBundledApp: Bool {
    Bundle.main.bundleIdentifier != nil && Bundle.main.bundleURL.pathExtension == "app"
  }

  func start() {
    guard timer == nil else { return }
    defaults.register(defaults: [Keys.lowSpaceThresholdGB: 20])
    Task { await refreshAuthorization(); evaluate() }
    timer = Timer.scheduledTimer(withTimeInterval: 30 * 60, repeats: true) { [weak self] _ in
      Task { @MainActor in
        guard let self else { return }
        await self.refreshAuthorization()
        self.evaluate()
      }
    }
  }

  func recordScan(at date: Date = Date()) {
    defaults.set(date, forKey: Keys.lastScanDate)
  }

  /// Asks for notification permission when the user turns an alert on.
  func requestAuthorization() async {
    guard notifications.available, !isRequestingAuthorization else { return }
    isRequestingAuthorization = true
    notificationError = nil
    defer { isRequestingAuthorization = false }
    // Decide from this read, rather than published state that a concurrent
    // foreground refresh may supersede before an explicit opt-in resumes.
    let status = await notifications.status()
    guard NotificationPermissionState(status) == .notRequested else {
      await refreshAuthorization()
      return
    }
    do {
      _ = try await notifications.request()
      await refreshAuthorization()
    } catch {
      notificationError = "Could not request notification access: \(error.localizedDescription)"
    }
  }

  /// Foreground and settings refreshes read existing permission without prompting.
  func refreshAuthorization() async {
    guard notifications.available else { notificationPermission = .unavailable; return }
    let generation = UUID()
    authorizationGeneration = generation
    let status = await notifications.status()
    guard generation == authorizationGeneration else { return }
    notificationPermission = NotificationPermissionState(status)
    objectWillChange.send() // Login Items approval can also change in System Settings.
  }

  func evaluate(now: Date = Date()) {
    guard notifications.available, !Self.isQuietHours(now),
      notificationPermission == .enabled || notificationPermission == .quiet else { return }

    if defaults.bool(forKey: Keys.lowSpaceAlerts) {
      let threshold = Int64(max(1, defaults.integer(forKey: Keys.lowSpaceThresholdGB))) * 1_000_000_000
      let free = Self.freeSpace()
      let last = defaults.object(forKey: Keys.lastLowSpaceAlert) as? Date ?? .distantPast
      if free > 0, free < threshold, now.timeIntervalSince(last) > 24 * 3600 {
        notify(
          id: "low-space",
          title: "Your Mac is running low on space",
          body: "\(ByteFormatter.string(free)) free. Open MacMint to review cleanup suggestions.",
          preferenceKey: Keys.lowSpaceAlerts, timestampKey: Keys.lastLowSpaceAlert, date: now)
      }
    }

    if defaults.bool(forKey: Keys.scanReminders) {
      let lastScan = defaults.object(forKey: Keys.lastScanDate) as? Date ?? .distantPast
      let lastReminder = defaults.object(forKey: Keys.lastScanReminder) as? Date ?? .distantPast
      let week: TimeInterval = 7 * 24 * 3600
      if now.timeIntervalSince(lastScan) > week, now.timeIntervalSince(lastReminder) > week {
        notify(
          id: "scan-reminder", title: "Time for a quick tidy-up",
          body: "It's been a week since your last Quick Scan. Nothing is removed without your review.",
          preferenceKey: Keys.scanReminders, timestampKey: Keys.lastScanReminder, date: now)
      }
    }
  }

  private func notify(id: String, title: String, body: String, preferenceKey: String,
    timestampKey: String, date: Date) {
    guard pendingNotifications.insert(id).inserted else { return }
    let content = UNMutableNotificationContent()
    content.title = title
    content.body = body
    content.sound = .default
    let request = UNNotificationRequest(identifier: id, content: content, trigger: nil)
    Task {
      defer { pendingNotifications.remove(id) }
      guard defaults.bool(forKey: preferenceKey) else { return }
      do {
        try await notifications.add(request)
        defaults.set(date, forKey: timestampKey)
        notificationError = nil
      } catch {
        notificationError = "Could not schedule a reminder: \(error.localizedDescription)"
      }
    }
  }

  static func isQuietHours(_ date: Date) -> Bool {
    let hour = Calendar.current.component(.hour, from: date)
    return hour >= 22 || hour < 8
  }

  static func freeSpace() -> Int64 {
    let values = try? FileManager.default.homeDirectoryForCurrentUser.resourceValues(forKeys: [
      .volumeAvailableCapacityForImportantUsageKey
    ])
    return values?.volumeAvailableCapacityForImportantUsage ?? 0
  }

  // MARK: Launch at login

  var launchesAtLogin: Bool {
    Self.isBundledApp && SMAppService.mainApp.status == .enabled
  }

  var launchAtLoginNeedsApproval: Bool {
    Self.isBundledApp && SMAppService.mainApp.status == .requiresApproval
  }

  var launchAtLoginRequested: Bool { launchesAtLogin || launchAtLoginNeedsApproval }

  func openLoginItemsSettings() { SMAppService.openSystemSettingsLoginItems() }

  func setLaunchAtLogin(_ enabled: Bool) {
    launchAtLoginError = nil
    guard Self.isBundledApp else {
      launchAtLoginError = "Available when MacMint runs as an installed app."
      return
    }
    do {
      if enabled {
        try SMAppService.mainApp.register()
      } else {
        try SMAppService.mainApp.unregister()
      }
    } catch {
      launchAtLoginError = error.localizedDescription
    }
    objectWillChange.send()
  }
}
