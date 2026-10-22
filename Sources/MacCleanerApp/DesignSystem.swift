import SwiftUI

enum AppAppearance: String, CaseIterable, Identifiable {
  case system, light, dark
  static let storageKey = "macmint.appearance"
  var id: String { rawValue }
  var title: String { rawValue.capitalized }
  var colorScheme: ColorScheme? {
    switch self { case .system: return nil; case .light: return .light; case .dark: return .dark }
  }
  var symbol: String {
    switch self { case .system: return "desktopcomputer"; case .light: return "sun.max"; case .dark: return "moon" }
  }
}

/// A page header that gives actions their own row when a window becomes narrow: the area's
/// 42 pt gradient badge, a 24 pt title and a one-line explanation.
struct PageHeader<Actions: View>: View {
  let title: String
  let subtitle: String
  var eyebrow: String? = nil
  /// Overrides the area's symbol in the badge.
  var symbol: String? = nil
  var showsBadge = true
  @ViewBuilder var actions: () -> Actions
  @Environment(\.areaSwatch) private var swatch
  @Environment(\.areaSymbol) private var areaSymbol

  var body: some View {
    ViewThatFits(in: .horizontal) {
      HStack(alignment: .center, spacing: 24) {
        heading.frame(minWidth: 240, alignment: .leading)
        Spacer(minLength: 12)
        HStack(spacing: 8) { actions() }.fixedSize()
      }
      VStack(alignment: .leading, spacing: 14) { heading; HStack(spacing: 8) { actions() } }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .fixedSize(horizontal: false, vertical: true)
    .accessibilityElement(children: .contain)
  }

  private var heading: some View {
    HStack(alignment: .center, spacing: 14) {
      if showsBadge { SwatchBadge(symbol: symbol ?? areaSymbol, swatch: swatch, size: 42, glow: true) }
      VStack(alignment: .leading, spacing: 3) {
        if let eyebrow { Eyebrow(eyebrow, color: swatch.text) }
        Text(title).font(.system(size: 24, weight: .bold)).tracking(-0.55)
          .foregroundStyle(AppTheme.ink).fixedSize(horizontal: false, vertical: true).accessibilityAddTraits(.isHeader)
        if !subtitle.isEmpty {
          Text(subtitle).font(.system(size: 13)).foregroundStyle(AppTheme.ink2)
            .fixedSize(horizontal: false, vertical: true).frame(maxWidth: 560, alignment: .leading)
        }
      }
    }
  }
}

extension PageHeader where Actions == EmptyView {
  init(_ title: String, subtitle: String, eyebrow: String? = nil, symbol: String? = nil, showsBadge: Bool = true) {
    self.title = title; self.subtitle = subtitle; self.eyebrow = eyebrow; self.symbol = symbol
    self.showsBadge = showsBadge; self.actions = { EmptyView() }
  }
}

struct IconTile: View {
  let symbol: String
  var tint: Color = AppTheme.accentText
  var size: CGFloat = 40
  /// A filled, colored badge instead of the quiet tinted tile.
  var swatch: AppTheme.Swatch? = nil
  var body: some View {
    if let swatch {
      SwatchBadge(symbol: symbol, swatch: swatch, size: size)
    } else {
      Image(systemName: symbol).font(.system(size: size * 0.42, weight: .semibold))
        .foregroundStyle(tint).frame(width: size, height: size)
        .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: size * 0.29, style: .continuous))
        .accessibilityHidden(true)
    }
  }
}

struct SearchField: View {
  let prompt: String
  @Binding var text: String
  @Environment(\.colorSchemeContrast) private var contrast
  @FocusState private var focused: Bool
  var body: some View {
    HStack(spacing: 7) {
      Image(systemName: "magnifyingglass").font(.system(size: 12, weight: .medium))
        .foregroundStyle(AppTheme.ink3).accessibilityHidden(true)
      TextField(prompt, text: $text).textFieldStyle(.plain).font(.system(size: 12.5)).accessibilityLabel(prompt)
        .focused($focused)
        .onKeyPress(.escape) {
          guard !text.isEmpty else { return .ignored }
          text = ""
          return .handled
        }
      if !text.isEmpty {
        Button { text = ""; focused = true } label: { Image(systemName: "xmark.circle.fill") }
          .buttonStyle(.plain).foregroundStyle(AppTheme.ink3).accessibilityLabel("Clear search")
          .help("Clear search · Esc")
      }
    }
    .padding(.horizontal, 10).frame(height: 30)
    .cardBackground(radius: 8)
    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(
      focused ? AppTheme.accentText : contrast == .increased ? AppTheme.ink.opacity(0.6) : Color.clear,
      lineWidth: 2))
  }
}

/// Every button in the app. Area buttons explore (Scan Photos, Map Folder) in the page's own
/// color; commit buttons (Add to Review, Final Check, Move to Trash, Done) are always mint, so
/// the button that brings a change closer always looks the same.
struct MintButtonStyle: ButtonStyle {
  enum Kind { case commit, area, secondary, destructive, plain }
  var kind: Kind

  init(prominent: Bool = true) { kind = prominent ? .commit : .secondary }
  init(_ kind: Kind) { self.kind = kind }

  func makeBody(configuration: Configuration) -> some View {
    StyledButtonFace(kind: kind, configuration: configuration)
  }
}

private struct StyledButtonFace: View {
  let kind: MintButtonStyle.Kind
  let configuration: ButtonStyleConfiguration
  @Environment(\.isEnabled) private var isEnabled
  @Environment(\.controlSize) private var controlSize
  @Environment(\.areaSwatch) private var swatch
  @Environment(\.colorSchemeContrast) private var contrast
  @State private var hovering = false

  var body: some View {
    let small = controlSize == .small || controlSize == .mini
    let shape = RoundedRectangle(cornerRadius: small ? 6 : 8, style: .continuous)
    configuration.label
      .font(.system(size: small ? 12 : 13, weight: kind == .secondary ? .medium : .semibold))
      .lineLimit(1)
      .foregroundStyle(foreground)
      .padding(.horizontal, kind == .plain ? 6 : small ? 10 : 14)
      .frame(minHeight: small ? 24 : 30)
      .background {
        switch kind {
        case .commit: shape.fill(AppTheme.commitGradient)
        case .area: shape.fill(swatch.fill)
        case .destructive: shape.fill(AppTheme.dangerFill)
        case .secondary: shape.fill(hovering && isEnabled ? AppTheme.panel : AppTheme.surface)
        case .plain: shape.fill(hovering && isEnabled ? AppTheme.panel : Color.clear)
        }
      }
      .overlay {
        switch kind {
        case .secondary:
          shape.strokeBorder(contrast == .increased ? AppTheme.ink.opacity(0.6) : AppTheme.border,
            lineWidth: contrast == .increased ? 2 : 1)
        case .commit, .area, .destructive:
          shape.strokeBorder(Color.white.opacity(0.16), lineWidth: 0.5)
        case .plain: EmptyView()
        }
      }
      .contentShape(shape)
      .brightness(configuration.isPressed ? -0.06 : hovering && isEnabled && filled ? 0.06 : 0)
      .scaleEffect(configuration.isPressed ? 0.98 : 1)
      .opacity(isEnabled ? 1 : 0.4)
      .onHover { hovering = $0 }
  }

  private var filled: Bool { kind == .commit || kind == .area || kind == .destructive }

  private var foreground: Color {
    switch kind {
    case .commit, .area, .destructive: return .white
    case .secondary: return AppTheme.ink
    case .plain: return AppTheme.accentText
    }
  }
}

struct AppearanceSettingsCard: View {
  @AppStorage(AppAppearance.storageKey) private var appearance: AppAppearance = .system
  var body: some View {
    SurfaceCard {
      VStack(alignment: .leading, spacing: 18) {
        HStack(spacing: 12) {
          IconTile(symbol: "paintpalette")
          VStack(alignment: .leading, spacing: 3) {
            Text("Appearance").font(.headline)
            Text("Make MacMint feel at home on your Mac.").font(.callout).foregroundStyle(.secondary)
          }
        }
        HStack(spacing: 12) {
          ForEach(AppAppearance.allCases) { option in
            Button { appearance = option } label: {
              VStack(alignment: .leading, spacing: 10) {
                appearancePreview(option)
                HStack(spacing: 6) {
                  Image(systemName: option.symbol)
                  Text(option.title)
                  Spacer(minLength: 0)
                  Image(systemName: appearance == option ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(appearance == option ? AppTheme.accentText : Color.secondary)
                }.font(.callout.weight(.medium))
              }
              .padding(10).background(appearance == option ? AppTheme.selection : AppTheme.panel,
                in: RoundedRectangle(cornerRadius: 12))
              .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(
                appearance == option ? AppTheme.accentText : AppTheme.border,
                lineWidth: appearance == option ? 2 : 1))
              .contentShape(RoundedRectangle(cornerRadius: 12))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(option == .system ? "Follow system appearance" : option.title + " appearance")
            .accessibilityAddTraits(appearance == option ? .isSelected : [])
          }
        }
        Text(appearance == .system ? "Follows your Mac’s Light or Dark setting automatically." : "Applies to windows, dialogs, and the menu bar. You can change it at any time.")
          .font(.caption).foregroundStyle(.secondary)
      }
    }
  }

  private func appearancePreview(_ option: AppAppearance) -> some View {
    GeometryReader { geometry in
      ZStack(alignment: .leading) {
        HStack(spacing: 0) {
          Color(white: 0.96)
          if option == .system { Color(white: 0.11) }
        }
        if option == .dark { Color(white: 0.11) }
        HStack(spacing: 9) {
          VStack(spacing: 6) {
            Capsule().fill(AppTheme.brand.opacity(0.65)).frame(height: 5)
            Capsule().fill(Color.gray.opacity(0.25)).frame(height: 4)
            Capsule().fill(Color.gray.opacity(0.25)).frame(height: 4)
            Spacer(minLength: 0)
          }.frame(width: geometry.size.width * 0.21)
          VStack(alignment: .leading, spacing: 7) {
            Capsule().fill(option == .dark ? Color.white.opacity(0.6) : Color.black.opacity(0.35))
              .frame(width: geometry.size.width * 0.36, height: 5)
            RoundedRectangle(cornerRadius: 4).fill(Color.gray.opacity(0.16)).frame(height: 21)
            HStack(spacing: 5) {
              RoundedRectangle(cornerRadius: 3).fill(Color.gray.opacity(0.15))
              RoundedRectangle(cornerRadius: 3).fill(Color.gray.opacity(0.15))
            }
          }
        }.padding(12)
      }
      .clipShape(RoundedRectangle(cornerRadius: 7))
      .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Color.gray.opacity(0.15)))
    }.frame(height: 84).accessibilityHidden(true)
  }
}


/// A quiet pointer affordance without changing layout or relying on motion.
struct CardButtonStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    CardButtonFace(content: configuration.label, pressed: configuration.isPressed)
  }
}

/// Colored tiles brighten slightly on hover instead of drawing an accent border.
struct TileButtonStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    TileButtonFace(content: configuration.label, pressed: configuration.isPressed)
  }
}

private struct TileButtonFace<Content: View>: View {
  let content: Content
  let pressed: Bool
  @State private var hovering = false
  var body: some View {
    content.brightness(pressed ? -0.05 : hovering ? 0.04 : 0).onHover { hovering = $0 }
  }
}

private struct CardButtonFace<Content: View>: View {
  let content: Content
  let pressed: Bool
  @State private var hovering = false
  var body: some View {
    // Tappable cards lift on hover (shadow2) instead of drawing an accent border. The offscreen
    // pass the lift needs exists only while the pointer is over the card, so resting pages
    // redraw as cheaply as plain cards.
    Group {
      if hovering {
        content.compositingGroup().shadow(color: .black.opacity(0.12), radius: 10, y: 6)
      } else {
        content
      }
    }
    .brightness(pressed ? -0.025 : 0).scaleEffect(pressed ? 0.99 : 1).onHover { hovering = $0 }
  }
}
