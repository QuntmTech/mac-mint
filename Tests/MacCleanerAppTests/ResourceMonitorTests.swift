import AppKit
import XCTest
@testable import MacCleanerApp

@MainActor
final class ResourceMonitorTests: XCTestCase {
  func testVisibilityLeasesAreIdempotentAndRespectFastestConsumer() {
    let monitor = SystemMonitor(), first = UUID(), second = UUID()
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
  func testProcessPolicyProtectsSelfSystemAndUnknownOwnership() {
    XCTAssertFalse(ProcessControlPolicy.allows(pid: 1, bundleID: "example.app"))
    XCTAssertFalse(ProcessControlPolicy.allows(pid: 1000, bundleID: "com.apple.finder"))
    XCTAssertFalse(ProcessControlPolicy.allows(pid: ProcessInfo.processInfo.processIdentifier, bundleID: "example.app"))
    XCTAssertFalse(ProcessControlPolicy.allows(pid: 1000, bundleID: nil))
    XCTAssertTrue(ProcessControlPolicy.allows(pid: 1000, bundleID: "example.editor"))
  }
}
