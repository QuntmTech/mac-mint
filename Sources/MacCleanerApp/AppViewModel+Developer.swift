import AppKit
import Foundation
import MacCleanerCore

extension AppViewModel {
  private static let projectRootsKey = "co.macmint.devProjectRoots"

  var devProjectRoots: [URL] {
    get {
      (UserDefaults.standard.stringArray(forKey: Self.projectRootsKey) ?? [])
        .map { URL(fileURLWithPath: $0) }
    }
    set {
      UserDefaults.standard.set(newValue.map(\.path), forKey: Self.projectRootsKey)
      objectWillChange.send()
    }
  }

  var queuedDevItems: [DevStorageItem] { devItems.filter { selectedDevIDs.contains($0.id) && $0.canTrash } }

  func scanDeveloper() {
    guard !isScanning, !isWorking else { return }
    beginScan(title: "Developer & AI", message: "Inventorying Xcode, package caches, and AI models…")
    let roots = devProjectRoots
    let scanner = DeveloperStorageScanner()

    currentTask = Task { [weak self] in
      guard let self else { return }
      let report = await scanner.scan(projectRoots: roots)
      guard !Task.isCancelled else {
        finishCancelledOperation()
        return
      }
      devItems = report.value
      selectedDevIDs = Set(report.value.filter(\.isSuggested).map(\.id))
      scanIssues = report.issues
      lastScanDuration = report.duration
      let total = report.value.reduce(Int64(0)) { $0 + $1.bytes }
      finishScan(message: "Found \(ByteFormatter.string(total)) of developer and AI data")
    }
  }

  func addProjectFolder() {
    guard let url = chooseFolder(prompt: "Choose a folder that contains your code projects") else { return }
    if !devProjectRoots.contains(url) { devProjectRoots.append(url) }
    scanDeveloper()
  }

  func removeProjectFolder(_ url: URL) {
    devProjectRoots.removeAll { $0 == url }
    devItems.removeAll { item in
      item.group == .projects && item.url.map { FileSystem.path($0, isInsideOrEqual: url) } == true
    }
    selectedDevIDs.formIntersection(devItems.map(\.id))
  }

  func reviewDeveloper() {
    let plan = OperationPlanner.plan(
      title: "Developer & AI cleanup", items: queuedDevItems.compactMap(PlanItem.developer),
      ignoredPaths: ignoredPaths)
    guard !isWorking, !isScanning, !plan.isEmpty || !plan.excluded.isEmpty else { return }
    pendingPlan = plan
  }

  func copyCommand(_ command: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(command, forType: .string)
    statusMessage = "Copied “\(command)” — paste it into Terminal"
  }
}
