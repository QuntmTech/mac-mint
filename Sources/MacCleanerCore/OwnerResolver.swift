import Foundation

/// Who an item belongs to, as far as the item itself can tell us.
public struct OwnerHint: Hashable, Sendable {
  /// Bundle identifier of the owning app, when known (resolve to a name/icon via NSWorkspace).
  public let bundleID: String?
  /// Human name to show when no installed app can be found (e.g. "Homebrew").
  public let displayName: String?

  public init(bundleID: String?, displayName: String?) {
    self.bundleID = bundleID
    self.displayName = displayName
  }
}

public enum OwnerResolver {
  /// Well-known folder names that aren't bundle identifiers.
  static let knownFolders: [String: OwnerHint] = [
    "google": .init(bundleID: "com.google.Chrome", displayName: "Google Chrome"),
    "chrome": .init(bundleID: "com.google.Chrome", displayName: "Google Chrome"),
    "firefox": .init(bundleID: "org.mozilla.firefox", displayName: "Firefox"),
    "microsoft edge": .init(bundleID: "com.microsoft.edgemac", displayName: "Microsoft Edge"),
    "bravesoftware": .init(bundleID: "com.brave.Browser", displayName: "Brave"),
    "brave-browser": .init(bundleID: "com.brave.Browser", displayName: "Brave"),
    "arc": .init(bundleID: "company.thebrowser.Browser", displayName: "Arc"),
    "vivaldi": .init(bundleID: "com.vivaldi.Vivaldi", displayName: "Vivaldi"),
    "spotify": .init(bundleID: "com.spotify.client", displayName: "Spotify"),
    "slack": .init(bundleID: "com.tinyspeck.slackmacgap", displayName: "Slack"),
    "discord": .init(bundleID: "com.hnc.Discord", displayName: "Discord"),
    "code": .init(bundleID: "com.microsoft.VSCode", displayName: "Visual Studio Code"),
    "cursor": .init(bundleID: "com.todesktop.230313mzl4w4u92", displayName: "Cursor"),
    "zoom.us": .init(bundleID: "us.zoom.xos", displayName: "zoom.us"),
    "jetbrains": .init(bundleID: nil, displayName: "JetBrains IDEs"),
    "adobe": .init(bundleID: nil, displayName: "Adobe apps"),
    "homebrew": .init(bundleID: nil, displayName: "Homebrew"),
    "pip": .init(bundleID: nil, displayName: "pip"),
    "yarn": .init(bundleID: nil, displayName: "Yarn"),
    "cocoapods": .init(bundleID: nil, displayName: "CocoaPods"),
    "org.swift.swiftpm": .init(bundleID: nil, displayName: "Swift Package Manager"),
    "node-gyp": .init(bundleID: nil, displayName: "Node.js"),
    "typescript": .init(bundleID: nil, displayName: "TypeScript"),
  ]

  /// Developer tools mapped to the app whose icon represents them.
  public static let toolBundleIDs: [String: String] = [
    "Xcode": "com.apple.dt.Xcode",
    "Simulator": "com.apple.iphonesimulator",
    "Docker": "com.docker.docker",
    "LM Studio": "ai.elementlabs.lmstudio",
    "Ollama": "com.electron.ollama",
  ]

  /// Library folders whose direct children are named after their owner.
  private static let ownerNamedRoots: Set<String> = [
    "caches", "logs", "application support", "containers", "group containers", "preferences",
    "saved application state", "httpstorages", "webkit", "application scripts", "cookies",
  ]

  /// An explicit owner wins; otherwise the folder directly under a Library root (or the item
  /// itself) is read as a bundle identifier or a well-known name.
  public static func hint(for url: URL, explicitBundleID: String? = nil) -> OwnerHint? {
    if let explicitBundleID { return OwnerHint(bundleID: explicitBundleID, displayName: nil) }
    let components = url.standardizedFileURL.pathComponents
    var candidates: [String] = []
    if let index = components.lastIndex(where: { ownerNamedRoots.contains($0.lowercased()) }),
      index + 1 < components.count
    {
      candidates.append(components[index + 1])
      if index + 2 < components.count { candidates.append(components[index + 2]) }
    }
    candidates.append(url.lastPathComponent)
    for name in candidates {
      if let known = knownFolders[name.lowercased()] { return known }
      let inGroups = components.contains { $0.lowercased() == "group containers" }
      if let id = OrphanScanner.bundleID(fromName: name, inGroupContainers: inGroups) {
        return OwnerHint(bundleID: id, displayName: nil)
      }
    }
    return nil
  }
}
