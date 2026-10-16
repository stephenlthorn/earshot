import Foundation
import Testing
@testable import EarshotKit

/// The send `earshot process` holds for a person (spec 2): the app never runs it on its own, and Retry asks first.
struct HeldSendTests {
    /// A meeting `earshot process` made, with the send held as the CLI holds it and `first` as the next stage.
    private func heldMeeting(_ w: V2World, first: Stage? = nil) throws -> Session {
        let s = try w.meeting()
        return try w.store.update(s.id) { current in
            current.startedBy = .cli
            current.stages[.dispatch] = StageState(failures: SessionStore.autoResumeLimit)
            if let first { current.stages[first] = StageState(status: .failed, error: "timed out", failures: 2) }
        }
    }

    @Test func theAppStopsAtAHeldSendAndMarksItForRetry() async throws {
        var world = V2World()
        let webhook = FakeTarget("webhook")
        world.targets = [webhook]
        let w = world
        let s = try heldMeeting(w)
        let asked = Locked(0)
        await w.pipeline(confirm: { _, notes in
            asked.update { $0 += 1 }
            return ActionItem.defaultSelection(notes.actionItems)
        }).run(sessionID: s.id)
        let after = try w.fresh(s)
        #expect(after.stages[.notes]?.status == .done, "the stages before the send still run")
        #expect(after.stages[.dispatch] == StageState(status: .failed, error: SessionStore.interruptedError,
                                                      failures: SessionStore.autoResumeLimit))
        #expect(after.failedStage == .dispatch)
        #expect(webhook.sent.get.isEmpty && asked.get == 0)
        #expect(w.events.get.contains(.failed(sessionID: s.id, stage: .dispatch, message: SessionStore.interruptedError)))
    }

    @Test func retryRunsThroughTheHeldSendAndAsksFirst() async throws {
        var world = V2World()
        let webhook = FakeTarget("webhook")
        world.targets = [webhook]
        let w = world
        // Transcription failed twice, so the meeting waits for Retry before it reaches the held send.
        let s = try heldMeeting(w, first: .transcribe)
        #expect(w.store.resumable().isEmpty)
        let asked = Locked(0)
        let pipeline = w.pipeline(confirm: { _, notes in
            asked.update { $0 += 1 }
            return ActionItem.defaultSelection(notes.actionItems)
        })
        // One Retry is the user's go-ahead for the rest, and the send still asks first.
        await pipeline.retry(sessionID: s.id)
        #expect(asked.get == 1 && webhook.sent.get.count == 1)
        #expect(try w.fresh(s).isFinished)
    }

    @Test func aCLIMeetingAlwaysOpensTheConfirmWindow() throws {
        var settings = EarshotSettings()
        settings.sendWithoutAsking = true
        var session = try SessionStore(root: tempDir()).create(mode: .notesAndDo, title: "t", now: at1530)
        session.startedBy = .cli
        session.profile = nil
        #expect(ConfirmPolicy.mustAsk(session: session, settings: settings))
    }
}
