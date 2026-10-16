import AppKit
import Foundation
import MacCleanerCore

extension AppViewModel {
  private static let preferredFoldersKey = "co.macmint.duplicatePreferredFolders"

  var duplicatePreferredFolders: [URL] {
    get {
      (UserDefaults.standard.stringArray(forKey: Self.preferredFoldersKey) ?? []).map { URL(fileURLWithPath: $0) }
    }
    set {
      UserDefaults.standard.set(newValue.map(\.path), forKey: Self.preferredFoldersKey)
      objectWillChange.send()
    }
  }

  /// Selects every copy except one per group, chosen by `rule`. Nothing moves until review.
  func autoSelectDuplicates(_ rule: DuplicateKeeperRule) {
    if rule == .preferredFolder, duplicatePreferredFolders.isEmpty {
      choosePreferredDuplicateFolder()
      guard !duplicatePreferredFolders.isEmpty else { return }
    }
    selectedDuplicateIDs = DuplicateKeeper.copiesToSelect(
      in: duplicateGroups, rule: rule, preferredFolders: duplicatePreferredFolders)
    statusMessage = "\(rule.rawValue): \(selectedDuplicateIDs.count) copies selected for review"
  }

  func choosePreferredDuplicateFolder() {
    guard let url = chooseFolder(prompt: "Choose a folder whose copies you always want to keep") else { return }
    if !duplicatePreferredFolders.contains(url) { duplicatePreferredFolders.append(url) }
  }
}
