import Foundation

/// Advisory installation guidance only. Never grants file or paid-operation access.
public enum InstallationLocation: Equatable, Sendable {
  case installed, downloads, readOnlyVolume, translocated, elsewhere, development

  public static func evaluate(bundleURL: URL, homeDirectory: URL, volumeIsReadOnly: Bool = false) -> Self {
    guard bundleURL.pathExtension.lowercased() == "app" else { return .development }
    let app = bundleURL.standardizedFileURL
    if app.pathComponents.contains("AppTranslocation") { return .translocated }
    if FileSystem.path(app, isInsideOrEqual: URL(fileURLWithPath: "/Applications"))
      || FileSystem.path(app, isInsideOrEqual: homeDirectory.appendingPathComponent("Applications")) {
      return .installed
    }
    if volumeIsReadOnly { return .readOnlyVolume }
    if FileSystem.path(app, isInsideOrEqual: homeDirectory.appendingPathComponent("Downloads")) {
      return .downloads
    }
    return .elsewhere
  }

  public var suggestsInstallation: Bool {
    self != .installed && self != .development
  }
}

/// Persists the step, not permission or account status. Reopening setup after
/// completion starts at Welcome; a restart during access setup resumes that step.
public struct SetupProgressStore {
  public static let completedKey = "care.onboardingDone"
  public static let stepKey = "setup.currentStep"
  public static let stepCount = 3
  private let defaults: UserDefaults

  public init(defaults: UserDefaults = .standard) { self.defaults = defaults }

  public var initialStep: Int {
    guard !defaults.bool(forKey: Self.completedKey) else { return 0 }
    let saved = defaults.integer(forKey: Self.stepKey)
    return (0..<Self.stepCount).contains(saved) ? saved : 0
  }

  public func record(step: Int) {
    guard (0..<Self.stepCount).contains(step) else { return }
    defaults.set(step, forKey: Self.stepKey)
  }

  public func complete() {
    defaults.set(true, forKey: Self.completedKey)
    defaults.removeObject(forKey: Self.stepKey)
  }
}
