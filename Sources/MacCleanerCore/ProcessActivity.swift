import Darwin
import Foundation

/// A running process of this user, as far as the move check needs it: its name and the folder it
/// is working in. Command lines are never read, so nothing secret can leak into a reason.
public struct ActiveProcess: Hashable, Sendable {
  public let pid: pid_t
  public let name: String
  /// Current working directory, when it could be read.
  public let workingDirectory: String?

  public init(pid: pid_t, name: String, workingDirectory: String?) {
    self.pid = pid
    self.name = name
    self.workingDirectory = workingDirectory
  }
}

/// What is running right now, read just before a move. A GUI app being closed doesn't mean a
/// terminal build, a package manager or a Node script isn't using the folder.
public enum ProcessActivity {
  /// Tools that write into build output while they run.
  public static let buildToolNames: Set<String> = [
    "xcodebuild", "XCBBuildService", "swift-build", "swift-frontend", "swift-package", "swift-test",
    "pod", "gradle", "java", "cargo", "rustc", "npm", "pnpm", "yarn", "bun", "node", "uv", "pip",
  ]

  /// This user's processes. Other users' processes can't be inspected and are left out.
  public static func current() -> [ActiveProcess] {
    let capacity = proc_listallpids(nil, 0)
    guard capacity > 0 else { return [] }
    var pids = [pid_t](repeating: 0, count: Int(capacity) + 64)
    let count = pids.withUnsafeMutableBufferPointer {
      proc_listallpids($0.baseAddress, Int32($0.count * MemoryLayout<pid_t>.stride))
    }
    guard count > 0 else { return [] }
    let me = geteuid()
    var result: [ActiveProcess] = []
    for pid in pids.prefix(Int(count)) where pid > 0 {
      var info = proc_bsdinfo()
      let infoSize = Int32(MemoryLayout<proc_bsdinfo>.stride)
      guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, infoSize) == infoSize, info.pbi_uid == me else { continue }
      var nameBuffer = [CChar](repeating: 0, count: Int(MAXCOMLEN) * 2 + 1)
      _ = proc_name(pid, &nameBuffer, UInt32(nameBuffer.count))
      let name = String(cString: nameBuffer)
      result.append(ActiveProcess(pid: pid, name: name, workingDirectory: workingDirectory(of: pid)))
    }
    return result
  }

  private static func workingDirectory(of pid: pid_t) -> String? {
    var info = proc_vnodepathinfo()
    let size = Int32(MemoryLayout<proc_vnodepathinfo>.stride)
    guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
    let path = withUnsafeBytes(of: &info.pvi_cdir.vip_path) { raw -> String in
      String(cString: raw.bindMemory(to: CChar.self).baseAddress!)
    }
    return path.isEmpty ? nil : path
  }

  /// Tools that write Xcode's DerivedData while they run, from any folder.
  public static let xcodeBuildToolNames: Set<String> = ["xcodebuild", "XCBBuildService", "swift-frontend", "ibtool", "actool"]

  /// Why moving `url` now could break something that is running, or nil when nothing is.
  /// - A process working inside the folder blocks it.
  /// - For a project's build output or installed packages, a build tool or runtime working in
  ///   that project blocks it (a Node server runs from the project, not from node_modules).
  /// - For Xcode's DerivedData, a running Xcode build tool blocks it wherever it runs.
  public static func conflict(
    for url: URL, projectFolder: URL? = nil, xcodeBuildData: Bool = false, processes: [ActiveProcess]
  ) -> String? {
    func isInside(_ process: ActiveProcess, _ folder: URL) -> Bool {
      guard let cwd = process.workingDirectory else { return false }
      let path = FileSystem.comparisonPath(URL(fileURLWithPath: cwd))
      let root = FileSystem.comparisonPath(folder)
      return path == root || path.hasPrefix(root.hasSuffix("/") ? root : root + "/")
    }
    if let inside = processes.first(where: { isInside($0, url) }) {
      return "\(inside.name) is working inside this folder right now. Try again when it's finished."
    }
    if let projectFolder, let tool = processes.first(where: { buildToolNames.contains($0.name) && isInside($0, projectFolder) }) {
      return "\(tool.name) is running in this project and may be using it. Try again when it's finished."
    }
    if xcodeBuildData, let tool = processes.first(where: { xcodeBuildToolNames.contains($0.name) }) {
      return "\(tool.name) is running and may be writing build data. Try again when it's finished."
    }
    return nil
  }
}
