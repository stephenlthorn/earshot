import Foundation

public struct Segment: Codable, Equatable, Sendable {
    public var track: Track
    public var start: Double
    public var end: Double
    public var text: String

    public init(track: Track, start: Double, end: Double, text: String) {
        self.track = track
        self.start = start
        self.end = end
        self.text = text
    }
}

public enum TranscriptMerger {
    /// Segments from one speaker closer than this many seconds become one turn.
    public static let joinGap = 1.5

    /// Shifts each track by its offset, drops mic echo of the call, sorts by time and joins close turns.
    public static func merge(_ segments: [Segment], offsets: [Track: Double] = [:]) -> [Segment] {
        let shifted = segments.map { segment in
            var segment = segment
            let offset = offsets[segment.track] ?? 0
            segment.start += offset
            segment.end += offset
            return segment
        }
        let them = shifted.filter { $0.track == .them }
        let kept = shifted.filter { segment in segment.track != .me || !them.contains { isEcho(segment, of: $0) } }
        var out: [Segment] = []
        for segment in kept.sorted(by: { ($0.start, $0.end) < ($1.start, $1.end) }) {
            if var last = out.last, last.track == segment.track, segment.start - last.end < joinGap {
                last.end = max(last.end, segment.end)
                last.text += " " + segment.text
                out[out.count - 1] = last
            } else {
                out.append(segment)
            }
        }
        return out
    }

    /// A mic segment is echo when at least half of it overlaps a call segment that says nearly the same words.
    static func isEcho(_ mine: Segment, of theirs: Segment) -> Bool {
        let overlap = max(0, min(mine.end, theirs.end) - max(mine.start, theirs.start))
        return overlap / max(mine.end - mine.start, 0.001) >= 0.5 && similarity(mine.text, theirs.text) >= 0.6
    }

    /// Jaccard similarity of the two texts' lowercased word sets.
    public static func similarity(_ a: String, _ b: String) -> Double {
        let left = words(a), right = words(b)
        let union = left.union(right)
        return union.isEmpty ? 0 : Double(left.intersection(right).count) / Double(union.count)
    }

    static func words(_ text: String) -> Set<String> {
        Set(text.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init))
    }
}

public enum TranscriptRenderer {
    public static func markdown(_ segments: [Segment], names: [Track: String]) -> String {
        segments.map { "[\(timestamp($0.start))] \(names[$0.track] ?? $0.track.defaultName): \($0.text)\n" }.joined()
    }

    public static func timestamp(_ seconds: Double) -> String {
        let total = Int(max(0, seconds).rounded(.down))
        return String(format: "%02d:%02d:%02d", total / 3600, total % 3600 / 60, total % 60)
    }
}
