import AppKit
import Darwin
import MacCleanerCore
import XCTest
@testable import MacCleanerApp

@MainActor
final class ResourceMonitorTests: XCTestCase {
  func testVisibilityLeasesAreIdempotentAndRespectFastestConsumer() {
    let monitor = SystemMonitor(activity: AppActivity(center: NotificationCenter(), evaluate: { true }))
    let first = UUID(), second = UUID()
    monitor.start(lease: first, interval: 20); monitor.start(lease: first, interval: 20)
    XCTAssertEqual(monitor.activeLeaseCount, 1)
    monitor.start(lease: second, interval: 15)
    XCTAssertEqual(monitor.samplingInterval, 15)
    monitor.stop(lease: second); XCTAssertEqual(monitor.samplingInterval, 20)
    monitor.stop(lease: second); XCTAssertEqual(monitor.activeLeaseCount, 1)
    monitor.stop(lease: first); XCTAssertNil(monitor.samplingInterval)
  }
  func testCPUUsesCounterDeltasAndRejectsReplacementOrCounterReset() {
    XCTAssertEqual(ResourceSampler.cpuPercent(previousCPU: 10, currentCPU: 210, previousTime: 100, currentTime: 200, sameProcess: true), 200)
    XCTAssertNil(ResourceSampler.cpuPercent(previousCPU: 100, currentCPU: 1, previousTime: 100, currentTime: 200, sameProcess: true))
    XCTAssertNil(ResourceSampler.cpuPercent(previousCPU: 10, currentCPU: 20, previousTime: 100, currentTime: 100, sameProcess: true))
    XCTAssertNil(ResourceSampler.cpuPercent(previousCPU: 10, currentCPU: 20, previousTime: 100, currentTime: 200, sameProcess: false))
  }
  func testRepeatedSamplingDoesNotAccumulateHostPortReferences() async {
    let sampler = ResourceSampler()
    _ = await sampler.read(pids: [])
    let host = mach_host_self()
    defer { _ = mach_port_deallocate(mach_task_self_, host) }
    var before: mach_port_urefs_t = 0, after: mach_port_urefs_t = 0
    XCTAssertEqual(mach_port_get_refs(mach_task_self_, host, MACH_PORT_RIGHT_SEND, &before), KERN_SUCCESS)
    for _ in 0..<20 { _ = await sampler.read(pids: []) }
    XCTAssertEqual(mach_port_get_refs(mach_task_self_, host, MACH_PORT_RIGHT_SEND, &after), KERN_SUCCESS)
    XCTAssertEqual(before, after, "Each sample must release its host send rights")
  }

  func testLiveListingAttributesAChildProcessToTheProcessThatStartedIt() async throws {
    let child = Process()
    child.executableURL = URL(fileURLWithPath: "/bin/sleep")
    child.arguments = ["10"]
    try child.run()
    defer { child.terminate() }
    let me = ProcessInfo.processInfo.processIdentifier
    let listing = ResourceSampler.listProcesses()
    XCTAssertTrue(listing.contains { $0.pid == me && $0.parent == getppid() })
    XCTAssertTrue(ProcessFamilies.members(of: [me], in: listing)[me]?.contains(child.processIdentifier) ?? false)
    XCTAssertEqual(ResourceSampler.executableName(child.processIdentifier), "sleep")
    let sampler = ResourceSampler(readDisk: { nil })
    let measured = await sampler.read(pids: [me], families: true)
    let helpers = try XCTUnwrap(measured.apps[me]?.helpers)
    XCTAssertGreaterThanOrEqual(helpers.count, 1)
    XCTAssertGreaterThan(helpers.memoryBytes, 0)
    let controlOnly = await sampler.read(pids: [me])
    XCTAssertNil(controlOnly.apps[me]?.helpers, "Auto Tame's samples don't list helper processes")
  }

  func testProcessPolicyProtectsSelfSystemAndUnknownOwnership() {
    XCTAssertFalse(ProcessControlPolicy.allows(pid: 1, bundleID: "example.app"))
    XCTAssertFalse(ProcessControlPolicy.allows(pid: 1000, bundleID: "com.apple.finder"))
    XCTAssertFalse(ProcessControlPolicy.allows(pid: ProcessInfo.processInfo.processIdentifier, bundleID: "example.app"))
    XCTAssertFalse(ProcessControlPolicy.allows(pid: 1000, bundleID: nil))
    XCTAssertTrue(ProcessControlPolicy.allows(pid: 1000, bundleID: "example.editor"))
  }
}
