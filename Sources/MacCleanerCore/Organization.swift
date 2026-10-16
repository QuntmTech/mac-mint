import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
@_silgen_name("renameat2")
private func exclusiveRename(_ fromFD: Int32, _ from: UnsafePointer<CChar>, _ toFD: Int32, _ to: UnsafePointer<CChar>, _ flags: UInt32) -> Int32
#endif

public struct OrganizationFile: Codable, Identifiable, Hashable, Sendable {
  public let id: String
  public let name: String
  public let identity: String
  public let bytes: Int64
  public let modified: Date
}
public struct OrganizationFolder: Codable, Identifiable, Hashable, Sendable {
  public let id: String
  public let name: String
  public let identity: String
}
public struct OrganizationInventory: Codable, Sendable {
  public let id: UUID
  public let root: URL
  public let rootIdentity: String
  public let files: [OrganizationFile]
  public let folders: [OrganizationFolder]
  public let omitted: Int
  public let wasLimited: Bool
}
public struct OrganizationProposal: Codable, Identifiable, Hashable, Sendable {
  public let fileID: String
  public let folderID: String
  public let name: String
  public let reason: String
  public var id: String { fileID }
  public init(fileID: String, folderID: String, name: String, reason: String) {
    self.fileID = fileID; self.folderID = folderID; self.name = name; self.reason = reason
  }
}
/// Only names and opaque IDs are sent after separate, per-request consent. No root path or content.
public struct AIOrganizationRequest: Codable, Sendable {
  public struct File: Codable, Sendable { public let id: String; public let name: String }
  public struct Folder: Codable, Sendable { public let id: String; public let name: String }
  public let files: [File]
  public let folders: [Folder]
  public init(_ inventory: OrganizationInventory) {
    files = inventory.files.map { File(id: $0.id, name: $0.name) }
    folders = inventory.folders.map { Folder(id: $0.id, name: $0.name) }
  }
}
public struct AIOrganizationResponse: Codable, Sendable { public let proposals: [OrganizationProposal]; public let model: String }
public struct OrganizationRecord: Codable, Identifiable, Sendable {
  public enum State: String, Codable, Sendable { case prepared, moving, moved, undoing, undone, failed, uncertain }
  public struct Item: Codable, Identifiable, Sendable {
    public let proposal: OrganizationProposal
    public var state: State
    public var message: String?
    public var id: String { proposal.id }
  }
  public let id: UUID
  public let date: Date
  public let inventory: OrganizationInventory
  public var items: [Item]
}

private struct OrganizationMoveUncertain: Error {}

public struct OrganizationHistory: Sendable {
  public let records: [OrganizationRecord]
  public let warnings: [String]
}

public struct OrganizationError: LocalizedError, Sendable {
  public let errorDescription: String?
  init(_ message: String) { errorDescription = message }
}

/// Bounded, shallow inspection and journaled same-volume renames. The model never supplies URLs.
public actor OrganizationStore {
  private let directory: URL
  private let home: URL
  private let writer: @Sendable (Data, URL) throws -> Void
  private let fm = FileManager.default
  private let supported: Set<String> = ["pdf", "txt", "rtf", "md", "csv", "docx", "xlsx", "pptx", "jpg", "jpeg", "png", "heic", "webp", "gif", "mov", "mp4", "m4v", "mp3", "m4a", "wav", "zip", "dmg"]
  public init(directory: URL, home: URL = FileManager.default.homeDirectoryForCurrentUser,
    writer: (@Sendable (Data, URL) throws -> Void)? = nil) {
    self.directory = directory; self.home = home.resolvingSymlinksInPath().standardizedFileURL
    self.writer = writer ?? { try FileSystem.writeDurably($0, to: $1) }
  }

  public func inspect(_ root: URL, ignoredPaths: Set<String> = []) throws -> OrganizationInventory {
    let root = root.resolvingSymlinksInPath().standardizedFileURL
    try validateRoot(root)
    guard !FileSystem.isIgnored(root, ignoredPaths: ignoredPaths) else { throw OrganizationError("This folder is excluded from inspection.") }
    guard let children = fm.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .contentModificationDateKey, .fileSizeKey], options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants, .skipsPackageDescendants]) else { throw OrganizationError("This folder could not be inspected.") }
    guard let identity = FileSystem.fileIdentity(at: root) else { throw OrganizationError("The selected folder could not be identified.") }
    var files: [OrganizationFile] = [], folders = [OrganizationFolder(id: "root", name: "This folder", identity: identity)], omitted = 0
    // Enumeration is shallow. Even directories with millions of descendants are never traversed.
    var inspected = 0, limited = false
    while let url = children.nextObject() as? URL {
      if inspected >= 500 { limited = true; break }
      inspected += 1
      try Task.checkCancellation()
      guard !FileSystem.isIgnored(url, ignoredPaths: ignoredPaths), validName(url.lastPathComponent),
        let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .contentModificationDateKey, .fileSizeKey]),
        values.isSymbolicLink != true, let identity = FileSystem.fileIdentity(at: url) else { omitted += 1; continue }
      if values.isDirectory == true, folders.count < 25, eligibleFolder(url), FileSystem.volumeIdentity(at: root) == FileSystem.volumeIdentity(at: url) {
        folders.append(OrganizationFolder(id: "d\(folders.count)", name: url.lastPathComponent, identity: identity))
      } else if values.isRegularFile == true, supported.contains(url.pathExtension.lowercased()), files.count < 100,
        !FileSystem.isCloudPlaceholder(url), FileSystem.linkCount(at: url) == 1, let modified = values.contentModificationDate {
        files.append(OrganizationFile(id: "f\(files.count)", name: url.lastPathComponent, identity: identity,
          bytes: Int64(values.fileSize ?? 0), modified: modified))
      } else { omitted += 1 }
    }
    return OrganizationInventory(id: UUID(), root: root.standardizedFileURL, rootIdentity: identity,
      files: files, folders: folders, omitted: omitted, wasLimited: limited)
  }

  public func localSuggestions(_ inventory: OrganizationInventory) -> [OrganizationProposal] {
    inventory.files.compactMap { file in
      let ext = (file.name as NSString).pathExtension.lowercased()
      let names: [String]
      if ["jpg", "jpeg", "png", "heic", "webp", "gif"].contains(ext) { names = ["images", "photos", "pictures"] }
      else if ["mp4", "mov", "m4v"].contains(ext) { names = ["videos", "movies"] }
      else if ["mp3", "m4a", "wav"].contains(ext) { names = ["audio", "music"] }
      else if ["zip", "dmg"].contains(ext) { names = ["archives", "installers"] }
      else { names = ["documents", "docs"] }
      guard let folder = inventory.folders.first(where: { $0.id != "root" && names.contains($0.name.lowercased()) }) else { return nil }
      return OrganizationProposal(fileID: file.id, folderID: folder.id, name: file.name, reason: "Matches the existing \(folder.name) folder by file type. No AI used.")
    }
  }

  public func problem(_ proposal: OrganizationProposal, in inventory: OrganizationInventory, ignoredPaths: Set<String> = []) -> String? {
    do {
      try validateRoot(inventory.root)
      guard FileSystem.fileIdentity(at: inventory.root) == inventory.rootIdentity,
        let file = inventory.files.first(where: { $0.id == proposal.fileID }),
        let folder = inventory.folders.first(where: { $0.id == proposal.folderID }), validName(proposal.name),
        supported.contains((file.name as NSString).pathExtension.lowercased()),
        (file.name as NSString).pathExtension == (proposal.name as NSString).pathExtension else { return "Unknown item, changed folder, invalid name, or changed extension." }
      let source = inventory.root.appendingPathComponent(file.name), destinationFolder = folderURL(folder, inventory: inventory)
      let destination = destinationFolder.appendingPathComponent(proposal.name)
      guard !FileSystem.isIgnored(source, ignoredPaths: ignoredPaths), !FileSystem.isIgnored(destination, ignoredPaths: ignoredPaths) else { return "This item or destination is excluded." }
      guard FileSystem.fileIdentity(at: destinationFolder) == folder.identity, eligibleFolder(destinationFolder),
        destinationFolder.resolvingSymlinksInPath().standardizedFileURL == destinationFolder.standardizedFileURL else { return "The destination changed or is not eligible." }
      guard FileSystem.volumeIdentity(at: source) == FileSystem.volumeIdentity(at: destinationFolder) else { return "Moves between volumes are not supported." }
      guard matches(file, at: source) else { return "The source changed, is unavailable, or is no longer a regular local file." }
      guard FileSystem.comparisonPath(source) != FileSystem.comparisonPath(destination) else { return "The proposed location is unchanged." }
      guard try !FileSystem.entryExists(at: destination) else { return "A file already occupies the proposed location." }
      return nil
    } catch { return error.localizedDescription }
  }

  public func apply(_ inventory: OrganizationInventory, proposals: [OrganizationProposal], ignoredPaths: Set<String> = []) throws -> OrganizationRecord {
    guard !proposals.isEmpty, proposals.count <= 100, Set(proposals.map(\.id)).count == proposals.count else { throw OrganizationError("Choose up to 100 distinct files.") }
    let journal = directory.appendingPathComponent(inventory.id.uuidString + ".json")
    // Retrying an operation ID returns its durable outcome; it never repeats a move.
    if try FileSystem.entryExists(at: journal) { return try recover(JSONDecoder().decode(OrganizationRecord.self, from: Data(contentsOf: journal))) }
    var destinations: Set<String> = []
    for proposal in proposals {
      if let issue = problem(proposal, in: inventory, ignoredPaths: ignoredPaths) { throw OrganizationError(issue) }
      let folder = inventory.folders.first { $0.id == proposal.folderID }!
      let key = FileSystem.comparisonPath(folderURL(folder, inventory: inventory).appendingPathComponent(proposal.name))
      guard destinations.insert(key).inserted else { throw OrganizationError("Two proposals use the same destination. Keep one of them.") }
    }
    var record = OrganizationRecord(id: inventory.id, date: Date(), inventory: inventory,
      items: proposals.map { .init(proposal: $0, state: .prepared) })
    try persist(record) // Must succeed before any filesystem change.
    for index in record.items.indices {
      if Task.isCancelled { break }
      let proposal = record.items[index].proposal
      if let issue = problem(proposal, in: inventory, ignoredPaths: ignoredPaths) {
        record.items[index].state = .failed; record.items[index].message = issue; try persist(record); continue
      }
      record.items[index].state = .moving; try persist(record)
      do { try move(record, item: record.items[index], undo: false) }
      catch is OrganizationMoveUncertain { throw OrganizationError("A move needs recovery verification. Its durable intent has been kept.") }
      catch { record.items[index].state = .failed; record.items[index].message = error.localizedDescription; try persist(record); continue }
      record.items[index].state = .moved
      try persist(record) // On failure the durable moving intent remains for reconciliation.
    }
    return record
  }

  public func history() throws -> [OrganizationRecord] {
    let report = try historyReport()
    guard report.warnings.isEmpty else { throw OrganizationError(report.warnings.joined(separator: " ")) }
    return report.records
  }
  public func historyReport() throws -> OrganizationHistory {
    guard try FileSystem.entryExists(at: directory) else { return OrganizationHistory(records: [], warnings: []) }
    var records: [OrganizationRecord] = [], warnings: [String] = []
    for url in try fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) where url.pathExtension == "json" {
      do {
        let record = try JSONDecoder().decode(OrganizationRecord.self, from: Data(contentsOf: url))
        do { records.append(try recover(record)) }
        catch { records.append(record); warnings.append("An interrupted record could not be reconciled. Its evidence has been preserved.") }
      } catch { warnings.append("An organization record could not be read. It has been preserved for diagnosis.") }
    }
    return OrganizationHistory(records: records.sorted { $0.date > $1.date }, warnings: warnings)
  }
  public func undo(recordID: UUID) throws -> OrganizationRecord {
    let url = directory.appendingPathComponent(recordID.uuidString + ".json")
    var record = try recover(JSONDecoder().decode(OrganizationRecord.self, from: Data(contentsOf: url)))
    for index in record.items.indices.reversed() where record.items[index].state == .moved {
      try Task.checkCancellation()
      record.items[index].state = .undoing; record.items[index].message = nil; try persist(record)
      do { try move(record, item: record.items[index], undo: true) }
      catch is OrganizationMoveUncertain { throw OrganizationError("Undo needs recovery verification. Its durable intent has been kept.") }
      catch { record.items[index].state = .moved; record.items[index].message = error.localizedDescription; try persist(record); continue }
      record.items[index].state = .undone; try persist(record)
    }
    return record
  }

  private func recover(_ original: OrganizationRecord) throws -> OrganizationRecord {
    var record = original, changed = false
    for index in record.items.indices where [.moving, .undoing].contains(record.items[index].state) {
      let item = record.items[index], file = record.inventory.files.first { $0.id == item.id }
      guard let file, let folder = record.inventory.folders.first(where: { $0.id == item.proposal.folderID }) else { throw OrganizationError("An organization record is unreadable. It has been preserved.") }
      let source = record.inventory.root.appendingPathComponent(file.name), destination = folderURL(folder, inventory: record.inventory).appendingPathComponent(item.proposal.name)
      if matches(file, at: destination), try !FileSystem.entryExists(at: source) { record.items[index].state = .moved }
      else if matches(file, at: source), try !FileSystem.entryExists(at: destination) { record.items[index].state = item.state == .undoing ? .undone : .failed }
      else { record.items[index].state = .uncertain; record.items[index].message = "An interrupted move could not be verified. Inspect both locations in Finder." }
      changed = true
    }
    if changed { try persist(record) }
    return record
  }

  private func persist(_ record: OrganizationRecord) throws {
    try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    let url = directory.appendingPathComponent(record.id.uuidString + ".json")
    try writer(JSONEncoder().encode(record), url)
    try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
  }
  private func validName(_ name: String) -> Bool {
    !name.isEmpty && name != "." && name != ".." && !name.hasPrefix(".") && name.utf8.count <= 200
      && name.rangeOfCharacter(from: .controlCharacters) == nil && !name.contains("/") && !name.contains(":") && !name.contains("\\")
  }
  private func folderURL(_ folder: OrganizationFolder, inventory: OrganizationInventory) -> URL {
    folder.id == "root" ? inventory.root : inventory.root.appendingPathComponent(folder.name)
  }
  private func eligibleFolder(_ url: URL) -> Bool {
    let name = url.lastPathComponent.lowercased()
    return !PhotoAnalysis.isInsideLibraryPackage(url) && url.pathExtension.isEmpty && !name.hasPrefix(".")
      && !["library", "applications", "node_modules", "vendor", "packages", "build", "dist"].contains(name)
      && !fm.fileExists(atPath: url.appendingPathComponent(".git").path)
  }
  private func validateRoot(_ root: URL) throws {
    let literal = root.standardizedFileURL, resolved = root.resolvingSymlinksInPath().standardizedFileURL
    guard literal == resolved, FileSystem.comparisonPath(literal).hasPrefix(FileSystem.comparisonPath(home) + "/"),
      !FileSystem.comparisonPath(literal).hasPrefix(FileSystem.comparisonPath(home.appendingPathComponent("Library")) + "/"),
      eligibleFolder(root) else { throw OrganizationError("Choose a local folder inside your home, outside app libraries, packages, and project repositories.") }
    var parent = root
    while parent.path.count > home.path.count {
      guard eligibleFolder(parent) else { throw OrganizationError("Folders inside app data or repositories are not supported.") }
      parent.deleteLastPathComponent()
    }
  }
  private func matches(_ file: OrganizationFile, at url: URL) -> Bool {
    guard validName(file.name), FileSystem.fileIdentity(at: url) == file.identity, FileSystem.linkCount(at: url) == 1,
      !FileSystem.isCloudPlaceholder(url), let values = try? FileSystem.fresh(url).resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey]) else { return false }
    return values.isRegularFile == true && values.isSymbolicLink != true && Int64(values.fileSize ?? -1) == file.bytes && values.contentModificationDate == file.modified
  }
  private func move(_ record: OrganizationRecord, item: OrganizationRecord.Item, undo: Bool) throws {
    let inventory = record.inventory
    try validateRoot(inventory.root)
    guard let file = inventory.files.first(where: { $0.id == item.id }),
      let folder = inventory.folders.first(where: { $0.id == item.proposal.folderID }), validName(item.proposal.name),
      FileSystem.fileIdentity(at: inventory.root) == inventory.rootIdentity,
      FileSystem.fileIdentity(at: folderURL(folder, inventory: inventory)) == folder.identity else { throw OrganizationError("A folder changed. Inspect the recorded locations.") }
    let other = folderURL(folder, inventory: inventory)
    let from = undo ? other : inventory.root, to = undo ? inventory.root : other
    let fromName = undo ? item.proposal.name : file.name, toName = undo ? file.name : item.proposal.name
    guard validName(fromName), validName(toName), validName(folder.name) || folder.id == "root" else { throw OrganizationError("Invalid recorded name.") }
    let fromFD = open(from.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
    guard fromFD >= 0 else { throw OrganizationError("The source folder is unavailable.") }
    defer { _ = close(fromFD) }
    let toFD = open(to.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
    guard toFD >= 0 else { throw OrganizationError("The destination folder is unavailable.") }
    defer { _ = close(toFD) }
    var sourceDirectory = stat(), targetDirectory = stat(), sourceInfo = stat()
    let expectedSourceFolder = undo ? folder.identity : inventory.rootIdentity
    let expectedTargetFolder = undo ? inventory.rootIdentity : folder.identity
    guard fstat(fromFD, &sourceDirectory) == 0, fstat(toFD, &targetDirectory) == 0,
      "\(sourceDirectory.st_dev):\(sourceDirectory.st_ino)" == expectedSourceFolder,
      "\(targetDirectory.st_dev):\(targetDirectory.st_ino)" == expectedTargetFolder,
      fstatat(fromFD, fromName, &sourceInfo, AT_SYMLINK_NOFOLLOW) == 0,
      "\(sourceInfo.st_dev):\(sourceInfo.st_ino)" == file.identity else { throw OrganizationError("The opened locations changed. Rescan before applying changes.") }
    // All expensive preparation and durable intent writes precede this last metadata check.
    guard matches(file, at: from.appendingPathComponent(fromName)),
      from.resolvingSymlinksInPath().standardizedFileURL == from.standardizedFileURL,
      to.resolvingSymlinksInPath().standardizedFileURL == to.standardizedFileURL else { throw OrganizationError("The file or folder changed. Nothing was overwritten.") }
    let result = fromName.withCString { source in toName.withCString { destination in
      #if canImport(Darwin)
      return renameatx_np(fromFD, source, toFD, destination, UInt32(RENAME_EXCL))
      #else
      return exclusiveRename(fromFD, source, toFD, destination, 1)
      #endif
    } }
    guard result == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
    guard fsync(fromFD) == 0, fsync(toFD) == 0 else {
      // The move occurred but durability is uncertain: leave the moving/undoing intent intact.
      throw OrganizationMoveUncertain()
    }
  }
}
