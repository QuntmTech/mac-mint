import Foundation
import MacCleanerCore
import XCTest
@testable import MacCleanerApp

@MainActor
final class OrganizationCoordinatorTests: XCTestCase {
  func testActivationGuardsApplyWhileLocalUndoPreservesUnrelatedSelections() async throws {
    let fm = FileManager.default
    let home = fm.homeDirectoryForCurrentUser.appendingPathComponent("MacMintOrganizationTest-" + UUID().uuidString)
    defer { try? fm.removeItem(at: home) }
    let root = home.appendingPathComponent("Downloads")
    try fm.createDirectory(at: root.appendingPathComponent("Photos"), withIntermediateDirectories: true)
    let source = root.appendingPathComponent("photo.jpg"), other = home.appendingPathComponent("other.jpg")
    try Data("image fixture".utf8).write(to: source); try Data("other image".utf8).write(to: other)
    let model = AppViewModel(supportDirectory: home.appendingPathComponent("Support"))
    let inventory = try await model.organizationStore.inspect(root)
    let proposals = await model.organizationStore.localSuggestions(inventory)
    model.exclusionsReady = true; model.authorizeRemoval = { false }
    do { _ = try await model.applyOrganization(inventory, proposals: proposals); XCTFail("Activation required") }
    catch AppViewModel.OrganizationAccessError.activation {} catch { XCTFail("\(error)") }
    XCTAssertTrue(fm.fileExists(atPath: source.path))
    let photos = [source,other].map { PhotoFingerprint(url: $0, bytes: 10, hash: 0, sharpness: 1, pixelWidth: 1, pixelHeight: 1) }
    model.photoScan = PhotoScanResult(photos: photos, similarGroups: [], blurry: [], screenshots: [], skippedLibraries: [], issues: [], wasCancelled: false)
    model.selectedPhotoIDs = [photos[1].id]
    model.largeFiles = [source,other].map { LargeFile(url: $0, size: 10, modifiedAt: nil, accessedAt: nil) }
    model.selectedLargeFileIDs = [other.path]
    model.authorizeRemoval = { true }
    let moved = try await model.applyOrganization(inventory, proposals: proposals)
    XCTAssertEqual(moved.items.first?.state, .moved)
    XCTAssertEqual(model.selectedPhotoIDs, [photos[1].id]); XCTAssertEqual(model.photoScan?.photos.map(\.id), [photos[1].id])
    XCTAssertEqual(model.selectedLargeFileIDs, [other.path])
    let generation = model.photoScan?.generation
    model.authorizeRemoval = { false }; model.exclusionsReady = false
    let undone = try await model.undoOrganization(moved.id)
    XCTAssertEqual(undone.items.first?.state, .undone)
    XCTAssertTrue(fm.fileExists(atPath: source.path))
    XCTAssertEqual(model.photoScan?.generation, generation)
  }
}
