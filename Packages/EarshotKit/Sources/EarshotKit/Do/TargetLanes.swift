import Foundation

/// One run at a time per Do target across the whole process (spec 3.2). Every live Start queue and the pipeline's
/// sends take a target's lane before they call it and give it back when the call returns, so a meeting's post-call
/// send, a finished meeting's live run and the next meeting's live Start never run the same target at once (two
/// Claude Code runs editing one work folder, say).
public final class TargetLanes: Sendable {
    /// The App's lanes. `earshot process` runs in its own process, so it has its own.
    public static let shared = TargetLanes()

    private struct State {
        var busy: Set<String> = []
        var waiters: [String: [UUID: CheckedContinuation<Void, Never>]] = [:]
    }

    private let state = Locked(State())

    public init() {}

    /// Takes `target`'s lane when it is free. Returns false, and takes nothing, when someone else has it.
    public func tryAcquire(_ target: String) -> Bool {
        var taken = false
        state.update { taken = $0.busy.insert(target).inserted }
        return taken
    }

    /// Gives `target`'s lane back and wakes everyone waiting for it.
    public func release(_ target: String) {
        var woken: [CheckedContinuation<Void, Never>] = []
        state.update { state in
            state.busy.remove(target)
            woken = Array((state.waiters.removeValue(forKey: target) ?? [:]).values)
        }
        woken.forEach { $0.resume() }
    }

    public func isBusy(_ target: String) -> Bool {
        state.get.busy.contains(target)
    }

    /// Returns once `target`'s lane is given back: at once when it is free now, and early when the task is cancelled.
    /// It doesn't take the lane; call `tryAcquire` after it.
    public func released(_ target: String) async {
        let key = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                var now = false
                state.update { state in
                    if !state.busy.contains(target) || Task.isCancelled {
                        now = true
                    } else {
                        state.waiters[target, default: [:]][key] = continuation
                    }
                }
                if now { continuation.resume() }
            }
        } onCancel: {
            var waiting: CheckedContinuation<Void, Never>?
            state.update { waiting = $0.waiters[target]?.removeValue(forKey: key) }
            waiting?.resume()
        }
    }

    /// Waits for `target`'s lane and takes it. Throws `CancellationError`, holding nothing, when the task is
    /// cancelled first.
    public func acquire(_ target: String) async throws {
        while !tryAcquire(target) {
            try Task.checkCancellation()
            await released(target)
        }
        if Task.isCancelled {
            release(target)
            throw CancellationError()
        }
    }
}
