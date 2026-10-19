import AppKit
import Darwin
import Foundation
import MacCleanerCore
import XCTest
@testable import MacCleanerApp

@MainActor
final class NativeTamingTests: XCTestCase {
  /// Compiles and launches only our disposable fixture, never an existing user app.
  func testDarwinBackgroundAndRestoreForOwnedRegularApp() async throws {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("macmint-taming-" + UUID().uuidString)
    defer { try? fm.removeItem(at: root) }
    let bundle = root.appendingPathComponent("Fixture.app")
    let executable = bundle.appendingPathComponent("Contents/MacOS/Fixture")
    try fm.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
    let bundleID = "test.macmint.taming." + UUID().uuidString.lowercased()
    let plist: [String: Any] = ["CFBundleExecutable": "Fixture", "CFBundleIdentifier": bundleID,
      "CFBundlePackageType": "APPL", "CFBundleName": "MacMint Slowdown Fixture"]
    try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
      .write(to: bundle.appendingPathComponent("Contents/Info.plist"))
    let source = root.appendingPathComponent("Fixture.swift")
    try "import AppKit\nlet app = NSApplication.shared\napp.setActivationPolicy(.regular)\napp.run()\n"
      .write(to: source, atomically: true, encoding: .utf8)
    let compiler = Process(); compiler.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
    compiler.arguments = ["swiftc", source.path, "-o", executable.path, "-framework", "AppKit"]
    try compiler.run()
    // Avoid blocking the main actor/WindowServer while the fixture compiles.
    while compiler.isRunning { try await Task.sleep(for: .milliseconds(50)) }
    XCTAssertEqual(compiler.terminationStatus, 0)
    guard compiler.terminationStatus == 0 else { return }
    let process = Process(); process.executableURL = executable
    try process.run()
    let pid = process.processIdentifier
    defer { if process.isRunning { process.terminate() } }
    var identity: TamingIdentity?
    for _ in 0..<100 {
      if let app = NSRunningApplication(processIdentifier: pid), app.activationPolicy == .regular,
        app.bundleIdentifier == bundleID, let usage = ResourceSampler.usage(pid) {
        identity = .init(pid: pid, started: usage.ri_proc_start_abstime, boot: DarwinTamingBackend.boot,
          bundleID: bundleID, path: bundle.resolvingSymlinksInPath().path)
        break
      }
      try await Task.sleep(for: .milliseconds(50))
    }
    let target = try XCTUnwrap(identity, "Only the marker-owned fixture PID is eligible")
    let backend = DarwinTamingBackend()
    XCTAssertEqual(backend.status(target), .current)
    defer { try? backend.setBackground(false, for: target) }
    try backend.setBackground(true, for: target)
    try backend.setBackground(false, for: target)
    let replacement = TamingIdentity(pid: pid, started: target.started &+ 1, boot: target.boot,
      bundleID: bundleID, path: target.path)
    XCTAssertEqual(backend.status(replacement), .goneOrChanged)
    XCTAssertThrowsError(try backend.setBackground(true, for: replacement))
  }
}
