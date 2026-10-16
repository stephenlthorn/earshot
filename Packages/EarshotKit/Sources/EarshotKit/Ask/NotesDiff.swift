import Foundation

/// What a Fix changed (spec 8): action items added, removed and changed, and whether the title, the summary or any
/// other section changed. The code-side `source` field and the order of items are ignored.
public struct NotesDiff: Equatable, Sendable {
    public struct Change: Equatable, Sendable {
        public var before: ActionItem
        public var after: ActionItem
    }

    /// Task similarity at or above this pairs a reworded item with the old one, so it counts as changed.
    public static let similarityThreshold = 0.5

    public var added: [ActionItem]
    public var removed: [ActionItem]
    public var changed: [Change]
    public var titleChanged: Bool
    public var summaryChanged: Bool
    /// Section names, in page order, of the other parts that changed: "Attendees", "Still open from before",
    /// "Decisions", "Flagged moments", "Key points", "Open questions".
    public var otherChanges: [String]

    public var isEmpty: Bool {
        added.isEmpty && removed.isEmpty && changed.isEmpty && !titleChanged && !summaryChanged && otherChanges.isEmpty
    }

    public static func compare(_ old: MeetingNotes, _ new: MeetingNotes) -> NotesDiff {
        let items = pairItems(old.actionItems, new.actionItems)
        let sections: [(String, Bool)] = [
            ("Attendees", old.attendees != new.attendees),
            ("Still open from before", old.stillOpen != new.stillOpen),
            ("Decisions", old.decisions != new.decisions),
            ("Flagged moments", old.flaggedMoments != new.flaggedMoments),
            ("Key points", old.keyPoints != new.keyPoints),
            ("Open questions", old.openQuestions != new.openQuestions),
        ]
        return NotesDiff(added: items.added, removed: items.removed, changed: items.changed,
                         titleChanged: old.title != new.title, summaryChanged: old.summary != new.summary,
                         otherChanges: sections.filter(\.1).map(\.0))
    }

    /// One plain line for the Fix window: "2 items added, 1 removed, 1 changed. The title changed."
    public var text: String {
        var sentences: [String] = []
        let counts = [(added.count, "added"), (removed.count, "removed"), (changed.count, "changed")].filter { $0.0 > 0 }
        if let first = counts.first {
            let lead = "\(first.0) \(first.0 == 1 ? "item" : "items") \(first.1)"
            sentences.append(([lead] + counts.dropFirst().map { "\($0.0) \($0.1)" }).joined(separator: ", ") + ".")
        }
        if titleChanged { sentences.append("The title changed.") }
        if summaryChanged { sentences.append("The summary changed.") }
        if !otherChanges.isEmpty {
            sentences.append("Also changed: " + otherChanges.map { $0.lowercased() }.joined(separator: ", ") + ".")
        }
        return sentences.isEmpty ? "Nothing changed." : sentences.joined(separator: " ")
    }

    // MARK: Pairing

    /// Pairs old and new items: identical items first, then the same live_ref, then the same task, then the most
    /// similar task. Paired items that differ are changed; the rest are removed or added.
    static func pairItems(_ old: [ActionItem], _ new: [ActionItem])
        -> (added: [ActionItem], removed: [ActionItem], changed: [Change]) {
        let old = old.map(stripped), new = new.map(stripped)
        var leftOld = Array(old.indices), leftNew = Array(new.indices)
        var pairs: [(Int, Int)] = []
        func pair(_ matches: (ActionItem, ActionItem) -> Bool) {
            for o in leftOld {
                guard let n = leftNew.first(where: { matches(old[o], new[$0]) }) else { continue }
                pairs.append((o, n))
                leftOld.removeAll { $0 == o }
                leftNew.removeAll { $0 == n }
            }
        }
        pair(==)
        pair { $0.liveRef != nil && $0.liveRef == $1.liveRef }
        pair { normalized($0.task) == normalized($1.task) }
        pairBySimilarity(old, new, &leftOld, &leftNew, &pairs)
        let changed = pairs.sorted { $0.1 < $1.1 }.filter { old[$0.0] != new[$0.1] }
            .map { Change(before: old[$0.0], after: new[$0.1]) }
        return (leftNew.map { new[$0] }, leftOld.map { old[$0] }, changed)
    }

    /// Repeatedly pairs the most similar remaining old and new tasks at or above the threshold.
    static func pairBySimilarity(_ old: [ActionItem], _ new: [ActionItem], _ leftOld: inout [Int],
                                 _ leftNew: inout [Int], _ pairs: inout [(Int, Int)]) {
        while true {
            var best: (Int, Int, Double)?
            for o in leftOld {
                for n in leftNew {
                    let score = TranscriptMerger.similarity(old[o].task, new[n].task)
                    if score >= similarityThreshold, score > (best?.2 ?? -1) { best = (o, n, score) }
                }
            }
            guard let (o, n, _) = best else { return }
            pairs.append((o, n))
            leftOld.removeAll { $0 == o }
            leftNew.removeAll { $0 == n }
        }
    }

    static func stripped(_ item: ActionItem) -> ActionItem {
        var item = item
        item.source = nil
        return item
    }

    static func normalized(_ text: String) -> String {
        text.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}
