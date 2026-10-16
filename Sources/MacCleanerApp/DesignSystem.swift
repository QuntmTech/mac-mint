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

/// A page header that gives actions their own row when a window becomes narrow.
struct PageHeader<Actions: View>: View {
  let title: String
  let subtitle: String
  var eyebrow: String? = nil
  @ViewBuilder var actions: () -> Actions

  var body: some View {
    ViewThatFits(in: .horizontal) {
      HStack(alignment: .center, spacing: 24) {
        heading.frame(minWidth: 240, alignment: .leading)
        Spacer(minLength: 12)
        actions().fixedSize()
      }
      VStack(alignment: .leading, spacing: 16) { heading; actions() }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .fixedSize(horizontal: false, vertical: true)
    .accessibilityElement(children: .contain)
  }

  private var heading: some View {
    VStack(alignment: .leading, spacing: 6) {
      if let eyebrow {
        Text(eyebrow.uppercased()).font(.system(size: 10, weight: .semibold))
          .tracking(1.6).foregroundStyle(AppTheme.accentText)
      }
      Text(title).font(.system(size: 29, weight: .semibold)).tracking(-0.8)
        .foregroundStyle(AppTheme.ink).fixedSize(horizontal: false, vertical: true)
      if !subtitle.isEmpty {
        Text(subtitle).font(.callout).foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true).frame(maxWidth: 560, alignment: .leading)
      }
    }
  }
}

extension PageHeader where Actions == EmptyView {
  init(_ title: String, subtitle: String, eyebrow: String? = nil) {
    self.title = title; self.subtitle = subtitle; self.eyebrow = eyebrow; self.actions = { EmptyView() }
  }
}

struct IconTile: View {
  let symbol: String
  var tint: Color = AppTheme.accentText
  var size: CGFloat = 40
  var body: some View {
    Image(systemName: symbol).font(.system(size: size * 0.42, weight: .medium))
      .foregroundStyle(tint).frame(width: size, height: size)
      .background(tint.opacity(0.10), in: RoundedRectangle(cornerRadius: size * 0.28))
      .accessibilityHidden(true)
  }
}

struct SearchField: View {
  let prompt: String
  @Binding var text: String
  @Environment(\.colorSchemeContrast) private var contrast
  var body: some View {
    HStack(spacing: 8) {
      Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
      TextField(prompt, text: $text).textFieldStyle(.plain).accessibilityLabel(prompt)
      if !text.isEmpty {
        Button { text = "" } label: { Image(systemName: "xmark.circle.fill") }
          .buttonStyle(.plain).foregroundStyle(.secondary).accessibilityLabel("Clear search")
      }
    }
    .padding(.horizontal, 11).padding(.vertical, 9)
    .background(AppTheme.surface, in: RoundedRectangle(cornerRadius: 9))
    .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(contrast == .increased ? Color.primary.opacity(0.6) : AppTheme.border))
  }
}

struct MintButtonStyle: ButtonStyle {
  var prominent = true
  @Environment(\.isEnabled) private var isEnabled
  @Environment(\.colorSchemeContrast) private var contrast
  func makeBody(configuration: Configuration) -> some View {
    configuration.label.font(.system(size: 13, weight: .semibold))
      .padding(.horizontal, 16).padding(.vertical, 10)
      .foregroundStyle(prominent ? Color.white : AppTheme.ink)
      .background(prominent ? AppTheme.accent : AppTheme.surface,
        in: RoundedRectangle(cornerRadius: 10, style: .continuous))
      .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(
        prominent ? Color.white.opacity(0.10) : AppTheme.border,
        lineWidth: contrast == .increased ? 2 : 1))
      .brightness(configuration.isPressed ? -0.06 : 0)
      .opacity(isEnabled ? 1 : 0.45)
      .contentShape(RoundedRectangle(cornerRadius: 10))
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
          Color(red: 0.96, green: 0.97, blue: 0.96)
          if option == .system { Color(red: 0.10, green: 0.13, blue: 0.12) }
        }
        if option == .dark { Color(red: 0.10, green: 0.13, blue: 0.12) }
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
            RoundedRectangle(cornerRadius: 4).fill(AppTheme.brand.opacity(0.16)).frame(height: 21)
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

private struct CardButtonFace<Content: View>: View {
  let content: Content
  let pressed: Bool
  @State private var hovering = false
  var body: some View {
    content.overlay(RoundedRectangle(cornerRadius: AppTheme.corner)
      .strokeBorder(AppTheme.accentText.opacity(hovering || pressed ? 0.55 : 0), lineWidth: 1))
      .brightness(pressed ? -0.025 : 0).onHover { hovering = $0 }
  }
}
