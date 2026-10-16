import Foundation

/// How a live pass's answer changes the to-do list (spec 4.3).
public enum LiveMerge {
    /// At most this many live to-dos in one meeting.
    public static let cap = 40

    /// `proposals` applied to `items`, in order:
    /// - a `ref` that names a known item updates it;
    /// - an empty (or unknown) `ref` whose task is at least 0.6 similar to a known task updates that one;
    /// - anything else is a new item with the next `L` number, while there are fewer than `cap`.
    ///
    /// An update never touches a frozen item: one in `frozen` (the pointer is over its row), or one that is no longer
    /// `suggested` (Start was pressed, or it was dismissed). Dismissed items stay dismissed. Blank tasks are ignored.
    /// - Parameters:
    ///   - time: seconds on the meeting clock, for `firstSeen` and `updated`.
    ///   - issued: the highest `L` number given out so far, even to an item `items` no longer holds. New numbers are
    ///     always above it, so a number is never reused.
    public static func merge(_ proposals: [LivePrompt.Proposal], into items: [LiveItem], at time: Double,
                             frozen: Set<String>, cap: Int = Self.cap, issued: Int = 0) -> [LiveItem] {
        proposals.reduce(items) { merged, proposal in
            apply(proposal, to: merged, at: time, frozen: frozen, cap: cap, issued: issued)
        }
    }

    static func apply(_ proposal: LivePrompt.Proposal, to items: [LiveItem], at time: Double, frozen: Set<String>,
                      cap: Int, issued: Int) -> [LiveItem] {
        let task = proposal.task.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !task.isEmpty else { return items }
        let owner = proposal.owner.trimmingCharacters(in: .whitespacesAndNewlines)
        let ref = proposal.ref.trimmingCharacters(in: .whitespacesAndNewlines)
        if let index = match(ref: ref, task: task, in: items) {
            let known = items[index]
            guard known.status == .suggested, !frozen.contains(known.id) else { return items }
            var updated = known
            updated.task = task
            updated.owner = owner.isEmpty ? "Unassigned" : owner
            updated.due = proposal.due
            updated.aiDoable = proposal.aiDoable
            updated.why = proposal.why
            updated.updated = time
            var out = items
            out[index] = updated
            return out
        }
        guard items.count < cap else { return items }
        let item = LiveItem(id: "L\(max(highestNumber(items), issued) + 1)", task: task, owner: owner.isEmpty ? "Unassigned" : owner,
                            due: proposal.due, aiDoable: proposal.aiDoable, why: proposal.why, firstSeen: time)
        return items + [item]
    }

    /// The known item a proposal is about: its `ref` when that names one, otherwise the most similar task at or
    /// above the threshold.
    static func match(ref: String, task: String, in items: [LiveItem]) -> Int? {
        if !ref.isEmpty, let index = items.firstIndex(where: { $0.id == ref }) { return index }
        let scored = items.indices.map { ($0, TranscriptMerger.similarity(items[$0].task, task)) }
            .filter { $0.1 >= ItemStatus.similarityThreshold }
        return scored.max { $0.1 < $1.1 }?.0
    }

    /// The highest "L<n>" in `items`, or 0.
    public static func highestNumber(_ items: [LiveItem]) -> Int {
        items.compactMap { $0.id.hasPrefix("L") ? Int($0.id.dropFirst()) : nil }.max() ?? 0
    }
}
