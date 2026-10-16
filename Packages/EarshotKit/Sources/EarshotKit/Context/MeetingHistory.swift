import Foundation

/// Past meetings with the same people (spec 5.4). The matching itself lives in `MeetingLibrary.related`.
public enum MeetingHistory {
    /// Up to five related meetings from the last 180 days, newest first, never `session` itself. The title is the
    /// one the user typed, else the event's (a blank typed title counts as none).
    ///
    /// Callers in the App must pass `userName: settings.userName`. On a delegated calendar the user is a plain
    /// attendee, not marked as the user, and only their name keeps their own address from linking every meeting
    /// they were in. The default of "" exists so the listed `related(to:library:now:)` form still compiles; it is
    /// right only when no user name is set.
    public static func related(to session: Session, library: MeetingLibrary, userName: String = "",
                               now: Date) -> [MeetingRecord] {
        let typed = session.title?.trimmingCharacters(in: .whitespacesAndNewlines)
        return library.related(to: session.calendarEvent, title: typed?.isEmpty == false ? typed : nil,
                               userName: userName, excluding: session.id, now: now)
    }
}
