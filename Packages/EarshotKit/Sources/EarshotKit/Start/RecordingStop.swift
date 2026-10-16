import Foundation

extension SessionStore {
    /// Closes a recording on disk (spec 14.3): its tracks, warnings, end time and `recording: false`. It goes through
    /// `update`, so what was saved during the recording (the calendar event, flags) is kept. When session.json is
    /// missing or can't be read, the in-memory `session` is saved instead, as v1 did, so the meeting is still
    /// processed. Throws only when neither way can save.
    @discardableResult
    public func finishRecording(_ session: Session, tracks: [TrackFile], warnings: [String],
                                endedAt: Date) throws -> Session {
        let close: (inout Session) -> Void = {
            $0.tracks = tracks
            $0.warnings += warnings
            $0.recording = false
            $0.endedAt = endedAt
        }
        do {
            return try update(session.id, close)
        } catch {
            var fromMemory = session
            close(&fromMemory)
            try save(fromMemory)
            return fromMemory
        }
    }
}

/// Waiting on a task with a time limit.
public enum TaskWait {
    /// Waits for `task` at most `limit`. True when it finished in time. The task is left running either way: work
    /// inside system calls that ignore cancellation can't be stopped, only stopped waiting for.
    public static func finished(_ task: Task<Void, Never>, within limit: Duration) async -> Bool {
        let slot = Locked<CheckedContinuation<Bool, Never>?>(nil)
        let finish: @Sendable (Bool) -> Void = { value in
            slot.update {
                $0?.resume(returning: value)
                $0 = nil
            }
        }
        return await withCheckedContinuation { continuation in
            slot.update { $0 = continuation }
            let timer = Task {
                guard (try? await Task.sleep(for: limit)) != nil else { return }
                finish(false)
            }
            Task {
                await task.value
                timer.cancel()
                finish(true)
            }
        }
    }
}
