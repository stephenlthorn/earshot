import Foundation

/// Which notes item each sent or confirmed item is (spec 6 and 14.4). items.json records it as `source` "n<k>", the
/// 1-based position in notes.json, so it is worked out again whenever the notes change.
extension Pipeline {
    /// Each item without a `source` gets the notes item it is. Items the app already tagged keep theirs.
    static func withSources(_ items: [ActionItem], notes: MeetingNotes) -> [ActionItem] {
        let count = notes.actionItems.count
        let claimed = Set(items.compactMap { notesIndex($0.source, count: count) })
        let matches = assign(items.map { $0.source == nil ? $0.task : nil }, to: notes.actionItems, claimed: claimed)
        return zip(items, matches).map { item, match in
            guard let match else { return item }
            var tagged = item
            tagged.source = ItemStatus.source(forNotesIndex: match)
            return tagged
        }
    }

    /// items.json after the notes changed from `old` to `new`: each entry that names a notes item (or names none)
    /// is matched again by the task it stood for, and loses its `source` when nothing in `new` matches, so
    /// `ItemStatus` falls back to the task. Entries with any other source are kept as they are.
    static func retagged(_ entries: [ActionItem], old: MeetingNotes?, new: MeetingNotes) -> [ActionItem] {
        let oldItems = old?.actionItems ?? []
        let keys: [String?] = entries.map { entry in
            guard entry.source == nil || isNotesSource(entry.source) else { return nil }
            return notesIndex(entry.source, count: oldItems.count).map { oldItems[$0].task } ?? entry.task
        }
        let matches = assign(keys, to: new.actionItems, claimed: [])
        return entries.indices.map { index in
            guard keys[index] != nil else { return entries[index] }
            var entry = entries[index]
            entry.source = matches[index].map(ItemStatus.source(forNotesIndex:))
            return entry
        }
    }

    /// For each task (nil to skip), the notes item it is, each notes item used at most once and never one in
    /// `claimed`. Every exact task match is made first, so an edited item can't take the place of an unchanged
    /// one; then the most similar pairs at or above `ItemStatus.similarityThreshold`, best first.
    static func assign(_ tasks: [String?], to notesItems: [ActionItem], claimed: Set<Int>) -> [Int?] {
        var used = claimed
        var result = [Int?](repeating: nil, count: tasks.count)
        for (index, task) in tasks.enumerated() {
            guard let task, let exact = notesItems.indices.first(where: { !used.contains($0) && notesItems[$0].task == task })
            else { continue }
            result[index] = exact
            used.insert(exact)
        }
        let pairs = tasks.indices.flatMap { index -> [(item: Int, notes: Int, score: Double)] in
            guard result[index] == nil, let task = tasks[index] else { return [] }
            return notesItems.indices.filter { !used.contains($0) }
                .map { (index, $0, TranscriptMerger.similarity(notesItems[$0].task, task)) }
                .filter { $0.score >= ItemStatus.similarityThreshold }
        }
        let best = pairs.sorted { ($1.score, $0.item, $0.notes) < ($0.score, $1.item, $1.notes) }
        for pair in best where result[pair.item] == nil && !used.contains(pair.notes) {
            result[pair.item] = pair.notes
            used.insert(pair.notes)
        }
        return result
    }

    /// The index of notes item "n<k>", or nil for any other source.
    static func notesIndex(_ source: String?, count: Int) -> Int? {
        guard let source, isNotesSource(source), let number = Int(source.dropFirst()), number >= 1, number <= count
        else { return nil }
        return number - 1
    }

    /// True for "n<k>", whether or not the notes have a k-th item.
    static func isNotesSource(_ source: String?) -> Bool {
        guard let source, source.hasPrefix("n") else { return false }
        return Int(source.dropFirst()) != nil
    }
}
