import Foundation
import MacCleanerCore

/// AI calls go through the signed-in session; the server holds the Anthropic key and enforces
/// plan, limits, and the kill switch.
extension AccountStore {
  private func requireToken(feature: String, separatelyConsented: Bool = false) throws -> String {
    guard separatelyConsented || UserDefaults.standard.bool(forKey: AppViewModel.aiEnabledKey) else {
      throw AccountAPIError(status: 403, code: "ai_consent", message: "Enable optional AI in Settings before sending a request.")
    }
    guard isUnlocked else { throw AccountAPIError(status: 402, code: "plan_required", message: "AI requests require an active MacMint plan. Local inspection and recovery remain available.") }
    guard aiStatus.reachable else { throw AccountAPIError(status: 503, code: "ai_offline", message: "MacMint could not reach the AI service. Check your connection and try again.") }
    guard aiStatus.allows(feature) else { throw AccountAPIError(status: 503, code: "ai_disabled", message: "This AI feature is currently turned off by the service.") }
    guard let token else {
      throw AccountAPIError(status: 401, code: "unauthorized", message: "Sign in to use AI features.")
    }
    return token
  }

  func refreshAIStatus() async {
    let generation = sessionGeneration
    let result = await client.aiStatus()
    guard !Task.isCancelled, generation == sessionGeneration else { return }
    aiStatus = result
    aiAvailable = aiStatus.enabled
  }

  private func refreshedAIToken(feature: String, separatelyConsented: Bool = false) async throws -> String {
    let generation = sessionGeneration
    try Task.checkCancellation()
    await refreshAIStatus()
    try Task.checkCancellation()
    // Availability checking must never send an old user's payload under a newer session.
    guard generation == sessionGeneration else { throw CancellationError() }
    return try requireToken(feature: feature, separatelyConsented: separatelyConsented)
  }

  /// The organizer's frozen payload is approved separately on every request.
  func aiOrganize(_ request: AIOrganizationRequest) async throws -> AIOrganizationResponse {
    let token = try await refreshedAIToken(feature: "organize", separatelyConsented: true)
    return try await client.organize(request, token: token)
  }

  func aiExplain(_ request: AIExplainRequest) async throws -> AIExplainResponse {
    let token = try await refreshedAIToken(feature: "explain")
    return try await client.explain(request, token: token)
  }

  func aiReview(_ request: AIReviewRequest) async throws -> AIReview {
    let token = try await refreshedAIToken(feature: "review")
    return try await client.review(request, token: token)
  }

  func aiAsk(question: String, history: [AITurn], context: AIContext) async throws -> AIAnswer {
    let token = try await refreshedAIToken(feature: "ask")
    return try await client.ask(question: question, history: history, context: context, token: token)
  }
}
