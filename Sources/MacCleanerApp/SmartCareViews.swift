import Charts
import MacCleanerCore
import SwiftUI

// MARK: - Smart Care recommendations

struct SmartCareList: View {
  @EnvironmentObject private var model: AppViewModel

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack(alignment: .firstTextBaseline, spacing: 8) {
        Text("Recommended for you").font(.system(size: 15, weight: .bold)).tracking(-0.2).foregroundStyle(AppTheme.ink)
        Spacer()
        let count = model.displayedRecommendations.count
        Text("\(count) suggestion\(count == 1 ? "" : "s")" + (model.smartCareRanAt.map { " · checked \($0.formatted(.relative(presentation: .named)))" } ?? ""))
          .font(.system(size: 11.5)).foregroundStyle(AppTheme.ink3)
      }
      .padding(.horizontal, 18).padding(.top, 14).padding(.bottom, 4)
      Text("Ranked by estimated space and how sure MacMint is. Sizes are estimates until the Trash is emptied.")
        .font(.system(size: 11.5)).foregroundStyle(AppTheme.ink3).fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, 18).padding(.bottom, 10)
      AIReviewPanel().padding(.horizontal, 18).padding(.bottom, 8)
      ForEach(model.displayedRecommendations) { recommendation in
        Rectangle().fill(AppTheme.divider).frame(height: 1)
        RecommendationRow(recommendation: recommendation).padding(.horizontal, 18).padding(.vertical, 11)
      }
    }
    .cardBackground()
  }
}

extension Recommendation.Confidence {
  /// Rebuildable is mint, Likely unneeded is sky, Worth a look is amber.
  var swatch: AppTheme.Swatch {
    switch self {
    case .safe: return .mint
    case .likely: return .sky
    case .review: return .amber
    }
  }
  var symbol: String {
    switch self {
    case .safe: return "checkmark.shield.fill"
    case .likely: return "clock.fill"
    case .review: return "eye.fill"
    }
  }
}

struct RecommendationRow: View {
  let recommendation: Recommendation
  @EnvironmentObject private var model: AppViewModel

  var body: some View {
    HStack(alignment: .center, spacing: 12) {
      SwatchBadge(symbol: recommendation.symbol, swatch: OverviewPresentation.style(recommendation.destination).swatch, size: 32)
      VStack(alignment: .leading, spacing: 3) {
        Text(recommendation.title).font(.system(size: 13, weight: .semibold)).foregroundStyle(AppTheme.ink).lineLimit(1)
        HStack(spacing: 6) {
          Chip(title: recommendation.confidence.label, symbol: recommendation.confidence.symbol, swatch: recommendation.confidence.swatch)
          Text(recommendation.detail).font(.system(size: 11.5)).foregroundStyle(AppTheme.ink3).lineLimit(1)
        }
        AIRecommendationNote(recommendationID: recommendation.id)
      }
      .help(recommendation.detail)
      Spacer(minLength: 8)
      VStack(alignment: .trailing, spacing: 1) {
        Text("≈ " + ByteFormatter.string(recommendation.bytes)).font(AppTheme.number(13, weight: .semibold)).monospacedDigit()
          .foregroundStyle(AppTheme.ink)
        if recommendation.count > 1 {
          Text("\(recommendation.count) items").font(.system(size: 10.5)).foregroundStyle(AppTheme.ink3)
        }
      }
      if recommendation.canReview {
        Button("Review") { model.review(recommendation) }
          .buttonStyle(MintButtonStyle(.secondary)).controlSize(.small)
          .disabled(model.isWorking || model.isScanning)
          .help("Opens the review sheet — nothing moves until you confirm")
      } else {
        Button("Show") { model.open(recommendation.destination) }.buttonStyle(MintButtonStyle(.secondary)).controlSize(.small)
      }
    }
    .accessibilityElement(children: .contain)
    .accessibilityLabel(
      "\(recommendation.title), about \(ByteFormatter.string(recommendation.bytes)), \(recommendation.confidence.label)")
  }
}

// MARK: - Free-space history

struct SpaceHistoryCard: View {
  @EnvironmentObject private var model: AppViewModel
  private static let line = AppTheme.hex(0x10B981)

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(alignment: .firstTextBaseline) {
        Text("Free space, last 30 days").font(.system(size: 15, weight: .bold)).tracking(-0.2).foregroundStyle(AppTheme.ink)
        Spacer()
        if let change = model.weeklySpaceChange {
          Text(change >= 0
            ? "+\(ByteFormatter.string(change)) this week"
            : "−\(ByteFormatter.string(-change)) this week")
            .font(.system(size: 12, weight: .semibold)).monospacedDigit()
            .foregroundStyle(change >= 0 ? AppTheme.accentText : AppTheme.warning)
        }
      }
      if model.spaceHistory.count >= 2 {
        Chart(model.spaceHistory) { sample in
          AreaMark(
            x: .value("Day", sample.day, unit: .day),
            y: .value("Free", Double(sample.freeBytes) / 1_073_741_824)
          )
          .foregroundStyle(
            LinearGradient(colors: [Self.line.opacity(0.35), Self.line.opacity(0)], startPoint: .top, endPoint: .bottom))
          LineMark(
            x: .value("Day", sample.day, unit: .day),
            y: .value("Free", Double(sample.freeBytes) / 1_073_741_824)
          )
          .foregroundStyle(Self.line)
          .lineStyle(StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
        }
        .chartYAxisLabel("GB free")
        .frame(height: 120)
        .accessibilityLabel("Free space over the last \(model.spaceHistory.count) days")
      } else {
        Text("MacMint records free space once a day. The trend appears after a second day.")
          .font(.system(size: 12)).foregroundStyle(AppTheme.ink2)
      }
      if !model.storageGrowth.isEmpty {
        Rectangle().fill(AppTheme.divider).frame(height: 1)
        Eyebrow("Grew since your last Storage map")
        ForEach(model.storageGrowth.prefix(4)) { growth in
          HStack {
            Image(systemName: "folder.fill").foregroundStyle(AppTheme.Swatch.indigo.text).accessibilityHidden(true)
            Text(displayPath(growth.path)).lineLimit(1).truncationMode(.middle).foregroundStyle(AppTheme.ink)
            Spacer()
            Text("+\(ByteFormatter.string(growth.delta))")
              .font(AppTheme.number(12, weight: .semibold)).monospacedDigit()
              .foregroundStyle(AppTheme.warning)
          }
          .font(.system(size: 12))
        }
        Button("Open Storage") { model.selectedSection = .storage }
          .buttonStyle(MintButtonStyle(.plain)).controlSize(.small)
      }
    }
    .padding(.horizontal, 18).padding(.vertical, 16)
    .cardBackground()
  }

  private func displayPath(_ path: String) -> String {
    path.replacingOccurrences(of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~")
  }
}

// MARK: - Downloads

struct DownloadsView: View {
  @EnvironmentObject private var model: AppViewModel
  @Environment(\.areaSwatch) private var area
  @State private var kind: DownloadKind?
  @State private var showOrganizer = false

  private var visible: [DownloadItem] {
    guard let kind else { return model.downloadItems }
    return model.downloadItems.filter { $0.kind == kind }
  }

  private var selectedBytes: Int64 { model.queuedDownloads.reduce(0) { $0 + $1.bytes } }

  var body: some View {
    VStack(spacing: 0) {
      header

      if model.isScanning && (model.operationTitle == "Downloads" || (model.downloadItems.isEmpty && !model.downloadsScanned)) {
        let own = model.operationTitle == "Downloads" || model.operationTitle == "Quick Scan"
        LoadingState(title: own ? "Reading your Downloads…" : "Downloads are next",
          detail: own
            ? "Checking each download's size, dates and Spotlight's record of when you last opened it."
            : "\(model.operationTitle ?? "Another scan") is running. Downloads load as soon as it finishes.",
          symbol: "arrow.down.circle", swatch: .teal,
          cancel: model.operationTitle == "Downloads" ? { model.cancelCurrentOperation() } : nil)
      } else if model.downloadItems.isEmpty {
        EmptyState(
          icon: model.downloadsScanned ? "checkmark.seal" : "arrow.down.circle",
          title: model.downloadsScanned ? "No downloads found" : "Take a look at your Downloads",
          detail:
            "Review downloads using their size, change dates, and available macOS usage records.",
          actionTitle: model.downloadsScanned ? nil : "Read Downloads",
          action: model.downloadsScanned ? nil : { model.scanDownloads() })
      } else {
        content
        selectionBar
      }
    }
    .task(id: model.autoLoadKey) { model.autoLoadIfNeeded(.downloads) }
    .sheet(isPresented: $showOrganizer) { OrganizerView() }
  }

  // MARK: Header

  private var header: some View {
    PageHeader(title: "Downloads", subtitle: "See what you downloaded, when it changed, and what macOS knows about its use.") {
      Button(model.downloadsScanned ? "Rescan" : "Scan",
        systemImage: model.downloadsScanned ? "arrow.clockwise" : "magnifyingglass") { model.scanDownloads() }
        .buttonStyle(MintButtonStyle(.area))
        .disabled(model.isScanning || model.isWorking)
    }
    .padding(.horizontal, AppTheme.pagePadding)
    .padding(.top, AppTheme.pageTopPadding)
    .padding(.bottom, 14)
    .frame(maxWidth: 1180)
    .frame(maxWidth: .infinity)
  }

  private var selectionBar: some View {
    let queued = model.queuedDownloads
    return SelectionBar(
      count: queued.count,
      bytes: selectedBytes,
      clear: { model.keepQueuedFiles(model.queuedDownloads.map(\.url)) },
      commitTitle: "Review…",
      commitDisabled: model.isWorking || model.isScanning,
      commit: { model.reviewDownloads() })
  }

  // MARK: Content

  private var content: some View {
    let items = visible
    return ScrollView {
      VStack(alignment: .leading, spacing: 14) {
        typeTiles
        organizerPromo
        tableToolbar(items)
        table(items)
      }
      .padding(.horizontal, AppTheme.pagePadding)
      .padding(.top, 2)
      .padding(.bottom, 24)
      .frame(maxWidth: 1180)
      .frame(maxWidth: .infinity)
    }
  }

  private var presentKinds: [DownloadKind] {
    DownloadKind.allCases.filter { k in model.downloadItems.contains { $0.kind == k } }
  }

  /// One tile per kind of download; each tile is the kind filter.
  private var typeTiles: some View {
    LazyVGrid(columns: [GridItem(.adaptive(minimum: 128), spacing: 10)], spacing: 10) {
      typeTile(nil, title: "All", items: model.downloadItems)
      ForEach(presentKinds, id: \.self) { k in
        typeTile(k, title: k.rawValue, items: model.downloadItems.filter { $0.kind == k })
      }
    }
  }

  private func typeTile(_ value: DownloadKind?, title: String, items: [DownloadItem]) -> some View {
    let selected = kind == value
    let swatch = Self.swatch(for: value)
    let bytes = items.reduce(Int64(0)) { $0 + $1.bytes }
    let shape = RoundedRectangle(cornerRadius: 13, style: .continuous)
    return Button { kind = value } label: {
      VStack(alignment: .leading, spacing: 6) {
        Image(systemName: Self.symbol(for: value))
          .font(.system(size: 14, weight: .semibold)).symbolVariant(.fill)
          .foregroundStyle(swatch.text)
          .frame(width: 28, height: 28)
          .background(swatch.tint, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        Text(title)
          .font(.system(size: 12, weight: .semibold))
          .foregroundStyle(AppTheme.ink)
          .lineLimit(1)
        HStack(alignment: .firstTextBaseline, spacing: 5) {
          Text(ByteFormatter.string(bytes))
            .font(AppTheme.number(17)).monospacedDigit()
            .foregroundStyle(AppTheme.ink)
            .lineLimit(1).minimumScaleFactor(0.8)
          Text("\(items.count)")
            .font(.system(size: 11, weight: .medium)).monospacedDigit()
            .foregroundStyle(AppTheme.ink3)
        }
      }
      .padding(.horizontal, 13)
      .padding(.vertical, 12)
      .frame(maxWidth: .infinity, alignment: .leading)
      .cardBackground(radius: 13)
      .overlay(shape.strokeBorder(selected ? area.color : Color.clear, lineWidth: 2))
      .contentShape(shape)
    }
    .buttonStyle(CardButtonStyle())
    .accessibilityLabel("\(title), \(ByteFormatter.string(bytes)), \(items.count) items")
    .accessibilityAddTraits(selected ? .isSelected : [])
  }

  /// Opens the organizer sheet. Organizing renames or moves files inside the folder you pick;
  /// it never moves anything to the Trash.
  private var organizerPromo: some View {
    let shape = RoundedRectangle(cornerRadius: AppTheme.corner, style: .continuous)
    return HStack(spacing: 14) {
      SwatchBadge(symbol: "folder.badge.gearshape", swatch: .iris, size: 36)
      VStack(alignment: .leading, spacing: 2) {
        Text("Want the keepers organized?")
          .font(.system(size: 13, weight: .semibold))
          .foregroundStyle(AppTheme.ink)
        Text("MacMint can suggest folders by file type. You approve every move, and nothing goes to the Trash.")
          .font(.system(size: 12))
          .foregroundStyle(AppTheme.ink2)
          .fixedSize(horizontal: false, vertical: true)
      }
      Spacer(minLength: 8)
      Button("Organize…") { showOrganizer = true }
        .buttonStyle(MintButtonStyle(.secondary))
        .controlSize(.small)
        .help("Suggest folders and names. You review every change first.")
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 14)
    .background {
      shape
        .fill(LinearGradient(colors: [AppTheme.Swatch.iris.tint, AppTheme.Swatch.sky.tint],
          startPoint: .leading, endPoint: .trailing))
        .elevation(.card)
    }
  }

  private func tableToolbar(_ items: [DownloadItem]) -> some View {
    let total = items.reduce(Int64(0)) { $0 + $1.bytes }
    return HStack(alignment: .firstTextBaseline, spacing: 10) {
      Text(kind?.rawValue ?? "All downloads")
        .font(.system(size: 15, weight: .bold)).tracking(-0.2)
        .foregroundStyle(AppTheme.ink)
        .lineLimit(1)
      Text("\(items.count) items · \(ByteFormatter.string(total))")
        .font(.system(size: 11.5)).monospacedDigit()
        .foregroundStyle(AppTheme.ink3)
        .lineLimit(1)
      Spacer(minLength: 8)
      Button("Select Never Opened") {
        for item in visible.filter(\.usage.neverOpened) { model.setFileSelection(item.url, selected: true) }
      }
      .buttonStyle(MintButtonStyle(.secondary))
      .controlSize(.small)
      .disabled(!visible.contains { $0.usage.neverOpened })
    }
  }

  private func table(_ items: [DownloadItem]) -> some View {
    VStack(spacing: 0) {
      HStack(spacing: 12) {
        Color.clear.frame(width: 22, height: 1)
        Text("Name").frame(maxWidth: .infinity, alignment: .leading)
        Text("Safety").frame(width: 130, alignment: .leading)
        Text("Size").frame(width: 80, alignment: .trailing)
        Color.clear.frame(width: 28, height: 1)
      }
      .font(.system(size: 11, weight: .semibold))
      .foregroundStyle(AppTheme.ink2)
      .padding(.horizontal, 16)
      .frame(height: 30)
      .background(AppTheme.panel)
      .accessibilityHidden(true)
      LazyVStack(spacing: 0) {
        ForEach(items) { item in
          Rectangle().fill(AppTheme.divider).frame(height: 1)
          row(item)
        }
      }
    }
    .clipShape(RoundedRectangle(cornerRadius: AppTheme.corner, style: .continuous))
    .cardBackground()
  }

  private func row(_ item: DownloadItem) -> some View {
    let selected = model.selectedDownloadIDs.contains(item.id)
    return HStack(spacing: 12) {
      Toggle(
        "",
        isOn: Binding(
          get: { model.selectedDownloadIDs.contains(item.id) },
          set: { isOn in
            model.setFileSelection(item.url, selected: isOn)
          })
      )
      .toggleStyle(MintCheckboxStyle())
      .labelsHidden()
      .accessibilityLabel("Select \(item.url.lastPathComponent)")
      .frame(width: 22)

      HStack(spacing: 10) {
        FileThumbnail(url: item.url, size: 30)
        VStack(alignment: .leading, spacing: 2) {
          Text(item.url.lastPathComponent)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(AppTheme.ink)
            .lineLimit(1).truncationMode(.middle)
          Text(item.evidence)
            .font(.system(size: 11.5))
            .foregroundStyle(AppTheme.ink2)
            .lineLimit(2)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)

      safetyChip(item)
        .frame(width: 130, alignment: .leading)

      Text(ByteFormatter.string(item.bytes))
        .font(AppTheme.number(13, weight: .semibold)).monospacedDigit()
        .foregroundStyle(AppTheme.ink)
        .frame(width: 80, alignment: .trailing)

      Menu {
        Button("Reveal in Finder") { model.reveal(item.url) }
        Button("Exclude from Future Scans") { model.ignore(item.url) }
      } label: {
        Image(systemName: "ellipsis.circle")
          .accessibilityLabel("More actions")
      }
      .menuStyle(.borderlessButton)
      .menuIndicator(.hidden)
      .frame(width: 28)
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 8)
    .frame(minHeight: 48)
    .background(selected ? AppTheme.selection.opacity(0.35) : Color.clear)
  }

  /// Never-opened downloads are likely unneeded; anything opened before, or with no usage
  /// record, needs a person to look.
  @ViewBuilder
  private func safetyChip(_ item: DownloadItem) -> some View {
    if item.usage.neverOpened {
      Chip.likelyUnneeded
    } else {
      RiskBadge(risk: .review)
    }
  }

  private static func symbol(for kind: DownloadKind?) -> String {
    guard let kind else { return "tray.full" }
    switch kind {
    case .installer: return "shippingbox"
    case .archive: return "archivebox"
    case .video: return "film"
    case .audio: return "music.note"
    case .image: return "photo"
    case .document: return "doc.text"
    case .folder: return "folder"
    case .other: return "doc"
    }
  }

  private static func swatch(for kind: DownloadKind?) -> AppTheme.Swatch {
    guard let kind else { return .teal }
    switch kind {
    case .installer: return .indigo
    case .archive: return .amber
    case .video: return .pink
    case .audio: return .orange
    case .image: return .sky
    case .document: return .iris
    case .folder: return .mint
    case .other: return .graphite
    }
  }
}
