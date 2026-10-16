import Foundation
import Testing
@testable import EarshotKit

/// "Send the N new items…" keeps what each target took, so every item reaches every target once (I1).
struct ExtraSendPlanTests {
    let deck = ActionItem(task: "Send the deck", owner: "Me", doer: .ai)
    let room = ActionItem(task: "Book a room", owner: "Me", doer: .ai)
    let venue = ActionItem(task: "Call the venue", owner: "Me", doer: .ai)
    let ok = DispatchResult(ok: true, detail: "200")
    let down = DispatchResult(ok: false, detail: "401")

    typealias Send = AskRules.ExtraSend

    @Test func theFirstSendGoesToEveryTargetInOneCall() {
        #expect(AskRules.extraSends([deck, room], targets: ["webhook", "command"], delivered: [:])
            == [Send(items: [deck, room], targets: ["webhook", "command"])])
        #expect(AskRules.extraSends([], targets: ["webhook"], delivered: [:]).isEmpty)
        #expect(AskRules.extraSends([deck], targets: [], delivered: [:]).isEmpty)
    }

    @Test func aTargetGetsOnlyTheItemsItHasNotTaken() {
        let delivered: [String: Set<ActionItem>] = ["webhook": [deck]]
        #expect(AskRules.extraSends([deck], targets: ["webhook", "command"], delivered: delivered)
            == [Send(items: [deck], targets: ["command"])])
        #expect(AskRules.targetsMissing([deck], targets: ["webhook", "command"], delivered: delivered) == ["command"])
        #expect(AskRules.targetsMissing([deck], targets: ["webhook"], delivered: delivered).isEmpty)
    }

    /// Finding 1 and 7: the retry's items are not a subset of the first send's. Pending [A, B]; the first try sends
    /// only A, which the webhook takes and the command misses. The retry with A and B sends A to the command only
    /// and B to both.
    @Test func aRetryWithItemsTheFirstSendLackedSendsThemToEveryTarget() {
        let first = Send(items: [deck], targets: ["webhook", "command"])
        let delivered = AskRules.delivered([:], after: first, results: ["webhook": ok, "command": down])
        #expect(delivered == ["webhook": [deck]])
        let retry = AskRules.extraSends([deck, room], targets: ["webhook", "command"], delivered: delivered)
        #expect(retry == [Send(items: [room], targets: ["webhook"]), Send(items: [deck, room], targets: ["command"])])
        let after = retry.reduce(delivered) { AskRules.delivered($0, after: $1, results: ["webhook": ok, "command": ok]) }
        #expect(after == ["webhook": [deck, room], "command": [deck, room]])
        #expect(AskRules.targetsMissing([deck, room], targets: ["webhook", "command"], delivered: after).isEmpty)
    }

    /// Finding 1: an item edited in the confirm window went nowhere yet, so every target gets it.
    @Test func anEditedItemGoesToEveryTarget() {
        var edited = deck
        edited.owner = "Dana"
        let delivered: [String: Set<ActionItem>] = ["webhook": [deck]]
        #expect(AskRules.extraSends([edited], targets: ["webhook", "command"], delivered: delivered)
            == [Send(items: [edited], targets: ["webhook", "command"])])
    }

    /// Finding 6: A and B reached the webhook but not the command, then a Fix added C. No item reaches a target twice.
    @Test func aFixThatAddsAnItemNeverSendsTheOldOnesTwice() {
        let first = Send(items: [deck, room], targets: ["webhook", "command"])
        let delivered = AskRules.delivered([:], after: first, results: ["webhook": ok, "command": down])
        let sends = AskRules.extraSends([deck, room, venue], targets: ["webhook", "command"], delivered: delivered)
        #expect(sends == [Send(items: [venue], targets: ["webhook"]),
                          Send(items: [deck, room, venue], targets: ["command"])])
        let webhookGot = [first.items] + sends.filter { $0.targets.contains("webhook") }.map(\.items)
        #expect(webhookGot.flatMap { $0 }.count == Set(webhookGot.flatMap { $0 }).count)
        // A Fix that only removes an item: the webhook already has the one left, so only the command gets it.
        #expect(AskRules.extraSends([deck], targets: ["webhook", "command"], delivered: delivered)
            == [Send(items: [deck], targets: ["command"])])
    }

    /// Finding 9: the target that failed is switched off now, so no target that is still on lacks anything; one
    /// switched on since then gets everything.
    @Test func theSendFollowsTheTargetsSwitchedOnNow() {
        let delivered: [String: Set<ActionItem>] = ["webhook": [deck]]
        #expect(AskRules.targetsMissing([deck], targets: ["webhook"], delivered: delivered).isEmpty)
        #expect(AskRules.extraSends([deck], targets: ["webhook"], delivered: delivered).isEmpty)
        #expect(AskRules.extraSends([deck], targets: ["webhook", "routine"], delivered: delivered)
            == [Send(items: [deck], targets: ["routine"])])
    }

    @Test func onlyTargetsThatTookTheSendHaveItsItems() {
        let send = Send(items: [deck], targets: ["webhook"])
        // A result for a target outside the send, or a failed one, records nothing.
        #expect(AskRules.delivered([:], after: send, results: ["command": ok, "webhook": down]).isEmpty)
        #expect(AskRules.delivered([:], after: send, results: [:]).isEmpty)
        // Items are kept without `source`, so the same item from the notes matches.
        var sourced = deck
        sourced.source = "n1"
        let had = AskRules.delivered([:], after: Send(items: [sourced], targets: ["webhook"]), results: ["webhook": ok])
        #expect(had == ["webhook": [deck]])
        #expect(AskRules.targetsMissing([sourced], targets: ["webhook"], delivered: had).isEmpty)
    }

    // MARK: The payload id of an extra send

    static let receiverRule = #"^[A-Za-z0-9-]{1,64}$"#

    @Test func theIDChangesWithTheItemsAndStaysTheSameForAnIdenticalRetry() {
        let id = "2026-10-14-1530-ab12"
        let first = Pipeline.extraPayloadID(sessionID: id, revision: 1, items: [deck])
        #expect(first.hasPrefix("\(id)-r1-"))
        #expect(first == Pipeline.extraPayloadID(sessionID: id, revision: 1, items: [deck]))
        // The item's other fields don't matter; its tasks, in the order they are carried, do.
        var reworded = room
        reworded.owner = "Dana"
        reworded.source = "n3"
        #expect(Pipeline.extraPayloadID(sessionID: id, revision: 1, items: [deck, room])
            == Pipeline.extraPayloadID(sessionID: id, revision: 1, items: [deck, reworded]))
        // The receiver keeps done-state per id and item position, so the same items in another order are a new send.
        #expect(Pipeline.extraPayloadID(sessionID: id, revision: 1, items: [deck, room])
            != Pipeline.extraPayloadID(sessionID: id, revision: 1, items: [room, deck]))
        #expect(Pipeline.extraPayloadID(sessionID: id, revision: 1, items: [deck, room]) != first)
        #expect(Pipeline.extraPayloadID(sessionID: id, revision: 1, items: [room]) != first)
        #expect(Pipeline.extraPayloadID(sessionID: id, revision: 2, items: [deck]) != first)
    }

    @Test func theIDKeepsToTheReceiversRule() {
        let tasks = [deck, room, venue, ActionItem(task: "Ünïcode and / slashes & more", owner: "Me", doer: .ai)]
        for id in ["2026-10-14-1530-ab12", String(repeating: "a", count: 64)] {
            for revision in [0, 1, 12, 9999] {
                let payload = Pipeline.extraPayloadID(sessionID: id, revision: revision, items: tasks)
                #expect(payload.range(of: Self.receiverRule, options: .regularExpression) != nil, "\(payload)")
            }
        }
    }
}
