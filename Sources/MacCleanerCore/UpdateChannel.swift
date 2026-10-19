import Foundation

/// The Sparkle feed MacMint follows (docs/UPDATES.md). Stable carries Developer ID-signed,
/// notarized releases; developer carries every successful build of `main`.
public enum UpdateChannel: String, CaseIterable, Sendable {
  case stable
  case developer

  public static let storageKey = "co.macmint.updates.channel"

  public var feedURL: URL {
    switch self {
    case .stable: URL(string: "https://github.com/QuntmTech/mac-mint/releases/latest/download/appcast.xml")!
    case .developer: URL(string: "https://github.com/QuntmTech/mac-mint/releases/download/dev-feed/appcast-dev.xml")!
    }
  }

  /// The saved choice. Missing or unrecognised values mean stable.
  public static func saved(in defaults: UserDefaults) -> UpdateChannel {
    defaults.string(forKey: storageKey).flatMap(UpdateChannel.init(rawValue:)) ?? .stable
  }

  public func save(in defaults: UserDefaults) {
    defaults.set(rawValue, forKey: Self.storageKey)
  }
}

/// Version metadata that scripts/build_app.sh stamps into the bundle's Info.plist:
/// `CFBundleShortVersionString` from VERSION, `CFBundleVersion` from the commit count and
/// `MacMintGitCommit`.
public struct BuildInfo: Equatable, Sendable {
  public let version: String
  public let build: String?
  public let commit: String?

  public init(version: String, build: String?, commit: String?) {
    self.version = version
    self.build = build.flatMap { $0.isEmpty || !$0.allSatisfy(\.isNumber) ? nil : $0 }
    self.commit = commit.flatMap { $0.count >= 7 && $0.allSatisfy(\.isHexDigit) ? $0.lowercased() : nil }
  }

  public init(infoDictionary: [String: Any]?) {
    self.init(
      version: infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0",
      build: infoDictionary?["CFBundleVersion"] as? String,
      commit: infoDictionary?["MacMintGitCommit"] as? String)
  }

  public var shortCommit: String? { commit.map { String($0.prefix(7)) } }

  /// "0.9.0 (build 312)", or the version alone.
  public var versionAndBuild: String { build.map { "\(version) (build \($0))" } ?? version }

  /// "Version 0.9.0 (build 312 · abc1234)".
  public var displayString: String {
    let details = [build.map { "build \($0)" }, shortCommit].compactMap { $0 }
    return details.isEmpty ? "Version \(version)" : "Version \(version) (\(details.joined(separator: " · ")))"
  }
}
