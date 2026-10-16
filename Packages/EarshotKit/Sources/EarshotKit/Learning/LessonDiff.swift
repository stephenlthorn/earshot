import Foundation

/// What the user taught Earshot when they pressed Send in the confirm window (spec 6).
///
/// The baseline is the selection the window showed by default (AI items, minus items started during the call).
/// Each change from it is one lesson: a default item unticked is `not_sent`, a non-default item ticked is
/// `sent_anyway`, and a sent item whose task, owner or due changed is `edited`, with before and after. A non-default
/// item that was ticked and edited gives both. The caller records nothing on Skip, on close, with
/// `sendWithoutAsking`, from the CLI or in e2e runs.
public enum LessonDiff {
    /// - Parameters:
    ///   - shown: the items as the window first showed them.
    ///   - baseline: indices into `shown` that were ticked by default.
    ///   - final: the items ticked at Send, each with its index into `shown` and its text after any edits.
    /// - Returns: the lessons in the window's order. Indices outside `shown` are ignored, and for an index given
    ///   twice in `final` only the first counts.
    public static func lessons(shown: [ActionItem], baseline: Set<Int>, final: [(index: Int, item: ActionItem)],
                               style: NotesStyle, title: String, date: Date) -> [Lesson] {
        var sent: [Int: ActionItem] = [:]
        for entry in final where shown.indices.contains(entry.index) && sent[entry.index] == nil {
            sent[entry.index] = entry.item
        }
        func lesson(_ kind: Lesson.Kind, before: ActionItem?, after: ActionItem?) -> Lesson {
            Lesson(date: date, style: style, kind: kind, before: before.map(Lesson.Item.init),
                   after: after.map(Lesson.Item.init), meetingTitle: title)
        }
        return shown.indices.flatMap { index -> [Lesson] in
            let original = shown[index]
            guard let item = sent[index] else {
                return baseline.contains(index) ? [lesson(.notSent, before: original, after: nil)] : []
            }
            var found: [Lesson] = []
            if !baseline.contains(index) { found.append(lesson(.sentAnyway, before: nil, after: item)) }
            if isEdited(original, item) { found.append(lesson(.edited, before: original, after: item)) }
            return found
        }
    }

    /// The user's own words from Fix, saved as a lesson (spec 8). The text is trimmed; when nothing is left,
    /// `LessonsStore.add` drops the lesson, so a blank Fix never reaches a prompt.
    public static func instruction(_ text: String, style: NotesStyle, title: String, date: Date) -> Lesson {
        Lesson(date: date, style: style, kind: .instruction,
               instruction: text.trimmingCharacters(in: .whitespacesAndNewlines), meetingTitle: title)
    }

    /// True when task, owner or due differ, ignoring surrounding whitespace; an empty due is the same as none.
    static func isEdited(_ before: ActionItem, _ after: ActionItem) -> Bool {
        func trimmed(_ text: String?) -> String { (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }
        return trimmed(before.task) != trimmed(after.task) || trimmed(before.owner) != trimmed(after.owner)
            || trimmed(before.due) != trimmed(after.due)
    }
}
