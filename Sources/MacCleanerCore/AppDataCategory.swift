import Foundation

public enum AppDataCategory: String, CaseIterable, Sendable {
  case caches = "Caches"
  case logs = "Logs"
  case settings = "Settings"
  case state = "Saved state"
  case support = "App data"
  case shared = "Shared data"
  case background = "Background items"
  public var consequence: String {
    switch self {
    case .caches: return "Rebuilt or downloaded again when the app needs them."
    case .logs: return "Diagnostic history will be removed."
    case .settings: return "Preferences and sign-in settings may reset."
    case .state: return "Saved windows and recovery state may be lost."
    case .support: return "May include local projects, downloads, databases and account data."
    case .shared: return "Other apps or another installed copy may depend on this data."
    case .background: return "Removes a user launch definition; running helpers may require a logout."
    }
  }
}

extension AppLeftover {
  public var category: AppDataCategory {
    if isShared { return .shared }
    let path = url.path.lowercased()
    if path.contains("/library/caches/") { return .caches }
    if path.contains("/library/logs/") { return .logs }
    if path.contains("/library/preferences/") { return .settings }
    if path.contains("/library/saved application state/") { return .state }
    if path.contains("/library/launchagents/") { return .background }
    return .support
  }
  public var isDisposableData: Bool { category == .caches || category == .logs }
}
