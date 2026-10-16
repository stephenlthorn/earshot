import Foundation
import Testing
@testable import EarshotKit

private func row(_ status: LiveItem.Status = .suggested, ai: Bool, detail: String? = nil) -> LiveItem {
    LiveItem(id: "L1", task: "Book the venue", owner: "Dana", aiDoable: ai, why: "Dana asked", firstSeen: 1,
             status: status, target: status == .suggested ? nil : "webhook", detail: detail)
}

/// Start is offered only on to-dos the model marked AI-doable (spec 4); other rows offer Dismiss only.
struct LiveRowsAITests {
    let now = Date(timeIntervalSince1970: 1_000)

    @Test func aSuggestionThatIsNotAIDoableOffersDismissOnly() {
        for start: LiveStartPolicy.Decision? in [.oneClick, .confirmSheet, .unavailable(LiveStartPolicy.setUpTarget), nil] {
            #expect(LiveRows.rows([row(ai: false)], start: start, pressedAt: [:], now: now)[0].actions == [.dismiss])
        }
    }

    @Test func aFailedRowThatIsNotAIDoableOffersDismissOnly() {
        let rows = LiveRows.rows([row(.failed, ai: false, detail: "timed out")], start: .oneClick, pressedAt: [:], now: now)
        #expect(rows[0].actions == [.dismiss])
        #expect(rows[0].state == "Failed: timed out")
    }

    @Test func aFailedAIRowKeepsStartForARetry() {
        let rows = LiveRows.rows([row(.failed, ai: true)], start: .oneClick, pressedAt: [:], now: now)
        #expect(rows[0].actions == [.start, .dismiss])
    }

    @Test func anAISuggestionStillOffersStartOrSetUp() {
        #expect(LiveRows.rows([row(ai: true)], start: .oneClick, pressedAt: [:], now: now)[0].actions == [.start, .dismiss])
        #expect(LiveRows.rows([row(ai: true)], start: .unavailable(LiveStartPolicy.setUpTarget), pressedAt: [:], now: now)[0]
            .actions == [.setUp(LiveStartPolicy.setUpTarget), .dismiss])
    }

    @Test func offersStartFollowsTheFlag() {
        #expect(LiveRows.offersStart(row(ai: true)))
        #expect(!LiveRows.offersStart(row(ai: false)))
    }
}
