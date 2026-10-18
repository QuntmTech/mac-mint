import Foundation

/// PID alone is never authority: a receipt is scoped to this boot and kernel process birth.
public struct TamingIdentity: Codable, Hashable, Sendable {
  public let pid: Int32
  public let started: UInt64
  public let boot: String
  public let bundleID: String
  public let path: String
  public init(pid: Int32, started: UInt64, boot: String, bundleID: String, path: String) {
    self.pid = pid; self.started = started; self.boot = boot; self.bundleID = bundleID; self.path = path
  }
}

public struct TamingReceipt: Codable, Equatable, Sendable {
  public let identity: TamingIdentity
  public let name: String
  public let automatic: Bool
  public let expires: Date
  public init(identity: TamingIdentity, name: String, automatic: Bool, expires: Date) {
    self.identity = identity; self.name = name; self.automatic = automatic; self.expires = expires
  }
}

public struct TamingState: Codable, Equatable, Sendable {
  public var receipts: [TamingReceipt] = []
  public var exceptions: [String: String] = [:]
  public init() {}
}

/// Small durable intent log, written before changing a process. Never overwrite unreadable data.
public struct TamingStore: Sendable {
  public let url: URL
  public init(url: URL) { self.url = url }
  public func load() throws -> TamingState {
    guard try FileSystem.entryExists(at: url) else { return TamingState() }
    let data = try Data(contentsOf: url)
    guard data.count <= 262_144 else { throw CocoaError(.fileReadCorruptFile) }
    let value = try JSONDecoder().decode(TamingState.self, from: data)
    guard value.receipts.count <= 64, value.exceptions.count <= 1024 else { throw CocoaError(.fileReadCorruptFile) }
    return value
  }
  public func save(_ state: TamingState) throws {
    let data = try JSONEncoder().encode(state)
    guard state.receipts.count <= 64, state.exceptions.count <= 1024, data.count <= 262_144 else {
      throw CocoaError(.fileWriteOutOfSpace)
    }
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try FileSystem.writeDurably(data, to: url)
  }
}

/// Conservative sustained-load rule. No inference, process suspension, or subsecond polling.
public struct AutoTamingPolicy: Sendable {
  public struct Candidate: Sendable {
    public let identity: TamingIdentity
    public let cpu: Double?
    public let eligible: Bool
    public init(identity: TamingIdentity, cpu: Double?, eligible: Bool) {
      self.identity = identity; self.cpu = cpu; self.eligible = eligible
    }
  }
  private var hotSince: [TamingIdentity: Date] = [:]
  private var coolSince: [TamingIdentity: Date] = [:]
  private var cooldown: [TamingIdentity: Date] = [:]
  private var lastSample: Date?
  public init() {}
  public mutating func reset() { hotSince = [:]; coolSince = [:]; lastSample = nil }
  public mutating func restored(_ identity: TamingIdentity, now: Date) {
    hotSince[identity] = nil; coolSince[identity] = nil
    cooldown[identity] = now.addingTimeInterval(120)
  }
  public mutating func evaluate(candidates: [Candidate], active: [TamingReceipt], systemCPU: Double?,
    now: Date, enabled: Bool) -> (slow: [TamingIdentity], restore: [TamingIdentity]) {
    let live = Set(candidates.map(\.identity))
    hotSince = hotSince.filter { live.contains($0.key) }
    coolSince = coolSince.filter { live.contains($0.key) }
    cooldown = cooldown.filter { live.contains($0.key) && $0.value > now }
    if let lastSample, now.timeIntervalSince(lastSample) > 25 || now < lastSample { reset() }
    lastSample = now
    let busy = systemCPU.map { $0.isFinite && $0 >= 0.65 && $0 <= 1 } ?? false
    let byID = Dictionary(candidates.map { ($0.identity, $0) }, uniquingKeysWith: { first, _ in first })
    let restoring = active.filter { receipt in
      guard let candidate = byID[receipt.identity], candidate.eligible else { return true }
      if receipt.expires <= now { return true }
      guard receipt.automatic else { return false }
      if !enabled { return true }
      let cool = !busy || (candidate.cpu.map { $0.isFinite && $0 < 20 } ?? false)
      if !cool { coolSince[receipt.identity] = nil; return false }
      if coolSince[receipt.identity] == nil { coolSince[receipt.identity] = now }
      return now.timeIntervalSince(coolSince[receipt.identity] ?? now) >= 30
    }.map(\.identity)
    let controlled = Set(active.map(\.identity))
    let slots = max(0, 2 - active.filter(\.automatic).count)
    guard enabled, busy else { hotSince = [:]; return ([], restoring) }
    var ready: [Candidate] = []
    for candidate in candidates {
      guard candidate.eligible, !controlled.contains(candidate.identity), cooldown[candidate.identity] == nil,
        let cpu = candidate.cpu, cpu.isFinite, cpu >= 80 else { hotSince[candidate.identity] = nil; continue }
      if hotSince[candidate.identity] == nil { hotSince[candidate.identity] = now }
      if now.timeIntervalSince(hotSince[candidate.identity] ?? now) >= 20 { ready.append(candidate) }
    }
    ready.sort { ($0.cpu ?? 0) == ($1.cpu ?? 0) ? $0.identity.pid < $1.identity.pid : ($0.cpu ?? 0) > ($1.cpu ?? 0) }
    return (Array(ready.prefix(slots).map(\.identity)), restoring)
  }
}
