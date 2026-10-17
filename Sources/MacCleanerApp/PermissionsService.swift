import AppKit
import Photos
import UserNotifications

/// Settings links are conveniences, not permission grants. macOS versions may
/// ignore a pane anchor, so every screen also provides its written settings path.
enum PermissionSettingsPane: CaseIterable {
  case fullDiskAccess, filesAndFolders, photos, notifications, appManagement

  var url: URL {
    let address: String
    switch self {
    case .fullDiskAccess:
      address = "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_AllFiles"
    case .filesAndFolders:
      address = "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_FilesAndFolders"
    case .photos:
      address = "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Photos"
    case .notifications:
      address = "x-apple.systempreferences:com.apple.Notifications-Settings.extension"
    case .appManagement:
      address = "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension"
    }
    return URL(string: address)!
  }

  var path: String {
    switch self {
    case .fullDiskAccess: return "System Settings → Privacy & Security → Full Disk Access"
    case .filesAndFolders: return "System Settings → Privacy & Security → Files & Folders"
    case .photos: return "System Settings → Privacy & Security → Photos"
    case .notifications: return "System Settings → Notifications → MacMint"
    case .appManagement: return "System Settings → Privacy & Security → App Management"
    }
  }
}

enum PhotosPermissionState: Equatable {
  case notRequested, allowed, limited, denied, restricted, unknown

  init(_ status: PHAuthorizationStatus) {
    switch status {
    case .notDetermined: self = .notRequested
    case .authorized: self = .allowed
    case .limited: self = .limited
    case .denied: self = .denied
    case .restricted: self = .restricted
    @unknown default: self = .unknown
    }
  }

  var requiresSettings: Bool { self == .denied || self == .restricted || self == .unknown }
  var title: String {
    switch self {
    case .notRequested: return "Asked when you scan your library"
    case .allowed: return "Allowed"
    case .limited: return "Selected photos only"
    case .denied: return "Access is off"
    case .restricted: return "Restricted by this Mac"
    case .unknown: return "Status unavailable"
    }
  }
  var detail: String {
    switch self {
    case .notRequested:
      return "Choose Scan in Photos to request library access. Folder photos do not need this permission."
    case .allowed:
      return "MacMint can analyze local library thumbnails. Deletion still requires your review and Photos confirmation."
    case .limited:
      return "MacMint can inspect only the library photos you made available. Other assets are outside this scan."
    case .denied:
      return "Allow MacMint in Photos settings, return here, and scan again. You can also inspect a photo folder without library access."
    case .restricted:
      return "A system or device-management restriction prevents library access. Your administrator may need to change it. You can still choose a photo folder."
    case .unknown:
      return "Review Photos access in System Settings, or choose a photo folder instead."
    }
  }
}

enum NotificationPermissionState: Equatable {
  case notRequested, enabled, quiet, denied, unavailable

  init(_ status: UNAuthorizationStatus?) {
    guard let status else { self = .unavailable; return }
    switch status {
    case .notDetermined: self = .notRequested
    case .authorized: self = .enabled
    case .provisional: self = .quiet
    case .denied: self = .denied
    @unknown default: self = .unavailable
    }
  }

  var title: String {
    switch self {
    case .notRequested: return "Asked when you enable a reminder"
    case .enabled: return "Allowed"
    case .quiet: return "Quiet delivery"
    case .denied: return "Notifications are off"
    case .unavailable: return "Check the installed app"
    }
  }
}

/// Reads existing authorization only. Creating or refreshing this service never
/// prompts for access, probes protected directories, or starts a scan.
@MainActor
final class PermissionsService: ObservableObject {
  @Published private(set) var photos: PhotosPermissionState = .notRequested
  @Published private(set) var notifications: NotificationPermissionState = .unavailable
  @Published private(set) var settingsError: String?

  private let readPhotos: () -> PHAuthorizationStatus
  private let readNotifications: () async -> UNAuthorizationStatus?
  private let openURL: (URL) -> Bool
  private var refreshGeneration = UUID()

  init(readPhotos: @escaping () -> PHAuthorizationStatus = { PHPhotoLibrary.authorizationStatus(for: .readWrite) },
    readNotifications: @escaping () async -> UNAuthorizationStatus? = {
      guard CareService.isBundledApp else { return nil }
      return await PermissionsService.notificationAuthorizationStatus()
    }, openURL: @escaping (URL) -> Bool = { NSWorkspace.shared.open($0) }) {
    self.readPhotos = readPhotos
    self.readNotifications = readNotifications
    self.openURL = openURL
  }

  func refresh() async {
    let generation = UUID()
    refreshGeneration = generation
    photos = PhotosPermissionState(readPhotos())
    let status = await readNotifications()
    guard generation == refreshGeneration else { return }
    notifications = NotificationPermissionState(status)
  }

  /// UNNotificationSettings is not Sendable on supported SDKs. Extract the
  /// authorization enum on the callback queue so that object never crosses actors.
  static func notificationAuthorizationStatus() async -> UNAuthorizationStatus {
    await withCheckedContinuation { continuation in
      UNUserNotificationCenter.current().getNotificationSettings { settings in
        continuation.resume(returning: settings.authorizationStatus)
      }
    }
  }

  func open(_ pane: PermissionSettingsPane) {
    settingsError = nil
    if !Self.openSettings(pane, openURL: openURL) {
      settingsError = "Open \(pane.path) from the Apple menu. MacMint could not open System Settings."
    }
  }

  @discardableResult
  static func openSettings(_ pane: PermissionSettingsPane,
    openURL: (URL) -> Bool = { NSWorkspace.shared.open($0) }) -> Bool {
    openURL(pane.url) || openURL(URL(fileURLWithPath: "/System/Applications/System Settings.app"))
  }

  func revealThisApp() {
    guard Bundle.main.bundleURL.pathExtension == "app" else {
      settingsError = "Run the installed MacMint.app to reveal the copy that needs access."
      return
    }
    settingsError = nil
    NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
  }
}
