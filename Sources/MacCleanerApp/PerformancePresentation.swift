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
    let memoryBytes: Int64
    let cpuPercent: Double?
    var fallbackSymbol = "app.fill"
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
      let detail = excepted ? "Never slowed · PID \(app.id.pid)" : receipt.map {
        "\($0.automatic ? "Auto tamed" : "Slowed") until " + $0.expires.formatted(date: .omitted, time: .shortened)
      } ?? "PID \(app.id.pid)" + (app.bundleID.map { " · " + $0 } ?? "")
      let cpu = validCPU(app.cpuPercent)
      let memory = app.memoryBytes >= 0 ? ByteFormatter.string(app.memoryBytes) : nil
      return Row(id: app.id, stripe: index.isMultiple(of: 2), name: app.name, detail: detail,
        help: app.name + " · PID \(app.id.pid)" + (app.bundleID.map { " · " + $0 } ?? ""),
        cpuText: cpu.map { String(format: "%.1f%%", $0) } ?? "—",
        cpuAccessibility: cpu.map { String(format: "%.1f percent of one core", $0) } ?? "Not measured yet",
        cpuFraction: quantized(cpuFraction(app.cpuPercent, logicalCPUCount: inputs.logicalCPUCount)),
        memoryText: memory ?? "—", memoryAccessibility: memory ?? "Unavailable",
        memoryFraction: quantized(memoryFraction(app.memoryBytes, physicalMemory: inputs.physicalMemory)),
        fallbackSymbol: app.fallbackSymbol,
        control: Control(id: app.id, name: app.name, bundleID: app.bundleID, slowed: receipt != nil,
          excepted: excepted, canControl: inputs.controllable.contains(app.id)))
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
