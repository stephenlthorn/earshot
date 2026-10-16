import Foundation

/// The pool for structured `claude` children (spec 3.2): at most `limit` at once. A freed slot goes to the waiting
/// call with the highest priority (notes, fix, ask, brief, live), oldest first within one role.
public actor ClaudeGate {
    public static let shared = ClaudeGate()

    private struct Waiter {
        let ticket: Int
        let rank: Int
        let continuation: CheckedContinuation<Void, any Error>
    }

    private let limit: Int
    private var busy = 0
    private var waiting: [Waiter] = []
    private var nextTicket = 0

    public init(limit: Int = 2) {
        self.limit = max(1, limit)
    }

    /// Runs `body` once a slot is free. With `skipIfBusy`, returns nil at once when no slot is free. A caller
    /// cancelled while it waits throws `CancellationError` and never runs.
    public func run<T: Sendable>(_ role: ClaudeRole, skipIfBusy: Bool,
                                 _ body: @Sendable () async throws -> T) async throws -> T? {
        if busy < limit {
            busy += 1
        } else if skipIfBusy {
            return nil
        } else {
            try await wait(rank: role.rank)
        }
        defer { release() }
        return try await body()
    }

    /// How many calls are waiting for a slot, for tests.
    var queued: Int { waiting.count }

    private func wait(rank: Int) async throws {
        let ticket = nextTicket
        nextTicket += 1
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else {
                    waiting.append(Waiter(ticket: ticket, rank: rank, continuation: continuation))
                }
            }
        } onCancel: {
            Task { await self.cancel(ticket) }
        }
    }

    private func cancel(_ ticket: Int) {
        guard let index = waiting.firstIndex(where: { $0.ticket == ticket }) else { return }
        waiting.remove(at: index).continuation.resume(throwing: CancellationError())
    }

    /// Hands the slot straight to the next waiter, so a new caller can't take it in between.
    private func release() {
        let order = { (index: Int) in (self.waiting[index].rank, self.waiting[index].ticket) }
        guard let next = waiting.indices.min(by: { order($0) < order($1) }) else {
            busy -= 1
            return
        }
        waiting.remove(at: next).continuation.resume()
    }
}
