import Foundation

/// What Start sends, and which notes items were already started during the call (spec 4.4).
public enum LiveDispatch {
    /// The receiver cuts `context` to this many characters; the payload never needs it to.
    public static let maxContext = 1000
    static let titleSuffix = " (live)"

    /// A DoPayload v1 for one live to-do, built from `item`, the row exactly as drawn. It carries no transcript text:
    /// the summary is "Started during the call. Why: <why>", the one item is for the AI with `why` as its context,
    /// and `transcript_path` points at live.json.
    /// - Parameters:
    ///   - event: the calendar event, for the attendee names (never addresses) and the title of an untitled meeting.
    ///   - time: the click, which becomes `ended_at`.
    public static func payload(for item: LiveItem, session: Session, folder: URL, event: CalendarEventInfo?,
                               at time: Date = Date()) -> DoPayload {
        let meetingTitle = CurrentEvent.meetingTitle(typed: session.title, event: event)?
            .fittedForReceiver(to: 1_000).nonBlank ?? "Meeting"
        let title = meetingTitle.fittedForReceiver(to: DoPayload.maxTitle - titleSuffix.count) + titleSuffix
        let summary = "Started during the call. Why: \(item.why)".fittedForReceiver(to: DoPayload.maxSummary)
        var live = session
        live.id = "\(session.id)-live-\(number(of: item))"
        live.title = title
        live.endedAt = max(time, session.startedAt)
        let notes = MeetingNotes(title: title, summary: summary,
                                 attendees: (event?.attendees ?? []).map(\.displayName).filter { !$0.isEmpty })
        let action = ActionItem(task: item.task, owner: item.owner, due: item.due, doer: .ai,
                                context: item.why.fitted(to: maxContext), source: item.id)
        return DoPayload(session: live, folder: folder, notes: notes, notesMarkdown: summary,
                         transcriptPath: folder.appending(path: MeetingFile.live).path, items: [action])
    }

    /// The indexes of `notesItems` that are the same work as a live to-do that went out, or may have (sending,
    /// running, done, sent, started in the cloud or interrupted). The notes model's `live_ref` decides; word
    /// similarity of 0.6 or more is used only when `live_ref` is null (`ItemStatus.linkedLiveItem`).
    public static func linked(_ notesItems: [ActionItem], live: [LiveItem]) -> Set<Int> {
        let started = live.filter(\.status.isStarted)
        return Set(notesItems.indices.filter { ItemStatus.linkedLiveItem(notesItems[$0], live: started) != nil })
    }

    /// The longest suffix the payload id takes from an item id.
    static let maxIdSuffix = 16

    /// 3 for "L3". An id that isn't letters then ASCII digits keeps only its ASCII letters and digits, and either way
    /// at most `maxIdSuffix` of them, so the payload id stays valid for the receiver.
    static func number(of item: LiveItem) -> String {
        let isDigit: (Character) -> Bool = { $0.isASCII && $0.isNumber }
        let digits = item.id.drop { !isDigit($0) }
        if !digits.isEmpty, digits.allSatisfy(isDigit) { return String(digits.prefix(maxIdSuffix)) }
        let safe = item.id.filter { $0.isASCII && ($0.isLetter || $0.isNumber) }
        return safe.isEmpty ? "0" : String(safe.prefix(maxIdSuffix))
    }
}
