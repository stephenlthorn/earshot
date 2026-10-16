import CryptoKit
import Foundation

/// A person on a past meeting, as the library keeps them: a name and a company domain, never a full address.
public struct RecordAttendee: Codable, Equatable, Hashable, Sendable {
    public var name: String
    public var domain: String?

    /// A name that is an address is stored as its domain.
    public init(name: String, domain: String? = nil) {
        self.name = Attendee.safeName(name, domain: domain)
        self.domain = domain
    }
}

/// One transcript line with its speaker's name. `start` is seconds on the meeting clock.
public struct TranscriptLine: Codable, Equatable, Hashable, Sendable {
    public var start: Double
    public var speaker: String
    public var text: String

    public init(start: Double, speaker: String, text: String) {
        self.start = start
        self.speaker = speaker
        self.text = text
    }

    /// Speaker names: `names` first, then the user's name for Me, then the track's default name.
    public static func lines(_ segments: [Segment], names: [Track: String], userName: String = "") -> [TranscriptLine] {
        segments.map { TranscriptLine(start: $0.start, speaker: speaker($0.track, names: names, userName: userName),
                                      text: $0.text) }
    }

    public static func speaker(_ track: Track, names: [Track: String], userName: String = "") -> String {
        if let name = names[track], !name.isEmpty { return name }
        return track == .me && !userName.isEmpty ? userName : track.defaultName
    }
}

/// What the library knows about one meeting: the session facts, the notes and what happened to each item. Built
/// from a meeting folder, stored in the index, and returned by `MeetingLibrary`.
public struct MeetingRecord: Codable, Equatable, Sendable, Identifiable {
    /// A notes action item with its status from `ItemStatus.compute`.
    public struct Item: Equatable, Sendable {
        public var item: ActionItem
        public var status: String
    }

    public var id: String
    /// Absolute path of the meeting folder.
    public var folder: String
    public var title: String
    /// The title the user typed, when there was one (v1 meetings use it to find related meetings).
    public var typedTitle: String?
    public var startedAt: Date
    public var duration: TimeInterval
    public var mode: Mode
    public var profile: MeetingProfile?
    public var startedBy: StartTrigger
    public var finished: Bool
    /// The calendar event id; nil for v1 meetings and meetings without an event.
    public var eventID: String?
    /// Everyone but the user, from the event and the notes.
    public var attendees: [RecordAttendee]
    /// `emailKey` of each attendee address that isn't the user's, so meetings can be matched by person without
    /// keeping the address. Internal on purpose: it lives only in the local index file (`IndexEntry` writes it) and
    /// is left out of this type's own JSON, so it must never be serialized to the CLI, the MCP server or Claude.
    var attendeeKeys: [String]
    public var notes: MeetingNotes?
    /// One per notes action item.
    public var statuses: [String]
    public var flags: [Flag]
    public var live: [LiveItem]
    public var brief: MeetingBrief?
    public var sent: [String]
    public var routineRuns: [String: String]
    public var hasTranscript: Bool

    public init(session: Session, folder: URL, notes: MeetingNotes? = nil, items: [ActionItem]? = nil,
                live: [LiveItem] = [], brief: MeetingBrief? = nil, hasTranscript: Bool = false) {
        id = session.id
        self.folder = folder.path
        title = [session.title, notes?.title].compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty } ?? "Meeting"
        typedTitle = session.title.flatMap { $0 == notes?.title || $0.isEmpty ? nil : $0 }
        startedAt = session.startedAt
        duration = session.duration
        mode = session.mode
        profile = session.profile
        startedBy = session.startedBy
        finished = session.isFinished
        eventID = session.calendarEvent?.id
        attendees = Self.attendees(event: session.calendarEvent, notes: notes)
        attendeeKeys = (session.calendarEvent?.others ?? []).compactMap(\.email).map(Self.emailKey)
        // The index keeps names, never addresses (spec 11.1), even when the notes listed someone by address.
        self.notes = notes.map { notes in
            var clean = notes
            clean.attendees = notes.attendees.filter { !$0.contains("@") }
            return clean
        }
        statuses = notes.map { notes in
            ItemStatus.compute(notes: notes, items: items, sent: session.sent, live: live,
                               cloudRuns: ItemStatus.cloudRuns(notes: notes, items: items, session: session))
        } ?? []
        flags = session.flags
        self.live = live
        self.brief = brief
        sent = session.sent
        routineRuns = session.routineRuns
        self.hasTranscript = hasTranscript
    }

    /// Every key but `attendeeKeys`, which `IndexEntry` writes next to them.
    enum CodingKeys: String, CodingKey {
        case id, folder, title, typedTitle, startedAt, duration, mode, profile, startedBy, finished, eventID, attendees
        case notes, statuses, flags, live, brief, sent, routineRuns, hasTranscript
    }

    /// Only `id`, `folder`, `startedAt` and `mode` are required. Anything else that is missing, of the wrong shape
    /// or an enum case this version doesn't know gets a default, so an entry written by another version of Earshot
    /// still loads.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        folder = try c.decode(String.self, forKey: .folder)
        startedAt = try c.decode(Date.self, forKey: .startedAt)
        mode = try c.decode(Mode.self, forKey: .mode)
        title = c.lenient(String.self, .title).flatMap { $0.isEmpty ? nil : $0 } ?? "Meeting"
        typedTitle = c.lenient(String.self, .typedTitle)
        duration = c.lenient(Double.self, .duration) ?? 0
        profile = c.lenientCase(MeetingProfile.self, .profile)
        startedBy = c.lenientCase(StartTrigger.self, .startedBy) ?? .manual
        finished = c.lenient(Bool.self, .finished) ?? false
        eventID = c.lenient(String.self, .eventID)
        attendees = c.lossy(RecordAttendee.self, .attendees)
        attendeeKeys = []
        notes = c.lenient(MeetingNotes.self, .notes)
        statuses = c.lossy(String.self, .statuses)
        flags = c.lossy(Flag.self, .flags)
        live = c.lossy(LiveItem.self, .live)
        brief = c.lenient(MeetingBrief.self, .brief)
        sent = c.lossy(String.self, .sent)
        routineRuns = c.lenient([String: String].self, .routineRuns) ?? [:]
        hasTranscript = c.lenient(Bool.self, .hasTranscript) ?? false
    }

    /// Reads the meeting's files. A file that is missing or can't be read is left out.
    public static func load(_ session: Session, from store: SessionStore) -> MeetingRecord {
        let notes = try? store.readIfPresent(MeetingNotes.self, session, MeetingFile.notes)
        let items = try? store.readIfPresent([ActionItem].self, session, MeetingFile.items)
        let live = try? store.readIfPresent(LiveFile.self, session, MeetingFile.live)
        let brief = try? store.readIfPresent(MeetingBrief.self, session, MeetingFile.brief)
        let hasTranscript = FileManager.default.fileExists(atPath: store.file(session, MeetingFile.transcript).path)
        return MeetingRecord(session: session, folder: store.folder(session), notes: notes, items: items,
                             live: live?.items ?? [], brief: brief, hasTranscript: hasTranscript)
    }

    public var summary: String { notes?.summary ?? "" }
    public var decisions: [String] { notes?.decisions ?? [] }

    /// The notes action items with their statuses.
    public var items: [Item] {
        (notes?.actionItems ?? []).enumerated().map { index, item in
            Item(item: item, status: index < statuses.count ? statuses[index] : ItemStatus.notSentYet)
        }
    }

    /// A stable, one-way key for an email address: SHA-256 of the trimmed, lowercased address, in hex.
    public static func emailKey(_ email: String) -> String {
        let normal = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return SHA256.hash(data: Data(normal.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// Event attendees other than the user (by `displayName`, with their domains), then names from the notes not
    /// already listed. A notes name that is an address is left out.
    static func attendees(event: CalendarEventInfo?, notes: MeetingNotes?) -> [RecordAttendee] {
        var out = (event?.others ?? []).map { RecordAttendee(name: $0.displayName, domain: $0.domain) }
        let me = event?.attendees.filter(\.isMe).map { MeetingLibrary.normalizedName($0.name) } ?? []
        for name in notes?.attendees ?? [] {
            let key = MeetingLibrary.normalizedName(name)
            guard !key.isEmpty, !me.contains(key), !name.contains("@"),
                  !out.contains(where: { MeetingLibrary.normalizedName($0.name) == key }) else { continue }
            out.append(RecordAttendee(name: name))
        }
        return out
    }
}
