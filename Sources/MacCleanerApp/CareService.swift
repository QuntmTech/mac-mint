import Foundation
import MacCleanerCore
import ServiceManagement
import UserNotifications

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

  @Published var notificationsDenied = false
  @Published var launchAtLoginError: String?

  private let defaults = UserDefaults.standard
  private var timer: Timer?

  /// UserNotifications and SMAppService only work from a bundled app, not `swift run`.
  static var isBundledApp: Bool {
    Bundle.main.bundleIdentifier != nil && Bundle.main.bundleURL.pathExtension == "app"
  }

  func start() {
    guard timer == nil else { return }
    defaults.register(defaults: [Keys.lowSpaceThresholdGB: 20])
    evaluate()
    timer = Timer.scheduledTimer(withTimeInterval: 30 * 60, repeats: true) { [weak self] _ in
      Task { @MainActor in self?.evaluate() }
    }
  }

  func recordScan(at date: Date = Date()) {
    defaults.set(date, forKey: Keys.lastScanDate)
  }

  /// Asks for notification permission when the user turns an alert on.
  func requestAuthorization() {
    guard Self.isBundledApp else { return }
    UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) {
      granted, _ in
      Task { @MainActor [weak self] in self?.notificationsDenied = !granted }
    }
  }

  func evaluate(now: Date = Date()) {
    guard Self.isBundledApp, !Self.isQuietHours(now) else { return }

    if defaults.bool(forKey: Keys.lowSpaceAlerts) {
      let threshold = Int64(max(1, defaults.integer(forKey: Keys.lowSpaceThresholdGB))) * 1_000_000_000
      let free = Self.freeSpace()
      let last = defaults.object(forKey: Keys.lastLowSpaceAlert) as? Date ?? .distantPast
      if free > 0, free < threshold, now.timeIntervalSince(last) > 24 * 3600 {
        notify(
          id: "low-space",
          title: "Your Mac is running low on space",
          body: "\(ByteFormatter.string(free)) free. Open MacMint to see what's safe to clean.")
        defaults.set(now, forKey: Keys.lastLowSpaceAlert)
      }
    }

    if defaults.bool(forKey: Keys.scanReminders) {
      let lastScan = defaults.object(forKey: Keys.lastScanDate) as? Date ?? .distantPast
      let lastReminder = defaults.object(forKey: Keys.lastScanReminder) as? Date ?? .distantPast
      let week: TimeInterval = 7 * 24 * 3600
      if now.timeIntervalSince(lastScan) > week, now.timeIntervalSince(lastReminder) > week {
        notify(
          id: "scan-reminder", title: "Time for a quick tidy-up",
          body: "It's been a week since your last Quick Scan. Nothing is removed without your review.")
        defaults.set(now, forKey: Keys.lastScanReminder)
      }
    }
  }

  private func notify(id: String, title: String, body: String) {
    let content = UNMutableNotificationContent()
    content.title = title
    content.body = body
    content.sound = .default
    let request = UNNotificationRequest(identifier: id, content: content, trigger: nil)
    UNUserNotificationCenter.current().add(request)
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
