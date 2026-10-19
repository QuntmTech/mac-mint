import Foundation
import MacCleanerCore

/// An item the user asked AI to explain, plus MacMint's own rule for it. The AI is advisory:
/// when MacMint's safety rules refuse an item, that refusal is shown no matter what the AI says.
struct ExplainTarget: Identifiable {
  let request: AIExplainRequest
  let title: String
  let bytes: Int64?
  /// MacMint's own verdict (nil = its rules would allow it through review).
  let ruleBlock: String?
  var id: String { request.id }
}

extension AppViewModel {
  static let aiEnabledKey = "co.macmint.ai.enabled"

  var aiEnabled: Bool {
    get { UserDefaults.standard.bool(forKey: Self.aiEnabledKey) }
    set {
      UserDefaults.standard.set(newValue, forKey: Self.aiEnabledKey)
      if !newValue { resetAIState() }
      objectWillChange.send()
    }
  }

  /// Runs `action` if AI is on; otherwise asks for consent first.
  func withAIConsent(_ action: @escaping @MainActor () -> Void) {
    if aiEnabled { action() } else { pendingAIAction = action; aiConsentPending = true }
  }

  func acceptAIConsent() {
    let action = pendingAIAction
    pendingAIAction = nil
    aiEnabled = true
    aiConsentPending = false
    Task { await Task.yield(); action?() }
  }

  func invalidateAIReview() {
    aiGeneration = UUID()
    assistantTask?.cancel()
    explanationTask?.cancel()
    assistantBusy = false
    invalidateRecommendationReview()
  }

  /// Recommendation changes retire the review and pending consent, whose payload described the
  /// old context. Assistant questions already carry their own frozen context and keep running.
  func invalidateRecommendationReview() {
    aiReviewGeneration = UUID()
    aiReviewTask?.cancel()
    aiReview = nil
    aiOrderRecommendations = false
    aiReviewBusy = false
    reviewAIError = nil
    pendingAIAction = nil
    aiConsentPending = false
  }

  func resetAIState() {
    invalidateAIReview()
    assistantTurns = []
    assistantDraft = ""
    explanations = [:]
    aiError = nil
    explanationError = nil
    pendingAIAction = nil
    aiPayloadPreview = ""
  }

  func previewPayload<T: Encodable>(_ value: T) -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    return (try? encoder.encode(value)).map { String(decoding: $0, as: UTF8.self) } ?? "No context"
  }

  // MARK: Explain targets (names only; Library items only)

  private static let libraryLocations: [(String, String)] = [
    ("Library/Caches", "Caches"), ("Library/Preferences", "Preferences"),
    ("Library/Application Support", "Application Support"), ("Library/Containers", "Containers"),
    ("Library/Group Containers", "Group Containers"), ("Library/Logs", "Logs"),
    ("Library/Saved Application State", "Saved Application State"), ("Library/WebKit", "WebKit"),
    ("Library/HTTPStorages", "HTTP Storage"), ("Library/Cookies", "Cookies"),
    ("Library/Application Scripts", "Application Scripts"), ("Library/LaunchAgents", "LaunchAgents"),
    ("Library/Developer", "Developer"),
  ]

  /// The Library area and the entry name directly inside it; nil outside ~/Library.
  static func libraryEntry(for url: URL) -> (location: String, name: String)? {
    let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
    let path = url.standardizedFileURL.path
    for (relative, label) in libraryLocations {
      let root = home + "/" + relative + "/"
      guard path.hasPrefix(root) else { continue }
      let rest = path.dropFirst(root.count)
      guard let first = rest.split(separator: "/").first else { return nil }
      return (label, String(first))
    }
    return nil
  }

  func aiTarget(for target: CleanupTarget) -> ExplainTarget? {
    guard target.category != .installers, let entry = Self.libraryEntry(for: target.url) else { return nil }
    let decision = safetyPolicy.cleanupDecision(for: target.url, category: target.category)
    return ExplainTarget(
      request: AIExplainRequest(kind: .libraryItem, identifier: entry.name, location: entry.location),
      title: target.displayName, bytes: target.size, ruleBlock: decision.allowed ? nil : decision.reason)
  }

  func aiTarget(for orphan: OrphanedItem) -> ExplainTarget {
    let decision = safetyPolicy.appLeftoverDecision(for: orphan.url)
    return ExplainTarget(
      request: AIExplainRequest(kind: .libraryItem, identifier: orphan.bundleID, location: orphan.location),
      title: orphan.url.lastPathComponent, bytes: orphan.bytes,
      ruleBlock: decision.allowed ? nil : decision.reason)
  }

  func aiTarget(for item: StartupItem) -> ExplainTarget {
    ExplainTarget(
      request: AIExplainRequest(
        kind: .launchAgent, identifier: item.label,
        location: item.scope.contains("Daemon") ? "LaunchDaemons" : "LaunchAgents"),
      title: item.label, bytes: nil,
      ruleBlock: "MacMint doesn't remove startup items. Turn them off in System Settings ▸ General ▸ Login Items, or with the app that installed them.")
  }

  func aiTarget(for item: DevStorageItem) -> ExplainTarget? {
    // Project folders carry personal project names; only tool caches are explained.
    guard item.group != .projects else { return nil }
    let decision = item.url.map { safetyPolicy.developerArtifactDecision(for: $0) }
    return ExplainTarget(
      request: AIExplainRequest(kind: .developerTool, identifier: item.tool, location: "Developer"),
      title: "\(item.tool): \(item.title)", bytes: item.bytes,
      ruleBlock: item.canTrash ? (decision?.allowed == false ? decision?.reason : nil)
        : "Managed by \(item.tool). Use its own command instead of deleting files.")
  }

  func aiTarget(for node: StorageNode) -> ExplainTarget? {
    guard node.isActionable, let entry = Self.libraryEntry(for: node.url) else { return nil }
    let decision = safetyPolicy.reviewedFileDecision(for: node.url)
    return ExplainTarget(
      request: AIExplainRequest(kind: .libraryItem, identifier: entry.name, location: entry.location),
      title: node.name, bytes: node.allocatedBytes, ruleBlock: decision.allowed ? nil : decision.reason)
  }

  func explain(_ target: ExplainTarget?) {
    guard let target else { return }
    aiPayloadPreview = previewPayload(target.request)
    withAIConsent { [self] in explainTarget = target }
  }

  func loadExplanation(_ target: ExplainTarget, account: AccountStore) async {
    guard explanations[target.id] == nil else { return }
    explanationError = nil
    let generation = aiGeneration
    let task = Task { [weak self] in
      guard let self else { return }
      do {
        let response = try await account.aiExplain(target.request)
        guard !Task.isCancelled, aiEnabled, aiGeneration == generation else { return }
        explanations[target.id] = response.explanation
      } catch {
        if !Task.isCancelled, aiGeneration == generation { explanationError = error.localizedDescription }
      }
    }
    explanationTask = task
    await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
  }

  // MARK: Smart Care AI review (advisory: ordering + notes only)

  func runAIReview(account: AccountStore) {
    guard !recommendations.isEmpty, !aiReviewBusy, !isScanning, !isWorking else { return }
    let generation = aiGeneration, reviewGeneration = aiReviewGeneration
    let request = AIContextBuilder.reviewRequest(recommendations: recommendations,
      totalBytes: volumeStats.total, freeBytes: volumeStats.free, growth: storageGrowth,
      home: FileManager.default.homeDirectoryForCurrentUser)
    aiPayloadPreview = previewPayload(request)
    withAIConsent { [self] in
      guard generation == aiGeneration, reviewGeneration == aiReviewGeneration, !aiReviewBusy, !isScanning, !isWorking else { return }
      aiReviewBusy = true
      reviewAIError = nil
      aiReviewTask = Task {
        do {
          let response = try await account.aiReview(request)
          guard !Task.isCancelled, aiEnabled, aiGeneration == generation, aiReviewGeneration == reviewGeneration else { return }
          aiReview = response
          aiOrderRecommendations = true
        } catch {
          if !Task.isCancelled, aiGeneration == generation, aiReviewGeneration == reviewGeneration { reviewAIError = error.localizedDescription }
        }
        if aiGeneration == generation, aiReviewGeneration == reviewGeneration { aiReviewBusy = false }
      }
    }
  }

  /// Display order only — never changes items, confidence, or selection.
  var displayedRecommendations: [Recommendation] {
    guard aiOrderRecommendations, let review = aiReview else { return recommendations }
    return recommendations.enumerated().sorted { lhs, rhs in
      let l = review.note(for: lhs.element.id)?.order ?? 1000 + lhs.offset
      let r = review.note(for: rhs.element.id)?.order ?? 1000 + rhs.offset
      return l < r
    }.map(\.element)
  }

  // MARK: Ask MacMint

  var aiContext: AIContext {
    var inputs = AIContextBuilder.Inputs(homeDirectory: FileManager.default.homeDirectoryForCurrentUser)
    let stats = volumeStats
    inputs.totalBytes = stats.total
    inputs.freeBytes = stats.free
    inputs.recommendations = recommendations
    inputs.storageRoot = storageScan?.root
    inputs.developer = devItems
    inputs.apps = apps
    inputs.downloads = downloadItems
    inputs.startupLabels = startupItems.map(\.label)
    inputs.growth = storageGrowth
    return AIContextBuilder.build(inputs)
  }

  func ask(_ question: String, account: AccountStore) {
    let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, !assistantBusy, !isScanning, !isWorking else { return }
    let generation = aiGeneration
    let request = AIAskRequest(question: trimmed, history: assistantTurns, context: aiContext)
    aiPayloadPreview = previewPayload(request)
    withAIConsent { [self] in
      guard generation == aiGeneration, !assistantBusy, !isScanning, !isWorking else { return }
      assistantDraft = ""
      assistantTurns.append(AITurn(role: .user, text: trimmed))
      assistantBusy = true
      aiError = nil
      assistantTask = Task {
        do {
          let answer = try await account.aiAsk(question: request.question, history: request.history, context: request.context)
          guard !Task.isCancelled, aiEnabled, aiGeneration == generation else { return }
          assistantTurns.append(AITurn(role: .assistant, text: answer.answer, actions: answer.actions))
        } catch {
          if !Task.isCancelled, aiGeneration == generation { aiError = error.localizedDescription }
        }
        if aiGeneration == generation { assistantBusy = false }
      }
    }
  }

  /// AI actions can only navigate — never select, change, or remove anything.
  func openAIDestination(_ destination: String) {
    let map: [String: Section] = [
      "dashboard": .dashboard, "review": .review, "cleaner": .cleaner, "storage": .storage,
      "developer": .developer, "downloads": .downloads, "photos": .photos, "removedApps": .removedApps,
      "performance": .performance, "applications": .applications, "largeFiles": .largeFiles,
      "duplicates": .duplicates, "startup": .startup, "history": .history, "settings": .settings,
    ]
    selectedSection = map[destination] ?? .dashboard
  }
}
