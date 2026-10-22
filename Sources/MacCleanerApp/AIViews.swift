import MacCleanerCore
import SwiftUI

// MARK: - Shared

extension AIExplanation.Verdict {
  /// Rebuildable cache is mint, Use caution amber, Keep rose, Not sure slate.
  var swatch: AppTheme.Swatch {
    switch self {
    case .safe: return .mint
    case .caution: return .amber
    case .keep: return .rose
    case .unknown: return .slate
    }
  }
  var title: String {
    switch self {
    case .safe: return "Rebuildable cache"
    case .caution: return "Use caution"
    case .keep: return "Keep"
    case .unknown: return "Not sure"
    }
  }
  var symbol: String {
    switch self {
    case .safe: return "checkmark.shield.fill"
    case .caution: return "exclamationmark.triangle.fill"
    case .keep: return "hand.raised.fill"
    case .unknown: return "questionmark.circle.fill"
    }
  }
}

struct AIDisclaimer: View {
  var body: some View {
    Label {
      Text("AI-generated — may be wrong. MacMint's own safety rules always decide what can be removed.")
    } icon: {
      Image(systemName: "sparkles").foregroundStyle(AppTheme.Swatch.iris.text)
    }
    .font(.system(size: 11))
    .foregroundStyle(AppTheme.ink2)
    .fixedSize(horizontal: false, vertical: true)
  }
}

/// What the automatic context holds, in one line.
struct AIPrivacyPill: View {
  var body: some View {
    HStack(spacing: 6) {
      Image(systemName: "lock.shield.fill")
        .font(.system(size: 12))
        .foregroundStyle(AppTheme.Swatch.iris.text)
      Text("Sizes and categories · never file contents")
        .font(.system(size: 11.5))
        .foregroundStyle(AppTheme.ink2)
        .lineLimit(1)
    }
    .padding(.horizontal, 10)
    .frame(height: 26)
    .background(AppTheme.surface, in: Capsule())
    .elevation(.card)
    .accessibilityElement(children: .combine)
  }
}

/// A note with a colored leading edge: AI advice and MacMint's own rules.
struct AIEdgeNote<Content: View>: View {
  let swatch: AppTheme.Swatch
  var fill: Color = AppTheme.surface
  @ViewBuilder var content: () -> Content

  var body: some View {
    VStack(alignment: .leading, spacing: 6) { content() }
      .padding(.leading, 18)
      .padding(.trailing, 13)
      .padding(.vertical, 11)
      .frame(maxWidth: .infinity, alignment: .leading)
      .overlay(alignment: .leading) {
        Capsule().fill(swatch.gradient).frame(width: 4).padding(.vertical, 9).padding(.leading, 8)
      }
      .cardBackground(fill, radius: 13)
  }
}

/// "Explain with AI…" for row menus. Hidden when AI is off on the server.
struct ExplainMenuItem: View {
  let target: ExplainTarget?
  @EnvironmentObject private var model: AppViewModel
  @EnvironmentObject private var account: AccountStore

  var body: some View {
    if account.aiStatus.allows("explain"), let target {
      Button {
        model.explain(target)
      } label: {
        Label("Explain with AI…", systemImage: "sparkles")
      }
    }
  }
}

// MARK: - Explain sheet

struct ExplainSheet: View {
  let target: ExplainTarget
  @EnvironmentObject private var model: AppViewModel
  @EnvironmentObject private var account: AccountStore
  @Environment(\.dismiss) private var dismiss

  private var explanation: AIExplanation? { model.explanations[target.id] }

  private var subtitle: String {
    if let bytes = target.bytes { return target.request.location + " · " + ByteFormatter.string(bytes) }
    return target.request.location
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      SheetHeader(symbol: "sparkles", swatch: .iris, eyebrow: "Explain with AI", title: target.title, subtitle: subtitle) {
        if let explanation { verdictPill(explanation.verdict) }
      }
      Rectangle().fill(AppTheme.divider).frame(height: 1)

      VStack(alignment: .leading, spacing: 14) {
        if let rule = target.ruleBlock {
          AIEdgeNote(swatch: .amber) {
            Label {
              Text("MacMint's rule").font(.system(size: 12, weight: .semibold)).foregroundStyle(AppTheme.ink)
            } icon: {
              Image(systemName: "checkmark.shield.fill").foregroundStyle(AppTheme.warning)
            }
            Text(rule)
              .font(.system(size: 12.5))
              .foregroundStyle(AppTheme.ink2)
              .fixedSize(horizontal: false, vertical: true)
          }
        }

        if let explanation {
          AIEdgeNote(swatch: explanation.verdict.swatch) {
            Text(explanation.summary)
              .font(.system(size: 13))
              .foregroundStyle(AppTheme.ink)
              .fixedSize(horizontal: false, vertical: true)
          }
          VStack(alignment: .leading, spacing: 10) {
            detail("Belongs to", explanation.owner)
            detail("If moved to the Trash", explanation.whatHappens)
            detail("Confidence", explanation.confidence.capitalized)
          }
        } else if let error = model.explanationError {
          Label(error, systemImage: "exclamationmark.triangle.fill")
            .font(.system(size: 12.5))
            .foregroundStyle(AppTheme.warning)
            .fixedSize(horizontal: false, vertical: true)
        } else {
          HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text("Asking MacMint AI…").font(.system(size: 13)).foregroundStyle(AppTheme.ink2)
          }
        }

        Spacer(minLength: 0)
        AIDisclaimer()
        Text("Sent: “\(target.request.identifier)” and its category. Unrecognized names are omitted. No path or file contents.")
          .font(.system(size: 11))
          .foregroundStyle(AppTheme.ink3)
          .fixedSize(horizontal: false, vertical: true)
      }
      .padding(22)

      SheetFooter {
        Spacer()
        Button("Done") { dismiss() }
          .buttonStyle(MintButtonStyle(.commit))
          .keyboardShortcut(.defaultAction)
      }
    }
    .frame(width: 480)
    .frame(minHeight: 340)
    .background(AppTheme.elevated)
    .task { await model.loadExplanation(target, account: account) }
  }

  private func detail(_ title: String, _ value: String) -> some View {
    VStack(alignment: .leading, spacing: 2) {
      Eyebrow(title)
      Text(value)
        .font(.system(size: 12.5))
        .foregroundStyle(AppTheme.ink)
        .fixedSize(horizontal: false, vertical: true)
    }
  }

  private func verdictPill(_ verdict: AIExplanation.Verdict) -> some View {
    Chip(title: verdict.title, symbol: verdict.symbol, swatch: verdict.swatch)
  }
}

// MARK: - Consent

struct AIConsentSheet: View {
  @EnvironmentObject private var model: AppViewModel
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      SheetHeader(symbol: "sparkles", swatch: .iris, eyebrow: "Optional", title: "Turn on MacMint AI?",
        subtitle: "AI features are optional. When you use one, MacMint sends a small summary to its server, which asks Anthropic's Claude and returns advice.")
      Rectangle().fill(AppTheme.divider).frame(height: 1)

      VStack(alignment: .leading, spacing: 14) {
        HStack(alignment: .top, spacing: 10) {
          column("Sent when you use AI", symbol: "arrow.up.circle.fill", swatch: .iris, items: [
            "Sizes and storage categories",
            "Recognized app or tool names",
            "Your typed questions and recent chat, as written",
          ])
          column("Never sent", symbol: "xmark.circle.fill", swatch: .rose, items: [
            "File contents",
            "Personal folder paths",
            "Unrecognized names",
          ])
        }
        .fixedSize(horizontal: false, vertical: true)
        Text("Questions are sent as you type them, so leave out private information.")
          .font(.system(size: 11.5))
          .foregroundStyle(AppTheme.ink2)
          .fixedSize(horizontal: false, vertical: true)
        AIEdgeNote(swatch: .mint) {
          Label {
            Text("AI only advises. It can't select, change, or remove anything, and MacMint's safety rules always win.")
              .font(.system(size: 12.5))
              .foregroundStyle(AppTheme.ink)
              .fixedSize(horizontal: false, vertical: true)
          } icon: {
            Image(systemName: "hand.raised.fill").foregroundStyle(AppTheme.Swatch.mint.text)
          }
        }
        DisclosureGroup {
          ScrollView {
            Text(model.aiPayloadPreview)
              .font(.system(size: 11, design: .monospaced))
              .foregroundStyle(AppTheme.ink)
              .textSelection(.enabled)
              .frame(maxWidth: .infinity, alignment: .leading)
          }
          .frame(maxHeight: 180)
          .padding(10)
          .background(AppTheme.panel, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
          .padding(.top, 6)
        } label: {
          Text("See the context that will be sent")
            .font(.system(size: 12.5, weight: .medium))
            .foregroundStyle(AppTheme.ink)
        }
        Text("You can turn this off any time in Settings.")
          .font(.system(size: 11.5))
          .foregroundStyle(AppTheme.ink3)
      }
      .padding(22)

      SheetFooter {
        Spacer()
        Button("Not Now") { model.pendingAIAction = nil; dismiss() }
          .buttonStyle(MintButtonStyle(.secondary))
          .keyboardShortcut(.cancelAction)
        Button("Turn On AI") {
          model.acceptAIConsent()
          dismiss()
        }
        .buttonStyle(MintButtonStyle(.area))
        .environment(\.areaSwatch, .iris)
        .keyboardShortcut(.defaultAction)
      }
    }
    .frame(width: 540)
    .background(AppTheme.elevated)
  }

  private func column(_ title: String, symbol: String, swatch: AppTheme.Swatch, items: [String]) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      Eyebrow(title, color: swatch.text)
      ForEach(items, id: \.self) { item in
        Label {
          Text(item)
            .font(.system(size: 12.5))
            .foregroundStyle(AppTheme.ink)
            .fixedSize(horizontal: false, vertical: true)
        } icon: {
          Image(systemName: symbol).foregroundStyle(swatch.text)
        }
      }
    }
    .padding(12)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .background(swatch.tint, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    .accessibilityElement(children: .combine)
  }
}

// MARK: - Smart Care AI review

struct AIReviewPanel: View {
  @EnvironmentObject private var model: AppViewModel
  @EnvironmentObject private var account: AccountStore

  var body: some View {
    if account.aiStatus.allows("review"), !model.recommendations.isEmpty {
      VStack(alignment: .leading, spacing: 10) {
        HStack(alignment: .center, spacing: 10) {
          SwatchBadge(symbol: "sparkles", swatch: .iris, size: 24)
          if let review = model.aiReview {
            Text(review.headline)
              .font(.system(size: 12.5, weight: .semibold))
              .foregroundStyle(AppTheme.ink)
              .fixedSize(horizontal: false, vertical: true)
          } else {
            Text("Get a second opinion on these recommendations.")
              .font(.system(size: 12.5))
              .foregroundStyle(AppTheme.ink2)
              .fixedSize(horizontal: false, vertical: true)
          }
          Spacer(minLength: 6)
          if model.aiReview != nil {
            Toggle("AI order", isOn: $model.aiOrderRecommendations)
              .toggleStyle(.switch)
              .controlSize(.small)
              .font(.system(size: 11.5))
              .help("Changes the display order only — nothing is selected or removed")
          }
          Button {
            model.runAIReview(account: account)
          } label: {
            if model.aiReviewBusy {
              ProgressView().controlSize(.small)
            } else {
              Label(model.aiReview == nil ? "Review with AI" : "Review Again", systemImage: "sparkles")
            }
          }
          .buttonStyle(MintButtonStyle(.area))
          .controlSize(.small)
          .environment(\.areaSwatch, .iris)
          .disabled(model.aiReviewBusy || model.isScanning || model.isWorking)
        }
        if let review = model.aiReview {
          ForEach(review.cautions, id: \.self) { caution in
            Label(caution, systemImage: "exclamationmark.triangle.fill")
              .font(.system(size: 11.5))
              .foregroundStyle(AppTheme.warning)
              .fixedSize(horizontal: false, vertical: true)
          }
          ForEach(review.insights, id: \.self) { insight in
            HStack(alignment: .center, spacing: 10) {
              VStack(alignment: .leading, spacing: 2) {
                Text(insight.title)
                  .font(.system(size: 12, weight: .semibold))
                  .foregroundStyle(AppTheme.ink)
                Text(insight.detail)
                  .font(.system(size: 11.5))
                  .foregroundStyle(AppTheme.ink2)
                  .fixedSize(horizontal: false, vertical: true)
              }
              Spacer(minLength: 6)
              Button("Open") { model.openAIDestination(insight.destination) }
                .buttonStyle(MintButtonStyle(.secondary))
                .controlSize(.small)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(AppTheme.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
          }
          AIDisclaimer()
        }
        if let error = model.reviewAIError, !model.aiReviewBusy, model.selectedSection != .assistant {
          Label(error, systemImage: "exclamationmark.triangle.fill")
            .font(.system(size: 11.5))
            .foregroundStyle(AppTheme.warning)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
      .padding(12)
      .background(AppTheme.Swatch.iris.tint, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
  }
}

/// MacMint AI's note on one recommendation: an iris edge, an "AI note" pill and the note.
struct AIRecommendationNote: View {
  let recommendationID: String
  @EnvironmentObject private var model: AppViewModel

  var body: some View {
    if let note = model.aiReview?.note(for: recommendationID), !note.note.isEmpty {
      HStack(alignment: .top, spacing: 6) {
        Chip(title: "AI note", symbol: "sparkles", swatch: .iris)
        Text(note.note)
          .font(.system(size: 11.5))
          .foregroundStyle(AppTheme.ink2)
          .fixedSize(horizontal: false, vertical: true)
          .padding(.top, 2)
      }
      .padding(.leading, 9)
      .overlay(alignment: .leading) {
        Capsule().fill(AppTheme.Swatch.iris.gradient).frame(width: 3)
      }
      .padding(.top, 2)
      .accessibilityElement(children: .combine)
    }
  }
}

// MARK: - Ask MacMint

struct AssistantView: View {
  @EnvironmentObject private var model: AppViewModel
  @EnvironmentObject private var account: AccountStore
  @FocusState private var focused: Bool
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  private let suggestions = [
    "What's using the most space on my Mac?",
    "What can I safely clean up first?",
    "Why is my free space shrinking?",
    "Which apps haven't I used in a while?",
  ]

  /// The chat column's width, centered like a conversation.
  private let columnWidth: CGFloat = 760

  var body: some View {
    VStack(spacing: 0) {
      PageHeader(title: "Ask MacMint", subtitle: "A second opinion on your storage. AI advises; you decide.") {
        AIPrivacyPill()
        if !model.assistantTurns.isEmpty {
          Button("New chat", systemImage: "square.and.pencil") { model.resetAIState() }
            .buttonStyle(MintButtonStyle(prominent: false))
        }
      }
      .padding(.horizontal, AppTheme.pagePadding)
      .padding(.top, AppTheme.pageTopPadding)
      .padding(.bottom, 12)

      if !account.aiStatus.allows("ask") {
        EmptyState(
          icon: "sparkles", title: "AI is unavailable",
          detail: "MacMint AI is turned off right now or you're offline. Everything else works as usual.",
          trust: "Optional. Everything else in MacMint works without AI.")
      } else {
        ScrollViewReader { proxy in
          ScrollView {
            VStack(alignment: .leading, spacing: 14) {
              if model.assistantTurns.isEmpty { suggestionGrid }
              ForEach(model.assistantTurns) { turn in
                bubble(turn).id(turn.id)
              }
              if model.assistantBusy {
                thinking.id("busy")
              }
              if let error = model.aiError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                  .font(.system(size: 12.5))
                  .foregroundStyle(AppTheme.warning)
                  .fixedSize(horizontal: false, vertical: true)
              }
            }
            .frame(maxWidth: columnWidth, alignment: .leading)
            .padding(.horizontal, AppTheme.pagePadding)
            .padding(.top, 4)
            .padding(.bottom, 16)
            .frame(maxWidth: .infinity)
          }
          .onChange(of: model.assistantTurns.count) {
            if let last = model.assistantTurns.last?.id {
              withAnimation(reduceMotion ? nil : .easeOut(duration: 0.18)) { proxy.scrollTo(last, anchor: .bottom) }
            }
          }
        }
        composer
      }
    }
  }

  private var avatar: some View {
    SwatchBadge(symbol: "sparkles", swatch: .iris, size: 28)
  }

  private var suggestionGrid: some View {
    VStack(alignment: .leading, spacing: 14) {
      HStack(alignment: .top, spacing: 10) {
        avatar
        VStack(alignment: .leading, spacing: 4) {
          Text("Ask about your storage")
            .font(.system(size: 15, weight: .bold))
            .tracking(-0.2)
            .foregroundStyle(AppTheme.ink)
          Text("Ask what a folder is, whether it's safe to remove, or what's filling your disk. AI only advises. You decide what to review.")
            .font(.system(size: 13))
            .foregroundStyle(AppTheme.ink2)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
      if model.recommendations.isEmpty && model.storageScan == nil {
        Label {
          Text("Run Quick Scan or open Storage first so MacMint has something to look at.")
            .foregroundStyle(AppTheme.ink2)
        } icon: {
          Image(systemName: "info.circle.fill").foregroundStyle(AppTheme.info)
        }
        .font(.system(size: 12.5))
        .fixedSize(horizontal: false, vertical: true)
      }
      Eyebrow("Try asking")
      LazyVGrid(columns: [GridItem(.adaptive(minimum: 240), spacing: 10)], alignment: .leading, spacing: 10) {
        ForEach(suggestions, id: \.self) { suggestion in
          Button {
            send(suggestion)
          } label: {
            HStack(spacing: 10) {
              Image(systemName: "sparkle")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(AppTheme.Swatch.iris.text)
                .accessibilityHidden(true)
              Text(suggestion)
                .font(.system(size: 13))
                .foregroundStyle(AppTheme.ink)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
              Spacer(minLength: 0)
              Image(systemName: "arrow.up.right")
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(AppTheme.ink3)
                .accessibilityHidden(true)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .cardBackground(radius: 12)
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
          }
          .buttonStyle(CardButtonStyle())
        }
      }
      AIDisclaimer()
    }
  }

  /// Inline markdown only (bold, lists, code); links are shown as plain text.
  static func rendered(_ text: String) -> AttributedString {
    var string = (try? AttributedString(
      markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
    for run in string.runs where run.link != nil { string[run.range].link = nil }
    return string
  }

  @ViewBuilder private func bubble(_ turn: AITurn) -> some View {
    if turn.role == .user {
      Text(Self.rendered(turn.text))
        .font(.system(size: 13))
        .foregroundStyle(.white)
        .textSelection(.enabled)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(AppTheme.Swatch.iris.gradient,
          in: UnevenRoundedRectangle(topLeadingRadius: 16, bottomLeadingRadius: 16, bottomTrailingRadius: 4,
            topTrailingRadius: 16, style: .continuous))
        .frame(maxWidth: 560, alignment: .trailing)
        .frame(maxWidth: .infinity, alignment: .trailing)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("You: ") + Text(Self.rendered(turn.text)))
    } else {
      HStack(alignment: .top, spacing: 10) {
        avatar
        VStack(alignment: .leading, spacing: 8) {
          Text(Self.rendered(turn.text))
            .font(.system(size: 13))
            .foregroundStyle(AppTheme.ink)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background {
              UnevenRoundedRectangle(topLeadingRadius: 4, bottomLeadingRadius: 16, bottomTrailingRadius: 16,
                topTrailingRadius: 16, style: .continuous)
                .fill(AppTheme.surface)
                .elevation(.card)
            }
            .accessibilityLabel(Text("MacMint: ") + Text(Self.rendered(turn.text)))
          if !turn.actions.isEmpty {
            HStack(spacing: 6) {
              ForEach(turn.actions, id: \.self) { action in
                Button {
                  model.openAIDestination(action.destination)
                } label: {
                  Label(action.label, systemImage: "arrow.right.circle")
                }
                .buttonStyle(MintButtonStyle(.secondary))
                .controlSize(.small)
              }
            }
          }
          Text("AI-generated — may be wrong")
            .font(.system(size: 11))
            .foregroundStyle(AppTheme.ink3)
        }
        Spacer(minLength: 40)
      }
    }
  }

  private var thinking: some View {
    HStack(alignment: .center, spacing: 10) {
      avatar
      HStack(spacing: 8) {
        ProgressView().controlSize(.small)
        Text("Thinking…")
          .font(.system(size: 13))
          .foregroundStyle(AppTheme.ink2)
      }
      .padding(.horizontal, 14)
      .padding(.vertical, 10)
      .background {
        UnevenRoundedRectangle(topLeadingRadius: 4, bottomLeadingRadius: 16, bottomTrailingRadius: 16,
          topTrailingRadius: 16, style: .continuous)
          .fill(AppTheme.surface)
          .elevation(.card)
      }
      Spacer(minLength: 0)
    }
  }

  private var sendDisabled: Bool {
    model.assistantDraft.trimmingCharacters(in: .whitespaces).isEmpty || model.assistantBusy || model.isScanning || model.isWorking
  }

  private var composer: some View {
    let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
    return HStack(alignment: .bottom, spacing: 8) {
      TextField("Ask about your Mac’s storage…", text: $model.assistantDraft, axis: .vertical)
        .textFieldStyle(.plain)
        .font(.system(size: 13))
        .lineLimit(1...4)
        .focused($focused)
        .onSubmit { send(model.assistantDraft) }
        .padding(.vertical, 8)
      Button {
        send(model.assistantDraft)
      } label: {
        Image(systemName: "arrow.up")
          .font(.system(size: 15, weight: .bold))
          .foregroundStyle(.white)
          .frame(width: 32, height: 32)
          .background(AppTheme.Swatch.iris.gradient, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
          .accessibilityLabel("Send")
      }
      .buttonStyle(.plain)
      .disabled(sendDisabled)
      .opacity(sendDisabled ? 0.45 : 1)
    }
    .padding(.leading, 14)
    .padding(.trailing, 6)
    .padding(.vertical, 6)
    .background { shape.fill(AppTheme.surface).elevation(.floating) }
    .overlay(shape.strokeBorder(focused ? AppTheme.Swatch.iris.color.opacity(0.6) : AppTheme.border, lineWidth: focused ? 1.5 : 1))
    .frame(maxWidth: columnWidth)
    .padding(.horizontal, AppTheme.pagePadding)
    .padding(.top, 10)
    .padding(.bottom, 16)
    .frame(maxWidth: .infinity)
  }

  private func send(_ text: String) {
    guard !model.assistantBusy else { return }
    model.assistantDraft = String(text.prefix(600))
    model.ask(model.assistantDraft, account: account)
  }
}

// MARK: - Settings

struct AISettingsCard: View {
  @EnvironmentObject private var model: AppViewModel
  @EnvironmentObject private var account: AccountStore

  var body: some View {
    SettingsCard {
      SettingsCardHeader(symbol: "sparkles", swatch: .iris, title: "Ask MacMint", subtitle: "MacMint AI · optional") {
        Toggle("", isOn: Binding(get: { model.aiEnabled }, set: { model.aiEnabled = $0 }))
          .toggleStyle(.switch)
          .controlSize(.small)
          .labelsHidden()
          .accessibilityLabel("MacMint AI")
      }
      Text(
        account.aiAvailable
          ? "Explain unfamiliar items, get a second opinion on Quick Scan, and ask questions about your storage. AI only advises — it can't select or remove anything, and MacMint's safety rules always win."
          : (account.aiStatus.reachable ? "MacMint AI is turned off by the service. Local tools remain available." : "The AI service could not be reached. You can still withdraw consent here and use local tools.")
      )
      .font(.system(size: 12.5))
      .foregroundStyle(AppTheme.ink2)
      .fixedSize(horizontal: false, vertical: true)
      Text(
        "Automatic context uses sizes, storage categories and recognized app/tool identifiers. Personal folder paths and unrecognized names are omitted. Your typed questions and recent conversation are sent as written to MacMint's server and Anthropic. File contents are never sent. The separate Organizer asks before each request to share the displayed file and destination-folder names. MacMint keeps usage counts for limits; its application database does not store chat transcripts."
      )
      .font(.system(size: 11.5))
      .foregroundStyle(AppTheme.ink3)
      .fixedSize(horizontal: false, vertical: true)
      DisclosureGroup {
        Text(model.previewPayload(model.aiContext))
          .font(.system(size: 11, design: .monospaced))
          .foregroundStyle(AppTheme.ink)
          .textSelection(.enabled)
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(10)
          .background(AppTheme.panel, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
          .padding(.top, 6)
      } label: {
        Text("Preview automatic chat context")
          .font(.system(size: 12.5, weight: .medium))
          .foregroundStyle(AppTheme.ink)
      }
    }
  }
}
