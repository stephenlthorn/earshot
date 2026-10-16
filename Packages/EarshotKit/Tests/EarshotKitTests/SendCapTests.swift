import Foundation
import Testing
@testable import EarshotKit

/// At most `DoPayload.maxItems` items go in one send, and nothing past the cap is ever recorded as sent.
struct SendCapTests {
    private static func notes(_ count: Int) -> MeetingNotes {
        MeetingNotes(title: "Planning", summary: "Plan.", actionItems: (1...count).map {
            ActionItem(task: "Task \($0)", owner: "Stephen", doer: .ai, context: "ctx")
        })
    }

    @Test func theConfirmWindowWontSendMoreThanOnePayloadCarries() {
        var draft = ConfirmDraft(notes: Self.notes(DoPayload.maxItems + 2), live: [])
        #expect(draft.chosenCount == 22)
        #expect(draft.problem == "At most 20 items go in one send. Untick 2.")
        #expect(!draft.canSend)
        draft.rows[0].chosen = false
        draft.rows[1].chosen = false
        #expect(draft.problem == nil && draft.canSend)
    }

    @Test func onlyWhatThePayloadCarriedIsRecordedAsSent() async throws {
        var world = V2World()
        let webhook = FakeTarget("webhook")
        world.targets = [webhook]
        let w = world
        w.writer.notes.update { $0 = Self.notes(24) }
        let s = try w.meeting()
        // As "Send without asking" does: the default picks, all 24, with no window.
        await w.pipeline().run(sessionID: s.id)
        let done = try w.fresh(s)
        #expect(done.isFinished && done.sent == ["webhook"])
        #expect(webhook.sent.get.first?.items.count == 20)
        let items = try w.items(done)
        #expect(items.map(\.task) == (1...20).map { "Task \($0)" })
        #expect(items.allSatisfy { $0.payload == done.id && $0.source != nil }, "source and payload are kept")
        #expect(done.warnings.contains("4 items were not sent: at most 20 items go in one send."))
        #expect(!done.warnings.contains { $0.contains("started during the call") }, "the cap is not blamed on live Start")
        let statuses = ItemStatus.compute(notes: try w.notes(done), items: items, sent: done.sent, live: [])
        #expect(statuses[19] != statuses[20], "item 21 isn't shown as sent")
        #expect(statuses[20] == statuses[23])
    }

    @Test func anExtraSendMarksOnlyWhatItCarriedAsDelivered() {
        let items = Self.notes(22).actionItems
        let send = AskRules.ExtraSend(items: items, targets: ["webhook"])
        let delivered = AskRules.delivered([:], after: send, results: ["webhook": DispatchResult(ok: true, detail: "")])
        #expect(delivered["webhook"]?.count == 20)
        #expect(AskRules.targetsMissing(items, targets: ["webhook"], delivered: delivered) == ["webhook"],
                "the two past the cap are offered again")
    }

    @Test func carriedSkipsBlankTasksBeforeTheCap() {
        let blank = ActionItem(task: "  ", owner: "Stephen", doer: .ai)
        let items = [blank] + Self.notes(21).actionItems
        #expect(DoPayload.carried(items).map(\.task) == (1...20).map { "Task \($0)" })
    }
}
