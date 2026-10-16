import Foundation
import XCTest
@testable import MacCleanerCore

/// Real mounted-volume coverage runs only in disposable macOS CI. Every image, mountpoint
/// and detach target belongs to this test; no user disk or existing mount is modified.
final class NativeVolumeTests: XCTestCase {
  func testMountedVolumeInsideHomeRemainsReadOnlyAndCaseBoundariesStayDistinct() async throws {
    guard ProcessInfo.processInfo.environment["MACMINT_VOLUME_TESTS"] == "1" else {
      throw XCTSkip("Disposable disk-image checks run in macOS CI")
    }
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("macmint-volume-" + UUID().uuidString)
    try fm.createDirectory(at: root, withIntermediateDirectories: true)
    let image = root.appendingPathComponent("fixture.sparseimage")
    let container = root.appendingPathComponent("container")
    try fm.createDirectory(at: container, withIntermediateDirectories: true)
    let mount = container.appendingPathComponent("mount")
    var attachedDevice: String?
    defer {
      if let attachedDevice {
        // Detach only the device returned by our own attach, including after a failed assertion.
        if (try? command(["detach", attachedDevice])) == nil { _ = try? command(["detach", "-force", attachedDevice]) }
      }
      // Never recursively remove a mountpoint if detach failed.
      if !fm.fileExists(atPath: mount.path)
        || FileSystem.volumeIdentity(at: mount) == FileSystem.volumeIdentity(at: root) {
        try? fm.removeItem(at: root)
      }
    }
    _ = try command(["create", "-size", "128m", "-type", "SPARSE", "-fs", "HFSX",
      "-volname", "MacMintFixture", "-o", image.path])
    let attached = try command(["attach", image.path, "-nobrowse", "-mountpoint", mount.path, "-plist"])
    let plist = try XCTUnwrap(try PropertyListSerialization.propertyList(from: attached, format: nil) as? [String: Any])
    let entities = try XCTUnwrap(plist["system-entities"] as? [[String: Any]])
    attachedDevice = entities.compactMap { $0["dev-entry"] as? String }.first
    XCTAssertNotNil(attachedDevice)
    XCTAssertNotEqual(FileSystem.volumeIdentity(at: mount), FileSystem.volumeIdentity(at: root))

    // A home folder on this volume may clean its own files; a different mounted volume
    // under a home folder on the host remains read-only.
    let owner = mount.appendingPathComponent("Owner")
    let sibling = mount.appendingPathComponent("owner")
    try fm.createDirectory(at: owner, withIntermediateDirectories: true)
    try fm.createDirectory(at: sibling, withIntermediateDirectories: true)
    let personal = owner.appendingPathComponent("allowed.txt")
    let other = sibling.appendingPathComponent("blocked.txt")
    try Data("one".utf8).write(to: personal)
    try Data("two".utf8).write(to: other)
    let mountedHome = SafetyPolicy(homeDirectory: owner)
    XCTAssertTrue(mountedHome.reviewedFileDecision(for: personal).allowed)
    XCTAssertFalse(mountedHome.reviewedFileDecision(for: other).allowed)
    let policy = SafetyPolicy(homeDirectory: root)
    XCTAssertFalse(policy.reviewedFileDecision(for: personal).allowed)
    let item = PlanItem(url: mount, displayName: "mounted filesystem", kind: .reviewedFile,
      expectedBytes: 0, reason: "Test", source: "Test", identity: FileSystem.fileIdentity(at: mount))
    let plan = OperationPlanner.plan(title: "Test", items: [item])
    let trash = UnexpectedVolumeTrash()
    let direct = await OperationExecutor(trashService: trash, safetyPolicy: policy).run(plan)
    XCTAssertTrue(direct.moved.isEmpty)
    XCTAssertTrue(direct.problems.first?.message?.contains("mounted volume") == true)
    let ancestor = PlanItem(url: container, displayName: "container", kind: .reviewedFile,
      expectedBytes: 0, reason: "Test", source: "Test", identity: FileSystem.fileIdentity(at: container))
    let ancestorPlan = OperationPlanner.plan(title: "Test", items: [ancestor])
    let result = await OperationExecutor(trashService: trash, safetyPolicy: policy).run(ancestorPlan)
    XCTAssertEqual(result.moved.count, 0)
    XCTAssertTrue(result.problems.first?.message?.contains("mounted volume") == true)
    let count = await trash.calls
    XCTAssertEqual(count, 0)
    XCTAssertTrue(fm.fileExists(atPath: personal.path))

    let externalOrganizer = OrganizationStore(directory: root.appendingPathComponent("Organization"), home: root)
    do { _ = try await externalOrganizer.inspect(owner); XCTFail("Organization must not adopt a mounted volume below home") } catch {}
    let organizationRoot = owner.appendingPathComponent("Documents")
    try fm.createDirectory(at: organizationRoot, withIntermediateDirectories: true)
    let organizationSource = organizationRoot.appendingPathComponent("report.txt")
    try Data("fixture".utf8).write(to: organizationSource)
    let organizer = OrganizationStore(directory: owner.appendingPathComponent("Organization"), home: owner)
    let inventory = try await organizer.inspect(organizationRoot)
    let organizationFile = try XCTUnwrap(inventory.files.first)
    let proposal = OrganizationProposal(fileID: organizationFile.id, folderID: "root", name: "renamed.txt", reason: "Test fixture")

    let trashItem = root.appendingPathComponent(".Trash/restore.txt")
    try fm.createDirectory(at: trashItem.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("restore".utf8).write(to: trashItem)
    let receipt = TrashReceipt(originalPath: root.appendingPathComponent("restore.txt").path,
      trashPath: trashItem.path, bytes: 7, identity: FileSystem.fileIdentity(at: trashItem))
    XCTAssertThrowsError(try RecoveryService().restore(receipt, into: owner)) { error in
      XCTAssertTrue(error.localizedDescription.contains("same volume"))
    }
    XCTAssertTrue(fm.fileExists(atPath: trashItem.path))

    let staleItem = PlanItem(url: personal, displayName: "allowed.txt", kind: .reviewedFile,
      expectedBytes: 3, reason: "Test", source: "Test", identity: FileSystem.fileIdentity(at: personal))
    let stalePlan = OperationPlanner.plan(title: "Test", items: [staleItem])
    XCTAssertEqual(stalePlan.items.count, 1)

    // Fill only our bounded 128 MB image, never the runner's/user's disk. This proves
    // actual ENOSPC stops movement when the initial journal cannot be made durable.
    let journals = owner.appendingPathComponent("Operations")
    try fm.createDirectory(at: journals, withIntermediateDirectories: true)
    let filler = owner.appendingPathComponent("bounded-full-disk-fixture")
    XCTAssertTrue(fm.createFile(atPath: filler.path, contents: nil))
    let handle = try FileHandle(forWritingTo: filler)
    defer { try? handle.close() }
    let chunk = Data(repeating: 0x56, count: 1_048_576)
    var fullError: NSError?
    for _ in 0..<192 {
      do { try handle.write(contentsOf: chunk) }
      catch { fullError = error as NSError; break }
    }
    // A failed 1 MB allocation can leave room for a small journal. Consume remaining
    // allocation blocks, and keep the handle open so closing cannot release preallocation.
    let block = Data(repeating: 0x57, count: 4096)
    for _ in 0..<2048 {
      do { try handle.write(contentsOf: block) }
      catch { fullError = error as NSError; break }
    }
    XCTAssertNotNil(fullError, "The disposable image did not reach its bounded capacity")
    let underlying = fullError?.userInfo[NSUnderlyingErrorKey] as? NSError
    XCTAssertTrue([fullError, underlying].compactMap { $0 }.contains {
      ($0.domain == NSPOSIXErrorDomain && $0.code == 28)
        || ($0.domain == NSCocoaErrorDomain && $0.code == CocoaError.fileWriteOutOfSpace.rawValue)
    }, "Expected an actual out-of-space error, not an unrelated write failure")
    let full = await OperationExecutor(trashService: trash, safetyPolicy: mountedHome,
      journalDirectory: journals).run(stalePlan)
    XCTAssertNotNil(full.persistenceError, "Full storage must fail closed before the first move")
    XCTAssertTrue(full.moved.isEmpty)
    XCTAssertTrue(fm.fileExists(atPath: personal.path))
    do { _ = try await organizer.apply(inventory, proposals: [proposal]); XCTFail("Actual full storage must block organization before movement") } catch {}
    XCTAssertTrue(fm.fileExists(atPath: organizationSource.path))
    XCTAssertFalse(fm.fileExists(atPath: organizationRoot.appendingPathComponent("renamed.txt").path))
    let callsAfterFullDisk = await trash.calls
    XCTAssertEqual(callsAfterFullDisk, 0)
    try handle.close()
    try fm.removeItem(at: filler)

    _ = try command(["detach", try XCTUnwrap(attachedDevice)])
    attachedDevice = nil
    let disconnected = await OperationExecutor(trashService: trash, safetyPolicy: mountedHome).run(stalePlan)
    XCTAssertEqual(disconnected.moved.count, 0)
    XCTAssertEqual(disconnected.problems.count, 1)
    let finalCount = await trash.calls
    XCTAssertEqual(finalCount, 0)
  }

  private func command(_ arguments: [String]) throws -> Data {
    let process = Process(), output = Pipe(), errors = Pipe()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
    process.arguments = arguments
    process.standardOutput = output; process.standardError = errors
    try process.run()
    let data = output.fileHandleForReading.readDataToEndOfFile()
    let error = errors.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
      throw NSError(domain: "MacMintVolumeFixture", code: Int(process.terminationStatus),
        userInfo: [NSLocalizedDescriptionKey: String(decoding: error, as: UTF8.self)])
    }
    return data
  }
}

private actor UnexpectedVolumeTrash: TrashService {
  var calls = 0
  func trash(_ url: URL) async throws -> URL? {
    calls += 1
    throw TrashServiceError.unsupported
  }
}
