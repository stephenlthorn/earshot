import Foundation
import Testing
@testable import EarshotKit

/// "Write notes" for a meeting recorded in Record mode: it becomes a Notes meeting and runs (task I2a).
struct RecordingNotesTests {
    /// A Record meeting whose compress stage is done, as Stop and the pipeline leave it.
    private func finishedRecording(_ h: Harness) async throws -> Session {
        let s = try h.stoppedSession(mode: .record)
        await h.pipeline().run(sessionID: s.id)
        let done = try h.store.load(folderName: s.folderName)
        #expect(done.isFinished && done.tracks.map(\.file) == ["mic.m4a", "system.m4a"])
        h.events.update { $0 = [] }
        return done
    }

    @Test func aFinishedRecordingGetsNotes() async throws {
        let h = Harness()
        let s = try await finishedRecording(h)
        try await h.pipeline().writeNotesForRecording(sessionID: s.id)
        let done = try h.store.load(folderName: s.folderName)
        #expect(done.mode == .notes && done.isFinished)
        #expect(done.stages[.transcribe]?.status == .done && done.stages[.notes]?.status == .done)
        #expect(done.stages[.compress] == StageState(status: .done))
        #expect(h.transcriber.calls.get == 2 && h.writer.calls.get == 1)
        #expect(FileManager.default.fileExists(atPath: h.store.file(done, MeetingFile.notesMarkdown).path))
        #expect(FileManager.default.fileExists(atPath: h.store.file(done, MeetingFile.notesPage).path))
        // The audio was compressed already: that stage doesn't run again, and the audio stays.
        #expect(done.tracks.map(\.file) == ["mic.m4a", "system.m4a"])
        #expect(done.tracks.allSatisfy { FileManager.default.fileExists(atPath: h.store.file(done, $0.file).path) })
        #expect(h.events.get == [.started(sessionID: s.id, stage: .transcribe), .started(sessionID: s.id, stage: .notes),
                                 .notesReady(sessionID: s.id, notes: h.store.file(done, MeetingFile.notesPage)),
                                 .finished(sessionID: s.id)])
    }

    /// The Notes ready notification opens the notes page, like the meeting rows; notes.md only without one.
    @Test func notesReadyOpensThePageAndFallsBackToTheMarkdown() async throws {
        let h = Harness()
        let s = try h.stoppedSession(mode: .notes)
        let pipeline = h.pipeline()
        await pipeline.run(sessionID: s.id)
        let done = try h.store.load(folderName: s.folderName)
        let page = h.store.file(done, MeetingFile.notesPage)
        #expect(h.events.get.contains(.notesReady(sessionID: s.id, notes: page)))
        try FileManager.default.removeItem(at: page)
        #expect(await pipeline.notesToOpen(done) == h.store.file(done, MeetingFile.notesMarkdown))
    }

    /// The switch goes through `SessionStore.update`, so what another writer saved meanwhile is kept.
    @Test func theSwitchKeepsWhatIsOnDisk() async throws {
        let h = Harness()
        var s = try await finishedRecording(h)
        s.flags = [Flag(offset: 12, source: .hotkey)]
        s.warnings = ["kept"]
        try h.store.save(s)
        try await h.pipeline().writeNotesForRecording(sessionID: s.id)
        let done = try h.store.load(folderName: s.folderName)
        #expect(done.flags == [Flag(offset: 12, source: .hotkey)] && done.warnings.contains("kept"))
    }

    /// The switch starts from the claimed copy but saves through `SessionStore.update`, so a change another writer
    /// saved after the claim survives: the stale copy never overwrites it.
    @Test func theSwitchRereadsTheMeetingAfterTheClaim() async throws {
        let h = Harness()
        let claimed = try await finishedRecording(h)
        _ = try h.store.update(claimed.id) { current in
            current.flags = [Flag(offset: 30, source: .hotkey)]
            current.warnings.append("saved after the claim")
        }
        let switched = try await h.pipeline().switchToNotes(claimed)
        let onDisk = try h.store.load(folderName: claimed.folderName)
        #expect(onDisk == switched)
        #expect(onDisk.mode == .notes && onDisk.stages[.notes] == StageState() && onDisk.stages[.compress]?.status == .done)
        #expect(onDisk.flags == [Flag(offset: 30, source: .hotkey)] && onDisk.warnings.contains("saved after the claim"))
        // What is on disk decides: a meeting that changed mode since the claim is not switched.
        let other = try await finishedRecording(h)
        _ = try h.store.update(other.id) { $0.mode = .notes }
        await #expect(throws: PipelineError.notAFinishedRecording) { try await h.pipeline().switchToNotes(other) }
    }

    @Test func aFailedNotesStageWaitsForRetryAsANotesMeeting() async throws {
        let h = Harness()
        let s = try await finishedRecording(h)
        h.writer.failure.update { $0 = NotesError.usageLimit("limit") }
        try await h.pipeline().writeNotesForRecording(sessionID: s.id)
        let failed = try h.store.load(folderName: s.folderName)
        #expect(failed.mode == .notes && failed.nextStage == .notes)
        #expect(failed.stages[.notes]?.status == .failed && failed.stages[.compress]?.status == .done)
        h.writer.failure.update { $0 = nil }
        await h.pipeline().retry(sessionID: s.id)
        #expect(try h.store.load(folderName: s.folderName).isFinished)
    }

    @Test func onlyAFinishedRecordMeetingCanSwitch() async throws {
        let h = Harness()
        let notes = try h.stoppedSession(mode: .notes)
        await h.pipeline().run(sessionID: notes.id)
        let unfinished = try h.stoppedSession(mode: .record)  // compress hasn't run
        var failedCompress = try h.stoppedSession(mode: .record)
        failedCompress.stages[.compress] = StageState(status: .failed, error: "disk", failures: 1)
        try h.store.save(failedCompress)
        for id in [notes.id, unfinished.id, failedCompress.id] {
            let before = try #require(h.store.find(id))
            await #expect(throws: PipelineError.notAFinishedRecording) {
                try await h.pipeline().writeNotesForRecording(sessionID: id)
            }
            #expect(h.store.find(id) == before, "nothing changed")
        }
        await #expect(throws: SessionStoreError.notFound("nope")) {
            try await h.pipeline().writeNotesForRecording(sessionID: "nope")
        }
        #expect(PipelineError.notAFinishedRecording.errorDescription == "Notes can be written only for a finished recording.")
    }

    @Test func aBusyMeetingIsLeftAlone() async throws {
        let h = Harness()
        // Still recording.
        var recording = try await finishedRecording(h)
        recording.recording = true
        try h.store.save(recording)
        await #expect(throws: PipelineError.meetingBusy) { try await h.pipeline().writeNotesForRecording(sessionID: recording.id) }
        #expect(h.store.find(recording.id)?.mode == .record)
        // Held by `earshot process` (a live busy marker).
        let held = try await finishedRecording(h)
        try h.store.markBusy(held)
        await #expect(throws: PipelineError.meetingBusy) { try await h.pipeline().writeNotesForRecording(sessionID: held.id) }
        #expect(h.store.find(held.id)?.mode == .record)
        h.store.clearBusy(held)
        // Already being switched and run here.
        let s = try await finishedRecording(h)
        let pipeline = h.pipeline()
        h.writer.held.update { $0 = true }
        let first = Task { try await pipeline.writeNotesForRecording(sessionID: s.id) }
        await pollUntil { h.writer.calls.get == 1 }
        await #expect(throws: PipelineError.meetingBusy) { try await pipeline.writeNotesForRecording(sessionID: s.id) }
        h.writer.held.update { $0 = false }
        try await first.value
        #expect(h.writer.calls.get == 1 && h.store.find(s.id)?.isFinished == true)
    }
}
