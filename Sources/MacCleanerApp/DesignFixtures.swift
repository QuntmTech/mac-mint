import MacCleanerCore
import SwiftUI

/// Synthetic data used only by the explicit --smoke-test harness. No scan, sign-in,
/// permission request, file creation, or removal is performed by this fixture.
@MainActor
func seedDesignFixtures(_ model: AppViewModel, root: URL) {
  let gib: Int64 = 1_073_741_824
  model.lastScanDate = Date().addingTimeInterval(-180)
  model.lastScanDuration = 2.8
  model.scanCompletedAreas = ["User caches", "Application inventory", "Developer caches", "Downloads", "Home Trash"]
  model.statusMessage = "Quick Scan complete · Review your results when you’re ready"
  model.cleanupTargets = [
    CleanupTarget(category: .userCaches, url: root.appendingPathComponent("Library/Caches/com.example.editor"), displayName: "Editor caches", size: gib * 2, risk: .safe, reason: "Generated previews and temporary data. Recreated when the app needs them.", ownerBundleID: "com.example.editor"),
    CleanupTarget(category: .browserCaches, url: root.appendingPathComponent("Library/Caches/com.example.browser"), displayName: "Browser cache", size: gib / 2, risk: .safe, reason: "Website resources download again. Browsing history and saved passwords are kept.", ownerBundleID: "com.example.browser"),
    CleanupTarget(category: .userLogs, url: root.appendingPathComponent("Library/Logs/Example"), displayName: "Application logs", size: gib / 8, risk: .safe, reason: "Diagnostic logs can help investigate an app problem. New logs are created automatically."),
    CleanupTarget(category: .deviceBackups, url: root.appendingPathComponent("Library/Application Support/MobileSync/Backup"), displayName: "Local iPhone backup", size: gib * 8, risk: .review, reason: "A local device backup. Confirm another usable backup exists before removing it.", isSelected: false),
    CleanupTarget(category: .installers, url: root.appendingPathComponent("Downloads/Example Installer.dmg"), displayName: "Downloaded installer", size: gib, risk: .review, reason: "Check that the app is installed and the installer can be downloaded again.", isSelected: false),
  ]
  model.apps = [
    AppRecord(url: root.appendingPathComponent("Applications/Example Editor.app"), name: "Example Editor", bundleIdentifier: "com.example.editor", version: "4.2.1", bundleSize: gib / 2, lastModified: Date(), lastUsed: Date()),
    AppRecord(url: root.appendingPathComponent("Applications/Example Browser.app"), name: "Example Browser", bundleIdentifier: "com.example.browser", version: "18.0", bundleSize: gib / 3, lastModified: Date(), lastUsed: Date().addingTimeInterval(-86400)),
    AppRecord(url: root.appendingPathComponent("Applications/Example Notes.app"), name: "Example Notes", bundleIdentifier: "com.example.notes", version: "2.6", bundleSize: gib / 8, lastModified: Date(), lastUsed: Date().addingTimeInterval(-180 * 86400)),
  ]
  model.selectedApp = model.apps.first
  model.devItems = [
    DevStorageItem(group: .xcode, tool: "Xcode", title: "ExampleApp build data", subtitle: "Last changed 32 days ago", url: root.appendingPathComponent("Library/Developer/Xcode/DerivedData/ExampleApp"), bytes: gib * 4, rebuild: .rebuildable, removal: .trash),
    DevStorageItem(group: .packageCaches, tool: "npm", title: "npm download cache", subtitle: "Packages download again when needed", url: root.appendingPathComponent(".npm/_cacache"), bytes: gib, rebuild: .redownload, removal: .trash),
    DevStorageItem(group: .projects, tool: "Swift", title: "ActiveWorkspace / .build", subtitle: "Recently changed · Review after closing the project", url: root.appendingPathComponent("Projects/ActiveWorkspace/.build"), bytes: gib * 2, rebuild: .rebuildable, removal: .trash, isActive: true),
    DevStorageItem(group: .containers, tool: "Docker", title: "Docker storage", subtitle: "Managed by Docker", url: nil, bytes: gib * 6, rebuild: .review, removal: .command("docker system df")),
  ]
  let children = [("Projects", Int64(28)), ("Movies", 18), ("Downloads", 12), ("Pictures", 9), ("Documents", 6), ("Music", 3)].map { name, count in
    StorageNode(url: root.appendingPathComponent(name), kind: .folder, allocatedBytes: count * gib, logicalBytes: count * gib, itemCount: Int(count) * 40)
  }
  model.storageRoot = root
  model.storageScan = StorageScan(root: StorageNode(url: root, name: "Home", kind: .folder, allocatedBytes: 76 * gib, logicalBytes: 76 * gib, itemCount: 3040, children: children), coverage: StorageCoverage(), duration: 1.4)
  let first = LargeFile(url: root.appendingPathComponent("Pictures/Coast.jpg"), size: gib / 128, modifiedAt: Date(), accessedAt: nil)
  let copy = LargeFile(url: root.appendingPathComponent("Downloads/Coast copy.jpg"), size: gib / 128, modifiedAt: Date().addingTimeInterval(-86400), accessedAt: nil)
  model.duplicateGroups = [DuplicateGroup(fingerprint: "design-fixture", files: [first, copy])]
  model.largeFiles = [LargeFile(url: root.appendingPathComponent("Movies/Weekend edit.mov"), size: gib * 5, modifiedAt: Date().addingTimeInterval(-86400 * 60), accessedAt: nil)]
  model.history = [HistoryEntry(date: Date().addingTimeInterval(-86400), action: "Quick Scan cleanup", paths: [root.appendingPathComponent("Library/Caches/Example").path], bytes: gib * 2, notes: "Fixture operation. No files were moved.", receipts: [])]
  model.refreshRecommendations()
}
