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

  public init(kind: AIExplainKind, identifier: String, location: String) {
    self.kind = kind
    self.identifier = String(identifier.prefix(200))
    self.location = location
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

struct AIAskRequest: Codable, Sendable {
  let question: String
  let history: [AITurn]
  let context: AIContext
}

public struct AIStatus: Sendable {
  public let enabled: Bool
}

// MARK: - Client

extension AccountClient {
  public func explain(_ request: AIExplainRequest, token: String) async throws -> AIExplainResponse {
    try await send("POST", "/api/macmint/ai/explain", token: token, json: request, timeout: 40)
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

  /// Server kill switch (public app_config record `ai`). Off when unreachable.
  public func aiStatus() async -> AIStatus {
    struct Page: Decodable {
      struct Item: Decodable {
        struct Value: Decodable { let enabled: Bool? }
        let value: Value?
      }
      let items: [Item]
    }
    var components = URLComponents(
      url: baseURL.appendingPathComponent("/api/collections/app_config/records"),
      resolvingAgainstBaseURL: false)
    components?.queryItems = [URLQueryItem(name: "filter", value: "key='ai'")]
    guard let url = components?.url else { return AIStatus(enabled: false) }
    var request = URLRequest(url: url)
    request.timeoutInterval = 15
    do {
      let (data, response) = try await transport(request)
      guard (response as? HTTPURLResponse)?.statusCode == 200 else { return AIStatus(enabled: false) }
      let page = try JSONDecoder().decode(Page.self, from: data)
      return AIStatus(enabled: page.items.first?.value?.enabled == true)
    } catch {
      return AIStatus(enabled: false)
    }
  }
}

// MARK: - Anonymized context

/// What "Ask MacMint" and the Smart Care review are allowed to see. Built only from sizes,
/// dates, categories, app names, and home-relative folder paths; never file contents, never
/// personal file names. Paths outside the home folder are dropped (except /Applications and
/// /Library), the account name is replaced, and anything email-like is removed.
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

  /// Home-relative, account name replaced, emails removed; nil when the path must not be sent.
  public static func sanitize(_ path: String, home: URL) -> String? {
    let homePath = home.standardizedFileURL.path
    var relative: String
    if path == homePath {
      relative = "~"
    } else if path.hasPrefix(homePath + "/") {
      relative = "~" + path.dropFirst(homePath.count)
    } else if path.hasPrefix("/Applications") || path.hasPrefix("/Library") {
      relative = path
    } else {
      return nil
    }
    let account = home.lastPathComponent
    if account.count >= 2 {
      relative = relative.replacingOccurrences(of: account, with: "user", options: .caseInsensitive)
    }
    relative = relative.replacingOccurrences(
      of: #"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}"#, with: "[email]", options: .regularExpression)
    return String(relative.prefix(200))
  }

  /// Folder names a few levels below home (personal file names are never included).
  public static func build(_ inputs: Inputs) -> AIContext {
    let home = inputs.homeDirectory
    var folders: [AIContext.Folder] = []
    if let root = inputs.storageRoot {
      for child in root.children where child.kind == .folder || child.kind == .package {
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
      return .init(name: String(app.name.prefix(60)), monthsSinceOpened: months, gb: gb(app.bundleSize))
    }.sorted { $0.gb > $1.gb }
    let downloads = Dictionary(grouping: inputs.downloads, by: { $0.kind.rawValue })
      .mapValues { gb($0.reduce(Int64(0)) { $0 + $1.bytes }) }

    return AIContext(
      disk: ["totalGB": gb(inputs.totalBytes), "freeGB": gb(inputs.freeBytes)],
      recommendations: inputs.recommendations.prefix(12).map {
        .init(title: $0.title, gb: gb($0.bytes), confidence: $0.confidence.label, items: $0.count)
      },
      biggestFolders: Array(folders.sorted { $0.gb > $1.gb }.prefix(14)),
      developerGB: developer,
      unusedApps: Array(unused.prefix(8)),
      downloadsGB: downloads,
      startupItems: Array(
        inputs.startupLabels.prefix(15).map { String($0.prefix(120)) }
          .map { $0.replacingOccurrences(of: #"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}"#, with: "[email]", options: .regularExpression) }),
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
          id: $0.id, title: $0.title, bytes: $0.bytes,
          confidence: $0.confidence == .safe ? "safe" : $0.confidence == .likely ? "likely" : "review",
          count: $0.count, detail: String($0.detail.prefix(300)))
      },
      disk: .init(totalBytes: totalBytes, freeBytes: freeBytes),
      growth: growth.prefix(5).compactMap { g in
        sanitize(g.path, home: home).map { .init(path: $0, delta: g.delta) }
      })
  }
}
