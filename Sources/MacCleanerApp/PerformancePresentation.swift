import Foundation

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

  static func apps(_ apps: [App], query: String, sort: Sort) -> [App] {
    let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
    return apps.filter { app in
      query.isEmpty || app.name.localizedCaseInsensitiveContains(query)
        || (app.bundleID?.localizedCaseInsensitiveContains(query) ?? false)
        || String(app.id.pid).contains(query)
    }.sorted { left, right in
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
}
