import Foundation

/// Notes for a meeting that was recorded in Record mode (task I2a; the menu's "Write notes" calls it).
extension Pipeline {
    /// Switches a finished Record meeting to Notes and runs it: transcribe and notes become pending, and compress
    /// stays done, so the audio is kept as it is. The switch is saved through `SessionStore.update` before anything
    /// runs. A failed stage then waits for Retry like any Notes meeting.
    /// - Throws: `PipelineError.meetingBusy` while the meeting records, runs here or is held by `earshot process`;
    ///   `PipelineError.notAFinishedRecording` for any other mode or an unfinished recording;
    ///   `SessionStoreError.notFound` for an unknown id.
    public func writeNotesForRecording(sessionID: String) async throws {
        let session = try claim(sessionID)
        do {
            _ = try switchToNotes(session)
        } catch {
            running.remove(sessionID)
            throw error
        }
        // `run` claims the meeting again; nothing can come in between on this actor.
        running.remove(sessionID)
        await run(sessionID: sessionID)
    }

    /// Saves the switch from the claimed meeting through `SessionStore.update`, which reads session.json again, so
    /// a change saved after the claim is kept. What is on disk decides whether it is still a finished recording.
    func switchToNotes(_ claimed: Session) throws -> Session {
        guard claimed.mode == .record, claimed.isFinished else { throw PipelineError.notAFinishedRecording }
        return try store.update(claimed.id) { current in
            guard current.mode == .record, current.isFinished else { throw PipelineError.notAFinishedRecording }
            current.mode = .notes
            current.stages[.transcribe] = StageState()
            current.stages[.notes] = StageState()
        }
    }
}
