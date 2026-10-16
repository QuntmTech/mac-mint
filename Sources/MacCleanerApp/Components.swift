import MacCleanerCore
import SwiftUI

struct AppTheme {
  static let corner: CGFloat = 16
  static let cardPadding: CGFloat = 20
  static let pagePadding: CGFloat = 28
  // White labels on this fill meet WCAG AA in both appearances.
  static let accent = Color(red: 0.016, green: 0.471, blue: 0.341)
  static let brand = Color(red: 0.063, green: 0.725, blue: 0.506)
  static let accentText = adaptive("AccentText", light: 0x047857, dark: 0x60DDAA)
  static let canvas = adaptive("Canvas", light: 0xF5F7F6, dark: 0x141917)
  static let surface = adaptive("Surface", light: 0xFFFFFF, dark: 0x1D2421)
  static let panel = adaptive("Panel", light: 0xEDF1EF, dark: 0x252E29)
  static let elevated = adaptive("Elevated", light: 0xFFFFFF, dark: 0x2B352F)
  static let sidebar = adaptive("Sidebar", light: 0xECF1EE, dark: 0x171E1A)
  static let ink = adaptive("Ink", light: 0x1E3429, dark: 0xEDF5EF)
  static let border = adaptive("Border", light: 0xDCE5DF, dark: 0x38463D)
  static let selection = adaptive("Selection", light: 0xD9EDE2, dark: 0x253F31)
  static let hero = adaptive("Hero", light: 0xE5F2EA, dark: 0x20382A)

  private static func adaptive(_ name: String, light: UInt32, dark: UInt32) -> Color {
    Color(nsColor: NSColor(name: "MacMint" + name) { appearance in
      let hex = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
      return NSColor(srgbRed: Double((hex >> 16) & 255) / 255,
        green: Double((hex >> 8) & 255) / 255, blue: Double(hex & 255) / 255, alpha: 1)
    })
  }
}

struct SurfaceCard<Content: View>: View {
  let content: Content
  @Environment(\.accessibilityContrast) private var contrast
  init(@ViewBuilder content: () -> Content) { self.content = content() }
  var body: some View {
    content.padding(AppTheme.cardPadding)
      .background(AppTheme.surface, in: RoundedRectangle(cornerRadius: AppTheme.corner))
      .overlay(RoundedRectangle(cornerRadius: AppTheme.corner)
        .strokeBorder(contrast == .increased ? Color.primary.opacity(0.45) : AppTheme.border))
  }
}

struct MetricCard: View {
  let title: String
  let value: String
  let subtitle: String
  let icon: String
  var action: (() -> Void)? = nil

  var body: some View {
    if let action {
      Button(action: action) { card }.buttonStyle(.plain)
        .help("Open " + title).accessibilityElement(children: .combine)
    } else { card.accessibilityElement(children: .combine) }
  }

  private var card: some View {
    SurfaceCard {
      VStack(alignment: .leading, spacing: 12) {
        HStack {
          IconTile(symbol: icon, size: 34)
          Spacer()
          if action != nil { Image(systemName: "arrow.up.right").font(.caption).foregroundStyle(.secondary) }
        }
        Text(value).font(.system(size: 28, weight: .semibold)).tracking(-0.8)
          .monospacedDigit().lineLimit(1).minimumScaleFactor(0.7).foregroundStyle(AppTheme.ink)
        VStack(alignment: .leading, spacing: 4) {
          Text(title).font(.system(size: 13, weight: .semibold))
          Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            .fixedSize(horizontal: false, vertical: true)
        }
      }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
    }
  }
}

struct RiskBadge: View {
  let risk: CleanupRisk

  var body: some View {
    Label(title, systemImage: icon)
      .font(.caption2.weight(.semibold))
      .labelStyle(.titleAndIcon)
      .padding(.horizontal, 8)
      .padding(.vertical, 4)
      .foregroundStyle(color)
      .background(color.opacity(0.12), in: Capsule())
  }

  private var title: String {
    switch risk {
    case .safe: return "Rebuildable"
    case .review: return "Review"
    case .restricted: return "Protected"
    }
  }

  private var icon: String {
    switch risk {
    case .safe: return "checkmark.shield.fill"
    case .review: return "eye.fill"
    case .restricted: return "lock.fill"
    }
  }

  private var color: Color {
    switch risk {
    case .safe: return .green
    case .review: return .orange
    case .restricted: return .red
    }
  }
}

struct EmptyState: View {
  let icon: String
  let title: String
  let detail: String
  var actionTitle: String? = nil
  var action: (() -> Void)? = nil

  var body: some View {
    VStack(spacing: 14) {
      Image(systemName: icon).font(.system(size: 30, weight: .light))
        .foregroundStyle(AppTheme.accentText).frame(width: 76, height: 76)
        .background(AppTheme.selection.opacity(0.65), in: RoundedRectangle(cornerRadius: 24))
        .accessibilityHidden(true)
      Text(title).font(.system(size: 21, weight: .semibold)).foregroundStyle(AppTheme.ink)
      Text(detail).font(.callout).foregroundStyle(.secondary)
        .multilineTextAlignment(.center).frame(maxWidth: 390)
        .fixedSize(horizontal: false, vertical: true)
      if let actionTitle, let action {
        Button(actionTitle, action: action).buttonStyle(MintButtonStyle()).padding(.top, 6)
      }
    }
    .padding(32).frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}

struct StorageRing: View {
  let used: Int64
  let total: Int64
  let centerValue: String
  let centerLabel: String
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  private var fraction: Double {
    guard total > 0 else { return 0 }
    return min(1, max(0, Double(used) / Double(total)))
  }

  var body: some View {
    ZStack {
      Circle()
        .stroke(AppTheme.accentText.opacity(0.13), lineWidth: 12)
      Circle()
        .trim(from: 0, to: fraction)
        .stroke(AppTheme.accentText, style: StrokeStyle(lineWidth: 12, lineCap: .round))
        .rotationEffect(.degrees(-90))
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.35), value: fraction)
      VStack(spacing: 2) {
        Text(centerValue)
          .font(.system(size: 27, weight: .semibold))
          .monospacedDigit()
        Text(centerLabel)
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
    .frame(width: 148, height: 148)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("Storage usage")
    .accessibilityValue("\(Int(fraction * 100)) percent used")
  }
}

struct StatusPill: View {
  let title: String
  let icon: String
  var tint: Color = .gray

  var body: some View {
    Label(title, systemImage: icon)
      .font(.caption.weight(.medium))
      .foregroundStyle(tint)
      .padding(.horizontal, 10)
      .padding(.vertical, 6)
      .background(tint.opacity(0.10), in: Capsule())
  }
}

struct ScanIssueSheet: View {
  let issues: [ScanIssue]
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack {
        VStack(alignment: .leading, spacing: 3) {
          Text("Scan details").font(.title2.bold())
          Text("These items were skipped or could not be inspected. No protection was bypassed.")
            .font(.callout)
            .foregroundStyle(.secondary)
        }
        Spacer()
        Button("Done") { dismiss() }
          .keyboardShortcut(.defaultAction)
      }
      .padding(22)
      Divider()
      if issues.isEmpty {
        EmptyState(
          icon: "checkmark.circle", title: "No scan issues",
          detail: "The last scan completed without reported filesystem access problems.")
      } else {
        List(issues) { issue in
          HStack(alignment: .top, spacing: 12) {
            Image(systemName: issueIcon(issue.severity))
              .foregroundStyle(issueColor(issue.severity))
              .frame(width: 18)
            VStack(alignment: .leading, spacing: 3) {
              Text(issue.area).fontWeight(.semibold)
              Text(issue.message).font(.callout)
              if let path = issue.path {
                Text(path).font(.caption2).foregroundStyle(.secondary).textSelection(.enabled)
              }
            }
          }
          .padding(.vertical, 4)
        }
      }
    }
    .frame(minWidth: 620, minHeight: 420)
    .onExitCommand { dismiss() }
  }

  private func issueIcon(_ severity: ScanIssueSeverity) -> String {
    switch severity {
    case .info: return "info.circle.fill"
    case .warning: return "exclamationmark.triangle.fill"
    case .error: return "xmark.octagon.fill"
    }
  }

  private func issueColor(_ severity: ScanIssueSeverity) -> Color {
    switch severity {
    case .info: return .blue
    case .warning: return .orange
    case .error: return .red
    }
  }
}
