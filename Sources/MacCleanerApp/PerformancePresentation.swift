import Foundation
import MacCleanerCore

/// Pure display data. It contains no running-application handle or process authority.
enum PerformancePresentation {
  struct ProcessID: Hashable, Sendable {
    let pid: Int32
    let started: UInt64
  }

  struct App: Identifiable, Equatable, Sendable {
    let id: ProcessID
    let name: String
    let bundleID: String?
    /// The app and its helper processes together.
    let memoryBytes: Int64
    let cpuPercent: Double?
    var fallbackSymbol = "app.fill"
    /// Helper processes included in the totals; nil when helpers weren't measured.
    var helpers: ProcessFamilies.Helpers? = nil
    /// The app's own process, the first line of the breakdown.
    var ownMemoryBytes: Int64? = nil
    var ownCPUPercent: Double? = nil
  }

  enum SortKey: String, CaseIterable, Sendable {
    case cpu = "CPU", memory = "Memory", name = "App"
  }

  enum Direction: String, Sendable {
    case ascending, descending
    var description: String { self == .descending ? "highest first" : "lowest first" }
  }

  struct Sort: Equatable, Sendable {
    var key: SortKey = .memory
    var direction: Direction = .descending

    mutating func select(_ key: SortKey, toggle: Bool = false) {
      if toggle && self.key == key {
        direction = direction == .descending ? .ascending : .descending
      } else {
        direction = key == .name ? .ascending : .descending
      }
      self.key = key
    }

    var description: String {
      key == .name ? (direction == .ascending ? "App, A to Z" : "App, Z to A") : "\(key.rawValue), \(direction.description)"
    }
  }

  static func matches(_ app: App, query: String) -> Bool {
    query.isEmpty || app.name.localizedCaseInsensitiveContains(query)
      || (app.bundleID?.localizedCaseInsensitiveContains(query) ?? false)
      || String(app.id.pid).contains(query)
      || (app.helpers?.largest.contains { $0.name.localizedCaseInsensitiveContains(query) } ?? false)
  }

  static func matchCount(_ apps: [App], query: String) -> Int {
    let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
    return apps.reduce(0) { $0 + (matches($1, query: query) ? 1 : 0) }
  }

  static func apps(_ apps: [App], query: String, sort: Sort) -> [App] {
    let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
    return apps.filter { matches($0, query: query) }.sorted { left, right in
      switch sort.key {
      case .cpu:
        if let decision = compare(validCPU(left.cpuPercent), validCPU(right.cpuPercent), direction: sort.direction) { return decision }
      case .memory:
        if let decision = compare(left.memoryBytes >= 0 ? left.memoryBytes : nil,
          right.memoryBytes >= 0 ? right.memoryBytes : nil, direction: sort.direction) { return decision }
      case .name:
        let comparison = left.name.localizedCaseInsensitiveCompare(right.name)
        if comparison != .orderedSame { return sort.direction == .ascending ? comparison == .orderedAscending : comparison == .orderedDescending }
      }
      // Ties have one deterministic order, regardless of sort direction or sample
      // arrival order. A repeated PID is distinguished by its kernel birth identity.
      let comparison = left.name.localizedCaseInsensitiveCompare(right.name)
      if comparison != .orderedSame { return comparison == .orderedAscending }
      if left.id.pid != right.id.pid { return left.id.pid < right.id.pid }
      return left.id.started < right.id.started
    }
  }

  private static func compare<Value: Comparable>(_ left: Value?, _ right: Value?, direction: Direction) -> Bool? {
    switch (left, right) {
    case (.some(let left), .some(let right)):
      if left == right { return nil }
      return direction == .descending ? left > right : left < right
    case (.some, .none): return true
    case (.none, .some): return false
    case (.none, .none): return nil
    }
  }

  static func validCPU(_ percent: Double?) -> Double? {
    guard let percent, percent.isFinite, percent >= 0 else { return nil }
    return percent
  }

  static func fraction(_ value: Double?, capacity: Double) -> Double? {
    guard let value, value.isFinite, value >= 0, capacity.isFinite, capacity > 0 else { return nil }
    return min(1, max(0, value / capacity))
  }

  /// Text keeps Activity Monitor's one-core units; only the bar uses whole-Mac capacity.
  static func cpuFraction(_ percent: Double?, logicalCPUCount: Int) -> Double? {
    guard logicalCPUCount > 0 else { return nil }
    return fraction(validCPU(percent), capacity: Double(logicalCPUCount) * 100)
  }

  static func memoryFraction(_ bytes: Int64?, physicalMemory: Int64) -> Double? {
    guard let bytes, bytes >= 0, physicalMemory > 0 else { return nil }
    return fraction(Double(bytes), capacity: Double(physicalMemory))
  }

  /// One line of a row's breakdown: the app itself, a large helper, or the remaining helpers.
  struct BreakdownLine: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let cpuText: String
    let memoryText: String
  }

  static func helperCountText(_ count: Int) -> String { count == 1 ? "1 helper" : "\(count) helpers" }

  /// The app's own process first, then its largest helpers, then the rest as one line.
  static func breakdown(_ app: App) -> [BreakdownLine] {
    guard let helpers = app.helpers, helpers.count > 0 else { return [] }
    func cpu(_ value: Double?) -> String { validCPU(value).map { String(format: "%.1f%%", $0) } ?? "—" }
    func memory(_ value: Int64?) -> String { value.flatMap { $0 >= 0 ? ByteFormatter.string($0) : nil } ?? "—" }
    var lines = [BreakdownLine(id: "app", name: app.name + " (the app itself)", cpuText: cpu(app.ownCPUPercent),
      memoryText: memory(app.ownMemoryBytes))]
    lines += helpers.largest.map {
      BreakdownLine(id: "pid-\($0.pid)", name: $0.name + " · PID \($0.pid)", cpuText: cpu($0.cpuPercent), memoryText: memory($0.memoryBytes))
    }
    let rest = helpers.count - helpers.largest.count
    if rest > 0 {
      let shown = helpers.largest.reduce(Int64(0)) { ProcessFamilies.add($0, $1.memoryBytes) }
      let shownCPU = helpers.largest.compactMap { validCPU($0.cpuPercent) }.reduce(0, +)
      lines.append(BreakdownLine(id: "rest", name: rest == 1 ? "1 more helper" : "\(rest) more helpers",
        cpuText: cpu(max(0, helpers.cpuPercent - shownCPU)), memoryText: memory(max(0, helpers.memoryBytes - shown))))
    }
    return lines
  }

  /// Display-ready row. Equal rows draw identically, so SwiftUI skips unchanged rows; meter
  /// fractions are rounded to half-percent steps, below what a bar can show.
  struct Row: Identifiable, Equatable, Sendable {
    let id: ProcessID
    let stripe: Bool
    let name: String
    let detail: String
    let help: String
    let cpuText: String
    let cpuAccessibility: String
    let cpuFraction: Double?
    let memoryText: String
    let memoryAccessibility: String
    let memoryFraction: Double?
    let fallbackSymbol: String
    let control: Control
    /// Empty when the app has no measured helpers.
    let breakdown: [BreakdownLine]
  }

  /// Inputs of the per-row action controls, which change only with slowdown state.
  struct Control: Equatable, Sendable {
    let id: ProcessID
    let name: String
    let bundleID: String?
    let slowed: Bool
    let excepted: Bool
    let canControl: Bool
  }

  struct RowInputs: Equatable, Sendable {
    var apps: [App]
    var query: String
    var sort: Sort
    var taming: TamingState
    var physicalMemory: Int64
    var logicalCPUCount: Int
    var controllable: Set<ProcessID>
  }

  static func quantized(_ fraction: Double?) -> Double? {
    fraction.map { ($0 * 200).rounded() / 200 }
  }

  static func rows(_ inputs: RowInputs) -> [Row] {
    apps(inputs.apps, query: inputs.query, sort: inputs.sort).enumerated().map { index, app in
      let receipt = inputs.taming.receipts.first { $0.identity.pid == app.id.pid && $0.identity.started == app.id.started }
      let excepted = app.bundleID.map { inputs.taming.exceptions[$0.lowercased()] != nil } ?? false
      let helperCount = app.helpers?.count ?? 0
      let helperText: String = helperCount > 0 ? " · with " + helperCountText(helperCount) : ""
      let detail: String
      if excepted {
        detail = "Never slowed · PID \(app.id.pid)" + helperText
      } else if let receipt {
        detail = (receipt.automatic ? "Auto tamed" : "Slowed") + " until " + receipt.expires.formatted(date: .omitted, time: .shortened)
      } else if helperCount > 0 {
        detail = "PID \(app.id.pid)" + helperText
      } else {
        detail = "PID \(app.id.pid)" + (app.bundleID.map { " · " + $0 } ?? "")
      }
      var help: String = app.name + " · PID \(app.id.pid)" + (app.bundleID.map { " · " + $0 } ?? "")
      if helperCount > 0 {
        help += "\nCPU and memory include \(helperCountText(helperCount)) this app started. Quit and Slow act on the app itself."
      }
      let cpu = validCPU(app.cpuPercent)
      let memory = app.memoryBytes >= 0 ? ByteFormatter.string(app.memoryBytes) : nil
      return Row(id: app.id, stripe: index.isMultiple(of: 2), name: app.name, detail: detail, help: help,
        cpuText: cpu.map { String(format: "%.1f%%", $0) } ?? "—",
        cpuAccessibility: cpu.map { String(format: "%.1f percent of one core", $0) } ?? "Not measured yet",
        cpuFraction: quantized(cpuFraction(app.cpuPercent, logicalCPUCount: inputs.logicalCPUCount)),
        memoryText: memory ?? "—", memoryAccessibility: memory ?? "Unavailable",
        memoryFraction: quantized(memoryFraction(app.memoryBytes, physicalMemory: inputs.physicalMemory)),
        fallbackSymbol: app.fallbackSymbol,
        control: Control(id: app.id, name: app.name, bundleID: app.bundleID, slowed: receipt != nil,
          excepted: excepted, canControl: inputs.controllable.contains(app.id)),
        breakdown: breakdown(app))
    }
  }

  /// Sorting, filtering and formatting run once per changed input, not on every render.
  @MainActor
  final class RowCache {
    private var inputs: RowInputs?
    private var cached: [Row] = []
    private(set) var builds = 0
    func rows(_ inputs: RowInputs) -> [Row] {
      if inputs == self.inputs { return cached }
      builds += 1
      cached = PerformancePresentation.rows(inputs); self.inputs = inputs
      return cached
    }
  }
}
