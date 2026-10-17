import Foundation

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

// MARK: - Wire models (mirror backend/pocketbase/pb_hooks/macmint_ai.pb.js)

public enum AIExplainKind: String, Codable, Sendable {
  case libraryItem = "library-item"
  case launchAgent = "launch-agent"
  case developerTool = "developer-tool"
}

public struct AIExplainRequest: Codable, Hashable, Sendable, Identifiable {
  public let kind: AIExplainKind
  /// A name only — never a full path, never file contents.
  public let identifier: String
  public let location: String

  public var id: String { "\(kind.rawValue)|\(location)|\(identifier)" }

  /// The name was not recognized and was replaced before sending. An AI answer about the
  /// placeholder would only guess, so it is explained locally without a request.
  public var isPlaceholder: Bool { AIContextBuilder.placeholderIdentifiers.contains(identifier) }

  public init(kind: AIExplainKind, identifier: String, location: String) {
    self.kind = kind
    self.identifier = AIContextBuilder.safeIdentifier(identifier, kind: kind)
    self.location = AIContextBuilder.safeLocation(location)
  }
}

public struct AIExplanation: Codable, Hashable, Sendable {
  public enum Verdict: String, Codable, Sendable {
    case safe, caution, keep, unknown
  }

  public let summary: String
  public let owner: String
  public let category: String
  public let verdict: Verdict
  public let whatHappens: String
  public let confidence: String
}

public struct AIExplainResponse: Codable, Sendable {
  public let explanation: AIExplanation
  public let cached: Bool?
  public let model: String?

  /// Matches the server's deterministic answer for placeholder names (macmint_ai_context.js).
  public static func local(for request: AIExplainRequest) -> AIExplainResponse {
    let developer = request.kind == .developerTool
    let subject = developer ? "developer tool names, so this cache" : "app identifiers, so this item"
    let owner = developer ? "tool" : "app"
    return AIExplainResponse(
      explanation: AIExplanation(
        summary: "MacMint only shares recognized \(subject) was not sent for an AI explanation. Check which \(owner) created it before removing it.",
        owner: "Unknown", category: developer ? "developer" : "unknown", verdict: .unknown,
        whatHappens: "Moving it to the Trash may remove settings or data that an app or tool uses. You can restore it from History.",
        confidence: "low"),
      cached: false, model: "local")
  }
}

public struct AIReviewRequest: Codable, Sendable {
  public struct Item: Codable, Sendable {
    public let id: String
    public let title: String
    public let bytes: Int64
    public let confidence: String
    public let count: Int
    public let detail: String
  }

  public struct Disk: Codable, Sendable {
    public let totalBytes: Int64
    public let freeBytes: Int64
  }

  public struct Growth: Codable, Sendable {
    public let path: String
    public let delta: Int64
  }

  public let recommendations: [Item]
  public let disk: Disk
  public let growth: [Growth]
}

public struct AIReview: Codable, Hashable, Sendable {
  public struct Note: Codable, Hashable, Sendable {
    public let id: String
    public let order: Int
    public let note: String
  }

  public struct Insight: Codable, Hashable, Sendable {
    public let title: String
    public let detail: String
    public let destination: String
  }

  public let headline: String
  public let notes: [Note]
  public let insights: [Insight]
  public let cautions: [String]
  public let model: String?

  public func note(for recommendationID: String) -> Note? { notes.first { $0.id == recommendationID } }
}

public struct AITurn: Codable, Hashable, Sendable, Identifiable {
  public enum Role: String, Codable, Sendable { case user, assistant }
  public let id: UUID
  public let role: Role
  public let text: String
  public let actions: [AIAction]

  public init(id: UUID = UUID(), role: Role, text: String, actions: [AIAction] = []) {
    self.id = id
    self.role = role
    self.text = text
    self.actions = actions
  }

  enum CodingKeys: String, CodingKey { case role, text }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = UUID()
    role = try container.decode(Role.self, forKey: .role)
    text = try container.decode(String.self, forKey: .text)
    actions = []
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(role, forKey: .role)
    try container.encode(String(text.prefix(1500)), forKey: .text)
  }
}

public struct AIAction: Codable, Hashable, Sendable {
  public let destination: String
  public let label: String
}

public struct AIAnswer: Codable, Sendable {
  public let answer: String
  public let actions: [AIAction]
  public let model: String?
}

public struct AIAskRequest: Codable, Sendable {
  public let question: String
  public let history: [AITurn]
  public let context: AIContext
  public init(question: String, history: [AITurn], context: AIContext) {
    self.question = String(question.prefix(600)); self.history = Array(history.suffix(6)); self.context = context
  }
}

public struct AIStatus: Sendable {
  public let enabled: Bool
  public let features: [String: Bool]
  public let reachable: Bool
  public init(enabled: Bool, features: [String: Bool] = [:], reachable: Bool = true) { self.enabled = enabled; self.features = features; self.reachable = reachable }
  public func allows(_ feature: String) -> Bool { enabled && (feature == "organize" ? features[feature] == true : features[feature] != false) }
}

// MARK: - Client

extension AccountClient {
  public func explain(_ request: AIExplainRequest, token: String) async throws -> AIExplainResponse {
    if request.isPlaceholder { return .local(for: request) }
    return try await send("POST", "/api/macmint/ai/explain", token: token, json: request, timeout: 40)
  }

  public func review(_ request: AIReviewRequest, token: String) async throws -> AIReview {
    try await send("POST", "/api/macmint/ai/review", token: token, json: request, timeout: 45)
  }

  public func ask(question: String, history: [AITurn], context: AIContext, token: String) async throws
    -> AIAnswer
  {
    try await send(
      "POST", "/api/macmint/ai/ask", token: token,
      json: AIAskRequest(question: String(question.prefix(600)), history: Array(history.suffix(6)), context: context),
      timeout: 45)
  }

  public func organize(_ request: AIOrganizationRequest, token: String) async throws -> AIOrganizationResponse {
    try await send("POST", "/api/macmint/ai/organize", token: token, json: request, timeout: 45)
  }

  /// Server kill switch (public app_config record `ai`). Off when unreachable.
  public func aiStatus() async -> AIStatus {
    struct Page: Decodable {
      struct Item: Decodable {
        struct Value: Decodable { let enabled: Bool?; let features: [String: Bool]? }
        let value: Value?
      }
      let items: [Item]
    }
    var components = URLComponents(
      url: baseURL.appendingPathComponent("/api/collections/app_config/records"),
      resolvingAgainstBaseURL: false)
    components?.queryItems = [URLQueryItem(name: "filter", value: "key='ai'")]
    guard let url = components?.url else { return AIStatus(enabled: false, reachable: false) }
    var request = URLRequest(url: url)
    request.timeoutInterval = 15
    do {
      let (data, response) = try await transport(request)
      guard (response as? HTTPURLResponse)?.statusCode == 200 else { return AIStatus(enabled: false, reachable: false) }
      let page = try JSONDecoder().decode(Page.self, from: data)
      return AIStatus(enabled: page.items.first?.value?.enabled == true, features: page.items.first?.value?.features ?? [:])
    } catch {
      return AIStatus(enabled: false, reachable: false)
    }
  }
}

// MARK: - Category-only automatic context

/// Automatic context includes fixed category labels, allowlisted identifiers, sizes and dates.
/// Arbitrary folder names, document packages, app labels and filenames are omitted. Typed
/// questions and previous chat turns are transmitted separately as the user's own text.
public struct AIContext: Codable, Hashable, Sendable {
  public struct Folder: Codable, Hashable, Sendable {
    public let path: String
    public let gb: Double
  }

  public struct Recommendation: Codable, Hashable, Sendable {
    public let title: String
    public let gb: Double
    public let confidence: String
    public let items: Int
  }

  public struct UnusedApp: Codable, Hashable, Sendable {
    public let name: String
    public let monthsSinceOpened: Int
    public let gb: Double
  }

  public let disk: [String: Double]
  public let recommendations: [Recommendation]
  public let biggestFolders: [Folder]
  public let developerGB: [String: Double]
  public let unusedApps: [UnusedApp]
  public let downloadsGB: [String: Double]
  public let startupItems: [String]
  public let recentGrowth: [Folder]
}

public enum AIContextBuilder {
  public struct Inputs: Sendable {
    public var homeDirectory: URL
    public var totalBytes: Int64 = 0
    public var freeBytes: Int64 = 0
    public var recommendations: [MacCleanerCore.Recommendation] = []
    public var storageRoot: StorageNode?
    public var developer: [DevStorageItem] = []
    public var apps: [AppRecord] = []
    public var downloads: [DownloadItem] = []
    public var startupLabels: [String] = []
    public var growth: [StorageGrowth] = []
    public var now = Date()

    public init(homeDirectory: URL) { self.homeDirectory = homeDirectory }
  }

  static func gb(_ bytes: Int64) -> Double { (Double(bytes) / 1_073_741_824 * 10).rounded() / 10 }

  /// Categories are an allowlist, not a heuristic attempt to anonymize arbitrary names.
  private static let categoryPaths: Set<String> = [
    "Desktop", "Documents", "Pictures", "Movies", "Music", "Downloads", "Library",
    "Library/Caches", "Library/Logs", "Library/Developer", "Library/Application Support",
    "Library/Containers", "Library/Group Containers", "Library/Developer/Xcode/DerivedData",
    "Library/Developer/CoreSimulator/Caches", ".npm/_cacache", ".gradle/caches",
    ".cache/huggingface/hub", ".lmstudio/models", ".ollama/models",
  ]
  public static let knownApps: [String: String] = [
    "com.apple.dt.Xcode": "Xcode", "com.apple.iphonesimulator": "Simulator",
    "com.apple.Safari": "Safari", "com.google.Chrome": "Chrome", "org.mozilla.firefox": "Firefox",
    "com.microsoft.edgemac": "Edge", "com.spotify.client": "Spotify", "com.docker.docker": "Docker",
    "com.brave.Browser": "Brave", "company.thebrowser.Browser": "Arc", "com.vivaldi.Vivaldi": "Vivaldi",
    "com.operasoftware.Opera": "Opera", "com.microsoft.VSCode": "Visual Studio Code",
  ]
  public static let knownTools: Set<String> = ["Xcode", "Simulator", "npm", "pnpm", "Yarn", "Bun", "Homebrew", "pip", "CocoaPods", "SwiftPM", "Gradle", "Maven", "Cargo", "Go", "Ollama", "LM Studio", "Hugging Face", "Docker"]

  public static func safeLocation(_ location: String) -> String {
    let allowed: Set<String> = ["Caches", "Preferences", "Application Support", "Containers", "Group Containers", "Logs", "Saved Application State", "WebKit", "HTTP Storage", "Cookies", "Application Scripts", "LaunchAgents", "LaunchDaemons", "Developer", "Startup", "Other"]
    return allowed.contains(location) ? location : "Other"
  }

  static let unrecognizedTool = "Unrecognized developer cache"
  static let unrecognizedItem = "Unrecognized Library item"
  static let placeholderIdentifiers: Set<String> = [unrecognizedTool, unrecognizedItem]

  public static func safeIdentifier(_ identifier: String, kind: AIExplainKind) -> String {
    if kind == .developerTool { return knownTools.contains(identifier) ? identifier : unrecognizedTool }
    return knownApps.keys.contains(identifier) ? identifier : unrecognizedItem
  }

  public static func sanitize(_ path: String, home: URL) -> String? {
    let homePath = home.standardizedFileURL.path
    if path == homePath { return "~" }
    if ["/Applications", "/Library"].contains(path) { return path }
    guard path.hasPrefix(homePath + "/") else { return nil }
    let relative = String(path.dropFirst(homePath.count + 1))
    return categoryPaths.contains(relative) ? "~/" + relative : nil
  }

  private static let recommendationLabels: [String: String] = [
    "caches": "Rebuildable caches and logs", "developer": "Developer build data",
    "firmware": "Device firmware", "downloads-never-opened": "Downloads with no recorded opens",
    "downloads-stale": "Old downloads", "removed-apps": "Possible removed-app data",
    "screenshots": "Old screenshots", "mail": "Mail attachment copies", "review-cleanup": "Backups, reports and installers",
    "unused-apps": "Apps with old recorded usage", "duplicates": "Exact duplicates", "trash": "Home Trash", "growth": "Storage category growth",
  ]

  /// Folder names a few levels below home (personal file names are never included).
  public static func build(_ inputs: Inputs) -> AIContext {
    let home = inputs.homeDirectory
    var folders: [AIContext.Folder] = []
    if let root = inputs.storageRoot {
      for child in root.children where child.kind == .folder {
        guard let path = sanitize(child.id, home: home) else { continue }
        folders.append(.init(path: path, gb: gb(child.allocatedBytes)))
        // One level deeper inside Library, where the big caches live.
        if child.name == "Library" {
          for inner in child.children.prefix(6) where inner.kind == .folder {
            if let innerPath = sanitize(inner.id, home: home) {
              folders.append(.init(path: innerPath, gb: gb(inner.allocatedBytes)))
            }
          }
        }
      }
    }
    let developer = Dictionary(grouping: inputs.developer, by: { $0.group.rawValue })
      .mapValues { gb($0.reduce(Int64(0)) { $0 + $1.bytes }) }
    let unused = inputs.apps.compactMap { app -> AIContext.UnusedApp? in
      guard let lastUsed = app.lastUsed else { return nil }
      let months = Int(inputs.now.timeIntervalSince(lastUsed) / (30.4 * 86_400))
      guard months >= 3 else { return nil }
      guard let id = app.bundleIdentifier, let name = knownApps[id] else { return nil }
      return .init(name: name, monthsSinceOpened: months, gb: gb(app.bundleSize))
    }.sorted { $0.gb > $1.gb }
    let downloads = Dictionary(grouping: inputs.downloads, by: { $0.kind.rawValue })
      .mapValues { gb($0.reduce(Int64(0)) { $0 + $1.bytes }) }

    return AIContext(
      disk: ["totalGB": gb(inputs.totalBytes), "freeGB": gb(inputs.freeBytes)],
      recommendations: inputs.recommendations.prefix(12).map {
        .init(title: recommendationLabels[$0.id] ?? "Storage recommendation", gb: gb($0.bytes), confidence: $0.confidence.label, items: $0.count)
      },
      biggestFolders: Array(folders.sorted { $0.gb > $1.gb }.prefix(14)),
      developerGB: developer,
      unusedApps: Array(unused.prefix(8)),
      downloadsGB: downloads,
      startupItems: Array(inputs.startupLabels.filter { knownApps[$0] != nil }.prefix(15)),
      recentGrowth: inputs.growth.prefix(5).compactMap { growth in
        sanitize(growth.path, home: home).map { .init(path: $0, gb: gb(growth.delta)) }
      })
  }

  /// The Smart Care review payload: recommendation summaries, disk size, and sanitized growth.
  public static func reviewRequest(
    recommendations: [MacCleanerCore.Recommendation], totalBytes: Int64, freeBytes: Int64,
    growth: [StorageGrowth], home: URL
  ) -> AIReviewRequest {
    AIReviewRequest(
      recommendations: recommendations.prefix(15).map {
        .init(
          id: recommendationLabels[$0.id] != nil ? $0.id : "other", title: recommendationLabels[$0.id] ?? "Storage recommendation", bytes: $0.bytes,
          confidence: $0.confidence == .safe ? "safe" : $0.confidence == .likely ? "likely" : "review",
          count: $0.count, detail: "\($0.count) items; local confidence: \($0.confidence.label). Review locally before removal.")
      },
      disk: .init(totalBytes: totalBytes, freeBytes: freeBytes),
      growth: growth.prefix(5).compactMap { g in
        sanitize(g.path, home: home).map { .init(path: $0, delta: g.delta) }
      })
  }
}
