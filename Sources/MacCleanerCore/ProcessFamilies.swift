import Foundation

/// One entry of a process listing: identity, parent link and display name.
public struct ProcessRecord: Hashable, Sendable {
  public let pid: Int32
  public let parent: Int32
  /// Start time in a unit shared by every record of one listing. A parent must have started
  /// no later than its child, which rejects a parent PID that was reused after the real parent exited.
  public let started: UInt64
  public let name: String

  public init(pid: Int32, parent: Int32, started: UInt64, name: String) {
    self.pid = pid
    self.parent = parent
    self.started = started
    self.name = name
  }
}

/// Read-only attribution of helper processes (browser renderers, editor extension hosts and
/// the tools they start) to the app whose process tree they belong to.
///
/// Each process is counted in at most one family: the nearest app above it. A chain that
/// reaches launchd, a missing parent or a reused parent PID stays unattributed instead of
/// being guessed; macOS starts XPC services and some helpers that way on an app's behalf.
/// Attribution never grants Quit or slowdown authority over a helper.
public enum ProcessFamilies {
  /// Root PID → its descendant PIDs (the root itself excluded), for roots present in `processes`.
  public static func members(of roots: Set<Int32>, in processes: [ProcessRecord]) -> [Int32: [Int32]] {
    let byPID = Dictionary(processes.map { ($0.pid, $0) }, uniquingKeysWith: { first, _ in first })
    var owner: [Int32: Int32] = [:]
    var unattributed: Set<Int32> = []
    var families: [Int32: [Int32]] = [:]

    for process in byPID.values where !roots.contains(process.pid) {
      var chain: [Int32] = []
      var current = process
      var found: Int32?
      while true {
        if let known = owner[current.pid] { found = known; break }
        if unattributed.contains(current.pid) { break }
        chain.append(current.pid)
        guard current.parent > 1, current.parent != current.pid, chain.count <= byPID.count,
          let parent = byPID[current.parent], parent.started <= current.started else { break }
        if roots.contains(parent.pid) { found = parent.pid; break }
        current = parent
      }
      for pid in chain {
        if let found { owner[pid] = found } else { unattributed.insert(pid) }
      }
      if let found { families[found, default: []].append(process.pid) }
    }
    for root in roots where byPID[root] != nil && families[root] == nil { families[root] = [] }
    return families
  }

  /// One measured process of a family.
  public struct Usage: Equatable, Sendable {
    public let pid: Int32
    public var name: String
    public let memoryBytes: Int64
    /// Percent of one core; nil until two samples of the same process exist.
    public let cpuPercent: Double?

    public init(pid: Int32, name: String, memoryBytes: Int64, cpuPercent: Double?) {
      self.pid = pid
      self.name = name
      self.memoryBytes = memoryBytes
      self.cpuPercent = cpuPercent
    }
  }

  /// The helpers of one app, measured. The app's own process is not included.
  public struct Helpers: Equatable, Sendable {
    /// Helpers that could be measured (ones that exited or refused access are left out).
    public let count: Int
    public let memoryBytes: Int64
    /// Sum over helpers with a CPU reading; helpers seen for the first time add nothing yet.
    public let cpuPercent: Double
    /// The largest helpers by memory, for display.
    public var largest: [Usage]

    public static let none = Helpers(count: 0, memoryBytes: 0, cpuPercent: 0, largest: [])

    public init(count: Int, memoryBytes: Int64, cpuPercent: Double, largest: [Usage]) {
      self.count = count
      self.memoryBytes = memoryBytes
      self.cpuPercent = cpuPercent
      self.largest = largest
    }

    public init(_ usages: [Usage], keep limit: Int = 5) {
      let measured = usages.filter { $0.memoryBytes >= 0 }
      self.init(
        count: measured.count,
        memoryBytes: measured.reduce(Int64(0)) { ProcessFamilies.add($0, $1.memoryBytes) },
        cpuPercent: measured.reduce(0) { total, usage in
          guard let cpu = usage.cpuPercent, cpu.isFinite, cpu >= 0 else { return total }
          return total + cpu
        },
        largest: Array(measured.sorted {
          $0.memoryBytes != $1.memoryBytes ? $0.memoryBytes > $1.memoryBytes : $0.pid < $1.pid
        }.prefix(max(0, limit))))
    }
  }

  /// Saturating byte total; a negative (unknown) operand keeps the total unknown.
  public static func add(_ left: Int64, _ right: Int64) -> Int64 {
    guard left >= 0, right >= 0 else { return -1 }
    let (sum, overflow) = left.addingReportingOverflow(right)
    return overflow ? .max : sum
  }
}
