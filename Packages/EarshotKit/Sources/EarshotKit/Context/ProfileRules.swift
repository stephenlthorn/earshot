import Foundation

/// Who a meeting is with, and what that means for the mode and the notes style (spec 5.3).
public enum ProfileRules {
    /// Domains anyone can have an address at; they never count as the user's company.
    public static let personalDomains: Set<String> = [
        "gmail.com", "googlemail.com", "icloud.com", "me.com", "mac.com", "outlook.com", "hotmail.com", "live.com",
        "yahoo.com", "aol.com", "proton.me", "protonmail.com", "fastmail.com",
    ]

    /// The domain of the event's `isMe` attendee plus the domains the user typed (comma, semicolon or space
    /// separated), lowercased, without personal domains.
    public static func myDomains(event: CalendarEventInfo?, typed: String) -> Set<String> {
        let mine = event?.attendees.filter(\.isMe).compactMap(\.domain) ?? []
        let words = typed.split(whereSeparator: { $0 == "," || $0 == ";" || $0.isWhitespace })
            .map { $0.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "@.")) }
        return Set((mine + words).filter { $0.contains(".") && !personalDomains.contains($0) })
    }

    public static func myDomains(event: CalendarEventInfo?, settings: EarshotSettings) -> Set<String> {
        myDomains(event: event, typed: settings.myDomains)
    }

    /// True when the attendee's address is at one of `myDomains` or a subdomain of one. An attendee without an
    /// address is outside, so an unknown person never makes a meeting look internal.
    public static func isInside(_ attendee: Attendee, myDomains: Set<String>) -> Bool {
        guard let domain = attendee.domain else { return false }
        return myDomains.contains { domain == $0 || domain.hasSuffix("." + $0) }
    }

    /// External when another attendee is outside `myDomains`, internal when all are inside, none without an event
    /// or without other attendees.
    public static func profile(event: CalendarEventInfo?, myDomains: Set<String>) -> MeetingProfile {
        guard let others = event?.others, !others.isEmpty else { return .noEvent }
        return others.allSatisfy { isInside($0, myDomains: myDomains) } ? .internal : .external
    }

    /// The External or Internal setting, or the default mode without a profile. Notes + Do needs a Do target that
    /// is switched on; without one it becomes Notes.
    public static func mode(profile: MeetingProfile, settings: EarshotSettings) -> Mode {
        let chosen = switch profile {
        case .external: settings.externalMode
        case .internal: settings.internalMode
        case .noEvent: settings.defaultMode
        }
        guard profile != .noEvent, chosen == .notesAndDo, !settings.anyTargetOn else { return chosen }
        return .notes
    }

    /// Sales call for an external meeting whose title has a sales keyword, General for other external and
    /// internal meetings, and the user's default style without a profile.
    public static func style(profile: MeetingProfile, title: String, settings: EarshotSettings) -> NotesStyle {
        style(profile: profile, title: title, salesKeywords: settings.salesKeywords, defaultStyle: settings.style)
    }

    public static func style(profile: MeetingProfile, title: String, salesKeywords keywords: String,
                             defaultStyle: NotesStyle) -> NotesStyle {
        switch profile {
        case .external:
            let words = " \(MeetingLibrary.normalizedTitle(title)) "
            let sales = salesKeywords(keywords).contains { words.contains(" \(MeetingLibrary.normalizedTitle($0)) ") }
            return sales ? .salesCall : .general
        case .internal: return .general
        case .noEvent: return defaultStyle
        }
    }

    /// The style a meeting's notes are written in, and its lessons are kept under: its profile's style, or the
    /// default without a profile ("Use my calendar" off). The live pass, the notes stage, the confirm window and Fix
    /// all use this, so they agree.
    public static func style(session: Session, salesKeywords: String, defaultStyle: NotesStyle) -> NotesStyle {
        guard let profile = session.profile else { return defaultStyle }
        let title = CurrentEvent.meetingTitle(typed: session.title, event: session.calendarEvent) ?? ""
        return style(profile: profile, title: title, salesKeywords: salesKeywords, defaultStyle: defaultStyle)
    }

    public static func style(session: Session, settings: EarshotSettings) -> NotesStyle {
        style(session: session, salesKeywords: settings.salesKeywords, defaultStyle: settings.style)
    }

    /// The comma-separated keywords, trimmed and lowercased, without empty ones.
    public static func salesKeywords(_ text: String) -> [String] {
        text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty }
    }

    /// Everyone on the event by name only (an address becomes its domain), with which side they are on.
    public static func contextAttendees(event: CalendarEventInfo?, myDomains: Set<String>) -> [ContextAttendee] {
        (event?.attendees ?? []).map { attendee in
            let side: ContextAttendee.Side = attendee.isMe ? .me
                : isInside(attendee, myDomains: myDomains) ? .internal : .external
            return ContextAttendee(attendee, side: side)
        }
    }

    /// "External" or "Internal", or "" without a profile.
    public static func label(_ profile: MeetingProfile) -> String {
        switch profile {
        case .external: "External"
        case .internal: "Internal"
        case .noEvent: ""
        }
    }
}
