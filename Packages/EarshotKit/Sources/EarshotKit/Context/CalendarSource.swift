import Foundation

/// What the user allowed for calendar events. Only `fullAccess` can read them.
public enum CalendarAuthorization: String, Sendable, CaseIterable {
    case notDetermined, restricted, denied, writeOnly, fullAccess

    public var canRead: Bool { self == .fullAccess }
}

/// Where calendar events come from. The App uses `EventKitCalendarSource`; tests use a fake.
public protocol CalendarSource: Sendable {
    /// The current authorization. Never shows a prompt.
    func authorization() async -> CalendarAuthorization
    /// Asks for full access to events (the system prompt shows once), then returns the authorization.
    func requestAccess() async -> CalendarAuthorization
    /// Events the user hasn't declined, other than all-day ones, overlapping `start...end`. Empty without access.
    func events(from start: Date, to end: Date) async -> [CalendarEventInfo]
}

/// Which calendar event is happening now (spec 5.1 and 5.2).
public enum CurrentEvent {
    /// An event starting this soon already counts as current.
    public static let leadTime: TimeInterval = 10 * 60
    /// Earshot only reads this far either side of now.
    public static let readWindow: TimeInterval = 12 * 3600
    /// How often the calendar is read while the menu is idle. It is also read when the panel opens and at
    /// recording start.
    public static let pollInterval: TimeInterval = 60

    /// The current event among `events`: one overlapping now, counting `leadTime` before its start. Among several,
    /// one with other attendees wins, then one with a video link, then the closest start.
    public static func pick(_ events: [CalendarEventInfo], now: Date) -> CalendarEventInfo? {
        let current = events.filter { $0.start <= now.addingTimeInterval(leadTime) && $0.end > now }
        return current.min { a, b in
            let (aPeople, bPeople) = (!a.others.isEmpty, !b.others.isEmpty)
            if aPeople != bPeople { return aPeople }
            let (aVideo, bVideo) = (VideoLinks.contains(a), VideoLinks.contains(b))
            if aVideo != bVideo { return aVideo }
            let (aGap, bGap) = (abs(a.start.timeIntervalSince(now)), abs(b.start.timeIntervalSince(now)))
            if aGap != bGap { return aGap < bGap }
            return a.start != b.start ? a.start < b.start : a.id < b.id
        }
    }

    /// Reads `readWindow` either side of `now` and picks the current event. Nil without access, and then nothing is read.
    public static func fetch(from source: any CalendarSource, now: Date) async -> CalendarEventInfo? {
        guard await source.authorization().canRead else { return nil }
        let events = await source.events(from: now.addingTimeInterval(-readWindow), to: now.addingTimeInterval(readWindow))
        return pick(events, now: now)
    }

    /// True when `event` is a different event from the one that was current before. Only then is its profile's mode
    /// preselected, so a mode the user changed is never changed back for the same event.
    public static func isNew(_ event: CalendarEventInfo?, previousID: String?) -> Bool {
        guard let event else { return false }
        return event.id != previousID
    }

    /// "Now: <title> · <profile>" for the menu. A meeting with nobody else shows the title alone.
    public static func menuLine(_ event: CalendarEventInfo, profile: MeetingProfile) -> String {
        let title = event.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let line = "Now: \(title.isEmpty ? "Untitled event" : title)"
        return profile == .noEvent ? line : "\(line) · \(ProfileRules.label(profile))"
    }

    /// The meeting title: what the user typed, or the event's cleaned title (`eventTitle`) when Title was left blank.
    /// Every consumer (the live prompt, Do payloads, routine text, session.json) reads the title through here, so
    /// an event title never reaches a model or a target raw.
    public static func meetingTitle(typed: String?, event: CalendarEventInfo?) -> String? {
        let typed = typed?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return typed.isEmpty ? event.flatMap(eventTitle) : typed
    }

    /// The event's title under the agenda rules (spec 2 and 5.2): a line with a passcode or meeting ID is dropped,
    /// links become "[link]" and addresses are reduced to their domain, since a title is third-party text and a join
    /// link in it can carry a passcode. Nil when nothing is left.
    public static func eventTitle(_ event: CalendarEventInfo) -> String? {
        let cleaned = AgendaSanitizer.clean(event.title).split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return cleaned.isEmpty ? nil : cleaned
    }
}

/// Finds a video call link (spec 5.2).
public enum VideoLinks {
    public static let hosts = ["zoom.us", "meet.google.com", "teams.microsoft.com", "teams.live.com", "webex.com",
                               "facetime.apple.com"]

    /// True when the event's URL, location or notes hold a link to a call service.
    public static func contains(_ event: CalendarEventInfo) -> Bool {
        [event.url, event.location, event.agenda].contains { contains(text: $0 ?? "") }
    }

    /// True when `text` names a call service host or one of its subdomains (us02web.zoom.us). Lookalikes such as
    /// zoom.us.example.com, notzoom.us and an address at zoom.us don't count.
    public static func contains(text: String) -> Bool {
        guard !text.isEmpty else { return false }
        return text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }

    static let pattern: String = {
        let names = hosts.map(NSRegularExpression.escapedPattern(for:)).joined(separator: "|")
        return #"(?<![A-Za-z0-9@.-])(?:[A-Za-z0-9-]+\.)*(?:"# + names + #")(?![A-Za-z0-9-]|\.[A-Za-z0-9])"#
    }()
}
