import Foundation

/// Picks the screen moments the notes model sees (spec 9), up to `limit` characters inside `<screen_text>`:
/// 1. moments within 60 s of a flag, nearest first;
/// 2. moments within 30 s of a transcript line that points at the screen, nearest first;
/// 3. the rest, spread evenly over the call's time.
/// Each excerpt counts `excerptOverhead` characters on top of its text, for the "At mm:ss:" line and the blank line
/// NotesPrompt puts around it, so the whole block stays within the limit.
/// The text is redacted again on the way in (screen.json is a file anyone can edit), and moments left empty are
/// dropped. The result is in time order.
public enum ScreenSelection {
    public static let limit = 8000
    public static let flagWindow = 60.0
    public static let pointerWindow = 30.0
    /// Room for "At hh:mm:ss:\n" before an excerpt and "\n\n" between two.
    public static let excerptOverhead = 16
    /// Words that point at the screen, matched case-insensitively.
    public static let pointerPhrases = ["this slide", "this number", "on screen", "you can see", "as shown", "this chart"]

    public static func excerpts(moments: [ScreenMoment], flags: [Flag], segments: [Segment],
                                limit: Int = limit) -> [Excerpt] {
        let cap = max(0, limit)
        let sorted = prepared(moments, cap: max(0, cap - excerptOverhead))
        let pointers = segments.filter(pointsAtScreen)
        let nearFlag = ranked(sorted) { moment in
            flags.map { abs(moment.offset - $0.offset) }.filter { $0 <= flagWindow }.min()
        }
        let nearPointer = ranked(sorted) { moment in
            pointers.map { distance(moment.offset, to: $0) }.filter { $0 <= pointerWindow }.min()
        }
        var remaining = cap
        var chosen: [Int] = []
        for index in uniqueIndices(nearFlag + nearPointer + spread(sorted)) where remaining > 0 {
            let size = sorted[index].text.count + excerptOverhead
            guard size <= remaining else { continue }
            chosen.append(index)
            remaining -= size
        }
        return chosen.sorted().map { Excerpt(offset: sorted[$0].offset, text: sorted[$0].text) }
    }

    /// The moments redacted, clipped to `cap` characters each, empty ones dropped, in time order.
    static func prepared(_ moments: [ScreenMoment], cap: Int) -> [ScreenMoment] {
        moments.enumerated()
            .map { (index: $0.offset, text: String(ScreenRedaction.clean($0.element.text).prefix(cap)), moment: $0.element) }
            .filter { !$0.text.isEmpty }
            .sorted { ($0.moment.offset, $0.index) < ($1.moment.offset, $1.index) }
            .map { ScreenMoment(offset: $0.moment.offset, text: $0.text) }
    }

    static func pointsAtScreen(_ segment: Segment) -> Bool {
        let text = segment.text.lowercased()
        return pointerPhrases.contains { text.contains($0) }
    }

    /// Seconds from `offset` to the segment's span; 0 inside it.
    static func distance(_ offset: Double, to segment: Segment) -> Double {
        max(0, segment.start - offset, offset - segment.end)
    }

    /// Indices of the moments that have a distance, nearest first, ties in time order.
    static func ranked(_ moments: [ScreenMoment], distance: (ScreenMoment) -> Double?) -> [Int] {
        moments.indices.compactMap { index in distance(moments[index]).map { (index, $0) } }
            .sorted { ($0.1, $0.0) < ($1.1, $1.0) }
            .map(\.0)
    }

    /// Indices of `moments` (in time order) ordered so that every prefix is spread evenly over the call's time: the
    /// moment nearest the middle of the call, then those nearest the middles of each half, and so on. Moments bunch up
    /// where slides change fast, so spreading by time, not by count, keeps the quiet stretches in view.
    static func spread(_ moments: [ScreenMoment]) -> [Int] {
        guard let first = moments.first?.offset, let last = moments.last?.offset else { return [] }
        var order: [Int] = []
        var used = Set<Int>()
        var spans = [(low: first, high: last)]
        while order.count < moments.count {
            var next: [(low: Double, high: Double)] = []
            for span in spans where order.count < moments.count {
                let middle = (span.low + span.high) / 2
                if let index = nearestUnused(to: middle, in: moments, used: used) {
                    order.append(index)
                    used.insert(index)
                }
                next += [(span.low, middle), (middle, span.high)]
            }
            spans = next
        }
        return order
    }

    /// The unused moment nearest `time`, the earlier one on a tie.
    static func nearestUnused(to time: Double, in moments: [ScreenMoment], used: Set<Int>) -> Int? {
        moments.indices.filter { !used.contains($0) }
            .min { (abs(moments[$0].offset - time), $0) < (abs(moments[$1].offset - time), $1) }
    }

    static func uniqueIndices(_ indices: [Int]) -> [Int] {
        var seen = Set<Int>()
        return indices.filter { seen.insert($0).inserted }
    }
}
