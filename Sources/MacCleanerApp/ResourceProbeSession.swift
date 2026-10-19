import AppKit
import MacCleanerCore

/// `--resource-probe <folder>` is passed only by scripts/native_startup_test.swift.
/// That launch keeps every support file (history, exclusions, snapshots, slowdown records)
/// in `<folder>/support`, and may map and scan the generated fixture folders named in
/// `<folder>/manifest.json`. It only reads: nothing is selected, moved or removed.
enum ResourceProbeSession {
  struct Manifest: Codable, Equatable {
    var storage: String?
    var photos: String?
  }

  static let folder: URL? = folder(arguments: CommandLine.arguments)

  static var supportDirectory: URL? { folder?.appendingPathComponent("support", isDirectory: true) }

  static func folder(arguments: [String], fileManager: FileManager = .default) -> URL? {
    guard let index = arguments.firstIndex(of: "--resource-probe"), arguments.indices.contains(index + 1),
      arguments[index + 1].hasPrefix("/") else { return nil }
    let url = URL(fileURLWithPath: arguments[index + 1], isDirectory: true).standardizedFileURL
    var isDirectory: ObjCBool = false
    guard url.lastPathComponent.hasPrefix("macmint-resource-probe"),
      fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue,
      fileManager.fileExists(atPath: url.appendingPathComponent("manifest.json").path) else { return nil }
    return url
  }

  @MainActor private static var started = false
  @MainActor private static var observers: [NSObjectProtocol] = []

  /// Runs the manifest's read-only scans as a person would (visible screen, same gates),
  /// returns to Overview, then writes `status.json` for the probe. Sample counts are written
  /// when the app is hidden and when it quits, so the probe can check that hidden apps stop.
  @MainActor
  static func runIfRequested(_ model: AppViewModel) async {
    guard let folder, !started,
      let data = try? Data(contentsOf: folder.appendingPathComponent("manifest.json")),
      let manifest = try? JSONDecoder().decode(Manifest.self, from: data) else { return }
    started = true
    for (name, event) in [(NSApplication.didHideNotification, "hide"), (NSApplication.willTerminateNotification, "quit")] {
      observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { @Sendable _ in
        MainActor.assumeIsolated { writeSamples(event, to: folder) }
      })
    }
    guard manifest.storage != nil || manifest.photos != nil else { return }
    for _ in 0..<600 where !(model.exclusionsReady && model.recoveryReady) {
      try? await Task.sleep(for: .milliseconds(100))
    }
    var status: [String: Int] = [:]
    if let storage = manifest.storage {
      model.storageRoot = URL(fileURLWithPath: storage, isDirectory: true)
      model.selectedSection = .storage
      model.scanStorage()
      await model.currentTask?.value
      status["storageItems"] = model.storageScan?.coverage.scannedItems ?? 0
      status["storageNodes"] = model.storageScan.map { Self.nodeCount($0.root) } ?? 0
    }
    if let photos = manifest.photos {
      model.photoSource = .folder(URL(fileURLWithPath: photos, isDirectory: true))
      model.selectedSection = .photos
      model.scanPhotos()
      await model.currentTask?.value
      status["photos"] = model.photoScan?.photos.count ?? 0
      status["similarGroups"] = model.photoScan?.similarGroups.count ?? 0
      // Visible previews decode while the results are on screen.
      try? await Task.sleep(for: .seconds(5))
    }
    model.selectedSection = .dashboard
    if let output = try? JSONSerialization.data(withJSONObject: status, options: [.sortedKeys]) {
      try? output.write(to: folder.appendingPathComponent("status.json"), options: .atomic)
    }
  }

  @MainActor
  private static func writeSamples(_ event: String, to folder: URL) {
    let counts = ["samples": SystemMonitor.samples, "publishedSamples": SystemMonitor.publishedSamples]
    if let data = try? JSONSerialization.data(withJSONObject: counts, options: [.sortedKeys]) {
      try? data.write(to: folder.appendingPathComponent("samples-\(event).json"), options: .atomic)
    }
  }

  static func nodeCount(_ node: StorageNode) -> Int {
    node.children.reduce(1) { $0 + nodeCount($1) }
  }
}
