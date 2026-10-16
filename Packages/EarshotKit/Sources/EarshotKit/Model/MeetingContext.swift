import Foundation

/// One person on a calendar event. The full address stays on this Mac: prompts, the index and MCP results only ever
/// use the name and `domain`.
public struct Attendee: Codable, Equatable, Hashable, Sendable {
    public var name: String
    public var email: String?
    /// The event's own attendee for the user (EventKit's `isCurrentUser`).
    public var isMe: Bool

    public init(name: String, email: String? = nil, isMe: Bool = false) {
        self.name = name
        self.email = email
        self.isMe = isMe
    }

    /// The lowercased part after "@", or nil without a usable address.
    public var domain: String? {
        guard let email, let at = email.lastIndex(of: "@") else { return nil }
        let domain = email[email.index(after: at)...].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return domain.isEmpty ? nil : domain
    }

    /// The name to show or store anywhere outside session.json: the name, or the domain when the name is empty or
    /// is itself an address (EventKit often gives "bob@acme.com" as the name). Never a full address (spec 2).
    public var displayName: String {
        Self.safeName(name, domain: domain)
    }

    /// `name`, or a domain in its place when it is empty or holds an address: `domain` if given, else the part of
    /// `name` after its last "@".
    public static func safeName(_ name: String, domain: String? = nil) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty || trimmed.contains("@") else { return name }
        if let domain, !domain.isEmpty { return domain }
        return Attendee(name: "", email: trimmed).domain ?? ""
    }

    enum CodingKeys: String, CodingKey { case name, email, isMe }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = c.lenient(String.self, .name) ?? ""
        email = c.lenient(String.self, .email)
        isMe = c.lenient(Bool.self, .isMe) ?? false
    }
}

/// The calendar event a meeting was recorded during, as stored in session.json (spec 5.2).
public struct CalendarEventInfo: Codable, Equatable, Sendable {
    public static let maxAttendees = 50
    public static let maxAgenda = 1500

    /// EventKit's event identifier.
    public var id: String
    public var title: String
    public var start: Date
    public var end: Date
    public var attendees: [Attendee]
    /// The event notes, clipped. Cleaned (links and dial-in lines removed) only when it is put in a prompt.
    public var agenda: String
    public var location: String?
    public var url: String?

    /// Clips the attendees to 50 and the agenda to 1500 characters.
    public init(id: String, title: String, start: Date, end: Date, attendees: [Attendee] = [], agenda: String = "",
                location: String? = nil, url: String? = nil) {
        self.id = id
        self.title = title
        self.start = start
        self.end = end
        self.attendees = Array(attendees.prefix(Self.maxAttendees))
        self.agenda = String(agenda.prefix(Self.maxAgenda))
        self.location = location
        self.url = url
    }

    /// Everyone but the user.
    public var others: [Attendee] { attendees.filter { !$0.isMe } }

    enum CodingKeys: String, CodingKey { case id, title, start, end, attendees, agenda, location, url }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let start = c.lenient(Date.self, .start) ?? Date(timeIntervalSince1970: 0)
        self.init(id: c.lenient(String.self, .id) ?? "", title: c.lenient(String.self, .title) ?? "",
                  start: start, end: c.lenient(Date.self, .end) ?? start,
                  attendees: c.lossy(Attendee.self, .attendees), agenda: c.lenient(String.self, .agenda) ?? "",
                  location: c.lenient(String.self, .location), url: c.lenient(String.self, .url))
    }
}

/// Who a meeting is with (spec 5.3). An unknown value in a file decodes to nil.
public enum MeetingProfile: String, Codable, CaseIterable, Sendable {
    case external
    case `internal`
    case noEvent = "none"
}

/// How a flag was made (spec 8).
public enum FlagSource: String, Codable, CaseIterable, Sendable, FallbackDecodable {
    case hotkey, panel, voice
    public static let fallback = FlagSource.panel
}

/// A moment the user flagged. `offset` is seconds on the meeting clock (spec 14.1).
public struct Flag: Codable, Equatable, Sendable {
    public static let maxCount = 100

    public var offset: Double
    public var source: FlagSource

    public init(offset: Double, source: FlagSource) {
        self.offset = offset
        self.source = source
    }
}

/// What started a recording. Older files without it decode to `manual`, or `importFile` for an import.
public enum StartTrigger: String, Codable, CaseIterable, Sendable {
    case manual, auto
    case importFile = "import"
    case cli
}

/// A note the notes model wrote for one flagged moment.
public struct FlaggedMoment: Codable, Equatable, Hashable, Sendable {
    public var seconds: Double
    public var note: String

    public init(seconds: Double, note: String) {
        self.seconds = seconds
        self.note = note
    }

    enum CodingKeys: String, CodingKey { case seconds, note }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        seconds = c.lenient(Double.self, .seconds) ?? 0
        note = c.lenient(String.self, .note) ?? ""
    }
}
