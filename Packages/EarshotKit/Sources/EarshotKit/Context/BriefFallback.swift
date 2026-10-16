import Foundation

/// Open loops without a Claude call (spec 5.5): the notes stage uses these when brief.json is missing, so a
/// resumed notes stage always sees the same input.
public enum BriefFallback {
    /// Each action item from `history`, in order, as a loop from "<meeting title>, <day> <month>". Text is one line,
    /// with addresses reduced to their domain.
    public static func openLoops(from history: [MeetingRecord], timeZone: TimeZone = .current) -> [OpenLoop] {
        history.flatMap { record in
            let from = source(record, timeZone: timeZone)
            return (record.notes?.actionItems ?? []).compactMap { item -> OpenLoop? in
                let task = oneLine(item.task)
                guard !task.isEmpty else { return nil }
                return OpenLoop(owner: oneLine(item.owner), task: task, from: from)
            }
        }
    }

    /// "Acme kickoff, 5 Oct".
    public static func source(_ record: MeetingRecord, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "d MMM"
        return "\(oneLine(record.title)), \(formatter.string(from: record.startedAt))"
    }

    static func oneLine(_ text: String) -> String {
        AgendaSanitizer.scrubAddresses(text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: " "))
    }
}
