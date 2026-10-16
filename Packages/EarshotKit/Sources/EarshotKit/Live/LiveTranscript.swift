import Foundation

/// The live transcript of a call: final segments from both tracks in time order, plus each track's volatile
/// text for the panel's ticker. Times are on the meeting clock (spec 14.1).
public actor LiveTranscript {
    private var finalSegments: [Segment] = []
    /// Final segments in the order they arrived, for `finals(after:)`.
    private var arrivals: [Segment] = []
    private var volatileSegments: [Track: Segment] = [:]
    private var characters = 0

    public init() {}

    /// A volatile result replaces its track's ticker text. A final one is kept, and clears ticker text that
    /// started before it ended. Empty text is never kept.
    public func apply(_ update: LiveUpdate) {
        var segment = update.segment
        segment.text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard update.isFinal else {
            volatileSegments[segment.track] = segment.text.isEmpty ? nil : segment
            return
        }
        if let shown = volatileSegments[segment.track], shown.start < segment.end {
            volatileSegments[segment.track] = nil
        }
        guard !segment.text.isEmpty, !finalSegments.contains(segment) else { return }
        let index = finalSegments.lastIndex { ($0.start, $0.end) <= (segment.start, segment.end) }.map { $0 + 1 } ?? 0
        finalSegments.insert(segment, at: index)
        arrivals.append(segment)
        characters += segment.text.count
    }

    /// Every final segment, in time order.
    public func finals() -> [Segment] { finalSegments }

    /// The new text for an extraction pass: every final that arrived after `cursor` (a count of finals, 0 at the
    /// start), in time order, and the cursor to pass next time. Finals arrive late and out of time order across
    /// the two tracks, so a time cutoff would skip some; arrival order never does.
    public func finals(after cursor: Int) -> (segments: [Segment], cursor: Int) {
        let from = min(max(cursor, 0), arrivals.count)
        let new = arrivals[from...].sorted { ($0.start, $0.end) < ($1.start, $1.end) }
        return (new, arrivals.count)
    }

    /// Final segments that end after `offset`, in time order. For windows of earlier context; use `finals(after:)`
    /// to find what is new since the last pass.
    public func finals(since offset: Double) -> [Segment] {
        finalSegments.filter { $0.end > offset }
    }

    /// Final segments that overlap `from..<to`.
    public func window(from start: Double, to end: Double) -> [Segment] {
        finalSegments.filter { $0.end > start && $0.start < end }
    }

    /// The track's tentative text, or "" when there is none.
    public func volatileText(_ track: Track) -> String {
        volatileSegments[track]?.text ?? ""
    }

    /// How many characters of final text have arrived so far. It only grows.
    public func finalCharacters() -> Int { characters }
}
