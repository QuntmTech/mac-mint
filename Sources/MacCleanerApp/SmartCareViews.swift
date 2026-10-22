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
  @State private var kind: DownloadKind?

  private var visible: [DownloadItem] {
    guard let kind else { return model.downloadItems }
    return model.downloadItems.filter { $0.kind == kind }
  }

  private var selectedBytes: Int64 { model.queuedDownloads.reduce(0) { $0 + $1.bytes } }

  var body: some View {
    VStack(spacing: 0) {
      PageHeader(title: "Downloads", subtitle: "See what you downloaded, when it changed, and what macOS knows about its use.") {
        HStack(spacing: 8) {
        if !model.selectedDownloadIDs.isEmpty {
          Button("Deselect") { model.keepQueuedFiles(model.queuedDownloads.map(\.url)) }
          Button {
            model.reviewDownloads()
          } label: {
            Label("Review \(ByteFormatter.string(selectedBytes))", systemImage: "trash")
          }
          .buttonStyle(.borderedProminent)
          .disabled(model.isWorking || model.isScanning)
        }
        Button(model.downloadsScanned ? "Rescan" : "Scan") { model.scanDownloads() }
          .buttonStyle(.borderedProminent)
          .disabled(model.isScanning || model.isWorking)
      }
      }
      .padding(AppTheme.pagePadding)
      Divider()

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
        HStack(spacing: 6) {
          filterChip(nil, title: "All")
          ForEach(DownloadKind.allCases.filter { k in model.downloadItems.contains { $0.kind == k } }, id: \.self) { k in
            filterChip(k, title: k.rawValue)
          }
          Spacer()
          Button("Select Never Opened") {
            for item in visible.filter(\.usage.neverOpened) { model.setFileSelection(item.url, selected: true) }
          }
          .disabled(!visible.contains { $0.usage.neverOpened })
        }
        .padding(.horizontal, AppTheme.pagePadding)
        .padding(.vertical, 10)
        .background(AppTheme.surface)
        Divider()
        List(visible) { item in row(item) }
          .listStyle(.inset)
      }
    }
    .task(id: model.autoLoadKey) { model.autoLoadIfNeeded(.downloads) }
  }

  private func filterChip(_ value: DownloadKind?, title: String) -> some View {
    Button(title) { kind = value }
      .buttonStyle(.bordered)
      .tint(kind == value ? AppTheme.accent : .secondary)
      .controlSize(.small)
  }

  private func row(_ item: DownloadItem) -> some View {
    HStack(spacing: 11) {
      Toggle(
        "",
        isOn: Binding(
          get: { model.selectedDownloadIDs.contains(item.id) },
          set: { isOn in
            model.setFileSelection(item.url, selected: isOn)
          })
      )
      .labelsHidden()
      .accessibilityLabel("Select \(item.url.lastPathComponent)")
      FileThumbnail(url: item.url, size: 36)
      VStack(alignment: .leading, spacing: 3) {
        HStack(spacing: 6) {
          Text(item.url.lastPathComponent).fontWeight(.medium).lineLimit(1).truncationMode(.middle)
          if item.usage.neverOpened {
            StatusPill(title: "Never opened", icon: "hand.thumbsup.fill", tint: AppTheme.info)
          }
        }
        Text(item.evidence).font(.caption).foregroundStyle(.secondary)
      }
      Spacer()
      Text(ByteFormatter.string(item.bytes)).font(.callout.monospacedDigit()).frame(width: 86, alignment: .trailing)
      Menu {
        Button("Reveal in Finder") { model.reveal(item.url) }
        Button("Exclude from Future Scans") { model.ignore(item.url) }
      } label: {
        Image(systemName: "ellipsis.circle")
          .accessibilityLabel("More actions")
      }
      .menuStyle(.borderlessButton)
      .frame(width: 28)
    }
    .padding(.vertical, 3)
  }
}
