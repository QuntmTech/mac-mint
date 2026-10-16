import Foundation
import MacCleanerCore

/// AI calls go through the signed-in session; the server holds the Anthropic key and enforces
/// plan, limits, and the kill switch.
extension AccountStore {
  private func requireToken() throws -> String {
    guard let token else {
      throw AccountAPIError(status: 401, code: "unauthorized", message: "Sign in to use AI features.")
    }
    return token
  }

  func refreshAIStatus() async {
    aiAvailable = await client.aiStatus().enabled
  }

  func aiExplain(_ request: AIExplainRequest) async throws -> AIExplainResponse {
    try await client.explain(request, token: requireToken())
  }

  func aiReview(_ request: AIReviewRequest) async throws -> AIReview {
    try await client.review(request, token: requireToken())
  }

  func aiAsk(question: String, history: [AITurn], context: AIContext) async throws -> AIAnswer {
    try await client.ask(question: question, history: history, context: context, token: requireToken())
  }
}
