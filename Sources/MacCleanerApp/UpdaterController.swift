import AppKit
import Combine
import MacCleanerCore
import Sparkle

/// Sparkle 2 for MacMint (docs/UPDATES.md): scheduled checks of the selected channel's
/// appcast, EdDSA-verified downloads from this repository's GitHub releases, and an
/// install-and-relaunch that waits for file operations to finish.
@MainActor
final class UpdaterController: NSObject, ObservableObject {
  struct Update: Equatable {
    let version: String
    let build: String

    init(version: String, build: String) {
      self.version = version
      self.build = build
    }

    init(_ item: SUAppcastItem) {
      self.init(version: item.displayVersionString, build: item.versionString)
    }

    var title: String { "\(version) (build \(build))" }
  }

  static let current = BuildInfo(infoDictionary: Bundle.main.infoDictionary)

  @Published private(set) var canCheckForUpdates = false
  @Published private(set) var lastCheck: Date?
  @Published private(set) var startError: String?
  /// The newest valid update Sparkle found in the selected feed.
  @Published private(set) var availableUpdate: Update?
  /// A scheduled update Sparkle left to MacMint's banner instead of interrupting with its alert.
  @Published private(set) var reminder: Update?
  /// Install and Relaunch was chosen while files were being moved; it continues when they finish.
  @Published private(set) var isWaitingForWork = false
  @Published var channel: UpdateChannel {
    didSet {
      guard channel != oldValue else { return }
      channel.save(in: defaults)
      availableUpdate = nil
      reminder = nil
      // The feed URL changed, so Sparkle checks the new channel straight away.
      controller?.updater.resetUpdateCycleAfterShortDelay()
    }
  }

  let relaunchGate = UpdateRelaunchGate()
  /// Runs after each scheduled or manual Sparkle cycle so the server's minimum-version gate
  /// follows Sparkle's schedule instead of a second timer.
  var onCycleFinished: (() -> Void)?
  private let defaults: UserDefaults
  private var controller: SPUStandardUpdaterController?
  private var subscriptions: Set<AnyCancellable> = []
  private var workSubscription: Set<AnyCancellable> = []
  private weak var boundModel: AppViewModel?

  /// `startingUpdater: false` builds the settings UI without scheduling checks (smoke renders).
  init(startingUpdater: Bool = true, defaults: UserDefaults = .standard) {
    self.defaults = defaults
    channel = UpdateChannel.saved(in: defaults)
    super.init()
    let controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: self, userDriverDelegate: self)
    self.controller = controller
    let updater = controller.updater
    updater.publisher(for: \.canCheckForUpdates).assign(to: &$canCheckForUpdates)
    // Sparkle's own alerts can change these; refresh the Settings toggles when they do.
    updater.publisher(for: \.automaticallyChecksForUpdates).map { _ in () }
      .merge(with: updater.publisher(for: \.automaticallyDownloadsUpdates).map { _ in () })
      .sink { [weak self] in self?.objectWillChange.send() }
      .store(in: &subscriptions)
    lastCheck = updater.lastUpdateCheckDate
    guard startingUpdater else { return }
    do {
      try updater.start()
    } catch {
      startError = "Updates are unavailable in this copy of MacMint. Download the current version from macmint.co."
      NSLog("MacMint updater did not start: %@", String(describing: error))
    }
  }

  var automaticallyChecks: Bool {
    get { controller?.updater.automaticallyChecksForUpdates ?? false }
    set {
      objectWillChange.send()
      controller?.updater.automaticallyChecksForUpdates = newValue
    }
  }

  var automaticallyInstalls: Bool {
    get { controller?.updater.automaticallyDownloadsUpdates ?? false }
    set {
      objectWillChange.send()
      controller?.updater.automaticallyDownloadsUpdates = newValue
    }
  }

  /// Whether Sparkle allows automatic installation for this app at all (Info.plist, admin policy).
  var allowsAutomaticInstalls: Bool { controller?.updater.allowsAutomaticUpdates ?? false }

  var receivesDeveloperBuilds: Bool {
    get { channel == .developer }
    set { channel = newValue ? .developer : .stable }
  }

  /// Shows Sparkle's update window: progress, the found update with Install, or up to date.
  func checkForUpdates() {
    reminder = nil
    controller?.checkForUpdates(nil)
  }

  /// Finds out whether the feed has an update without showing any window. Used when the
  /// server reports a newer or required version, so the banner can install it.
  func probeForUpdate() {
    guard let updater = controller?.updater, canCheckForUpdates, !updater.sessionInProgress else { return }
    updater.checkForUpdateInformation()
  }

  func dismissReminder() { reminder = nil }

  /// Holds Sparkle's relaunch while `model` is working and releases it when work ends.
  func bind(to model: AppViewModel) {
    guard boundModel !== model else { return }
    boundModel = model
    workSubscription = []
    relaunchGate.isWorking = { [weak model] in model?.isWorking ?? false }
    model.$isWorking.removeDuplicates()
      .receive(on: DispatchQueue.main)
      .sink { [weak self] _ in
        guard let self else { return }
        relaunchGate.workDidChange()
        isWaitingForWork = relaunchGate.isHolding && !relaunchGate.isRelaunching
      }
      .store(in: &workSubscription)
  }

  /// Sparkle's postpone decision: wait while files are being moved, then continue the install.
  func postponeRelaunch(_ installHandler: @escaping () -> Void) -> Bool {
    let postponed = relaunchGate.postponeRelaunch { [weak self] in
      self?.isWaitingForWork = false
      installHandler()
    }
    isWaitingForWork = postponed
    return postponed
  }

  /// Fixture states for the offscreen smoke renders only.
  func showPreview(available: Update?, reminder: Update?, waitingForWork: Bool) {
    availableUpdate = available
    self.reminder = reminder
    isWaitingForWork = waitingForWork
  }

  /// The feed Sparkle reads for a channel. Anything outside this repository's release assets is refused.
  static func feedURLString(for channel: UpdateChannel) -> String? {
    ReleaseChecker.trustedUpdateURL(channel.feedURL.absoluteString)?.absoluteString
  }
}

extension UpdaterController: SPUUpdaterDelegate {
  func feedURLString(for updater: SPUUpdater) -> String? {
    Self.feedURLString(for: channel)
  }

  func updater(_ updater: SPUUpdater, shouldProceedWithUpdate item: SUAppcastItem, updateCheck: SPUUpdateCheck) throws {
    guard ReleaseChecker.trustedUpdateURL(item.fileURL?.absoluteString) != nil else {
      throw NSError(domain: "co.macmint.updates", code: 1, userInfo: [
        NSLocalizedDescriptionKey: "This update is not a MacMint release download, so it was not installed.",
      ])
    }
  }

  func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
    availableUpdate = Update(item)
  }

  func updaterDidNotFindUpdate(_ updater: SPUUpdater) {
    availableUpdate = nil
    reminder = nil
  }

  func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: (any Error)?) {
    lastCheck = updater.lastUpdateCheckDate ?? lastCheck
    if updateCheck != .updateInformation { onCycleFinished?() }
  }

  func updater(_ updater: SPUUpdater, shouldPostponeRelaunchForUpdate item: SUAppcastItem,
    untilInvokingBlock installHandler: @escaping () -> Void) -> Bool {
    postponeRelaunch(installHandler)
  }

  func updaterWillRelaunchApplication(_ updater: SPUUpdater) {
    relaunchGate.relaunchWillBegin()
  }
}

/// Gentle reminders: a scheduled update found while the user is busy appears as MacMint's
/// banner rather than an alert. Sparkle calls these on the main thread.
extension UpdaterController: SPUStandardUserDriverDelegate {
  nonisolated var supportsGentleScheduledUpdateReminders: Bool { true }

  nonisolated func standardUserDriverShouldHandleShowingScheduledUpdate(_ update: SUAppcastItem,
    andInImmediateFocus immediateFocus: Bool) -> Bool {
    immediateFocus
  }

  nonisolated func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool,
    forUpdate update: SUAppcastItem, state: SPUUserUpdateState) {
    guard !handleShowingUpdate else { return }
    MainActor.assumeIsolated { reminder = Update(update) }
  }

  nonisolated func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
    MainActor.assumeIsolated { reminder = nil }
  }

  nonisolated func standardUserDriverWillFinishUpdateSession() {
    MainActor.assumeIsolated { reminder = nil }
  }
}
