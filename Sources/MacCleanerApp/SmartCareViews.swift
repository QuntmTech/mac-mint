import Charts
import MacCleanerCore
import SwiftUI

// MARK: - Smart Care recommendations

struct SmartCareList: View {
  @EnvironmentObject private var model: AppViewModel

  var body: some View {
    SurfaceCard {
      VStack(alignment: .leading, spacing: 12) {
        HStack(alignment: .firstTextBaseline) {
          VStack(alignment: .leading, spacing: 2) {
            Text("Recommendations").font(.headline)
            Text("Ranked by estimated space and how confident MacMint is. Sizes are estimates until the Trash is emptied.")
              .font(.caption)
              .foregroundStyle(.secondary)
              .fixedSize(horizontal: false, vertical: true)
          }
          Spacer()
          if let ran = model.smartCareRanAt {
            Text("Checked \(ran.formatted(.relative(presentation: .named)))")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
        }
        AIReviewPanel()
        Divider()
        ForEach(model.displayedRecommendations) { recommendation in
          RecommendationRow(recommendation: recommendation)
          if recommendation.id != model.displayedRecommendations.last?.id { Divider() }
        }
      }
    }
  }
}

struct RecommendationRow: View {
  let recommendation: Recommendation
  @EnvironmentObject private var model: AppViewModel

  private var tint: Color {
    switch recommendation.confidence {
    case .safe: return AppTheme.accentText
    case .likely: return AppTheme.info
    case .review: return AppTheme.warning
    }
  }

  var body: some View {
    HStack(alignment: .center, spacing: 12) {
      ZStack {
        RoundedRectangle(cornerRadius: 9, style: .continuous)
          .fill(tint.opacity(0.12))
          .frame(width: 36, height: 36)
        Image(systemName: recommendation.symbol)
          .font(.system(size: 15, weight: .semibold))
          .foregroundStyle(tint)
      }
      .accessibilityHidden(true)

      VStack(alignment: .leading, spacing: 3) {
        HStack(spacing: 6) {
          Text(recommendation.title).fontWeight(.semibold)
          StatusPill(title: recommendation.confidence.label, icon: icon, tint: tint)
        }
        Text(recommendation.detail)
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(3)
          .fixedSize(horizontal: false, vertical: true)
        AIRecommendationNote(recommendationID: recommendation.id)
      }

      Spacer(minLength: 8)

      VStack(alignment: .trailing, spacing: 2) {
        Text("≈ " + ByteFormatter.string(recommendation.bytes))
          .font(.callout.monospacedDigit().weight(.semibold))
        if recommendation.count > 1 {
          Text("\(recommendation.count) items").font(.caption2).foregroundStyle(.secondary)
        }
      }

      if recommendation.canReview {
        Button("Review") { model.review(recommendation) }
          .disabled(model.isWorking || model.isScanning)
          .help("Opens the review sheet — nothing moves until you confirm")
      } else {
        Button("Show") { model.open(recommendation.destination) }
      }
    }
    .padding(.vertical, 2)
    .accessibilityElement(children: .contain)
    .accessibilityLabel(
      "\(recommendation.title), about \(ByteFormatter.string(recommendation.bytes)), \(recommendation.confidence.label)")
  }

  private var icon: String {
    switch recommendation.confidence {
    case .safe: return "checkmark.shield.fill"
    case .likely: return "hand.thumbsup.fill"
    case .review: return "eye.fill"
    }
  }
}

// MARK: - Free-space history

struct SpaceHistoryCard: View {
  @EnvironmentObject private var model: AppViewModel

  var body: some View {
    SurfaceCard {
      VStack(alignment: .leading, spacing: 10) {
        HStack(alignment: .firstTextBaseline) {
          Text("Free space").font(.headline)
          Spacer()
          if let change = model.weeklySpaceChange {
            Label(
              change >= 0
                ? "\(ByteFormatter.string(change)) more free than a week ago"
                : "\(ByteFormatter.string(-change)) less free than a week ago",
              systemImage: change >= 0 ? "arrow.up.right" : "arrow.down.right"
            )
            .font(.caption.weight(.medium))
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
              LinearGradient(
                colors: [AppTheme.accent.opacity(0.35), AppTheme.accent.opacity(0.05)],
                startPoint: .top, endPoint: .bottom))
            LineMark(
              x: .value("Day", sample.day, unit: .day),
              y: .value("Free", Double(sample.freeBytes) / 1_073_741_824)
            )
            .foregroundStyle(AppTheme.accent)
          }
          .chartYAxisLabel("GB free")
          .frame(height: 120)
          .accessibilityLabel("Free space over the last \(model.spaceHistory.count) days")
        } else {
          Text("MacMint records free space once a day. The trend appears after a second day.")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        if !model.storageGrowth.isEmpty {
          Divider()
          Text("Grew since your last Storage map").font(.caption.weight(.semibold))
          ForEach(model.storageGrowth.prefix(4)) { growth in
            HStack {
              Image(systemName: "folder.fill").foregroundStyle(AppTheme.accentText).accessibilityHidden(true)
              Text(displayPath(growth.path)).lineLimit(1).truncationMode(.middle)
              Spacer()
              Text("+\(ByteFormatter.string(growth.delta))")
                .font(.caption.monospacedDigit())
                .foregroundStyle(AppTheme.warning)
            }
            .font(.caption)
          }
          Button("Open Storage") { model.selectedSection = .storage }
            .buttonStyle(.link)
            .tint(AppTheme.accentText)
            .font(.caption)
        }
      }
    }
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
