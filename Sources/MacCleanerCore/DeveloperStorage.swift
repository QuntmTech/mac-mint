import Foundation

public enum DevGroup: String, CaseIterable, Codable, Hashable, Sendable {
  case xcode = "Xcode"
  case simulators = "Simulators"
  case packageCaches = "Package caches"
  case projects = "Project build folders"
  case aiModels = "AI models"
  case containers = "Containers"
}

public enum RebuildCost: String, Codable, Hashable, Sendable {
  /// Recreated automatically by the next build.
  case rebuildable
  /// Downloaded again the next time it's needed.
  case redownload
  /// May not be recoverable (archives, models you trained or converted).
  case review

  public var explanation: String {
    switch self {
    case .rebuildable: return "Rebuilt automatically the next time you build."
    case .redownload: return "Downloaded again the next time it's needed."
    case .review: return "May not come back on its own — review before removing."
    }
  }
}

public enum DevRemoval: Hashable, Sendable {
  /// Safe to move to the Trash.
  case trash
  /// Managed by its tool; run this command instead of deleting files.
  case command(String)
  /// Shown for awareness only.
  case none(String)
}

public struct DevStorageItem: Identifiable, Hashable, Sendable {
  public let id: String
  public let group: DevGroup
  public let tool: String
  public let title: String
  public let subtitle: String
  public let url: URL?
  public let bytes: Int64
  public let lastUsed: Date?
  public let rebuild: RebuildCost
  public let removal: DevRemoval
  /// Touched recently, so probably in active use; never preselected.
  public let isActive: Bool

  public init(
    id: String? = nil, group: DevGroup, tool: String, title: String, subtitle: String = "",
    url: URL?, bytes: Int64, lastUsed: Date? = nil, rebuild: RebuildCost, removal: DevRemoval,
    isActive: Bool = false
  ) {
    self.id = id ?? url?.standardizedFileURL.path ?? "\(tool):\(title)"
    self.group = group
    self.tool = tool
    self.title = title
    self.subtitle = subtitle
    self.url = url
    self.bytes = bytes
    self.lastUsed = lastUsed
    self.rebuild = rebuild
    self.removal = removal
    self.isActive = isActive
  }

  /// Rebuildable, idle items that can go to the Trash are suggested by default.
  public var isSuggested: Bool {
    rebuild == .rebuildable && removal == .trash && !isActive
  }

  public var canTrash: Bool { removal == .trash && url != nil }
}

/// Inventories developer and AI storage with tool-specific knowledge instead of path guessing.
public actor DeveloperStorageScanner {
  private let fileManager: FileManager
  private let home: URL
  private let environment: [String: String]
  private let activeWindow: TimeInterval

  /// Folder names that are always build output, recreated by their tool.
  public static let projectArtifactNames: Set<String> = [
    "node_modules", ".build", "target", "DerivedData", ".gradle", "__pycache__", ".next", ".nuxt",
    ".turbo", ".parcel-cache", ".svelte-kit", "Pods",
  ]

  public init(
    fileManager: FileManager = .default, homeDirectory: URL? = nil,
    environment: [String: String] = ProcessInfo.processInfo.environment,
    activeWindow: TimeInterval = 3 * 86_400
  ) {
    self.fileManager = fileManager
    self.home = homeDirectory ?? fileManager.homeDirectoryForCurrentUser
    self.environment = environment
    self.activeWindow = activeWindow
  }

  /// Model/cache locations moved through environment variables, so removal rules follow them.
  public static func configuredRoots(
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) -> [URL] {
    [
      environment["HF_HUB_CACHE"],
      environment["HF_HOME"].map { $0 + "/hub" },
    ].compactMap { $0 }.map { URL(fileURLWithPath: $0) }
  }

  public func scan(projectRoots: [URL] = []) async -> ScanReport<[DevStorageItem]> {
    let started = Date()
    var items: [DevStorageItem] = []
    var issues: [ScanIssue] = []
    let adapters: [() -> [DevStorageItem]] = [
      xcodeDerivedData, xcodeArchives, deviceSupport, simulatorCaches, packageCaches,
      ollamaModels, lmStudioModels, huggingFaceModels, dockerDisk,
    ]
    for adapter in adapters {
      if Task.isCancelled { break }
      items += adapter()
    }
    for root in projectRoots {
      if Task.isCancelled { break }
      let report = projectArtifacts(in: root)
      items += report.items
      issues += report.issues
    }
    let sorted = items.filter { $0.bytes > 0 }.sorted { $0.bytes > $1.bytes }
    return ScanReport(
      value: sorted, issues: issues, duration: Date().timeIntervalSince(started),
      wasCancelled: Task.isCancelled)
  }

  // MARK: Xcode

  private func xcodeDerivedData() -> [DevStorageItem] {
    let root = home.appendingPathComponent("Library/Developer/Xcode/DerivedData")
    return children(of: root).filter { $0.lastPathComponent != "ModuleCache.noindex" }.map { url in
      // Folder names are "<Project>-<hash>".
      let name = url.lastPathComponent.split(separator: "-").dropLast().joined(separator: "-")
      return item(
        url, group: .xcode, tool: "Xcode", title: name.isEmpty ? url.lastPathComponent : name,
        subtitle: "Build data", rebuild: .rebuildable)
    }
      + children(of: root).filter { $0.lastPathComponent == "ModuleCache.noindex" }.map {
        item($0, group: .xcode, tool: "Xcode", title: "Module cache", subtitle: "Shared by all projects", rebuild: .rebuildable)
      }
  }

  private func xcodeArchives() -> [DevStorageItem] {
    let root = home.appendingPathComponent("Library/Developer/Xcode/Archives")
    return children(of: root).flatMap { day in
      children(of: day).filter { $0.pathExtension == "xcarchive" }.map { archive in
        item(
          archive, group: .xcode, tool: "Xcode",
          title: archive.deletingPathExtension().lastPathComponent,
          subtitle: "Archive from \(day.lastPathComponent) — needed to symbolicate crash reports for that release",
          rebuild: .review)
      }
    }
  }

  private func deviceSupport() -> [DevStorageItem] {
    ["iOS", "watchOS", "tvOS", "visionOS"].flatMap { platform -> [DevStorageItem] in
      let root = home.appendingPathComponent("Library/Developer/Xcode/\(platform) DeviceSupport")
      let versions = children(of: root).sorted { modified($0) ?? .distantPast > modified($1) ?? .distantPast }
      return versions.enumerated().map { index, url in
        item(
          url, group: .xcode, tool: "Xcode", title: "\(platform) \(url.lastPathComponent)",
          subtitle: index == 0
            ? "Device support — most recent, kept for debugging"
            : "Device support — re-copied when that device version is connected",
          rebuild: .redownload, forceActive: index == 0)
      }
    }
  }

  private func simulatorCaches() -> [DevStorageItem] {
    var items: [DevStorageItem] = []
    let caches = home.appendingPathComponent("Library/Developer/CoreSimulator/Caches")
    if exists(caches) {
      items.append(
        item(caches, group: .simulators, tool: "Simulator", title: "Simulator caches", subtitle: "Dyld and runtime caches", rebuild: .rebuildable))
    }
    let devices = home.appendingPathComponent("Library/Developer/CoreSimulator/Devices")
    if exists(devices) {
      items.append(
        DevStorageItem(
          id: devices.path, group: .simulators, tool: "Simulator", title: "Simulator devices",
          subtitle: "Managed by Xcode — removes only simulators whose runtime is no longer installed",
          url: devices, bytes: FileSystem.itemSize(at: devices, fileManager: fileManager),
          lastUsed: modified(devices), rebuild: .review,
          removal: .command("xcrun simctl delete unavailable")))
    }
    return items
  }

  // MARK: Package managers

  private func packageCaches() -> [DevStorageItem] {
    let goPath = environment["GOPATH"].map { URL(fileURLWithPath: $0) } ?? home.appendingPathComponent("go")
    let caches: [(String, String, String)] = [
      ("npm", ".npm/_cacache", "npm download cache"),
      ("pnpm", "Library/pnpm/store", "pnpm content store — projects relink on next install"),
      ("Yarn", "Library/Caches/Yarn", "Yarn download cache"),
      ("Bun", ".bun/install/cache", "Bun install cache"),
      ("Homebrew", "Library/Caches/Homebrew", "Downloaded bottles and casks"),
      ("pip", "Library/Caches/pip", "Python package downloads"),
      ("CocoaPods", "Library/Caches/CocoaPods", "Pod downloads"),
      ("SwiftPM", "Library/Caches/org.swift.swiftpm", "Swift package checkouts"),
      ("Gradle", ".gradle/caches", "Gradle dependency and build cache"),
      ("Maven", ".m2/repository", "Maven artifacts"),
      ("Cargo", ".cargo/registry/cache", "Downloaded crates"),
    ]
    var items = caches.compactMap { tool, relative, detail -> DevStorageItem? in
      let url = home.appendingPathComponent(relative)
      guard exists(url) else { return nil }
      return item(url, group: .packageCaches, tool: tool, title: tool, subtitle: detail, rebuild: .redownload)
    }
    let goModules = goPath.appendingPathComponent("pkg/mod")
    if exists(goModules) {
      items.append(
        DevStorageItem(
          id: goModules.path, group: .packageCaches, tool: "Go", title: "Go modules",
          subtitle: "Read-only module cache — clear it with Go's own command",
          url: goModules, bytes: FileSystem.itemSize(at: goModules, fileManager: fileManager),
          lastUsed: modified(goModules), rebuild: .redownload,
          removal: .command("go clean -modcache")))
    }
    return items
  }

  // MARK: Projects

  private func projectArtifacts(in root: URL) -> (items: [DevStorageItem], issues: [ScanIssue]) {
    guard
      let enumerator = fileManager.enumerator(
        at: root, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
        options: [.skipsPackageDescendants], errorHandler: { _, _ in true })
    else {
      return ([], [ScanIssue(area: "Developer", path: root.path, message: "Could not read this folder.")])
    }
    var found: [URL] = []
    FileSystem.walk(enumerator) { url in
      if Task.isCancelled { return .stop }
      guard (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true,
        (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true
      else { return .continue }
      let name = url.lastPathComponent
      if Self.projectArtifactNames.contains(name), isProjectArtifact(url) {
        found.append(url)
        return .skipDescendants
      }
      // Hidden folders other than known artifacts (e.g. .git) are not interesting.
      return name.hasPrefix(".") ? .skipDescendants : .continue
    }
    let items = found.map { url -> DevStorageItem in
      let project = url.deletingLastPathComponent()
      return item(
        url, group: .projects, tool: url.lastPathComponent, title: project.lastPathComponent,
        subtitle: "\(url.lastPathComponent) in \(project.path.replacingOccurrences(of: home.path, with: "~"))",
        rebuild: .rebuildable, activityURL: project)
    }
    return (items, [])
  }

  /// Requires the build tool's marker next to the folder, so a personal folder that happens
  /// to be called "target" or "Pods" is never offered.
  private func isProjectArtifact(_ url: URL) -> Bool {
    let project = url.deletingLastPathComponent()
    let has: (String) -> Bool = { self.exists(project.appendingPathComponent($0)) }
    switch url.lastPathComponent {
    case "node_modules", ".next", ".nuxt", ".turbo", ".parcel-cache", ".svelte-kit":
      return has("package.json")
    case ".build": return has("Package.swift")
    case "target": return has("Cargo.toml") || has("pom.xml")
    case ".gradle": return has("build.gradle") || has("build.gradle.kts") || has("settings.gradle")
    case "Pods": return has("Podfile")
    case "__pycache__": return true
    case "DerivedData": return true
    default: return false
    }
  }

  // MARK: AI models

  private func ollamaModels() -> [DevStorageItem] {
    let root = environment["OLLAMA_MODELS"].map { URL(fileURLWithPath: $0) }
      ?? home.appendingPathComponent(".ollama/models")
    let manifests = root.appendingPathComponent("manifests")
    guard exists(manifests),
      let enumerator = fileManager.enumerator(at: manifests, includingPropertiesForKeys: [.isRegularFileKey])
    else { return [] }
    var files: [URL] = []
    FileSystem.walk(enumerator) { url in
      if (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true { files.append(url) }
      return .continue
    }
    return files.compactMap { manifest -> DevStorageItem? in
      guard let data = try? Data(contentsOf: manifest),
        let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
        let layers = json["layers"] as? [[String: Any]]
      else { return nil }
      let size = layers.compactMap { ($0["size"] as? NSNumber)?.int64Value }.reduce(0, +)
      // manifests/<registry>/<namespace>/<model>/<tag>
      let tag = manifest.lastPathComponent
      let model = manifest.deletingLastPathComponent().lastPathComponent
      let namespace = manifest.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent
      let name = namespace == "library" ? "\(model):\(tag)" : "\(namespace)/\(model):\(tag)"
      return DevStorageItem(
        id: "ollama:\(name)", group: .aiModels, tool: "Ollama", title: name,
        subtitle: "Stored in \(root.path.replacingOccurrences(of: home.path, with: "~")) — layers shared between models are freed only when unused",
        url: manifest, bytes: size, lastUsed: modified(manifest), rebuild: .redownload,
        removal: .command("ollama rm \(name)"))
    }
  }

  private func lmStudioModels() -> [DevStorageItem] {
    let roots = [
      home.appendingPathComponent(".lmstudio/models"),
      home.appendingPathComponent(".cache/lm-studio/models"),
    ].filter(exists)
    return roots.flatMap { root in
      children(of: root).flatMap { publisher in
        children(of: publisher).map { model in
          item(
            model, group: .aiModels, tool: "LM Studio", title: model.lastPathComponent,
            subtitle: "\(publisher.lastPathComponent) • remove it in LM Studio's My Models, or move it to the Trash here",
            rebuild: .redownload)
        }
      }
    }
  }

  private func huggingFaceModels() -> [DevStorageItem] {
    let hubRoot =
      environment["HF_HUB_CACHE"].map { URL(fileURLWithPath: $0) }
      ?? environment["HF_HOME"].map { URL(fileURLWithPath: $0).appendingPathComponent("hub") }
      ?? home.appendingPathComponent(".cache/huggingface/hub")
    return children(of: hubRoot).filter { $0.lastPathComponent.contains("--") }.map { repo in
      // models--org--name / datasets--org--name; each repo folder owns all of its blobs.
      let parts = repo.lastPathComponent.components(separatedBy: "--")
      let kind = parts.first ?? "models"
      let name = parts.dropFirst().joined(separator: "/")
      return item(
        repo, group: .aiModels, tool: "Hugging Face", title: name,
        subtitle: "\(kind.dropLast()) cache — whole repository, all revisions",
        rebuild: .redownload)
    }
  }

  private func dockerDisk() -> [DevStorageItem] {
    let raw = home.appendingPathComponent(
      "Library/Containers/com.docker.docker/Data/vms/0/data/Docker.raw")
    guard exists(raw) else { return [] }
    return [
      DevStorageItem(
        group: .containers, tool: "Docker", title: "Docker Desktop disk image",
        subtitle: "Images, containers, and volumes live inside this file — prune them in Docker instead",
        url: raw, bytes: FileSystem.itemSize(at: raw, fileManager: fileManager), lastUsed: modified(raw),
        rebuild: .review, removal: .command("docker system prune"))
    ]
  }

  // MARK: Helpers

  private func item(
    _ url: URL, group: DevGroup, tool: String, title: String, subtitle: String,
    rebuild: RebuildCost, forceActive: Bool = false, activityURL: URL? = nil
  ) -> DevStorageItem {
    let lastUsed = modified(activityURL ?? url)
    let recent = lastUsed.map { Date().timeIntervalSince($0) < activeWindow } ?? false
    return DevStorageItem(
      group: group, tool: tool, title: title, subtitle: subtitle, url: url,
      bytes: FileSystem.itemSize(at: url, fileManager: fileManager), lastUsed: lastUsed,
      rebuild: rebuild, removal: .trash, isActive: forceActive || recent)
  }

  private func children(of url: URL) -> [URL] {
    (try? fileManager.contentsOfDirectory(
      at: url, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles]))
      ?? []
  }

  private func exists(_ url: URL) -> Bool { fileManager.fileExists(atPath: url.path) }

  private func modified(_ url: URL) -> Date? {
    (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
  }
}
