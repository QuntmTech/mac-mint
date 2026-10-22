import MacCleanerCore
import SwiftUI

struct AppTheme {
  static let corner: CGFloat = 16
  static let cardPadding: CGFloat = 20
  static let pagePadding: CGFloat = 28
  // White labels on this fill meet WCAG AA in both appearances.
  static let accent = Color(red: 0.016, green: 0.471, blue: 0.341)
  static let brand = Color(red: 0.063, green: 0.725, blue: 0.506)
  static let accentText = adaptive("AccentText", light: 0x046F50, dark: 0x60DDAA)
  static let canvas = adaptive("Canvas", light: 0xF7F7F8, dark: 0x141416)
  static let surface = adaptive("Surface", light: 0xFFFFFF, dark: 0x1D1D20)
  static let panel = adaptive("Panel", light: 0xEEEEF0, dark: 0x26262A)
  static let elevated = adaptive("Elevated", light: 0xFFFFFF, dark: 0x2E2E33)
  static let sidebar = adaptive("Sidebar", light: 0xF0F0F2, dark: 0x18181B)
  static let ink = adaptive("Ink", light: 0x202124, dark: 0xF1F1F3)
  static let border = adaptive("Border", light: 0xDFDFE3, dark: 0x3A3A40)
  static let selection = adaptive("Selection", light: 0xE5E5E9, dark: 0x303036)
  static let warning = adaptive("Warning", light: 0x915000, dark: 0xF5BC67)
  static let danger = adaptive("Danger", light: 0xB33430, dark: 0xFF958D)
  static let info = adaptive("Info", light: 0x1C65A6, dark: 0x8AC4F4)
  static let violet = adaptive("Violet", light: 0x754B9B, dark: 0xCBB0EF)
  /// The Overview hero's soft wash: mint into sky into lavender, deep tones in Dark Mode.
  static let heroStart = adaptive("HeroStart", light: 0xE4F7EE, dark: 0x0F2B25)
  static let heroMiddle = adaptive("HeroMiddle", light: 0xE8F1FD, dark: 0x132238)
  static let heroEnd = adaptive("HeroEnd", light: 0xF0EBFD, dark: 0x1E1B3A)

  /// One color per area of the app, used for its sidebar badge, tiles and icons. White
  /// labels meet WCAG AA (at least 4.5:1) on both stops of every swatch.
  struct Swatch: Equatable, Sendable {
    let start: Color
    let end: Color
    var color: Color { start }
    var gradient: LinearGradient {
      LinearGradient(colors: [start, end], startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    static let mint = Swatch(start: rgb(0x047857), end: rgb(0x0F766E))
    static let sky = Swatch(start: rgb(0x0369A1), end: rgb(0x1D4ED8))
    static let indigo = Swatch(start: rgb(0x4F46E5), end: rgb(0x7C3AED))
    static let violet = Swatch(start: rgb(0x7C3AED), end: rgb(0xC026D3))
    static let pink = Swatch(start: rgb(0xDB2777), end: rgb(0xE11D48))
    static let orange = Swatch(start: rgb(0xC2410C), end: rgb(0xB45309))
    static let amber = Swatch(start: rgb(0xB45309), end: rgb(0xA16207))
    static let slate = Swatch(start: rgb(0x475569), end: rgb(0x334155))
    static let graphite = Swatch(start: rgb(0x52525B), end: rgb(0x3F3F46))
    static let iris = Swatch(start: rgb(0x6D28D9), end: rgb(0x2563EB))
    static let teal = Swatch(start: rgb(0x0F766E), end: rgb(0x0E7490))
    static let rose = Swatch(start: rgb(0xBE123C), end: rgb(0x9F1239))

    private static func rgb(_ hex: UInt32) -> Color {
      Color(.sRGB, red: Double((hex >> 16) & 255) / 255, green: Double((hex >> 8) & 255) / 255,
        blue: Double(hex & 255) / 255)
    }
  }

  private static func adaptive(_ name: String, light: UInt32, dark: UInt32) -> Color {
    Color(nsColor: NSColor(name: "MacMint" + name) { appearance in
      let hex = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
      return NSColor(srgbRed: Double((hex >> 16) & 255) / 255,
        green: Double((hex >> 8) & 255) / 255, blue: Double(hex & 255) / 255, alpha: 1)
    })
  }
}

extension AppViewModel.Section {
  /// Tabs share their workspace's color, so a page always matches its sidebar badge.
  var swatch: AppTheme.Swatch {
    switch parent {
    case .dashboard, .review: return .mint
    case .cleaner: return .sky
    case .storage: return .indigo
    case .applications: return .violet
    case .photos: return .pink
    case .developer: return .orange
    case .assistant: return .iris
    case .history: return .slate
    default: return .graphite
    }
  }
}

/// A System Settings–style badge: a white glyph on its area's color.
struct SwatchBadge: View {
  let symbol: String
  let swatch: AppTheme.Swatch
  var size: CGFloat = 24

  var body: some View {
    let shape = RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
    Image(systemName: symbol).font(.system(size: size * 0.46, weight: .semibold))
      .foregroundStyle(.white).frame(width: size, height: size)
      .background(swatch.gradient, in: shape)
      .overlay(shape.strokeBorder(Color.white.opacity(0.18), lineWidth: 0.5))
      .shadow(color: swatch.color.opacity(0.25), radius: 1.5, y: 1)
      .accessibilityHidden(true)
  }
}

struct SurfaceCard<Content: View>: View {
  let content: Content
  @Environment(\.colorSchemeContrast) private var contrast
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
  var swatch: AppTheme.Swatch? = nil
  var action: (() -> Void)? = nil

  var body: some View {
    if let action {
      Button(action: action) { card }.buttonStyle(CardButtonStyle())
        .help("Open " + title).accessibilityElement(children: .combine)
    } else { card.accessibilityElement(children: .combine) }
  }

  private var card: some View {
    SurfaceCard {
      VStack(alignment: .leading, spacing: 12) {
        HStack {
          IconTile(symbol: icon, size: 34, swatch: swatch)
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
    case .safe: return AppTheme.accentText
    case .review: return AppTheme.warning
    case .restricted: return AppTheme.danger
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
      Text(title).font(.system(size: 21, weight: .semibold)).foregroundStyle(AppTheme.ink).accessibilityAddTraits(.isHeader)
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

/// What a page shows while its first results are on the way, instead of an empty list: what
/// is happening, how far along it is when that's known, and placeholder rows in the shape of
/// the results. The only motion is the system spinner, so it costs next to nothing to show.
struct LoadingState: View {
  let title: String
  let detail: String
  var symbol = "magnifyingglass"
  var swatch: AppTheme.Swatch = .mint
  /// 0...1 when the amount of work is known.
  var progress: Double? = nil
  /// Extra line under the detail, such as "42 of 180 apps".
  var status: String? = nil
  var rows = 5
  var cancel: (() -> Void)? = nil

  private static let titleWidths: [CGFloat] = [180, 140, 210, 120, 160]
  private static let detailWidths: [CGFloat] = [90, 120, 70, 110, 80]

  var body: some View {
    VStack(spacing: 18) {
      HStack(spacing: 14) {
        SwatchBadge(symbol: symbol, swatch: swatch, size: 40)
        VStack(alignment: .leading, spacing: 4) {
          HStack(spacing: 8) {
            Text(title).font(.system(size: 17, weight: .semibold)).foregroundStyle(AppTheme.ink)
            ProgressView().controlSize(.small)
          }
          Text(detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
          if let status {
            Text(status).font(.caption).foregroundStyle(.secondary).monospacedDigit()
          }
        }
        .accessibilityElement(children: .combine)
        Spacer(minLength: 0)
        if let cancel { Button("Cancel", action: cancel).controlSize(.small) }
      }
      if let progress {
        ProgressView(value: min(1, max(0, progress))).tint(swatch.color)
      }
      VStack(spacing: 10) {
        ForEach(0..<rows, id: \.self) { row in
          HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 8).fill(AppTheme.panel).frame(width: 34, height: 34)
            VStack(alignment: .leading, spacing: 6) {
              Capsule().fill(AppTheme.panel).frame(width: Self.titleWidths[row % 5], height: 9)
              Capsule().fill(AppTheme.panel.opacity(0.7)).frame(width: Self.detailWidths[row % 5], height: 7)
            }
            Spacer()
            Capsule().fill(AppTheme.panel).frame(width: 54, height: 9)
          }
          .opacity(1 - Double(row) * 0.14)
        }
      }
      .accessibilityHidden(true)
    }
    .padding(24)
    .frame(maxWidth: 620)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    .padding(.top, 24)
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
      // Mint into teal into blue along the used arc.
      Circle()
        .trim(from: 0, to: fraction)
        .stroke(AngularGradient(colors: [AppTheme.brand, Color(red: 0.05, green: 0.58, blue: 0.53), Color(red: 0.15, green: 0.39, blue: 0.92)],
          // Starting a little before 12 o'clock keeps the rounded start cap mint, not the end color.
          center: .center, startAngle: .degrees(-10), endAngle: .degrees(360 * max(fraction, 0.01))),
          style: StrokeStyle(lineWidth: 12, lineCap: .round))
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
    .accessibilityValue(total > 0
      ? "\(Int(fraction * 100)) percent used. \(centerValue) \(centerLabel). \(ByteFormatter.string(used)) of \(ByteFormatter.string(total)) used."
      : "Disk space unavailable")
  }
}

struct StatusPill: View {
  let title: String
  let icon: String
  var tint: Color = .secondary

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
  @State private var showingAccessHelp = false

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
      if !issues.isEmpty {
        Divider()
        HStack {
          Text("Access denied? Review the permission guide, then rescan.")
            .font(.caption).foregroundStyle(.secondary)
          Spacer()
          Button("Access Help…") { showingAccessHelp = true }
        }
        .padding(16)
      }
    }
    .frame(minWidth: 620, minHeight: 420)
    .sheet(isPresented: $showingAccessHelp) { PermissionHelpSheet() }
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
    case .info: return AppTheme.info
    case .warning: return AppTheme.warning
    case .error: return AppTheme.danger
    }
  }
}
