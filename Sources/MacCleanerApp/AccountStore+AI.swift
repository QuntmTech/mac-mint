import Foundation
import MacCleanerCore

/// AI calls go through the signed-in session; the server holds the Anthropic key and enforces
/// plan, limits, and the kill switch.
extension AccountStore {
  private func requireToken(feature: String) throws -> String {
    guard UserDefaults.standard.bool(forKey: AppViewModel.aiEnabledKey), aiStatus.allows(feature), isUnlocked else {
      throw AccountAPIError(status: 403, code: "ai_unavailable", message: "AI needs your consent, an active plan and an available feature.")
    }
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
