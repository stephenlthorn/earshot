import Foundation

public enum NotesRenderer {
    public static func markdown(_ notes: MeetingNotes, startedAt: Date, duration: TimeInterval,
                                timeZone: TimeZone = .current, transcriptFile: String? = "transcript.md") -> String {
        var facts = ["**Date:** \(dateText(startedAt, timeZone))", "**Length:** \(lengthText(duration))"]
        if !notes.attendees.isEmpty { facts.append("**With:** \(notes.attendees.joined(separator: ", "))") }
        var out = ["# \(notes.title)", "", facts.joined(separator: " · "), "", "## Summary", "", notes.summary]
        section(&out, "Still open from before", notes.stillOpen.map { "- \($0)" })
        section(&out, "Decisions", notes.decisions.map { "- \($0)" })
        section(&out, "Action items", notes.actionItems.map(itemLine))
        section(&out, "Flagged moments", notes.flaggedMoments.sorted { $0.seconds < $1.seconds }
            .map { "- **\(clock($0.seconds))** \($0.note)" })
        section(&out, "Key points", notes.keyPoints.map { "- \($0)" })
        section(&out, "Open questions", notes.openQuestions.map { "- \($0)" })
        if let transcriptFile { out += ["", "[Full transcript](\(transcriptFile))"] }
        return out.joined(separator: "\n") + "\n"
    }

    public static func dateText(_ date: Date, _ timeZone: TimeZone) -> String {
        SessionStore.formatter("EEE d MMM yyyy, HH:mm", timeZone).string(from: date)
    }

    public static func lengthText(_ seconds: TimeInterval) -> String {
        let minutes = max(1, Int((seconds / 60).rounded()))
        return minutes < 60 ? "\(minutes) min" : "\(minutes / 60) h \(minutes % 60) min"
    }

    /// The longest time `clock` shows: 99 hours, 59 minutes and 59 seconds.
    public static let maxSeconds = 359_999

    /// Seconds as "mm:ss" ("05:07"); minutes keep counting past an hour ("75:10").
    public static func clock(_ seconds: Double) -> String {
        let whole = wholeSeconds(seconds)
        return String(format: "%02d:%02d", whole / 60, whole % 60)
    }

    /// Whole seconds, rounded down and kept between 0 and `maxSeconds`. Clamped before converting, because a
    /// model-written number such as 1e30, an infinity or NaN would crash `Int(_:)`.
    public static func wholeSeconds(_ seconds: Double) -> Int {
        guard seconds.isFinite else { return 0 }
        return Int(min(max(seconds.rounded(.down), 0), Double(maxSeconds)))
    }

    static func itemLine(_ item: ActionItem) -> String {
        "- [ ] \(item.task) (\(item.owner)\(item.due.map { ", due \($0)" } ?? ""))"
    }

    static func section(_ out: inout [String], _ title: String, _ lines: [String]) {
        guard !lines.isEmpty else { return }
        out += ["", "## \(title)", ""] + lines
    }
}
