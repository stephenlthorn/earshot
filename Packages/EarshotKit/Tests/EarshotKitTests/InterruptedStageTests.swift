import Foundation
import Testing
@testable import EarshotKit

/// A stage stopped part-way after it had already failed twice, or after `earshot process` held it back from
/// resuming on its own (failures 2), comes back from `recover()` as failed, so Retry appears (A8, B1, I1).
struct InterruptedStageTests {
    /// A PID whose process has exited.
    static func deadPID() throws -> Int32 {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/true")
        try process.run()
        process.waitUntilExit()
        return process.processIdentifier
    }

    /// What a kill -9 of `earshot process --send` during the send leaves: notes written, the AI's pick in
    /// items.json, the target in flight, dispatch running with the CLI's failures 2, and `.busy` naming a dead PID.
    func killedDuringTheSend(_ w: V2World) throws -> Session {
        let s = try w.meeting()
        try Pipeline.json(meetingSegments.values.flatMap { $0 }).write(to: w.store.file(s, MeetingFile.transcript))
        try w.store.write(sampleNotes, s, MeetingFile.notes)
        try Data("# Notes\n".utf8).write(to: w.store.file(s, MeetingFile.notesMarkdown))
        try Pipeline.json([sampleNotes.actionItems[0]]).write(to: w.store.file(s, MeetingFile.items))
        try SessionStore.writeBusyMarker(pid: try Self.deadPID(), to: w.store.file(s, MeetingFile.busy))
        return try w.store.update(s.id) {
            $0.startedBy = .cli
            $0.stages[.transcribe] = StageState(status: .done)
            $0.stages[.notes] = StageState(status: .done)
            $0.stages[.dispatch] = StageState(status: .running, failures: 2)
            $0.inFlight = ["webhook"]
        }
    }

    @Test func aSendKilledMidwayIsFailedAfterRecoverAndRetryAsksFirst() async throws {
        var w = V2World()
        let target = FakeTarget("webhook")
        w.targets = [target]
        let s = try killedDuringTheSend(w)
        #expect(!w.store.isBusy(s))
        #expect(FileManager.default.fileExists(atPath: w.store.file(s, MeetingFile.items).path))

        let recovered = try #require(try w.store.recover().first { $0.id == s.id })
        #expect(recovered.stages[.dispatch]
            == StageState(status: .failed, error: SessionStore.interruptedError, failures: 2))
        #expect(try w.fresh(s) == recovered)
        #expect(!w.store.resumable().contains { $0.id == s.id })
        #expect(recovered.failedStage == .dispatch)

        let asked = Locked(0)
        let sentWhenAsked = Locked<Int?>(nil)
        let pipeline = w.pipeline(confirm: { _, notes in
            asked.update { $0 += 1 }
            sentWhenAsked.update { $0 = target.sent.get.count }
            return [notes.actionItems[1]]
        })
        // Launch resumes nothing on its own.
        await pipeline.resumeAll()
        #expect(asked.get == 0 && target.sent.get.isEmpty)
        // Retry asks before anything goes out, and sends what the person chose.
        await pipeline.retry(sessionID: s.id)
        #expect(asked.get == 1)
        #expect(sentWhenAsked.get == 0)
        #expect(target.sent.get.map { $0.items.map(\.task) } == [["Call the venue"]])
        #expect(try w.fresh(s).isFinished)
    }

    @Test func recoverFailsAStageStoppedAfterTwoFailures() throws {
        let store = SessionStore(root: tempDir(), timeZone: newYork)
        var s = try store.create(mode: .notesAndDo, title: "Held", now: at1530)
        s.recording = false
        s.stages[.transcribe] = StageState(status: .done)
        s.stages[.notes] = StageState(status: .pending, failures: 2)
        s.stages[.dispatch] = StageState(status: .running, failures: 3)
        try store.save(s)
        let recovered = try #require(try store.recover(now: at1530).first)
        let interrupted = SessionStore.interruptedError
        #expect(recovered.stages[.notes] == StageState(status: .failed, error: interrupted, failures: 2))
        #expect(recovered.stages[.dispatch] == StageState(status: .failed, error: interrupted, failures: 3))
        #expect(recovered.failedStage == .notes)
        #expect(store.resumable().isEmpty)
        #expect(try store.load(folderName: s.folderName) == recovered)
    }

    /// Finding 11: a kill -9 of `earshot process --send` during transcription leaves transcribe running and
    /// dispatch pending with the CLI's hold (failures 2). Nothing was sent, so dispatch is not marked interrupted;
    /// the meeting resumes, but stops at the held send, which waits for Retry, and Retry asks before sending.
    @Test func aKillBeforeTheSendLeavesTheHeldSendAsItWas() async throws {
        var w = V2World()
        let target = FakeTarget("webhook")
        w.targets = [target]
        let s = try w.meeting()
        try SessionStore.writeBusyMarker(pid: try Self.deadPID(), to: w.store.file(s, MeetingFile.busy))
        _ = try w.store.update(s.id) {
            $0.startedBy = .cli
            $0.stages[.transcribe] = StageState(status: .running)
            $0.stages[.notes] = StageState(status: .pending)
            $0.stages[.dispatch] = StageState(status: .pending, failures: 2)
        }
        let recovered = try #require(try w.store.recover().first { $0.id == s.id })
        #expect(recovered.stages[.transcribe] == StageState(status: .pending))
        #expect(recovered.stages[.dispatch] == StageState(status: .pending, failures: 2))
        #expect(recovered.failedStage == nil)
        #expect(w.store.resumable().map(\.id) == [s.id])

        let asked = Locked(0)
        let sentWhenAsked = Locked<Int?>(nil)
        let pipeline = w.pipeline(confirm: { _, notes in
            asked.update { $0 += 1 }
            sentWhenAsked.update { $0 = target.sent.get.count }
            return [notes.actionItems[1]]
        })
        await pipeline.resumeAll()
        #expect(asked.get == 0 && target.sent.get.isEmpty, "the app never sends a held meeting on its own")
        #expect(try w.fresh(s).failedStage == .dispatch)
        await pipeline.retry(sessionID: s.id)
        #expect(asked.get == 1)
        #expect(sentWhenAsked.get == 0)
        #expect(target.sent.get.map { $0.items.map(\.task) } == [["Call the venue"]])
        #expect(try w.fresh(s).isFinished)
    }

    @Test func recoverLeavesOtherStagesAsBefore() throws {
        let store = SessionStore(root: tempDir(), timeZone: newYork)
        var s = try store.create(mode: .notesAndDo, title: "Mixed", now: at1530)
        s.recording = false
        s.stages[.transcribe] = StageState(status: .running, failures: 1)
        s.stages[.notes] = StageState(status: .failed, error: "Credit balance too low", failures: 2)
        s.stages[.dispatch] = StageState(status: .pending, failures: 1)
        try store.save(s)
        let recovered = try #require(try store.recover(now: at1530).first)
        // A running stage that failed fewer than two times goes back to pending and resumes on its own.
        #expect(recovered.stages[.transcribe] == StageState(status: .pending, failures: 1))
        // A failed stage keeps its own error; a pending one under two failures is untouched.
        #expect(recovered.stages[.notes] == StageState(status: .failed, error: "Credit balance too low", failures: 2))
        #expect(recovered.stages[.dispatch] == StageState(status: .pending, failures: 1))
        #expect(store.resumable().map(\.id) == [s.id])
        // Nothing left to change: a second recover saves nothing new.
        let again = try #require(try store.recover(now: at1530.addingTimeInterval(60)).first)
        #expect(again == recovered)
    }

    @Test func aMeetingStillBusyKeepsItsStoppedStage() throws {
        let store = SessionStore(root: tempDir(), timeZone: newYork)
        var s = try store.create(mode: .notesAndDo, title: "CLI", now: at1530)
        s.recording = false
        s.stages[.dispatch] = StageState(status: .pending, failures: 2)
        try store.save(s)
        try store.markBusy(s)
        #expect(try store.recover(now: at1530).isEmpty)
        #expect(try store.load(folderName: s.folderName).stages[.dispatch] == StageState(status: .pending, failures: 2))
    }
}
