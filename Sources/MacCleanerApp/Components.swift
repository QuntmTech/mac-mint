import MacCleanerCore
import SwiftUI

struct AppTheme {
  static let corner: CGFloat = 18
  static let cardPadding: CGFloat = 18
  static let pagePadding: CGFloat = 26

  /// Fills, tints, and selection (#047857). White text on it is 5.5:1 (WCAG AA).
  static let accent = Color(red: 0.016, green: 0.471, blue: 0.341)
  /// Mint for text and icons on window backgrounds: #047857 in light mode (4.6:1),
  /// #34D399 in dark mode (6.7:1+).
  static let accentText = Color(
    nsColor: NSColor(name: "MacMintAccentText") { appearance in
      appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        ? NSColor(srgbRed: 0.204, green: 0.827, blue: 0.600, alpha: 1)
        : NSColor(srgbRed: 0.016, green: 0.471, blue: 0.341, alpha: 1)
    })
  /// Brand mint (#10B981) for gradients and illustration only — never for text.
  static let brand = Color(red: 0.063, green: 0.725, blue: 0.506)
  static var panel: Color { Color(nsColor: .controlBackgroundColor).opacity(0.72) }
  static var elevated: Color { Color(nsColor: .windowBackgroundColor).opacity(0.88) }
  static var border: Color { Color.primary.opacity(0.08) }
}

struct SurfaceCard<Content: View>: View {
  let content: Content

  init(@ViewBuilder content: () -> Content) {
    self.content = content()
  }

  var body: some View {
    content
      .padding(AppTheme.cardPadding)
      .background(
        RoundedRectangle(cornerRadius: AppTheme.corner, style: .continuous)
          .fill(.regularMaterial)
          .overlay(
            RoundedRectangle(cornerRadius: AppTheme.corner, style: .continuous)
              .stroke(AppTheme.border, lineWidth: 1)
          )
      )
  }
}

struct MetricCard: View {
  let title: String
  let value: String
  let subtitle: String
  let icon: String
  var action: (() -> Void)? = nil

  var body: some View {
    SurfaceCard {
      VStack(alignment: .leading, spacing: 12) {
        HStack {
          ZStack {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
              .fill(AppTheme.accent.opacity(0.12))
              .frame(width: 38, height: 38)
            Image(systemName: icon)
              .font(.system(size: 17, weight: .semibold))
              .foregroundStyle(AppTheme.accentText)
          }
          Spacer()
          if action != nil {
            Image(systemName: "chevron.right")
              .font(.caption.bold())
              .foregroundStyle(.tertiary)
          }
        }
        Text(value)
          .font(.system(size: 28, weight: .bold, design: .rounded))
          .monospacedDigit()
          .lineLimit(1)
          .minimumScaleFactor(0.6)
        Text(title).font(.headline)
        Text(subtitle)
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(3)
          .fixedSize(horizontal: false, vertical: true)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .contentShape(Rectangle())
      .onTapGesture { action?() }
      .accessibilityElement(children: .combine)
      .accessibilityAddTraits(action == nil ? [] : .isButton)
      .accessibilityAction { action?() }
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
    case .safe: return "Safe"
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

  var body: some View {
    ContentUnavailableView(title, systemImage: icon, description: Text(detail))
      .frame(maxWidth: .infinity, maxHeight: .infinity)
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
        .stroke(AppTheme.accent.opacity(0.12), lineWidth: 14)
      Circle()
        .trim(from: 0, to: fraction)
        .stroke(AppTheme.accent, style: StrokeStyle(lineWidth: 14, lineCap: .round))
        .rotationEffect(.degrees(-90))
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.35), value: fraction)
      VStack(spacing: 2) {
        Text(centerValue)
          .font(.system(size: 22, weight: .bold, design: .rounded))
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
