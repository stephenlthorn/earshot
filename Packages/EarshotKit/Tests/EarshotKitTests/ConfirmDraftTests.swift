import Foundation
import Testing
@testable import EarshotKit

private func item(_ task: String, owner: String = "Stephen", due: String? = nil, doer: ActionItem.Doer = .ai,
                  liveRef: String? = nil) -> ActionItem {
    ActionItem(task: task, owner: owner, due: due, doer: doer, context: "ctx", liveRef: liveRef)
}

private func live(_ id: String, _ task: String, _ status: LiveItem.Status) -> LiveItem {
    LiveItem(id: id, task: task, owner: "Stephen", aiDoable: true, firstSeen: 10, status: status)
}

private let threeItems = MeetingNotes(title: "Acme", summary: "s", actionItems: [
    item("Draft the pilot scope email", due: "Friday"),
    item("Call the venue", doer: .me),
    item("Book the demo room", liveRef: "L1"),
])

/// Spec 6 and 4.4: the confirm window's rows, what Send returns and the lessons it records.
struct ConfirmDraftTests {
    @Test func defaultSelectionIsAIItemsMinusThoseStartedDuringTheCall() {
        let draft = ConfirmDraft(notes: threeItems, live: [live("L1", "Book the demo room", .running)])
        #expect(draft.rows.map(\.chosen) == [true, false, false])
        #expect(draft.rows.map(\.startedDuringCall) == [false, false, true])
        #expect(draft.baseline == [0])
        #expect(draft.chosenCount == 1)
    }

    @Test func aLiveItemThatWasOnlySuggestedDoesNotLockItsRow() {
        let draft = ConfirmDraft(notes: threeItems, live: [live("L1", "Book the demo room", .suggested)])
        #expect(draft.rows.map(\.startedDuringCall) == [false, false, false])
        #expect(draft.baseline == [0, 2])
    }

    @Test func sentItemsCarryTheirOneBasedNotesSource() {
        var draft = ConfirmDraft(notes: threeItems, live: [])
        draft.rows[1].chosen = true
        #expect(draft.chosenItems.map(\.source) == ["n1", "n2", "n3"])
        #expect(draft.chosenItems.map(\.task) == threeItems.actionItems.map(\.task))
    }

    @Test func aLockedRowIsNeverSentEvenWhenTicked() {
        var draft = ConfirmDraft(notes: threeItems, live: [live("L1", "Book the demo room", .done)])
        draft.rows[2].chosen = true
        #expect(draft.chosenItems.map(\.source) == ["n1"])
        #expect(draft.chosenCount == 1)
    }

    @Test func editsChangeTheSentItemAndABlankDueBecomesNone() {
        var draft = ConfirmDraft(notes: threeItems, live: [])
        draft.rows[0].task = "  Draft the pilot scope email for Dana "
        draft.rows[0].owner = "Ashley"
        draft.rows[0].due = "  "
        let sent = draft.chosenItems[0]
        #expect(sent.task == "Draft the pilot scope email for Dana")
        #expect(sent.owner == "Ashley")
        #expect(sent.due == nil)
        #expect(sent.doer == .ai)
        #expect(sent.context == "ctx")
        #expect(draft.rows[0].isEdited)
        #expect(!draft.rows[1].isEdited)
    }

    @Test func aBlankOwnerIsSentAsUnassigned() {
        var draft = ConfirmDraft(notes: threeItems, live: [])
        draft.rows[0].owner = " "
        #expect(draft.chosenItems[0].owner == "Unassigned")
    }

    @Test func anUntouchedItemWithABlankOwnerIsNotAnEdit() {
        let notes = MeetingNotes(title: "A", summary: "s", actionItems: [item("Send the deck", owner: ""),
                                                                         item("Book a room", owner: "  ")])
        let draft = ConfirmDraft(notes: notes, live: [])
        #expect(draft.rows.allSatisfy { !$0.isEdited })
        #expect(draft.chosenItems.map(\.owner) == ["Unassigned", "Unassigned"])
        #expect(draft.lessons(style: .general, title: "A", date: at1530).isEmpty)
    }

    @Test func typingUnassignedForABlankOwnerIsNotAnEditButANameIs() {
        let notes = MeetingNotes(title: "A", summary: "s", actionItems: [item("Send the deck", owner: "")])
        var draft = ConfirmDraft(notes: notes, live: [])
        draft.rows[0].owner = "Unassigned"
        #expect(!draft.rows[0].isEdited)
        draft.rows[0].owner = "Dana"
        #expect(draft.rows[0].isEdited)
        let lessons = draft.lessons(style: .general, title: "A", date: at1530)
        #expect(lessons.map(\.kind) == [.edited])
        #expect(lessons[0].after?.owner == "Dana")
    }

    @Test func sendNeedsAtLeastOneItemAndEveryTickedItemNeedsATask() {
        var draft = ConfirmDraft(notes: threeItems, live: [live("L1", "Book the demo room", .running)])
        #expect(draft.canSend)
        draft.rows[0].task = "   "
        #expect(!draft.canSend)
        draft.rows[0].chosen = false
        #expect(!draft.canSend)
        #expect(draft.problem == nil)
        draft.rows[1].chosen = true
        #expect(draft.canSend)
        draft.rows[0].chosen = true
        #expect(draft.problem == ConfirmDraft.needsTask)
    }

    @Test func lessonsFollowTheBaselineAndEdits() {
        var draft = ConfirmDraft(notes: threeItems, live: [live("L1", "Book the demo room", .sent)])
        draft.rows[0].chosen = false
        draft.rows[1].chosen = true
        draft.rows[1].owner = "Dana"
        draft.rows[2].chosen = true  // locked: ignored
        let lessons = draft.lessons(style: .salesCall, title: "Acme", date: at1530)
        #expect(lessons.map(\.kind) == [.notSent, .sentAnyway, .edited])
        #expect(lessons[0].before?.task == "Draft the pilot scope email")
        #expect(lessons[2].before?.owner == "Stephen")
        #expect(lessons[2].after?.owner == "Dana")
        #expect(lessons.allSatisfy { $0.style == .salesCall && $0.meetingTitle == "Acme" && $0.date == at1530 })
    }

    @Test func noChangesGiveNoLessons() {
        let draft = ConfirmDraft(notes: threeItems, live: [])
        #expect(draft.lessons(style: .general, title: "Acme", date: at1530).isEmpty)
    }

    @Test func onlyShowsTheChosenNotesItemsAndKeepsTheirNotesNumbers() {
        let draft = ConfirmDraft(notes: threeItems, live: [], only: [2, 0, 7])
        #expect(draft.rows.map(\.notesIndex) == [0, 2])
        #expect(draft.chosenItems.map(\.source) == ["n1", "n3"])
    }

    @Test func theDefaultItemsAreWhatSendWithoutAskingSends() {
        let items = ConfirmDraft.defaultItems(notes: threeItems, live: [live("L1", "Book the demo room", .interrupted)])
        #expect(items.map(\.source) == ["n1"])
    }

    @Test func similarWordingLinksARowWhenTheModelGaveNoLiveRef() {
        let notes = MeetingNotes(title: "A", summary: "s", actionItems: [item("Send Dana the pilot scope email")])
        let draft = ConfirmDraft(notes: notes, live: [live("L4", "Send Dana the pilot scope email", .startedInCloud)])
        #expect(draft.rows[0].startedDuringCall)
        #expect(draft.chosenItems.isEmpty)
    }
}
