import Foundation

/// The confirm window's checklist (spec 6 and 4.4): one row per notes action item, editable task, owner and due.
///
/// - Items linked to a live to-do that went out (`LiveDispatch.linked`) are shown "Started during the call",
///   unticked and locked, and are never returned.
/// - The default selection, which is also the lessons baseline, is the AI items minus those locked rows.
/// - Returned items carry `source = "n<k>"`, k being the 1-based index in the notes.
public struct ConfirmDraft: Equatable, Sendable {
    public static let startedDuringCall = ItemStatus.startedDuringCall
    public static let needsTask = "Every ticked item needs a task."

    /// Send is off past the cap a target takes in one send (`DoPayload.maxItems`).
    public static func tooMany(_ count: Int) -> String {
        "At most \(DoPayload.maxItems) items go in one send. Untick \(count - DoPayload.maxItems)."
    }
    public static let unassigned = "Unassigned"

    public struct Row: Equatable, Sendable, Identifiable {
        /// The row's place in the window, which is also its index in `shown`.
        public let id: Int
        /// The item's index in the notes, counted from 0.
        public let notesIndex: Int
        public let original: ActionItem
        public var task: String
        public var owner: String
        /// Empty means no due date.
        public var due: String
        public var chosen: Bool
        public let startedDuringCall: Bool

        /// The item as Send returns it: the edited text, trimmed, and the notes source.
        public var item: ActionItem {
            var item = original
            item.task = task.trimmingCharacters(in: .whitespacesAndNewlines)
            let owner = owner.trimmingCharacters(in: .whitespacesAndNewlines)
            item.owner = owner.isEmpty ? ConfirmDraft.unassigned : owner
            let due = due.trimmingCharacters(in: .whitespacesAndNewlines)
            item.due = due.isEmpty ? nil : due
            item.source = ItemStatus.source(forNotesIndex: notesIndex)
            return item
        }

        /// The item as the window first showed it, with a blank owner read as "Unassigned" the way Send writes it,
        /// so an untouched item never counts as an edit.
        public var shown: ActionItem {
            var item = original
            if item.owner.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { item.owner = ConfirmDraft.unassigned }
            return item
        }

        public var isEdited: Bool { LessonDiff.isEdited(shown, item) }
        /// Ticked and allowed to go out.
        public var sends: Bool { chosen && !startedDuringCall }
    }

    public var rows: [Row]
    /// The rows ticked when the window opened.
    public let baseline: Set<Int>

    /// - Parameters:
    ///   - live: live.json's to-dos; only those that went out (or may have) lock a row.
    ///   - only: notes indices to show (for sending the new items after a Fix), in notes order; nil shows all.
    public init(notes: MeetingNotes, live: [LiveItem], only: [Int]? = nil) {
        let linked = LiveDispatch.linked(notes.actionItems, live: live)
        let indices = notes.actionItems.indices.filter { only.map(Set.init)?.contains($0) ?? true }
        rows = indices.enumerated().map { position, index in
            let item = notes.actionItems[index]
            let started = linked.contains(index)
            return Row(id: position, notesIndex: index, original: item, task: item.task, owner: item.owner,
                       due: item.due ?? "", chosen: item.doer == .ai && !started, startedDuringCall: started)
        }
        baseline = Set(rows.filter(\.chosen).map(\.id))
    }

    /// What Send returns, in notes order.
    public var chosenItems: [ActionItem] { rows.filter(\.sends).map(\.item) }

    public var chosenCount: Int { rows.filter(\.sends).count }

    /// Why Send is not allowed although items are ticked, or nil.
    public var problem: String? {
        if rows.contains(where: { $0.sends && $0.item.task.isEmpty }) { return Self.needsTask }
        return chosenCount > DoPayload.maxItems ? Self.tooMany(chosenCount) : nil
    }

    public var canSend: Bool { chosenCount > 0 && problem == nil }

    /// The lessons Send records, when "Learn from my edits" is on (spec 6).
    public func lessons(style: NotesStyle, title: String, date: Date) -> [Lesson] {
        LessonDiff.lessons(shown: rows.map(\.shown), baseline: baseline,
                           final: rows.filter(\.sends).map { (index: $0.id, item: $0.item) },
                           style: style, title: title, date: date)
    }

    /// What is sent when the window is not shown (`sendWithoutAsking` where `ConfirmPolicy` allows it).
    public static func defaultItems(notes: MeetingNotes, live: [LiveItem]) -> [ActionItem] {
        ConfirmDraft(notes: notes, live: live).chosenItems
    }
}
