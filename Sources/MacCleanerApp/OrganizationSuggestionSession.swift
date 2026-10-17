import Combine
import Foundation
import MacCleanerCore

/// Preparation can be cancelled without touching a local move already in progress.
/// Late responses never replace newer edits, clear a newer busy state, or publish errors.
@MainActor
final class OrganizationSuggestionSession: ObservableObject {
  @Published private(set) var isBusy = false
  private var generation = UUID()
  private var task: Task<Void, Never>?

  @discardableResult
  func start(
    request: @escaping @MainActor () async throws -> [OrganizationProposal],
    receive: @escaping @MainActor ([OrganizationProposal]) -> Void,
    reportError: @escaping @MainActor (String) -> Void
  ) -> Task<Void, Never> {
    cancel()
    let token = generation
    isBusy = true
    let pending = Task { [weak self] in
      do {
        let result = try await request()
        guard !Task.isCancelled, let self, self.generation == token else { return }
        self.task = nil; self.isBusy = false
        receive(result)
      } catch {
        guard !Task.isCancelled, let self, self.generation == token else { return }
        self.task = nil; self.isBusy = false
        reportError(error.localizedDescription)
      }
    }
    task = pending
    return pending
  }

  func cancel() {
    generation = UUID()
    task?.cancel(); task = nil; isBusy = false
  }
}
