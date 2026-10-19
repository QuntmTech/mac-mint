import AppKit
import MacCleanerCore
import SwiftUI

/// Synthetic data used only by the explicit --smoke-test harness. No scan, sign-in,
/// permission request, or removal is performed. Preview images live only in the isolated test directory.
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
  model.appLeftovers = [
    AppLeftover(url: root.appendingPathComponent("Library/Caches/com.example.editor"), size: gib / 8,
      confidence: .high, reason: "Named with this app's exact bundle identifier."),
    AppLeftover(url: root.appendingPathComponent("Library/Preferences/com.example.editor.plist"), size: 8192,
      confidence: .high, reason: "Named with this app's exact bundle identifier."),
    AppLeftover(url: root.appendingPathComponent("Library/Group Containers/group.example.editor"), size: gib / 16,
      confidence: .medium, reason: "Other apps from the developer may use this container.", isShared: true),
  ]
  model.selectedLeftoverIDs = Set(model.appLeftovers.filter(\.isSuggested).map(\.id))
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
  // Deterministic, synthetic preview images exercise the real thumbnail path without
  // relying on a runner's Photos library, an internet image, or anyone's personal data.
  let photos: [PhotoFingerprint] = (0..<3).map { index in
    let url = root.appendingPathComponent("Pictures/Sample coast \(index + 1).png")
    let image = NSImage(size: NSSize(width: 480, height: 360), flipped: false) { rect in
      NSGradient(colors: [NSColor(srgbRed: 0.72, green: 0.88, blue: 0.87, alpha: 1),
        NSColor(srgbRed: 0.30, green: 0.62, blue: 0.67, alpha: 1)])?.draw(in: rect, angle: -90)
      NSColor(srgbRed: 0.98, green: 0.89, blue: 0.65, alpha: 1).setFill()
      NSBezierPath(ovalIn: NSRect(x: 326 - index * 5, y: 247, width: 50, height: 50)).fill()
      NSColor(srgbRed: 0.17, green: 0.40, blue: 0.37, alpha: 1).setFill()
      let hill = NSBezierPath()
      hill.move(to: NSPoint(x: 0, y: 0)); hill.line(to: NSPoint(x: 0, y: 130))
      hill.curve(to: NSPoint(x: 480, y: 60), controlPoint1: NSPoint(x: 155, y: 270), controlPoint2: NSPoint(x: 250, y: 75))
      hill.line(to: NSPoint(x: 480, y: 0)); hill.close(); hill.fill()
      NSColor(srgbRed: 0.80, green: 0.77, blue: 0.58, alpha: 1).setFill()
      let beach = NSBezierPath()
      beach.move(to: NSPoint(x: 0, y: 0)); beach.line(to: NSPoint(x: 480, y: 0))
      beach.line(to: NSPoint(x: 480, y: 70))
      beach.curve(to: NSPoint(x: 0, y: 35), controlPoint1: NSPoint(x: 270, y: 135), controlPoint2: NSPoint(x: 120, y: 0))
      beach.close(); beach.fill()
      return true
    }
    try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    if let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
       let png = bitmap.representation(using: .png, properties: [:]) { try? png.write(to: url) }
    return PhotoFingerprint(url: url, bytes: 4_000_000, hash: UInt64(index), sharpness: 100 - Double(index), pixelWidth: 480, pixelHeight: 360)
  }
  model.photoSource = .folder(root.appendingPathComponent("Pictures"))
  model.photoScan = PhotoScanResult(photos: photos,
    similarGroups: [SimilarPhotoGroup(id: "sample-coast", photos: photos, keeperIndex: 0)],
    blurry: [], screenshots: [], skippedLibraries: [], issues: [], wasCancelled: false)
  model.refreshRecommendations()
}
