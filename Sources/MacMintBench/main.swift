// macmint-bench — performance benchmarks for MacMint's scanners (see .github/workflows/benchmarks.yml).
//
//   macmint-bench fixture <root> [--items N]     build a reproducible fixture home under <root>
//   macmint-bench run <root> <scanner>           time one scanner; prints a JSON line
//   macmint-bench cancel <root> <scanner> [--after SECONDS]
//                                                cancel mid-scan; prints how long acknowledgement took
//   macmint-bench hash <file>                    MacMint SHA-256 throughput on one file
//
// Scanners: cleanup, storage, large, duplicates. Peak memory is measured by the caller
// (/usr/bin/time -l), one scanner per process, so each figure is independent.

import Foundation
import MacCleanerCore

// MARK: - Helpers

struct SplitMix64 {
  var state: UInt64
  mutating func next() -> UInt64 {
    state &+= 0x9E37_79B9_7F4A_7C15
    var z = state
    z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
    z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
    return z ^ (z >> 31)
  }

  mutating func data(_ count: Int) -> Data {
    var bytes = [UInt8](repeating: 0, count: count)
    var index = 0
    while index < count {
      var word = next()
      for _ in 0..<8 where index < count {
        bytes[index] = UInt8(truncatingIfNeeded: word)
        word >>= 8
        index += 1
      }
    }
    return Data(bytes)
  }
}

func fail(_ message: String) -> Never {
  FileHandle.standardError.write(Data((message + "\n").utf8))
  exit(2)
}

func emit(_ fields: [String: Any]) {
  let data = try! JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys])
  print(String(decoding: data, as: UTF8.self))
}

func option(_ name: String, in args: [String]) -> String? {
  guard let index = args.firstIndex(of: name), index + 1 < args.count else { return nil }
  return args[index + 1]
}

nonisolated(unsafe) let fm = FileManager.default

nonisolated(unsafe) var createdDirectories: Set<String> = []

/// Plain (non-atomic) write; folders are created once. Fixture generation is I/O-bound, so
/// avoiding temp-file renames and repeated mkdir calls matters at 100k files.
func write(_ url: URL, _ data: Data) {
  let folder = url.deletingLastPathComponent()
  if createdDirectories.insert(folder.path).inserted {
    try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
  }
  try? data.write(to: url)
}

func sparse(_ url: URL, bytes: UInt64) {
  try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
  _ = fm.createFile(atPath: url.path, contents: nil)
  let handle = try! FileHandle(forWritingTo: url)
  try! handle.truncate(atOffset: bytes)
  try! handle.close()
}

// MARK: - Fixture

/// About `items` files: caches and logs (CleanupScanner), nested project files, 20 app packages,
/// 100 duplicate sets (3 × 1 MB), hard links, 6 real 100 MB media files and 12 sparse ones
/// (~2.4 GB logical, ~0.9 GB allocated).
func buildFixture(root: URL, items: Int) {
  let home = root.appendingPathComponent("home")
  try? fm.removeItem(at: home)
  var rng = SplitMix64(state: 42)
  var created = 0

  let small = rng.data(8192)
  func smallFile(_ seed: Int, size: Int) -> Data {
    // Distinct small content without generating 100k random buffers.
    var data = small.prefix(size)
    withUnsafeBytes(of: UInt64(seed)) { data.replaceSubrange(0..<8, with: $0) }
    return Data(data)
  }

  // Caches + logs (45%)
  let cacheCount = items * 40 / 100
  for i in 0..<cacheCount {
    let app = i % 40
    write(
      home.appendingPathComponent("Library/Caches/com.bench.app\(app)/d\(i % 10)/f\(i).cache"),
      smallFile(i, size: 4096))
  }
  let logCount = items * 5 / 100
  for i in 0..<logCount {
    write(home.appendingPathComponent("Library/Logs/com.bench.app\(i % 40)/log\(i).log"), smallFile(i, size: 2048))
  }
  created += cacheCount + logCount

  // App packages: 20 × 50 files
  for app in 0..<20 {
    let bundle = home.appendingPathComponent("Documents/Bundles/App\(app).app/Contents")
    write(
      bundle.appendingPathComponent("Info.plist"),
      Data("<plist><dict><key>CFBundleIdentifier</key><string>com.bench.bundle\(app)</string></dict></plist>".utf8))
    write(bundle.appendingPathComponent("MacOS/App\(app)"), rng.data(65_536))
    for r in 0..<48 {
      write(bundle.appendingPathComponent("Resources/r\(r).dat"), smallFile(app * 1000 + r, size: 4096))
    }
  }
  created += 20 * 50

  // Duplicates: 100 sets × 3 copies of 1 MB, plus 50 hard links
  for set in 0..<100 {
    let content = rng.data(1_048_576)
    for copy in 0..<3 {
      write(home.appendingPathComponent("Documents/Dupes/set\(set)/copy\(copy).bin"), content)
    }
  }
  for link in 0..<50 {
    let source = home.appendingPathComponent("Documents/Dupes/set\(link)/copy0.bin")
    let target = home.appendingPathComponent("Documents/Links/link\(link).bin")
    try? fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
    try? fm.linkItem(at: source, to: target)
  }
  created += 350

  // Large media: 6 real 100 MB files + 12 sparse 150 MB files
  let chunk = rng.data(1_048_576)
  for i in 0..<6 {
    let url = home.appendingPathComponent("Documents/Media/real\(i).mov")
    try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    _ = fm.createFile(atPath: url.path, contents: nil)
    let handle = try! FileHandle(forWritingTo: url)
    for _ in 0..<100 { handle.write(chunk) }
    try! handle.close()
  }
  for i in 0..<12 {
    sparse(home.appendingPathComponent("Documents/Media/sparse\(i).mov"), bytes: 150 * 1_048_576)
  }
  created += 18

  // Nested project files for the remainder
  let remaining = max(0, items - created)
  for i in 0..<remaining {
    let path = "Documents/Projects/p\(i % 50)/src/m\(i % 7)/g\((i / 7) % 13)/file\(i).txt"
    write(home.appendingPathComponent(path), smallFile(i, size: 1024 + (i % 7) * 1024))
  }
  created += remaining

  emit(["fixture": home.path, "items": created])
}

// MARK: - Scanners

struct ScanResult: Sendable {
  let scanner: String
  let results: Int
  let bytes: Int64
  let cancelled: Bool
  let seconds: Double

  var json: [String: Any] {
    ["scanner": scanner, "results": results, "bytes": bytes, "cancelled": cancelled, "seconds": seconds]
  }
}

func runScanner(_ name: String, home: URL) async -> ScanResult {
  let clock = ContinuousClock()
  let start = clock.now
  let results: Int
  let bytes: Int64
  let cancelled: Bool
  switch name {
  case "photos":
    var rng = SplitMix64(state: 42)
    var photos: [PhotoFingerprint] = []
    for i in 0..<100000 {
      if i % 256 == 0, Task.isCancelled { break }
      let hash = i % 2 == 0 ? rng.next() : (photos.last?.hash ?? 0) ^ 0b111
      photos.append(PhotoFingerprint(url: home.appendingPathComponent("photo\(i).jpg"), bytes: 1000000,
        hash: hash, sharpness: Double(i % 1000), pixelWidth: 3000, pixelHeight: 2000))
    }
    let groups = PhotoAnalysis.group(photos)
    (results, bytes, cancelled) = (groups.count, groups.reduce(0) { $0 + $1.reclaimableBytes }, Task.isCancelled)
  case "developer":
    let report = await DeveloperStorageScanner(homeDirectory: home).scan(projectRoots: [home.appendingPathComponent("Documents/Projects")])
    (results, bytes, cancelled) = (report.value.count, report.value.reduce(0) { $0 + $1.bytes }, report.wasCancelled)
  case "combined":
    async let cleanup = runScanner("cleanup", home: home)
    async let developer = runScanner("developer", home: home)
    async let large = runScanner("large", home: home)
    let all = await [cleanup, developer, large]
    (results, bytes, cancelled) = (all.reduce(0) { $0 + $1.results }, all.reduce(0) { $0 + $1.bytes }, all.contains { $0.cancelled })
  case "cleanup":
    let report = await CleanupScanner(catalog: CleanupCatalog(homeDirectory: home)).scanReport()
    (results, bytes, cancelled) = (
      report.value.count, report.value.reduce(Int64(0)) { $0 + $1.size }, report.wasCancelled
    )
  case "storage":
    let scan = await StorageTreeScanner().scan(home)
    (results, bytes, cancelled) = (
      scan.coverage.scannedItems, scan.root.allocatedBytes, scan.coverage.wasCancelled
    )
  case "large":
    let report = await LargeFileFinder().findReport(
      in: [home], minimumSize: 50 * 1_048_576, excludedRoots: [home.appendingPathComponent("Library")])
    (results, bytes, cancelled) = (
      report.value.count, report.value.reduce(Int64(0)) { $0 + $1.size }, report.wasCancelled
    )
  case "duplicates":
    let report = await DuplicateFinder().findReport(
      in: [home.appendingPathComponent("Documents")], minimumSize: 512 * 1024)
    (results, bytes, cancelled) = (
      report.value.count, report.value.reduce(Int64(0)) { $0 + $1.reclaimableBytes },
      report.wasCancelled
    )
  default:
    fail("unknown scanner \(name) — use cleanup, storage, large, duplicates, photos, developer, combined")
  }
  let elapsed = clock.now - start
  return ScanResult(
    scanner: name, results: results, bytes: bytes, cancelled: cancelled,
    seconds: Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18)
}

// MARK: - Entry

let args = Array(CommandLine.arguments.dropFirst())
guard let command = args.first else {
  fail("usage: macmint-bench fixture|run|cancel|hash …")
}

switch command {
case "fixture":
  guard args.count >= 2 else { fail("usage: macmint-bench fixture <root> [--items N]") }
  buildFixture(
    root: URL(fileURLWithPath: args[1]), items: Int(option("--items", in: args) ?? "") ?? 100_000)

case "run":
  guard args.count >= 3 else { fail("usage: macmint-bench run <root> <scanner>") }
  let home = URL(fileURLWithPath: args[1]).appendingPathComponent("home")
  emit(await runScanner(args[2], home: home).json)

case "cancel":
  guard args.count >= 3 else { fail("usage: macmint-bench cancel <root> <scanner> [--after S]") }
  let home = URL(fileURLWithPath: args[1]).appendingPathComponent("home")
  let scanner = args[2]
  let after = Double(option("--after", in: args) ?? "") ?? 0.5
  let clock = ContinuousClock()
  let task = Task { await runScanner(scanner, home: home) }
  try? await Task.sleep(for: .seconds(after))
  let cancelledAt = clock.now
  task.cancel()
  let result = await task.value
  let ack = clock.now - cancelledAt
  let ackMs = Double(ack.components.seconds) * 1000 + Double(ack.components.attoseconds) / 1e15
  emit([
    "scanner": scanner, "cancelAfterSeconds": after, "ackMilliseconds": ackMs,
    "reportedCancelled": result.cancelled,
    "finishedBeforeCancel": result.seconds < after,
  ])

case "hash":
  guard args.count >= 2 else { fail("usage: macmint-bench hash <file>") }
  let url = URL(fileURLWithPath: args[1])
  let size = (try? fm.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0
  let clock = ContinuousClock()
  let start = clock.now
  let digest = try SHA256.hexDigest(file: url)
  let elapsed = clock.now - start
  let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
  emit([
    "digest": digest, "bytes": size, "seconds": seconds,
    "megabytesPerSecond": seconds > 0 ? Double(size) / 1_048_576 / seconds : 0,
  ])

default:
  fail("unknown command \(command)")
}
