import EventKit
import Foundation

/// Calendar events through EventKit (spec 5.1). EventKit's types are not Sendable, so they never leave this actor:
/// each event is copied into a `Snapshot` value and every decision (skip, attendees, id) is made by the pure
/// `info(_:)`, which the tests cover. Needs `NSCalendarsFullAccessUsageDescription` and the
/// `com.apple.security.personal-information.calendars` entitlement in the App.
public actor EventKitCalendarSource: CalendarSource {
    /// Made on first use, so reading the authorization never touches the event store.
    private var store: EKEventStore?
    /// The authorization the store was made under. A store made before access was granted may never see events, so
    /// it is replaced when the authorization changes.
    private var storeAuthorization: CalendarAuthorization?
    private var accessError: String?

    public init() {}

    public func authorization() -> CalendarAuthorization {
        Self.authorization(EKEventStore.authorizationStatus(for: .event))
    }

    /// Asks for full access. When EventKit fails, the authorization is still returned and the reason is kept for
    /// `lastAccessError()`.
    public func requestAccess() async -> CalendarAuthorization {
        let store = eventStore()
        do {
            _ = try await store.requestFullAccessToEvents()
            accessError = nil
        } catch {
            accessError = error.localizedDescription
        }
        return authorization()
    }

    /// Why the last `requestAccess()` failed, or nil when it did not, so the App can log it.
    public func lastAccessError() -> String? { accessError }

    /// Reads synchronously, off the main thread (the actor's executor), as EventKit asks.
    public func events(from start: Date, to end: Date) -> [CalendarEventInfo] {
        guard authorization().canRead, end > start else { return [] }
        let store = eventStore()
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        return store.events(matching: predicate).map(Self.snapshot).compactMap(Self.info)
    }

    private func eventStore() -> EKEventStore {
        let now = authorization()
        if let store, !Self.needsNewStore(madeUnder: storeAuthorization, now: now) { return store }
        let made = EKEventStore()
        store = made
        storeAuthorization = now
        return made
    }

    /// True when the cached store was made under a different authorization than the current one.
    static func needsNewStore(madeUnder: CalendarAuthorization?, now: CalendarAuthorization) -> Bool {
        guard let madeUnder else { return false }
        return madeUnder != now
    }

    /// The address in a `mailto:` participant link, or nil for any other link.
    static func email(from url: URL) -> String? {
        guard url.scheme?.lowercased() == "mailto" else { return nil }
        let address = URLComponents(url: url, resolvingAgainstBaseURL: false)?.path ?? ""
        return address.contains("@") ? address : nil
    }

    static func authorization(_ status: EKAuthorizationStatus) -> CalendarAuthorization {
        switch status {
        case .fullAccess: .fullAccess
        case .writeOnly: .writeOnly
        case .denied: .denied
        case .restricted: .restricted
        case .notDetermined: .notDetermined
        @unknown default: .denied
        }
    }

    /// The event as a plain value: a copy only, with no decisions.
    private static func snapshot(_ event: EKEvent) -> Snapshot {
        Snapshot(itemID: event.calendarItemIdentifier, title: event.title, start: event.startDate, end: event.endDate,
                 isAllDay: event.isAllDay, status: event.status, attendees: (event.attendees ?? []).map(participant),
                 organizer: event.organizer.map(participant), notes: event.notes, location: event.location,
                 url: event.url)
    }

    private static func participant(_ p: EKParticipant) -> Snapshot.Participant {
        Snapshot.Participant(name: p.name, url: p.url, isCurrentUser: p.isCurrentUser, type: p.participantType,
                             status: p.participantStatus)
    }
}

extension EventKitCalendarSource {
    /// What EventKit says about one event, copied out of the non-Sendable `EKEvent`.
    struct Snapshot: Sendable {
        struct Participant: Sendable {
            var name: String?
            var url: URL
            var isCurrentUser: Bool
            var type: EKParticipantType
            var status: EKParticipantStatus
        }

        var itemID: String
        var title: String?
        var start: Date?
        var end: Date?
        var isAllDay: Bool
        var status: EKEventStatus
        var attendees: [Participant]
        var organizer: Participant?
        var notes: String?
        var location: String?
        var url: URL?
    }

    /// The event as Earshot sees it, or nil when it can never be the current meeting: all-day, cancelled, or
    /// declined by the user (their own attendee entry, never the organizer's or anyone else's).
    static func info(_ event: Snapshot) -> CalendarEventInfo? {
        let declined = event.attendees.first(where: \.isCurrentUser)?.status == .declined
        guard !event.isAllDay, event.status != .canceled, !declined else { return nil }
        let start = event.start ?? Date(timeIntervalSince1970: 0)
        return CalendarEventInfo(id: occurrenceID(event.itemID, start: start), title: event.title ?? "", start: start,
                                 end: event.end ?? start, attendees: attendees(event), agenda: event.notes ?? "",
                                 location: event.location, url: event.url?.absoluteString)
    }

    /// People only: rooms and other resources are not attendees, or a booked room would make every meeting
    /// External. The organizer is added when the attendee list leaves them out.
    static func attendees(_ event: Snapshot) -> [Attendee] {
        let people = event.attendees.filter { $0.type != .room && $0.type != .resource }
        var attendees = people.map(attendee)
        if !attendees.isEmpty, let organizer = event.organizer.map(attendee), let address = organizer.email?.lowercased(),
           !attendees.contains(where: { $0.email?.lowercased() == address }) {
            attendees.insert(organizer, at: 0)
        }
        return attendees
    }

    /// Unique per occurrence: a recurring event shares one `calendarItemIdentifier`, so its start is added, and the
    /// next standup counts as a different event (spec 5.3).
    static func occurrenceID(_ itemID: String, start: Date) -> String {
        "\(itemID)|\(Int(start.timeIntervalSince1970))"
    }

    private static func attendee(_ participant: Snapshot.Participant) -> Attendee {
        Attendee(name: participant.name ?? "", email: email(from: participant.url), isMe: participant.isCurrentUser)
    }
}
