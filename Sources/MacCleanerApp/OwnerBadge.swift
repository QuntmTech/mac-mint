import AppKit
import MacCleanerCore
import SwiftUI

/// Installed app (name + icon) for an owner hint, cached per bundle identifier.
@MainActor
enum OwnerDirectory {
  struct Owner {
    let name: String
    let icon: NSImage?
  }

  private static var cache: [String: Owner?] = [:]

  static var count: Int { cache.count }
  static func removeAll() { cache.removeAll() }

  static func owner(for hint: OwnerHint?) -> Owner? {
    guard let hint else { return nil }
    if let id = hint.bundleID {
      if let cached = cache[id] { return cached ?? hint.displayName.map { Owner(name: $0, icon: nil) } }
      var resolved: Owner?
      if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
        resolved = Owner(
          name: FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: ""),
          icon: FileIcons.icon(forPath: url.path))
      }
      cache[id] = resolved
      if let resolved { return resolved }
    }
    return hint.displayName.map { Owner(name: $0, icon: nil) }
  }
}

/// App icon for an item's owner, falling back to a symbol.
struct OwnerIcon: View {
  let hint: OwnerHint?
  let fallbackSymbol: String
  var size: CGFloat = 34

  var body: some View {
    if let icon = OwnerDirectory.owner(for: hint)?.icon {
      Image(nsImage: icon)
        .resizable()
        .interpolation(.high)
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    } else {
      ZStack {
        RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
          .fill(AppTheme.accent.opacity(0.08))
          .frame(width: size, height: size)
        Image(systemName: fallbackSymbol)
          .foregroundStyle(AppTheme.accentText)
      }
      .accessibilityHidden(true)
    }
  }
}
