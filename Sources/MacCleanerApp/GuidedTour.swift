import SwiftUI

/// Places in the window the guided tour points at.
enum TourTarget: Hashable, Sendable {
  /// The whole sidebar: every area at once.
  case map
  case quickScan, performance, review, history, goTo, help
  /// One sidebar area, so the map step can label it.
  case area(AppViewModel.Section)
}

/// One stop on the tour: what it points at, the page shown behind it, and what it says.
struct TourStep: Equatable, Sendable {
  let target: TourTarget
  /// The page to show while this step is up; nil keeps the current page.
  let section: AppViewModel.Section?
  let title: String
  let message: String
  let symbol: String
  let swatch: AppTheme.Swatch
}

/// A one-minute first-run walk through the window: each step dims the window, outlines one
/// control and explains it in a sentence or two. The tour itself starts and changes nothing.
enum GuidedTour {
  static let steps: [TourStep] = [
    TourStep(target: .map, section: .dashboard, title: "Where everything lives",
      message: "Seven areas, each with its own color. Pick one to open it. Tabs at the top of a page hold related pages.",
      symbol: "map.fill", swatch: .mint),
    TourStep(target: .quickScan, section: .dashboard, title: "Quick Scan",
      message: "Checks caches, app leftovers, old downloads and developer clutter. It only looks. Nothing moves until you review it.",
      symbol: "dot.radiowaves.left.and.right", swatch: .mint),
    TourStep(target: .performance, section: .dashboard, title: "Tabs",
      message: "Related pages sit in tabs. Performance shows which apps use memory and CPU right now, helpers included.",
      symbol: "gauge.with.dots.needle.67percent", swatch: .sky),
    TourStep(target: .review, section: .dashboard, title: "Review",
      message: "Everything you pick on any page collects here. You check it all once more before anything moves to the Trash.",
      symbol: "checklist", swatch: .mint),
    TourStep(target: .history, section: .history, title: "History and Restore",
      message: "Everything MacMint moved to the Trash, with a Restore button while it is still there.",
      symbol: "clock.arrow.circlepath", swatch: .slate),
    TourStep(target: .goTo, section: nil, title: "⌘K and Help",
      message: "Press ⌘K and type any page to jump to it. Help, permissions and this tour live under the ? at the bottom of the sidebar.",
      symbol: "command", swatch: .graphite),
  ]

  /// What the map step says beside each area.
  static func areaLabel(_ section: AppViewModel.Section) -> String {
    switch section {
    case .dashboard: return "Your Mac at a glance"
    case .cleaner: return "Caches, logs and downloads"
    case .storage: return "What takes up space"
    case .applications: return "Apps and their leftovers"
    case .photos: return "Similar shots and screenshots"
    case .developer: return "Build data that rebuilds"
    case .history: return "Undo with Restore"
    default: return section.rawValue
    }
  }
}

/// Window-space frames of the tour's targets. Global frames, like the smoke test's layout
/// evidence, because the sidebar and the detail column are hosted separately.
struct TourTargetFrames: PreferenceKey {
  static let defaultValue: [TourTarget: CGRect] = [:]
  static func reduce(value: inout [TourTarget: CGRect], nextValue: () -> [TourTarget: CGRect]) {
    value.merge(nextValue(), uniquingKeysWith: { _, next in next })
  }
}

extension View {
  /// Marks this view as a stop on the guided tour.
  func tourTarget(_ target: TourTarget) -> some View {
    background(GeometryReader { geometry in
      Color.clear.preference(key: TourTargetFrames.self, value: [target: geometry.frame(in: .global)])
    })
  }
}

enum TourLayout {
  static let margin: CGFloat = 16
  static let gap: CGFloat = 14

  /// Where the explanation card goes: beside the target when there is room (right, then left),
  /// otherwise below or above it, always inside the window. Centered when there is no target.
  static func cardOrigin(target: CGRect?, card: CGSize, bounds: CGSize) -> CGPoint {
    func clamp(_ point: CGPoint) -> CGPoint {
      CGPoint(x: min(max(point.x, margin), max(margin, bounds.width - card.width - margin)),
        y: min(max(point.y, margin), max(margin, bounds.height - card.height - margin)))
    }
    guard let target, !target.isEmpty else {
      return clamp(CGPoint(x: (bounds.width - card.width) / 2, y: (bounds.height - card.height) / 2))
    }
    if target.maxX + gap + card.width + margin <= bounds.width, target.height < card.height * 2 || target.width < bounds.width * 0.3 {
      return clamp(CGPoint(x: target.maxX + gap, y: target.midY - card.height / 2))
    }
    if target.maxY + gap + card.height + margin <= bounds.height {
      return clamp(CGPoint(x: target.midX - card.width / 2, y: target.maxY + gap))
    }
    if target.minY - gap - card.height >= margin {
      return clamp(CGPoint(x: target.midX - card.width / 2, y: target.minY - gap - card.height))
    }
    return clamp(CGPoint(x: target.minX - gap - card.width, y: target.midY - card.height / 2))
  }
}

/// The dimmed window with a cut-out around the current target and the explanation card.
struct TourOverlay: View {
  let step: TourStep
  let index: Int
  let count: Int
  /// Global frames of the tour's targets; a missing target centers the card.
  let frames: [TourTarget: CGRect]
  let back: () -> Void
  let next: () -> Void
  let skip: () -> Void
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  private let cardSize = CGSize(width: 340, height: 214)
  private static let ring = AppTheme.hex(0x34D399)
  /// The map step's area labels sit between the sidebar and the card.
  private static let labelRoom: CGFloat = 200

  var body: some View {
    GeometryReader { geometry in
      let origin = geometry.frame(in: .global).origin
      let local = { (frame: CGRect) in frame.offsetBy(dx: -origin.x, dy: -origin.y) }
      let target = frames[step.target].map(local)
      let hole = target?.insetBy(dx: -6, dy: -6)
      let placementTarget = step.target == .map ? target.map { CGRect(x: $0.minX, y: $0.minY, width: $0.width + Self.labelRoom, height: $0.height) } : target
      ZStack(alignment: .topLeading) {
        Path { path in
          path.addRect(CGRect(origin: .zero, size: geometry.size))
          if let hole { path.addRoundedRect(in: hole, cornerSize: CGSize(width: 12, height: 12)) }
        }
        .fill(Color.black.opacity(0.55), style: FillStyle(eoFill: true))
        .contentShape(Rectangle())
        .onTapGesture {}
        .accessibilityHidden(true)
        if let hole {
          RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(Self.ring, lineWidth: 2.5)
            .shadow(color: Self.ring.opacity(0.25), radius: 7)
            .frame(width: hole.width, height: hole.height)
            .offset(x: hole.minX, y: hole.minY)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
        if step.target == .map {
          ForEach(AppViewModel.Section.primary) { section in
            if let frame = frames[.area(section)].map(local), let hole {
              areaLabel(section)
                .fixedSize()
                .offset(x: hole.maxX + 14, y: frame.midY - 13)
                .allowsHitTesting(false)
            }
          }
          .accessibilityHidden(true)
        }
        card
          .frame(width: cardSize.width)
          .offset(position(of: placementTarget, in: geometry.size))
          .animation(reduceMotion ? nil : .easeOut(duration: 0.22), value: index)
      }
    }
    .ignoresSafeArea()
  }

  private func position(of target: CGRect?, in bounds: CGSize) -> CGSize {
    let origin = TourLayout.cardOrigin(target: target, card: cardSize, bounds: bounds)
    return CGSize(width: origin.x, height: origin.y)
  }

  private func areaLabel(_ section: AppViewModel.Section) -> some View {
    HStack(spacing: 7) {
      Circle().fill(section.swatch.gradient).frame(width: 7, height: 7)
      Text(GuidedTour.areaLabel(section)).font(.system(size: 12, weight: .medium)).foregroundStyle(AppTheme.ink)
    }
    .padding(.horizontal, 10).frame(height: 26)
    .background(AppTheme.elevated, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    .elevation(.overlay)
  }

  private var card: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(spacing: 10) {
        SwatchBadge(symbol: step.symbol, swatch: step.swatch, size: 30)
        Text("QUICK TOUR · \(index + 1) OF \(count)").font(.system(size: 10.5, weight: .bold)).tracking(1.2)
          .foregroundStyle(AppTheme.accentText)
        Spacer()
        Button("Skip", action: skip).buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(AppTheme.ink2)
          .keyboardShortcut(.cancelAction).help("Skip the tour · Esc")
      }
      Text(step.title).font(.system(size: 18, weight: .bold)).tracking(-0.3).foregroundStyle(AppTheme.ink)
      Text(step.message).font(.system(size: 13)).foregroundStyle(AppTheme.ink2)
        .fixedSize(horizontal: false, vertical: true)
      HStack(spacing: 4) {
        ForEach(0..<count, id: \.self) { bar in
          Capsule().fill(bar <= index ? AnyShapeStyle(AppTheme.commitGradient) : AnyShapeStyle(AppTheme.track)).frame(height: 4)
        }
      }
      .accessibilityHidden(true)
      HStack(spacing: 8) {
        Text("← → to move").font(.system(size: 11)).foregroundStyle(AppTheme.ink3)
        Spacer()
        if index > 0 { Button("Back", action: back).buttonStyle(MintButtonStyle(.secondary)).controlSize(.small) }
        Button(index + 1 == count ? "Finish" : "Next", action: next)
          .buttonStyle(MintButtonStyle(.commit)).controlSize(.small)
          .keyboardShortcut(.defaultAction)
      }
      // Arrow keys move between steps.
      ZStack {
        Button("", action: next).keyboardShortcut(.rightArrow, modifiers: [])
        Button("", action: back).keyboardShortcut(.leftArrow, modifiers: [])
      }
      .frame(width: 0, height: 0).opacity(0).accessibilityHidden(true)
    }
    .padding(16)
    .background(AppTheme.elevated, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(AppTheme.border.opacity(0.6), lineWidth: 0.5))
    .elevation(.overlay)
    .accessibilityElement(children: .contain)
    .accessibilityLabel("Quick tour, step \(index + 1) of \(count): \(step.title)")
    .accessibilityAddTraits(.isModal)
  }
}

extension AppViewModel {
  nonisolated static let tourSeenKey = "care.tourSeen"

  func startTour() {
    tourStep = 0
    showTourPage()
  }

  func advanceTour() {
    guard let step = tourStep else { return }
    if step + 1 < GuidedTour.steps.count {
      tourStep = step + 1
      showTourPage()
    } else {
      endTour(finished: true)
    }
  }

  func retreatTour() {
    guard let step = tourStep, step > 0 else { return }
    tourStep = step - 1
    showTourPage()
  }

  /// Finishing returns to Overview; skipping stays on the page the person is looking at.
  func endTour(finished: Bool) {
    tourStep = nil
    UserDefaults.standard.set(true, forKey: Self.tourSeenKey)
    if finished { selectedSection = .dashboard }
  }

  private func showTourPage() {
    guard let step = tourStep, GuidedTour.steps.indices.contains(step),
      let section = GuidedTour.steps[step].section else { return }
    selectedSection = section
  }
}
