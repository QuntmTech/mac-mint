import MacCleanerCore
import SwiftUI

// MARK: - Shared

struct AIDisclaimer: View {
  var body: some View {
    Label(
      "AI-generated — may be wrong. MacMint's own safety rules always decide what can be removed.",
      systemImage: "sparkles"
    )
    .font(.caption)
    .foregroundStyle(.secondary)
    .fixedSize(horizontal: false, vertical: true)
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

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      HStack(alignment: .firstTextBaseline) {
        VStack(alignment: .leading, spacing: 3) {
          Text(target.title).font(.title3.weight(.semibold)).lineLimit(2)
          HStack(spacing: 6) {
            Text(target.request.location)
            if let bytes = target.bytes { Text("•"); Text(ByteFormatter.string(bytes)) }
          }
          .font(.caption)
          .foregroundStyle(.secondary)
        }
        Spacer()
        if let explanation { verdictPill(explanation.verdict) }
      }

      if let rule = target.ruleBlock {
        Label {
          VStack(alignment: .leading, spacing: 2) {
            Text("MacMint's rule").font(.caption.weight(.semibold))
            Text(rule).font(.callout)
          }
        } icon: {
          Image(systemName: "checkmark.shield.fill").foregroundStyle(AppTheme.warning)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppTheme.warning.opacity(0.10), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
      }

      Divider()

      if let explanation {
        VStack(alignment: .leading, spacing: 12) {
          Text(explanation.summary).fixedSize(horizontal: false, vertical: true)
          detail("Belongs to", explanation.owner)
          detail("If moved to the Trash", explanation.whatHappens)
          detail("Confidence", explanation.confidence.capitalized)
        }
      } else if let error = model.explanationError {
        Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(AppTheme.warning)
      } else {
        HStack(spacing: 8) {
          ProgressView().controlSize(.small)
          Text("Asking MacMint AI…").foregroundStyle(.secondary)
        }
      }

      Spacer(minLength: 0)
      AIDisclaimer()
      Text("Sent: “\(target.request.identifier)” and its category. Unrecognized names are omitted. No path or file contents.")
        .font(.caption2)
        .foregroundStyle(.tertiary)
        .fixedSize(horizontal: false, vertical: true)
      HStack {
        Spacer()
        Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
      }
    }
    .padding(22)
    .frame(width: 480)
    .frame(minHeight: 340)
    .task { await model.loadExplanation(target, account: account) }
  }

  private func detail(_ title: String, _ value: String) -> some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
      Text(value).fixedSize(horizontal: false, vertical: true)
    }
  }

  private func verdictPill(_ verdict: AIExplanation.Verdict) -> some View {
    switch verdict {
    case .safe: return StatusPill(title: "Rebuildable cache", icon: "checkmark.circle.fill", tint: AppTheme.accentText)
    case .caution: return StatusPill(title: "Use caution", icon: "exclamationmark.triangle.fill", tint: AppTheme.warning)
    case .keep: return StatusPill(title: "Keep", icon: "hand.raised.fill", tint: .red)
    case .unknown: return StatusPill(title: "Not sure", icon: "questionmark.circle", tint: .gray)
    }
  }
}

// MARK: - Consent

struct AIConsentSheet: View {
  @EnvironmentObject private var model: AppViewModel
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      Label("Turn on MacMint AI?", systemImage: "sparkles").font(.title3.weight(.semibold))
      Text("AI features are optional. When you use one, MacMint sends a small summary to its server, which asks Anthropic's Claude and returns advice.")
        .fixedSize(horizontal: false, vertical: true)
      VStack(alignment: .leading, spacing: 6) {
        point("checkmark.circle", "Automatic context: sizes, storage categories, and recognized app or tool identifiers. Unrecognized names and personal folder paths are omitted.")
        point("xmark.circle", "File contents are never sent. Your typed questions and recent conversation are sent as written; avoid including private information.")
        point("hand.raised", "AI only advises. It can't select, change, or remove anything, and MacMint's safety rules always win.")
      }
      DisclosureGroup("See the context that will be sent") {
        ScrollView { Text(model.aiPayloadPreview).font(.system(.caption, design: .monospaced)).textSelection(.enabled) }.frame(maxHeight: 180)
      }
      Text("You can turn this off any time in Settings.").font(.caption).foregroundStyle(.secondary)
      HStack {
        Spacer()
        Button("Not Now") { model.pendingAIAction = nil; dismiss() }.keyboardShortcut(.cancelAction)
        Button("Turn On AI") {
          model.acceptAIConsent()
          dismiss()
        }
        .keyboardShortcut(.defaultAction)
        .buttonStyle(.borderedProminent)
      }
    }
    .padding(22)
    .frame(width: 460)
  }

  private func point(_ icon: String, _ text: String) -> some View {
    Label {
      Text(text).font(.callout).fixedSize(horizontal: false, vertical: true)
    } icon: {
      Image(systemName: icon).foregroundStyle(AppTheme.accentText)
    }
  }
}

// MARK: - Smart Care AI review

struct AIReviewPanel: View {
  @EnvironmentObject private var model: AppViewModel
  @EnvironmentObject private var account: AccountStore

  var body: some View {
    if account.aiStatus.allows("review"), !model.recommendations.isEmpty {
      VStack(alignment: .leading, spacing: 10) {
        HStack(spacing: 10) {
          if let review = model.aiReview {
            Text(review.headline).font(.callout.weight(.semibold)).fixedSize(horizontal: false, vertical: true)
          } else {
            Text("Get a second opinion on these recommendations.").font(.callout).foregroundStyle(.secondary)
          }
          Spacer()
          if model.aiReview != nil {
            Toggle("AI order", isOn: $model.aiOrderRecommendations)
              .toggleStyle(.switch)
              .controlSize(.small)
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
          .disabled(model.aiReviewBusy || model.isScanning || model.isWorking)
        }
        if let review = model.aiReview {
          ForEach(review.cautions, id: \.self) { caution in
            Label(caution, systemImage: "exclamationmark.triangle.fill")
              .font(.caption)
              .foregroundStyle(AppTheme.warning)
              .fixedSize(horizontal: false, vertical: true)
          }
          ForEach(review.insights, id: \.self) { insight in
            HStack(alignment: .top) {
              VStack(alignment: .leading, spacing: 2) {
                Text(insight.title).font(.caption.weight(.semibold))
                Text(insight.detail).font(.caption).foregroundStyle(.secondary)
                  .fixedSize(horizontal: false, vertical: true)
              }
              Spacer()
              Button("Open") { model.openAIDestination(insight.destination) }.controlSize(.small)
            }
          }
          AIDisclaimer()
        }
        if let error = model.reviewAIError, !model.aiReviewBusy, model.selectedSection != .assistant {
          Label(error, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(AppTheme.warning)
        }
      }
      .padding(12)
      .background(AppTheme.accent.opacity(0.06), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
  }
}

struct AIRecommendationNote: View {
  let recommendationID: String
  @EnvironmentObject private var model: AppViewModel

  var body: some View {
    if let note = model.aiReview?.note(for: recommendationID), !note.note.isEmpty {
      Label(note.note, systemImage: "sparkles")
        .font(.caption)
        .foregroundStyle(AppTheme.accentText)
        .fixedSize(horizontal: false, vertical: true)
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

  var body: some View {
    VStack(spacing: 0) {
      PageHeader(title: "Ask MacMint", subtitle: "A second opinion on your storage. AI advises; you decide.") {
        if !model.assistantTurns.isEmpty {
          Button("New chat", systemImage: "square.and.pencil") { model.resetAIState() }
            .buttonStyle(MintButtonStyle(prominent: false))
        }
      }
      .padding(AppTheme.pagePadding)

      if !account.aiStatus.allows("ask") {
        EmptyState(
          icon: "sparkles", title: "AI is unavailable",
          detail: "MacMint AI is turned off right now or you're offline. Everything else works as usual.")
      } else {
        ScrollViewReader { proxy in
          ScrollView {
            VStack(alignment: .leading, spacing: 14) {
              if model.assistantTurns.isEmpty { suggestionGrid }
              ForEach(model.assistantTurns) { turn in
                bubble(turn).id(turn.id)
              }
              if model.assistantBusy {
                HStack(spacing: 8) {
                  ProgressView().controlSize(.small)
                  Text("Thinking…").foregroundStyle(.secondary)
                }
                .id("busy")
              }
              if let error = model.aiError {
                Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(AppTheme.warning)
              }
            }
            .padding(.horizontal, AppTheme.pagePadding)
            .padding(.bottom, 12)
            .frame(maxWidth: 820, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
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

  private var suggestionGrid: some View {
    VStack(alignment: .leading, spacing: 10) {
      if model.recommendations.isEmpty && model.storageScan == nil {
        Label("Run Quick Scan or open Storage first so MacMint has something to look at.", systemImage: "info.circle")
          .font(.callout)
          .foregroundStyle(.secondary)
      }
      LazyVGrid(columns: [GridItem(.adaptive(minimum: 240), spacing: 10)], alignment: .leading, spacing: 10) {
        ForEach(suggestions, id: \.self) { suggestion in
          Button {
            send(suggestion)
          } label: {
            Text(suggestion)
              .frame(maxWidth: .infinity, alignment: .leading)
              .padding(12)
              .background(AppTheme.panel, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
          }
          .buttonStyle(.plain)
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

  private func bubble(_ turn: AITurn) -> some View {
    VStack(alignment: turn.role == .user ? .trailing : .leading, spacing: 8) {
      Label(turn.role == .user ? "You" : "MacMint", systemImage: turn.role == .user ? "person.crop.circle" : "sparkles")
        .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
      Text(Self.rendered(turn.text))
        .textSelection(.enabled)
        .padding(12)
        .background(
          turn.role == .user ? AppTheme.selection : AppTheme.surface,
          in: RoundedRectangle(cornerRadius: 12, style: .continuous))
      if !turn.actions.isEmpty {
        HStack(spacing: 8) {
          ForEach(turn.actions, id: \.self) { action in
            Button {
              model.openAIDestination(action.destination)
            } label: {
              Label(action.label, systemImage: "arrow.right.circle")
            }
            .controlSize(.small)
          }
        }
      }
      if turn.role == .assistant {
        Text("AI-generated — may be wrong").font(.caption2).foregroundStyle(.tertiary)
      }
    }
    .frame(maxWidth: .infinity, alignment: turn.role == .user ? .trailing : .leading)
  }

  private var composer: some View {
    HStack(spacing: 10) {
      TextField("Ask about your Mac’s storage…", text: $model.assistantDraft, axis: .vertical)
        .textFieldStyle(.plain).font(.callout).padding(12)
        .background(AppTheme.canvas, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(AppTheme.border))
        .lineLimit(1...4)
        .focused($focused)
        .onSubmit { send(model.assistantDraft) }
      Button {
        send(model.assistantDraft)
      } label: {
        Image(systemName: "arrow.up.circle.fill").font(.title2)
          .accessibilityLabel("Send")
      }
      .buttonStyle(.plain)
      .foregroundStyle(AppTheme.accentText)
      .disabled(model.assistantDraft.trimmingCharacters(in: .whitespaces).isEmpty || model.assistantBusy || model.isScanning || model.isWorking)
    }
    .padding(.horizontal, AppTheme.pagePadding)
    .padding(.vertical, 12)
    .background(AppTheme.surface)
    .overlay(alignment: .top) { Divider() }
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
    SurfaceCard {
      VStack(alignment: .leading, spacing: 12) {
        HStack {
          Label("MacMint AI", systemImage: "sparkles").font(.headline)
          Spacer()
          Toggle("", isOn: Binding(get: { model.aiEnabled }, set: { model.aiEnabled = $0 }))
            .toggleStyle(.switch)
            .labelsHidden()
            .accessibilityLabel("MacMint AI")
        }
        Text(
          account.aiAvailable
            ? "Explain unfamiliar items, get a second opinion on Quick Scan, and ask questions about your storage. AI only advises — it can't select or remove anything, and MacMint's safety rules always win."
            : (account.aiStatus.reachable ? "MacMint AI is turned off by the service. Local tools remain available." : "The AI service could not be reached. You can still withdraw consent here and use local tools.")
        )
        .font(.callout)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
        Text(
          "Automatic context uses sizes, storage categories and recognized app/tool identifiers. Personal folder paths and unrecognized names are omitted. Your typed questions and recent conversation are sent as written to MacMint's server and Anthropic. File contents are never sent. MacMint keeps usage counts for limits; its application database does not store chat transcripts."
        )
        .font(.caption)
        .foregroundStyle(.tertiary)
        .fixedSize(horizontal: false, vertical: true)
        DisclosureGroup("Preview automatic chat context") {
          Text(model.previewPayload(model.aiContext)).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
        }
      }
    }
  }
}
