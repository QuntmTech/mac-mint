import MacCleanerCore
import SwiftUI

struct DashboardView: View {
  @EnvironmentObject private var model: AppViewModel
  @AppStorage(AppViewModel.tourSeenKey) private var tourSeen = false
  @AppStorage(CareService.Keys.onboardingDone) private var onboardingDone = false
  @State private var showingCoverage = false

  var body: some View {
    let categories = OverviewPresentation.categories(model.recommendations)
    ScrollView {
      VStack(alignment: .leading, spacing: 18) {
        greeting
        if onboardingDone && !tourSeen && model.tourStep == nil { tourOffer }
        hero(categories)
        SystemHealthRow(volume: model.volume) { model.selectedSection = .performance }
        StorageOverviewCard(categories: categories, volume: model.volume, scanned: model.lastScanDate != nil)
        if !categories.isEmpty { categoryTiles(categories) }
        LazyVGrid(columns: [GridItem(.flexible(minimum: 300), spacing: 14, alignment: .top),
          GridItem(.flexible(minimum: 280), spacing: 14, alignment: .top)], alignment: .leading, spacing: 14) {
          if model.recommendations.isEmpty { SpaceHistoryCard() } else { SmartCareList() }
          VStack(spacing: 14) {
            if !model.recommendations.isEmpty { SpaceHistoryCard() }
            coverage
            trashCard
          }
        }
        tools
      }
      .frame(maxWidth: 1180).padding(.horizontal, 28).padding(.top, 22).padding(.bottom, 34).frame(maxWidth: .infinity)
    }
    .onAppear {
      guard !SmokeTest.isRequested else { return }
      model.refreshTrashStatus(); model.recordFreeSpace(); model.refreshRecommendations()
    }
  }

  // MARK: Header

  private var greeting: some View {
    HStack(alignment: .bottom, spacing: 16) {
      VStack(alignment: .leading, spacing: 3) {
        Eyebrow(Self.greetingWord(), color: AppTheme.Swatch.mint.text)
        Text("Overview").font(.system(size: 26, weight: .bold)).tracking(-0.6).foregroundStyle(AppTheme.ink)
          .accessibilityAddTraits(.isHeader)
        Text("How your Mac is doing, and where space could come back.").font(.system(size: 13)).foregroundStyle(AppTheme.ink2)
      }
      Spacer(minLength: 12)
      HStack(spacing: 6) {
        Image(systemName: "checkmark.shield.fill").font(.system(size: 12)).foregroundStyle(AppTheme.Swatch.mint.text)
        Text(TrustLine.promise).font(.system(size: 11.5)).foregroundStyle(AppTheme.ink2)
      }
      .padding(.horizontal, 10).frame(height: 26)
      .background(AppTheme.surface, in: Capsule())
      .elevation(.card)
      .accessibilityElement(children: .combine)
    }
  }

  private static func greetingWord(_ date: Date = Date()) -> String {
    switch Calendar.current.component(.hour, from: date) {
    case 5..<12: return "Good morning"
    case 12..<18: return "Good afternoon"
    default: return "Good evening"
    }
  }

  /// For people who finished setup before the tour existed; new installs see it after setup.
  private var tourOffer: some View {
    HStack(spacing: 14) {
      SwatchBadge(symbol: "map.fill", swatch: .iris, size: 34)
      VStack(alignment: .leading, spacing: 2) {
        Text("New here? Take the one-minute tour.").font(.system(size: 13, weight: .semibold)).foregroundStyle(AppTheme.ink)
        Text("It shows where everything lives. Nothing is changed while it's open.")
          .font(.system(size: 12)).foregroundStyle(AppTheme.ink2).fixedSize(horizontal: false, vertical: true)
      }
      Spacer(minLength: 12)
      Button("Not Now") { tourSeen = true }.buttonStyle(MintButtonStyle(.plain)).foregroundStyle(AppTheme.ink2)
      Button("Take the Tour") { model.startTour() }.buttonStyle(MintButtonStyle(.secondary))
    }
    .padding(.horizontal, 16).padding(.vertical, 14)
    .cardBackground(radius: 14)
  }

  // MARK: Hero

  /// Quick Scan itself, as opposed to another page's scan that also sets `isScanning`.
  private var quickScanning: Bool { model.isScanning && model.operationTitle == "Quick Scan" }

  private func hero(_ categories: [OverviewPresentation.Category]) -> some View {
    let found = categories.filter { $0.destination != .trash }.reduce(Int64(0)) { OverviewPresentation.add($0, $1.bytes) }
    let shape = RoundedRectangle(cornerRadius: 22, style: .continuous)
    return ViewThatFits(in: .horizontal) {
      HStack(spacing: 28) {
        heroText(found: found, top: categories.first)
        heroRing(found: found)
      }
      VStack(alignment: .leading, spacing: 20) {
        heroText(found: found, top: categories.first)
        heroRing(found: found)
      }
    }
    .padding(.horizontal, 28).padding(.vertical, 26)
    .frame(maxWidth: .infinity, alignment: .leading)
    .foregroundStyle(.white)
    .background {
      ZStack {
        shape.fill(AppTheme.heroGradient)
        Circle().fill(RadialGradient(colors: [AppTheme.hex(0xA7F0D2).opacity(0.35), .clear], center: .center, startRadius: 0, endRadius: 160))
          .frame(width: 320, height: 320).offset(x: 60, y: -90)
          .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
        Ellipse().fill(RadialGradient(colors: [AppTheme.hex(0x7DD3FC).opacity(0.22), .clear], center: .center, startRadius: 0, endRadius: 180))
          .frame(width: 360, height: 260).offset(x: 0, y: 140)
          .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        Image(systemName: "leaf.fill").font(.system(size: 200)).foregroundStyle(Color.white.opacity(0.05))
          .rotationEffect(.degrees(-18)).offset(x: -190, y: 70)
          .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
      }
      .clipShape(shape)
      // Flattened once into one layer: the glows, leaf and shadow don't re-render when the
      // hero's text changes (the disk reading refreshes about once a minute).
      .drawingGroup()
      .shadow(color: AppTheme.hex(0x045A46).opacity(0.35), radius: 12, y: 8)
      .accessibilityHidden(true)
    }
  }

  private func heroText(found: Int64, top: OverviewPresentation.Category?) -> some View {
    VStack(alignment: .leading, spacing: 12) {
      Label("QUICK SCAN", systemImage: "dot.radiowaves.left.and.right")
        .font(.system(size: 10.5, weight: .bold)).tracking(1.4).foregroundStyle(AppTheme.hex(0xB7F5DA))
      if quickScanning {
        Text("Getting the full picture…").font(.system(size: 34, weight: .bold)).tracking(-1.1)
          .fixedSize(horizontal: false, vertical: true)
        checkChips
      } else if found > 0 {
        Text("\(ByteFormatter.string(found)) is worth a look.").font(.system(size: 34, weight: .bold)).tracking(-1.1)
          .fixedSize(horizontal: false, vertical: true).frame(maxWidth: 520, alignment: .leading)
        Text((top.map { "\($0.title) is the largest part. " } ?? "") + "You check every item before anything moves to the Trash.")
          .font(.system(size: 13.5)).foregroundStyle(Color.white.opacity(0.86))
          .fixedSize(horizontal: false, vertical: true).frame(maxWidth: 470, alignment: .leading)
      } else {
        Text(model.lastScanDate == nil ? "Let's see what's taking up space." : "Nothing big to clear right now.")
          .font(.system(size: 34, weight: .bold)).tracking(-1.1)
          .fixedSize(horizontal: false, vertical: true).frame(maxWidth: 520, alignment: .leading)
        Text("Quick Scan checks caches, app leftovers, old downloads, developer clutter and the Trash. It only reads. Nothing is removed.")
          .font(.system(size: 13.5)).foregroundStyle(Color.white.opacity(0.86))
          .fixedSize(horizontal: false, vertical: true).frame(maxWidth: 470, alignment: .leading)
      }
      ViewThatFits(in: .horizontal) {
        HStack(spacing: 8) { reviewButton; scanButton }
        VStack(alignment: .leading, spacing: 8) { reviewButton; scanButton }
      }
      .padding(.top, 4)
      HStack(spacing: 6) {
        if model.isScanning && !quickScanning {
          ProgressView().controlSize(.mini).tint(.white)
          Text("\(model.operationTitle ?? "A scan") is running · Quick Scan can start when it finishes")
        } else if quickScanning {
          Image(systemName: "eye")
          Text(model.scanCompletedAreas.isEmpty ? "Checking known storage locations…" : "\(model.scanCompletedAreas.count) of 5 checks done")
        } else if let date = model.lastScanDate {
          Image(systemName: "clock")
          Text("Last scanned \(date.formatted(.relative(presentation: .named)))")
        } else {
          Image(systemName: "lock.shield")
          Text("Local scan · No account needed")
        }
      }
      .font(.system(size: 11.5)).foregroundStyle(Color.white.opacity(0.8))
    }
    .frame(minWidth: 300, maxWidth: .infinity, alignment: .leading)
  }

  /// The checks Quick Scan has finished, while it runs.
  private var checkChips: some View {
    HStack(spacing: 6) {
      ForEach(model.scanCompletedAreas.prefix(4), id: \.self) { area in
        heroChip(area, symbol: "checkmark.circle.fill", done: true)
      }
      heroChip("Checking…", symbol: "magnifyingglass", done: false)
    }
  }

  private func heroChip(_ title: String, symbol: String, done: Bool) -> some View {
    HStack(spacing: 5) {
      Image(systemName: symbol).font(.system(size: 11, weight: .semibold))
      Text(title).font(.system(size: 12, weight: .medium)).lineLimit(1)
    }
    .foregroundStyle(done ? AppTheme.hex(0x04583F) : Color.white)
    .padding(.horizontal, 10).frame(height: 26)
    .background(done ? Color.white.opacity(0.92) : Color.white.opacity(0.14), in: Capsule())
  }

  private func heroRing(found: Int64) -> some View {
    let stats = model.volume
    let used = stats.isMeasured ? min(1, Double(stats.used) / Double(stats.total)) : 0
    let foundShare = stats.isMeasured ? min(used, Double(found) / Double(stats.total)) : 0
    return VStack(spacing: 10) {
      ZStack {
        Circle().stroke(Color.white.opacity(0.16), lineWidth: 13)
        Circle().trim(from: 0, to: used)
          .stroke(Color.white.opacity(0.92), style: StrokeStyle(lineWidth: 13, lineCap: .round))
          .rotationEffect(.degrees(-90))
        if foundShare > 0 {
          Circle().trim(from: max(0, used - foundShare), to: used)
            .stroke(AppTheme.hex(0x6EE7B7), style: StrokeStyle(lineWidth: 13, lineCap: .round))
            .rotationEffect(.degrees(-90))
        }
        VStack(spacing: 3) {
          Text(stats.isMeasured ? ByteFormatter.string(stats.free) : "—").font(AppTheme.number(28)).tracking(-0.6)
            .monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
          Text(stats.isMeasured ? "available" : "unavailable").font(.system(size: 11.5)).foregroundStyle(Color.white.opacity(0.8))
        }
        .padding(.horizontal, 18)
      }
      .frame(width: 156, height: 156)
      HStack(spacing: 12) {
        legendDot(Color.white, stats.isMeasured ? "Used " + ByteFormatter.string(stats.used) : "Capacity unknown")
        if found > 0 { legendDot(AppTheme.hex(0x6EE7B7), "Worth a look") }
      }
      .font(.system(size: 11)).foregroundStyle(Color.white.opacity(0.85))
    }
    .padding(.horizontal, 6)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("Storage usage")
    .accessibilityValue(stats.isMeasured
      ? "\(ByteFormatter.string(stats.free)) available. \(ByteFormatter.string(stats.used)) of \(ByteFormatter.string(stats.total)) used."
      : "Disk space unavailable")
  }

  private func legendDot(_ color: Color, _ title: String) -> some View {
    HStack(spacing: 5) {
      RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 8, height: 8)
      Text(title).monospacedDigit()
    }
  }

  private var scanButton: some View {
    Button {
      if quickScanning { model.cancelCurrentOperation() } else { model.runSmartCare() }
    } label: {
      Label(quickScanning ? "Cancel Scan" : model.lastScanDate == nil ? "Run Quick Scan" : "Scan Again",
        systemImage: quickScanning ? "xmark" : "dot.radiowaves.left.and.right")
    }
    .buttonStyle(HeroButtonStyle(filled: model.safeRecommendationBytes == 0 && !quickScanning))
    .disabled(!quickScanning && (model.isScanning || model.isWorking))
    .tourTarget(.quickScan)
  }

  @ViewBuilder private var reviewButton: some View {
    if !quickScanning && model.safeRecommendationBytes > 0 {
      Button { model.reviewAllSafe() } label: {
        Label("Review \(ByteFormatter.string(model.safeRecommendationBytes)) rebuildable", systemImage: "checklist")
      }
      .buttonStyle(HeroButtonStyle(filled: true)).disabled(model.isWorking || model.isScanning)
      .help("Review rebuildable items before moving them to the Trash")
    }
  }

  // MARK: Found space

  /// What Quick Scan found, one colored tile per area, largest first and twice as wide.
  private func categoryTiles(_ categories: [OverviewPresentation.Category]) -> some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack(alignment: .firstTextBaseline) {
        Text("Where space can come back").font(.system(size: 17, weight: .bold)).tracking(-0.3).foregroundStyle(AppTheme.ink)
        Spacer()
        Text("Estimates · you review everything first").font(.system(size: 11.5)).foregroundStyle(AppTheme.ink3)
      }
      .padding(.top, 4)
      BentoLayout(minimumWidth: 176, height: 132, spacing: 12) {
        ForEach(categories) { category in
          CategoryTile(category: category) {
            if category.destination == .trash { model.emptyTrash() } else { model.open(category.destination) }
          }
        }
      }
    }
  }

  // MARK: Side cards

  private var coverage: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(spacing: 12) {
        SwatchBadge(symbol: "checklist.checked", swatch: .slate, size: 32)
        VStack(alignment: .leading, spacing: 2) {
          Text("Know what's been checked").font(.system(size: 13, weight: .semibold)).foregroundStyle(AppTheme.ink)
          Text("\(model.scanCompletedAreas.count) of 5 areas · \(model.ignoredPaths.count) exclusion\(model.ignoredPaths.count == 1 ? "" : "s") · \(model.scanIssues.count) issue\(model.scanIssues.count == 1 ? "" : "s")")
            .font(.system(size: 11.5)).foregroundStyle(AppTheme.ink3).monospacedDigit()
        }
        Spacer(minLength: 8)
        Button(showingCoverage ? "Hide" : "Details") { showingCoverage.toggle() }.buttonStyle(MintButtonStyle(.plain))
          .accessibilityLabel(showingCoverage ? "Hide what's been checked" : "Show what's been checked")
      }
      if showingCoverage {
        VStack(alignment: .leading, spacing: 8) {
          Text(model.scanCompletedAreas.isEmpty
            ? "Quick Scan checks known cache, app, developer, Downloads, and home Trash locations. Run a scan to see coverage here."
            : "Completed: " + model.scanCompletedAreas.joined(separator: "; "))
          Text("Storage mapping, duplicate matching, Photos analysis, and project searches run separately.")
          HStack(spacing: 8) {
            if !model.scanIssues.isEmpty {
              Button("Review \(model.scanIssues.count) scan issues") { model.showingScanIssues = true }
                .buttonStyle(MintButtonStyle(.secondary)).controlSize(.small)
            }
            Button("Manage exclusions") { model.selectedSection = .settings }
              .buttonStyle(MintButtonStyle(.secondary)).controlSize(.small)
          }
        }
        .font(.system(size: 12)).foregroundStyle(AppTheme.ink2).fixedSize(horizontal: false, vertical: true)
        .padding(.leading, 44)
      }
    }
    .padding(.horizontal, 16).padding(.vertical, 14)
    .cardBackground()
  }

  @ViewBuilder private var trashCard: some View {
    if let status = model.trashStatus, status.items > 0 || !status.isComplete {
      HStack(spacing: 12) {
        SwatchBadge(symbol: "trash.fill", swatch: .graphite, size: 32)
        VStack(alignment: .leading, spacing: 2) {
          Text(status.isComplete ? "\(ByteFormatter.string(status.bytes)) still in the Trash" : "Still in the Trash")
            .font(.system(size: 13, weight: .semibold)).foregroundStyle(AppTheme.ink).monospacedDigit()
          Text(status.isComplete
            ? "\(status.items) item\(status.items == 1 ? "" : "s") · space comes back after you empty it"
            : "Full Disk Access is needed to measure your home Trash.")
            .font(.system(size: 11.5)).foregroundStyle(AppTheme.ink3).fixedSize(horizontal: false, vertical: true)
        }
        Spacer(minLength: 8)
        Button("Open in Finder") { model.emptyTrash() }.buttonStyle(MintButtonStyle(.secondary)).controlSize(.small)
          .disabled(model.isWorking)
      }
      .padding(.horizontal, 16).padding(.vertical, 14)
      .cardBackground()
    }
  }

  // MARK: Explore

  private var tools: some View {
    LazyVGrid(columns: [GridItem(.adaptive(minimum: 200), spacing: 10)], spacing: 10) {
      tool("Explore storage", detail: "What takes up room, folder by folder", section: .storage)
      tool("Manage apps", detail: "Apps and the data they leave behind", section: .applications)
      tool("Review photos", detail: "Similar shots and old screenshots", section: .photos)
      tool("Developer workspace", detail: "Build output, caches and models", section: .developer)
    }
  }

  private func tool(_ title: String, detail: String, section: AppViewModel.Section) -> some View {
    let swatch = section.swatch
    return Button { model.selectedSection = section } label: {
      HStack(spacing: 11) {
        Image(systemName: section.icon).font(.system(size: 14, weight: .semibold)).foregroundStyle(swatch.text)
          .frame(width: 30, height: 30)
          .background(swatch.tint, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
          .accessibilityHidden(true)
        VStack(alignment: .leading, spacing: 1) {
          Text(title).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(AppTheme.ink)
          Text(detail).font(.system(size: 11)).foregroundStyle(AppTheme.ink3).lineLimit(1)
        }
        Spacer(minLength: 4)
        Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(AppTheme.ink3)
      }
      .padding(.horizontal, 14).padding(.vertical, 12)
      .cardBackground(radius: 13)
      .contentShape(RoundedRectangle(cornerRadius: 13))
    }
    .buttonStyle(CardButtonStyle())
    .accessibilityElement(children: .combine)
  }
}

/// The hero's own buttons: white with deep mint text, or a translucent white ghost.
private struct HeroButtonStyle: ButtonStyle {
  let filled: Bool
  @Environment(\.isEnabled) private var isEnabled

  func makeBody(configuration: Configuration) -> some View {
    let shape = RoundedRectangle(cornerRadius: 9, style: .continuous)
    configuration.label
      .font(.system(size: 13, weight: filled ? .bold : .semibold))
      .foregroundStyle(filled ? AppTheme.hex(0x04583F) : Color.white)
      .padding(.horizontal, 15).frame(height: 34)
      .background {
        if filled {
          shape.fill(Color.white).shadow(color: .black.opacity(0.25), radius: 8, y: 6)
        } else {
          shape.fill(Color.white.opacity(0.14)).overlay(shape.strokeBorder(Color.white.opacity(0.28)))
        }
      }
      .contentShape(shape)
      .brightness(configuration.isPressed ? -0.06 : 0)
      .scaleEffect(configuration.isPressed ? 0.98 : 1)
      .opacity(isEnabled ? 1 : 0.5)
  }
}

/// Tiles in rows of equal height; the first (largest) spans two columns once three fit.
struct BentoLayout: Layout {
  let minimumWidth: CGFloat
  let height: CGFloat
  let spacing: CGFloat

  private func columns(for width: CGFloat) -> Int {
    max(1, Int((width + spacing) / (minimumWidth + spacing)))
  }

  /// Each item's column and row.
  private func cells(count: Int, columns: Int) -> [(column: Int, row: Int, span: Int)] {
    var cells: [(column: Int, row: Int, span: Int)] = []
    var column = 0, row = 0
    for index in 0..<count {
      let span = index == 0 && columns >= 3 ? 2 : 1
      if column + span > columns { column = 0; row += 1 }
      cells.append((column: column, row: row, span: span))
      column += span
    }
    return cells
  }

  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    let width = proposal.width ?? (minimumWidth * 3 + spacing * 2)
    let placed = cells(count: subviews.count, columns: columns(for: width))
    let rows = (placed.map { $0.row }.max() ?? -1) + 1
    return CGSize(width: width, height: rows == 0 ? 0 : CGFloat(rows) * height + CGFloat(rows - 1) * spacing)
  }

  func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
    let count = columns(for: bounds.width)
    let columnWidth = (bounds.width - spacing * CGFloat(count - 1)) / CGFloat(count)
    for (index, cell) in cells(count: subviews.count, columns: count).enumerated() {
      let width = columnWidth * CGFloat(cell.span) + spacing * CGFloat(cell.span - 1)
      subviews[index].place(
        at: CGPoint(x: bounds.minX + CGFloat(cell.column) * (columnWidth + spacing), y: bounds.minY + CGFloat(cell.row) * (height + spacing)),
        proposal: ProposedViewSize(width: width, height: height))
    }
  }
}
