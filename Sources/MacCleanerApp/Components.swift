import MacCleanerCore
import SwiftUI

struct AppTheme {
  static let corner: CGFloat = 16
  static let cardPadding: CGFloat = 18
  static let pagePadding: CGFloat = 26
  static let pageTopPadding: CGFloat = 20
  // White labels on this fill meet WCAG AA in both appearances.
  static let accent = hex(0x047857)
  /// The lighter top stop of commit buttons (mint gradient #0A8A63 → #047857).
  static let accentTop = hex(0x0A8A63)
  /// Decorative mint only (icons, chart lines); never text.
  static let brand = adaptive("Brand", light: 0x10B981, dark: 0x34D399)
  static let accentText = adaptive("AccentText", light: 0x04704F, dark: 0x5EE0AE)

  // Neutrals carry a slight mint tint; Dark Mode is a deep green-black rather than grey.
  static let canvas = adaptive("Canvas", light: 0xF5F7F6, dark: 0x0F1412)
  static let sidebar = adaptive("Sidebar", light: 0xEAF0ED, dark: 0x131A17)
  static let surface = adaptive("Surface", light: 0xFFFFFF, dark: 0x171E1B)
  static let elevated = adaptive("Elevated", light: 0xFFFFFF, dark: 0x1F2724)
  static let panel = adaptive("Panel", light: 0xEEF2F0, dark: 0x212A26)
  static let panel2 = adaptive("Panel2", light: 0xE3E9E6, dark: 0x2A342F)
  static let track = adaptive("Track", light: 0xE5EBE8, dark: 0x2A332F)
  static let border = adaptive("Border", light: 0xDCE3E0, dark: 0x2B3531)
  static let borderStrong = adaptive("BorderStrong", light: 0xC7D0CC, dark: 0x3A4641)
  static let divider = adaptive("Divider", light: 0xE6EBE9, dark: 0x222B27)
  static let selection = adaptive("Selection", light: 0xE0F1E9, dark: 0x163A2E)
  static let ink = adaptive("Ink", light: 0x15201B, dark: 0xEDF3F0)
  /// Secondary text.
  static let ink2 = adaptive("Ink2", light: 0x4E5A55, dark: 0xAAB5B0)
  /// Tertiary text: captions and counts on canvas, surface and the sidebar.
  static let ink3 = adaptive("Ink3", light: 0x5F6A65, dark: 0x85918C)

  static let success = accentText
  static let successTint = adaptive("SuccessTint", light: 0xE2F5EC, dark: 0x0F2A20)
  static let warning = adaptive("Warning", light: 0x925300, dark: 0xF5BC67)
  static let warningTint = adaptive("WarningTint", light: 0xFBEFD9, dark: 0x2C2210)
  static let danger = adaptive("Danger", light: 0xB42318, dark: 0xFF8F86)
  static let dangerTint = adaptive("DangerTint", light: 0xFDE8E6, dark: 0x351715)
  /// Destructive buttons only; white labels.
  static let dangerFill = adaptive("DangerFill", light: 0xC2352A, dark: 0xD2392E)
  static let info = adaptive("Info", light: 0x0B5FA5, dark: 0x86C3F4)
  static let infoTint = adaptive("InfoTint", light: 0xE3F0FB, dark: 0x0E2131)
  static let violet = adaptive("Violet", light: 0x6D28D9, dark: 0xCDB0FA)

  /// Overview's hero: deep mint into teal into indigo, with white type in both appearances.
  static let heroStops: [Color] = [hex(0x05523D), hex(0x047857), hex(0x0E7490), hex(0x3B3AB8)]
  static var heroGradient: LinearGradient {
    LinearGradient(colors: heroStops, startPoint: .topLeading, endPoint: .bottomTrailing)
  }
  /// Commit actions (Add to Review, Final Check, Move to Trash, Done).
  static var commitGradient: LinearGradient {
    LinearGradient(colors: [accentTop, accent], startPoint: .top, endPoint: .bottom)
  }

  /// SF Rounded for every number: sizes, percentages and counts.
  static func number(_ size: CGFloat, weight: Font.Weight = .bold) -> Font {
    .system(size: size, weight: weight, design: .rounded)
  }

  /// One color per area of the app: its sidebar badge, page header, wash, tiles and primary
  /// button. White labels meet WCAG AA (at least 4.5:1) on both gradient stops; `text` meets
  /// it on `tint`, canvas and surface.
  struct Swatch: Equatable, Sendable {
    let name: String
    let start: Color
    let end: Color
    /// A soft wash for page backgrounds and chips.
    let tint: Color
    /// The area's foreground on its tint, the canvas and surfaces.
    let text: Color
    var color: Color { start }
    var gradient: LinearGradient {
      LinearGradient(colors: [start, end], startPoint: .topLeading, endPoint: .bottomTrailing)
    }
    /// Top-to-bottom, for buttons.
    var fill: LinearGradient {
      LinearGradient(colors: [start, end], startPoint: .top, endPoint: .bottom)
    }
    static func == (lhs: Swatch, rhs: Swatch) -> Bool { lhs.name == rhs.name }

    private init(_ name: String, _ start: UInt32, _ end: UInt32, tint: (UInt32, UInt32), text: (UInt32, UInt32)) {
      self.name = name
      self.start = AppTheme.hex(start)
      self.end = AppTheme.hex(end)
      self.tint = AppTheme.adaptive(name + "Tint", light: tint.0, dark: tint.1)
      self.text = AppTheme.adaptive(name + "Text", light: text.0, dark: text.1)
    }

    static let mint = Swatch("Mint", 0x047857, 0x0F766E, tint: (0xE2F5EC, 0x0F2A20), text: (0x04704F, 0x5EE0AE))
    static let sky = Swatch("Sky", 0x0369A1, 0x1D4ED8, tint: (0xE3F0FB, 0x0E2131), text: (0x075E97, 0x7CC3F2))
    static let indigo = Swatch("Indigo", 0x4F46E5, 0x6D28D9, tint: (0xECEBFD, 0x1A1A3A), text: (0x4338CA, 0xA9ABFF))
    static let violet = Swatch("Violet", 0x7C3AED, 0xA21CAF, tint: (0xF2E9FE, 0x23173A), text: (0x6D28D9, 0xCDB0FA))
    static let pink = Swatch("Pink", 0xDB2777, 0xE11D48, tint: (0xFCE7F0, 0x33141F), text: (0xBE185D, 0xF9A0C6))
    static let orange = Swatch("Orange", 0xC2410C, 0xB45309, tint: (0xFDEDE2, 0x33190D), text: (0xB13C0A, 0xFDB48A))
    static let amber = Swatch("Amber", 0xB45309, 0xA16207, tint: (0xFBF0DA, 0x2E220C), text: (0x925300, 0xF5C46C))
    static let slate = Swatch("Slate", 0x475569, 0x334155, tint: (0xEBEFF3, 0x1C2329), text: (0x475569, 0xAEBBCB))
    static let graphite = Swatch("Graphite", 0x52525B, 0x3F3F46, tint: (0xEEEEF0, 0x232326), text: (0x52525B, 0xB9B9C2))
    static let iris = Swatch("Iris", 0x6D28D9, 0x2563EB, tint: (0xEDEAFE, 0x1C1838), text: (0x5B34D6, 0xB7A6FF))
    static let teal = Swatch("Teal", 0x0F766E, 0x0E7490, tint: (0xE0F4F2, 0x0E2626), text: (0x0F6F68, 0x6FDCD2))
    static let rose = Swatch("Rose", 0xBE123C, 0x9F1239, tint: (0xFDE6EA, 0x331219), text: (0xB4123A, 0xFF9FB0))
    static let all: [Swatch] = [.mint, .sky, .indigo, .violet, .pink, .orange, .amber, .slate, .graphite, .iris, .teal, .rose]
  }

  static func hex(_ value: UInt32) -> Color {
    Color(.sRGB, red: Double((value >> 16) & 255) / 255, green: Double((value >> 8) & 255) / 255,
      blue: Double(value & 255) / 255)
  }

  static func adaptive(_ name: String, light: UInt32, dark: UInt32) -> Color {
    Color(nsColor: NSColor(name: "MacMint" + name) { appearance in
      let hex = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
      return NSColor(srgbRed: Double((hex >> 16) & 255) / 255,
        green: Double((hex >> 8) & 255) / 255, blue: Double(hex & 255) / 255, alpha: 1)
    })
  }
}

extension AppViewModel.Section {
  /// Tabs share their workspace's color, except Performance (live activity, sky) and
  /// Downloads (teal), so those tabs read apart from the page beside them.
  var swatch: AppTheme.Swatch {
    switch self {
    case .performance: return .sky
    case .downloads: return .teal
    default: break
    }
    switch parent {
    case .dashboard, .review: return .mint
    case .cleaner: return .sky
    case .storage: return .indigo
    case .applications: return .violet
    case .photos: return .pink
    case .developer: return .orange
    case .assistant: return .iris
    case .history, .settings: return .slate
    default: return .graphite
    }
  }
}

private struct AreaSwatchKey: EnvironmentKey { static let defaultValue = AppTheme.Swatch.mint }
private struct AreaSymbolKey: EnvironmentKey { static let defaultValue = "leaf.fill" }

extension EnvironmentValues {
  /// The color of the page being shown: its header badge, wash, primary buttons and empty states.
  var areaSwatch: AppTheme.Swatch {
    get { self[AreaSwatchKey.self] }
    set { self[AreaSwatchKey.self] = newValue }
  }
  /// The page's symbol, for its header badge.
  var areaSymbol: String {
    get { self[AreaSymbolKey.self] }
    set { self[AreaSymbolKey.self] = newValue }
  }
}

extension View {
  /// Gives a page its area's color and symbol.
  func area(_ section: AppViewModel.Section) -> some View {
    environment(\.areaSwatch, section.swatch).environment(\.areaSymbol, section.icon)
  }

  /// Card, floating and overlay shadows (shadow1, shadow2, shadow3).
  func elevation(_ level: Elevation) -> some View { modifier(ElevationModifier(level: level)) }

  /// A surface card's background: fill, hairline ring and card shadow. Cards have no border in
  /// Light Mode; Increase Contrast draws a 1 pt ink stroke instead.
  func cardBackground(_ fill: Color = AppTheme.surface, radius: CGFloat = AppTheme.corner, raised: Bool = false) -> some View {
    background(CardBackground(fill: fill, radius: radius, raised: raised))
  }
}

enum Elevation { case card, floating, overlay }

private struct ElevationModifier: ViewModifier {
  let level: Elevation
  @Environment(\.colorScheme) private var scheme

  func body(content: Content) -> some View {
    let dark = scheme == .dark
    let (opacity, radius, y): (Double, CGFloat, CGFloat) = switch level {
    case .card: (dark ? 0.35 : 0.07, 1, 1)
    case .floating: (dark ? 0.42 : 0.16, 11, 8)
    case .overlay: (dark ? 0.55 : 0.34, 30, 24)
    }
    return content.shadow(color: .black.opacity(opacity), radius: radius, y: y)
  }
}

struct CardBackground: View {
  var fill: Color = AppTheme.surface
  var radius: CGFloat = AppTheme.corner
  var raised = false
  @Environment(\.colorScheme) private var scheme
  @Environment(\.colorSchemeContrast) private var contrast

  var body: some View {
    let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
    shape.fill(fill)
      .overlay(shape.strokeBorder(ring, lineWidth: contrast == .increased ? 1 : 0.5))
      .elevation(raised ? .floating : .card)
  }

  private var ring: Color {
    if contrast == .increased { return AppTheme.ink.opacity(0.45) }
    return scheme == .dark ? Color.white.opacity(0.06) : Color.black.opacity(0.05)
  }
}

/// The page background: the area's tint fading into the canvas over the top 240 pt.
struct AreaWash: View {
  @Environment(\.areaSwatch) private var swatch
  var body: some View {
    VStack(spacing: 0) {
      LinearGradient(colors: [swatch.tint, AppTheme.canvas], startPoint: .top, endPoint: .bottom).frame(height: 240)
      AppTheme.canvas
    }
    .accessibilityHidden(true)
  }
}

/// A System Settings–style badge: a white glyph on its area's color.
struct SwatchBadge: View {
  let symbol: String
  let swatch: AppTheme.Swatch
  var size: CGFloat = 24
  /// The soft colored glow page headers and empty states use.
  var glow = false

  var body: some View {
    let shape = RoundedRectangle(cornerRadius: size * 0.29, style: .continuous)
    Image(systemName: symbol).font(.system(size: size * 0.5, weight: .semibold))
      .symbolVariant(.fill)
      .foregroundStyle(.white).frame(width: size, height: size)
      .background(swatch.gradient, in: shape)
      .overlay(shape.strokeBorder(Color.white.opacity(0.2), lineWidth: 0.5))
      .shadow(color: swatch.color.opacity(glow ? 0.45 : 0.25), radius: glow ? 9 : 1.5, y: glow ? 6 : 1)
      .accessibilityHidden(true)
  }
}

/// An uppercase label above a group: WORKSPACE, QUICK SCAN, GOOD MORNING.
struct Eyebrow: View {
  let text: String
  var color: Color = AppTheme.ink3
  init(_ text: String, color: Color = AppTheme.ink3) { self.text = text; self.color = color }
  var body: some View {
    Text(text.uppercased()).font(.system(size: 10.5, weight: .bold)).tracking(1.2).foregroundStyle(color)
  }
}

struct SurfaceCard<Content: View>: View {
  let content: Content
  var padding: CGFloat = AppTheme.cardPadding
  init(padding: CGFloat = AppTheme.cardPadding, @ViewBuilder content: () -> Content) {
    self.padding = padding
    self.content = content()
  }
  var body: some View {
    content.padding(padding).cardBackground()
  }
}

struct MetricCard: View {
  let title: String
  let value: String
  let subtitle: String
  let icon: String
  var swatch: AppTheme.Swatch? = nil
  var action: (() -> Void)? = nil
  @Environment(\.areaSwatch) private var area

  var body: some View {
    if let action {
      Button(action: action) { card }.buttonStyle(CardButtonStyle())
        .help("Open " + title).accessibilityElement(children: .combine)
    } else { card.accessibilityElement(children: .combine) }
  }

  private var card: some View {
    SurfaceCard(padding: 16) {
      VStack(alignment: .leading, spacing: 10) {
        HStack(spacing: 8) {
          SwatchBadge(symbol: icon, swatch: swatch ?? area, size: 22)
          Eyebrow(title)
          Spacer(minLength: 4)
          if action != nil { Image(systemName: "arrow.up.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(AppTheme.ink3) }
        }
        Text(value).font(AppTheme.number(24)).tracking(-0.5)
          .monospacedDigit().lineLimit(1).minimumScaleFactor(0.7).foregroundStyle(AppTheme.ink)
        Text(subtitle).font(.system(size: 11.5)).foregroundStyle(AppTheme.ink2).lineLimit(2)
          .fixedSize(horizontal: false, vertical: true)
      }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
    }
  }
}

/// A 20 pt pill: a filled glyph and a short label on the swatch's tint.
struct Chip: View {
  let title: String
  var symbol: String? = nil
  var swatch: AppTheme.Swatch = .slate

  var body: some View {
    HStack(spacing: 4) {
      if let symbol { Image(systemName: symbol).font(.system(size: 9.5, weight: .bold)).symbolVariant(.fill) }
      Text(title).lineLimit(1)
    }
    .font(.system(size: 11, weight: .semibold))
    .foregroundStyle(swatch.text)
    .padding(.horizontal, 8).frame(height: 20)
    .background(swatch.tint, in: Capsule())
  }

  /// Downloads and old files that nobody has opened in a long time.
  static var likelyUnneeded: Chip { Chip(title: "Likely unneeded", symbol: "clock.fill", swatch: .sky) }
}

extension CleanupRisk {
  /// Rebuildable is mint, Review is amber (it needs a person, it isn't dangerous), Protected is rose.
  var swatch: AppTheme.Swatch {
    switch self {
    case .safe: return .mint
    case .review: return .amber
    case .restricted: return .rose
    }
  }
  var title: String {
    switch self {
    case .safe: return "Rebuildable"
    case .review: return "Review"
    case .restricted: return "Protected"
    }
  }
  var symbol: String {
    switch self {
    case .safe: return "checkmark.shield.fill"
    case .review: return "eye.fill"
    case .restricted: return "lock.fill"
    }
  }
}

struct RiskBadge: View {
  let risk: CleanupRisk
  var body: some View { Chip(title: risk.title, symbol: risk.symbol, swatch: risk.swatch) }
}

/// A 16 pt checkbox mark: a ring when off, mint with a check when on, mint with a dash when mixed.
struct CheckboxMark: View {
  enum Kind { case off, on, mixed }
  let state: Kind
  var body: some View {
    let shape = RoundedRectangle(cornerRadius: 5, style: .continuous)
    ZStack {
      if state == .off {
        shape.strokeBorder(AppTheme.borderStrong, lineWidth: 1.5).background(AppTheme.surface, in: shape)
      } else {
        shape.fill(AppTheme.commitGradient)
        Image(systemName: state == .on ? "checkmark" : "minus").font(.system(size: 9, weight: .heavy)).foregroundStyle(.white)
      }
    }
    .frame(width: 16, height: 16)
    .accessibilityHidden(true)
  }
}

/// The mint checkbox as a toggle style, keeping the toggle's accessibility.
struct MintCheckboxStyle: ToggleStyle {
  func makeBody(configuration: Configuration) -> some View { MintCheckbox(configuration: configuration) }
}

/// Disabled checkboxes dim and ignore clicks and VoiceOver actions alike.
private struct MintCheckbox: View {
  let configuration: ToggleStyleConfiguration
  @Environment(\.isEnabled) private var isEnabled

  var body: some View {
    HStack(spacing: 8) {
      CheckboxMark(state: configuration.isMixed ? .mixed : configuration.isOn ? .on : .off)
      configuration.label
    }
    .opacity(isEnabled ? 1 : 0.4)
    .contentShape(Rectangle())
    .onTapGesture { if isEnabled { configuration.isOn.toggle() } }
    .accessibilityElement(children: .combine)
    .accessibilityAddTraits(.isButton)
    .accessibilityValue(configuration.isMixed ? "Mixed" : configuration.isOn ? "Checked" : "Unchecked")
    .accessibilityAction { if isEnabled { configuration.isOn.toggle() } }
  }
}

/// A segmented control on a panel track; the selected segment is a raised surface. Risk
/// filters add a colored dot and a count to each segment.
struct SegmentedPills<Value: Hashable>: View {
  struct Option: Identifiable {
    let value: Value
    let title: String
    var dot: Color? = nil
    var count: Int? = nil
    var id: Value { value }
  }

  @Binding var selection: Value
  let options: [Option]

  var body: some View {
    HStack(spacing: 2) {
      ForEach(options) { option in
        let selected = option.value == selection
        Button { selection = option.value } label: {
          HStack(spacing: 6) {
            if let dot = option.dot { Circle().fill(dot).frame(width: 7, height: 7) }
            Text(option.title).lineLimit(1)
            if let count = option.count {
              Text("\(count)").font(AppTheme.number(11, weight: .semibold)).monospacedDigit().foregroundStyle(AppTheme.ink3)
            }
          }
          .font(.system(size: 12, weight: selected ? .semibold : .medium))
          .foregroundStyle(selected ? AppTheme.ink : AppTheme.ink2)
          .padding(.horizontal, 10).frame(height: 24)
          .background {
            if selected { RoundedRectangle(cornerRadius: 7, style: .continuous).fill(AppTheme.surface).elevation(.card) }
          }
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
      }
    }
    .padding(2)
    .background(AppTheme.panel, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
  }
}

/// The sticky bar under lists you pick from (Cleanup, Review): what is picked, a reassurance
/// line, Clear, and the commit action. Nothing moves until the final check.
struct SelectionBar: View {
  let count: Int
  let bytes: Int64
  var message = "Nothing is removed yet. You check everything once more before it moves to the Trash."
  var clear: (() -> Void)? = nil
  let commitTitle: String
  var commitDisabled = false
  let commit: () -> Void

  var body: some View {
    HStack(spacing: 12) {
      CheckboxMark(state: count > 0 ? .on : .off)
      VStack(alignment: .leading, spacing: 2) {
        HStack(spacing: 6) {
          Text("\(count) selected").font(.system(size: 13, weight: .semibold)).monospacedDigit()
          Text("·").foregroundStyle(AppTheme.ink3)
          Text(ByteFormatter.string(bytes)).font(AppTheme.number(13)).monospacedDigit()
        }.foregroundStyle(AppTheme.ink)
        Text(message).font(.system(size: 11.5)).foregroundStyle(AppTheme.ink2).lineLimit(1)
      }
      .accessibilityElement(children: .combine)
      Spacer(minLength: 8)
      if let clear, count > 0 { Button("Clear", action: clear).buttonStyle(MintButtonStyle(.plain)) }
      Button(commitTitle, action: commit).buttonStyle(MintButtonStyle(.commit)).disabled(commitDisabled || count == 0)
    }
    .padding(.horizontal, AppTheme.pagePadding).padding(.vertical, 10)
    .background(AppTheme.surface)
    .overlay(alignment: .top) { Rectangle().fill(AppTheme.divider).frame(height: 1) }
  }
}

/// A sheet's header: area badge, eyebrow, title and subtitle on an optional tint wash.
struct SheetHeader<Trailing: View>: View {
  let symbol: String
  let swatch: AppTheme.Swatch
  var eyebrow: String? = nil
  let title: String
  var subtitle: String? = nil
  var wash = true
  @ViewBuilder var trailing: () -> Trailing

  var body: some View {
    HStack(alignment: .top, spacing: 14) {
      SwatchBadge(symbol: symbol, swatch: swatch, size: 42, glow: true)
      VStack(alignment: .leading, spacing: 3) {
        if let eyebrow { Eyebrow(eyebrow, color: swatch.text) }
        Text(title).font(.system(size: 19, weight: .bold)).tracking(-0.3).foregroundStyle(AppTheme.ink)
          .fixedSize(horizontal: false, vertical: true).accessibilityAddTraits(.isHeader)
        if let subtitle {
          Text(subtitle).font(.system(size: 12.5)).foregroundStyle(AppTheme.ink2).fixedSize(horizontal: false, vertical: true)
        }
      }
      Spacer(minLength: 8)
      trailing()
    }
    .padding(.horizontal, 22).padding(.top, 20).padding(.bottom, 16)
    .background {
      if wash { LinearGradient(colors: [swatch.tint, swatch.tint.opacity(0)], startPoint: .top, endPoint: .bottom) }
    }
  }
}

extension SheetHeader where Trailing == EmptyView {
  init(symbol: String, swatch: AppTheme.Swatch, eyebrow: String? = nil, title: String, subtitle: String? = nil, wash: Bool = true) {
    self.symbol = symbol; self.swatch = swatch; self.eyebrow = eyebrow; self.title = title
    self.subtitle = subtitle; self.wash = wash; self.trailing = { EmptyView() }
  }
}

/// A sheet's footer: a panel bar with a divider; plain actions lead, Cancel and the primary trail.
struct SheetFooter<Content: View>: View {
  @ViewBuilder var content: () -> Content
  var body: some View {
    HStack(spacing: 8) { content() }
      .padding(.horizontal, 20).padding(.vertical, 12)
      .frame(maxWidth: .infinity)
      .background(AppTheme.panel)
      .overlay(alignment: .top) { Rectangle().fill(AppTheme.divider).frame(height: 1) }
  }
}

/// The line that sits under every empty state and scan.
enum TrustLine {
  static let scanning = "Scanning only looks. Nothing moves until you review it."
  static let promise = "We look · you decide · you can undo"
}

struct EmptyState: View {
  let icon: String
  let title: String
  let detail: String
  var actionTitle: String? = nil
  var action: (() -> Void)? = nil
  var secondaryTitle: String? = nil
  var secondaryAction: (() -> Void)? = nil
  /// The reassurance under the actions; nil hides it.
  var trust: String? = TrustLine.scanning
  var swatch: AppTheme.Swatch? = nil
  @Environment(\.areaSwatch) private var area

  var body: some View {
    let color = swatch ?? area
    VStack(spacing: 14) {
      ZStack {
        Circle().fill(color.tint).frame(width: 120, height: 120).offset(x: -34, y: 8)
        RoundedRectangle(cornerRadius: 26, style: .continuous).fill(color.tint.opacity(0.8))
          .frame(width: 70, height: 70).rotationEffect(.degrees(14)).offset(x: 44, y: -16)
        Image(systemName: icon).font(.system(size: 30, weight: .semibold)).symbolVariant(.fill)
          .foregroundStyle(.white).frame(width: 72, height: 72)
          .background(color.gradient, in: RoundedRectangle(cornerRadius: 21, style: .continuous))
          .shadow(color: color.color.opacity(0.4), radius: 12, y: 8)
      }
      .frame(height: 128)
      .accessibilityHidden(true)
      Text(title).font(.system(size: 20, weight: .bold)).tracking(-0.3).foregroundStyle(AppTheme.ink)
        .multilineTextAlignment(.center).accessibilityAddTraits(.isHeader)
      Text(detail).font(.system(size: 13)).foregroundStyle(AppTheme.ink2)
        .multilineTextAlignment(.center).frame(maxWidth: 400)
        .fixedSize(horizontal: false, vertical: true)
      if (actionTitle != nil && action != nil) || (secondaryTitle != nil && secondaryAction != nil) {
        HStack(spacing: 8) {
          if let secondaryTitle, let secondaryAction {
            Button(secondaryTitle, action: secondaryAction).buttonStyle(MintButtonStyle(.secondary))
          }
          if let actionTitle, let action {
            Button(actionTitle, action: action).buttonStyle(MintButtonStyle(.area))
          }
        }
        .environment(\.areaSwatch, color)
        .padding(.top, 4)
      }
      if let trust {
        Label(trust, systemImage: "checkmark.shield.fill")
          .font(.system(size: 11.5)).foregroundStyle(AppTheme.ink3)
          .symbolRenderingMode(.hierarchical)
          .padding(.top, 2)
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
  var swatch: AppTheme.Swatch? = nil
  /// 0...1 when the amount of work is known.
  var progress: Double? = nil
  /// Extra line under the detail, such as "42 of 180 apps".
  var status: String? = nil
  var rows = 5
  var cancel: (() -> Void)? = nil
  @Environment(\.areaSwatch) private var area

  private static let titleWidths: [CGFloat] = [180, 140, 210, 120, 160]
  private static let detailWidths: [CGFloat] = [90, 120, 70, 110, 80]

  var body: some View {
    let color = swatch ?? area
    VStack(alignment: .leading, spacing: 14) {
      VStack(alignment: .leading, spacing: 14) {
        HStack(alignment: .top, spacing: 14) {
          SwatchBadge(symbol: symbol, swatch: color, size: 44, glow: true)
          VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
              Text(title).font(.system(size: 17, weight: .bold)).foregroundStyle(AppTheme.ink)
              ProgressView().controlSize(.small)
            }
            Text(detail).font(.system(size: 13)).foregroundStyle(AppTheme.ink2).fixedSize(horizontal: false, vertical: true)
            if let status {
              Text(status).font(AppTheme.number(12, weight: .semibold)).foregroundStyle(AppTheme.ink3).monospacedDigit()
            }
          }
          .accessibilityElement(children: .combine)
          Spacer(minLength: 0)
          if let cancel { Button("Cancel", action: cancel).buttonStyle(MintButtonStyle(.secondary)).controlSize(.small) }
        }
        if let progress {
          GeometryReader { geometry in
            Capsule().fill(AppTheme.track).overlay(alignment: .leading) {
              Capsule().fill(color.gradient).frame(width: max(6, geometry.size.width * min(1, max(0, progress))))
            }
          }
          .frame(height: 6)
          .accessibilityElement()
          .accessibilityLabel("Progress")
          .accessibilityValue("\(Int(min(1, max(0, progress)) * 100)) percent")
        }
      }
      .padding(18)
      .cardBackground()
      VStack(spacing: 0) {
        ForEach(0..<rows, id: \.self) { row in
          HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 8, style: .continuous).fill(AppTheme.panel2).frame(width: 32, height: 32)
            VStack(alignment: .leading, spacing: 6) {
              Capsule().fill(AppTheme.panel2).frame(width: Self.titleWidths[row % 5], height: 9)
              Capsule().fill(AppTheme.panel).frame(width: Self.detailWidths[row % 5], height: 7)
            }
            Spacer()
            Capsule().fill(AppTheme.panel2).frame(width: 54, height: 9)
          }
          .padding(.horizontal, 14).frame(height: 48)
          .opacity(1 - Double(row) * (0.52 / Double(max(1, rows - 1))))
          if row < rows - 1 { Rectangle().fill(AppTheme.divider).frame(height: 1).padding(.leading, 58) }
        }
      }
      .cardBackground()
      .accessibilityHidden(true)
      Label("Reading only — nothing is changed while this runs.", systemImage: "eye")
        .font(.system(size: 11.5)).foregroundStyle(AppTheme.ink3)
    }
    .frame(maxWidth: 640)
    .padding(24)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    .padding(.top, 12)
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
        .stroke(AppTheme.track, lineWidth: 12)
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
          .font(AppTheme.number(26))
          .monospacedDigit()
        Text(centerLabel)
          .font(.system(size: 11.5))
          .foregroundStyle(AppTheme.ink2)
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
  var tint: Color = AppTheme.ink2

  var body: some View {
    HStack(spacing: 4) {
      Image(systemName: icon).font(.system(size: 9.5, weight: .bold))
      Text(title).lineLimit(1)
    }
    .font(.system(size: 11, weight: .semibold))
    .foregroundStyle(tint)
    .padding(.horizontal, 8).frame(height: 20)
    .background(tint.opacity(0.12), in: Capsule())
  }
}

struct ScanIssueSheet: View {
  let issues: [ScanIssue]
  @Environment(\.dismiss) private var dismiss
  @State private var showingAccessHelp = false

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      SheetHeader(symbol: "exclamationmark.triangle.fill", swatch: .amber, eyebrow: "Scan details",
        title: issues.isEmpty ? "No scan issues" : "\(issues.count) item\(issues.count == 1 ? " was" : "s were") skipped",
        subtitle: "These items were skipped or could not be inspected. No protection was bypassed.") {
        Button("Done") { dismiss() }.buttonStyle(MintButtonStyle(.commit))
          .keyboardShortcut(.defaultAction)
      }
      Rectangle().fill(AppTheme.divider).frame(height: 1)
      if issues.isEmpty {
        EmptyState(
          icon: "checkmark.circle", title: "No scan issues",
          detail: "The last scan completed without reported filesystem access problems.", trust: nil, swatch: .mint)
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
        SheetFooter {
          Text("Access denied? Review the permission guide, then rescan.")
            .font(.system(size: 11.5)).foregroundStyle(AppTheme.ink2)
          Spacer()
          Button("Access Help…") { showingAccessHelp = true }.buttonStyle(MintButtonStyle(.secondary))
        }
      }
    }
    .frame(minWidth: 620, minHeight: 420)
    .background(AppTheme.elevated)
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
