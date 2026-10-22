import SwiftUI

/// Places in the window the guided tour points at.
enum TourTarget: String, Hashable, Sendable {
  case overview, quickScan, performance, cleanup, storage, apps, photos, developer, history, review, goTo, help
}

/// One stop on the tour: what it points at, the page shown behind it, and what it says.
struct TourStep: Equatable, Sendable {
  let target: TourTarget
  /// The page to show while this step is up; nil keeps the current page.
  let section: AppViewModel.Section?
  let title: String
  let message: String
}

/// A short first-run walk through the window: each step dims the window, outlines one
/// control and explains it in a sentence or two. Nothing runs or changes while it is open.
enum GuidedTour {
  static let steps: [TourStep] = [
    TourStep(target: .overview, section: .dashboard, title: "Overview",
      message: "Your Mac at a glance: free space, memory, CPU and what Quick Scan found. Start here."),
    TourStep(target: .quickScan, section: .dashboard, title: "Quick Scan",
      message: "Looks for caches, app leftovers and old downloads. It only looks. Nothing is removed until you review it."),
    TourStep(target: .performance, section: .dashboard, title: "Performance",
      message: "See which apps are using memory and CPU right now, including all of their helper processes."),
    TourStep(target: .cleanup, section: .cleaner, title: "Cleanup",
      message: "Caches, logs and downloads you can clear, grouped by how safe each one is."),
    TourStep(target: .storage, section: .storage, title: "Storage",
      message: "Map a folder to see what takes up space. Large Files and Duplicates are tabs at the top of this page."),
    TourStep(target: .apps, section: .applications, title: "Apps",
      message: "Every app on your Mac with its size and when you last opened it. Uninstall an app together with its leftover files. Removed Apps and Startup Items are tabs here."),
    TourStep(target: .photos, section: .photos, title: "Photos",
      message: "Find similar shots, old screenshots and blurry photos. You choose which ones to keep."),
    TourStep(target: .developer, section: .developer, title: "Developer",
      message: "Build caches, simulators and other developer-tool data that can be rebuilt."),
    TourStep(target: .history, section: .history, title: "History",
      message: "Everything MacMint moved to the Trash, with a Restore button while it is still there."),
    TourStep(target: .review, section: .dashboard, title: "Review",
      message: "Nothing is removed until you check it here. Items you pick on any page collect in this list."),
    TourStep(target: .goTo, section: nil, title: "Go to…",
      message: "Press ⌘K and type the name of any page to jump straight to it."),
    TourStep(target: .help, section: nil, title: "Help",
      message: "Open help, check permissions or replay this tour any time."),
  ]
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
    if target.maxX + gap + card.width + margin <= bounds.width, target.height < card.height * 2 {
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
  /// The target's global frame; nil when it isn't on screen.
  let targetFrame: CGRect?
  let back: () -> Void
  let next: () -> Void
  let skip: () -> Void
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  private let cardSize = CGSize(width: 320, height: 196)

  var body: some View {
    GeometryReader { geometry in
      let origin = geometry.frame(in: .global).origin
      let target = targetFrame.map { $0.offsetBy(dx: -origin.x, dy: -origin.y) }
      let hole = target?.insetBy(dx: -6, dy: -6)
      ZStack(alignment: .topLeading) {
        Path { path in
          path.addRect(CGRect(origin: .zero, size: geometry.size))
          if let hole { path.addRoundedRect(in: hole, cornerSize: CGSize(width: 12, height: 12)) }
        }
        .fill(Color.black.opacity(0.42), style: FillStyle(eoFill: true))
        .contentShape(Rectangle())
        .onTapGesture {}
        .accessibilityHidden(true)
        if let hole {
          RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(AppTheme.accent, lineWidth: 2.5)
            .frame(width: hole.width, height: hole.height)
            .offset(x: hole.minX, y: hole.minY)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
        card
          .frame(width: cardSize.width)
          .offset(position(of: target, in: geometry.size))
          .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: index)
      }
    }
    .ignoresSafeArea()
  }

  private func position(of target: CGRect?, in bounds: CGSize) -> CGSize {
    let origin = TourLayout.cardOrigin(target: target, card: cardSize, bounds: bounds)
    return CGSize(width: origin.x, height: origin.y)
  }

  private var card: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack {
        Text("QUICK TOUR · \(index + 1) OF \(count)").font(.system(size: 10, weight: .semibold)).tracking(1.2)
          .foregroundStyle(AppTheme.accentText)
        Spacer()
        Button("Skip tour", action: skip).buttonStyle(.plain).font(.caption).foregroundStyle(.secondary)
          .keyboardShortcut(.cancelAction)
      }
      Text(step.title).font(.system(size: 17, weight: .semibold)).foregroundStyle(AppTheme.ink)
      Text(step.message).font(.callout).foregroundStyle(AppTheme.ink.opacity(0.8))
        .fixedSize(horizontal: false, vertical: true)
      HStack(spacing: 8) {
        HStack(spacing: 4) {
          ForEach(0..<count, id: \.self) { dot in
            Circle().fill(dot == index ? AppTheme.accentText : AppTheme.border).frame(width: 5, height: 5)
          }
        }.accessibilityHidden(true)
        Spacer()
        if index > 0 { Button("Back", action: back).controlSize(.small) }
        Button(index + 1 == count ? "Done" : "Next", action: next)
          .buttonStyle(MintButtonStyle()).controlSize(.small)
          .keyboardShortcut(.defaultAction)
      }
    }
    .padding(16)
    .background(AppTheme.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(AppTheme.border))
    .shadow(color: .black.opacity(0.22), radius: 18, y: 8)
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
