import Foundation
import MacCleanerCore

/// AI calls go through the signed-in session; the server holds the Anthropic key and enforces
/// plan, limits, and the kill switch.
extension AccountStore {
  private func requireToken(feature: String) throws -> String {
    guard UserDefaults.standard.bool(forKey: AppViewModel.aiEnabledKey) else {
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
    aiStatus = await client.aiStatus()
    aiAvailable = aiStatus.enabled
  }

  func aiExplain(_ request: AIExplainRequest) async throws -> AIExplainResponse {
    await refreshAIStatus()
    return try await client.explain(request, token: requireToken(feature: "explain"))
  }

  func aiReview(_ request: AIReviewRequest) async throws -> AIReview {
    await refreshAIStatus()
    return try await client.review(request, token: requireToken(feature: "review"))
  }

  func aiAsk(question: String, history: [AITurn], context: AIContext) async throws -> AIAnswer {
    await refreshAIStatus()
    return try await client.ask(question: question, history: history, context: context, token: requireToken(feature: "ask"))
  }
}
