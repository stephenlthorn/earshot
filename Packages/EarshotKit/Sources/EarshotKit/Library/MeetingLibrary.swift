import Foundation

public enum LibraryError: Error, Equatable, LocalizedError {
    /// macOS refused to let this app read the folder (EPERM or EACCES), usually ~/Documents.
    case folderNotReadable(String)
    case notFound(String)

    public var errorDescription: String? {
        switch self {
        case .folderNotReadable: message(app: "the app you're using")
        case let .notFound(id): "No meeting matches \"\(id)\"."
        }
    }

    /// The spec 11.1 line, naming the app that needs access.
    public func message(app: String) -> String {
        switch self {
        case .folderNotReadable: "Allow \(app) to access your Documents folder, or move the Earshot folder in Settings."
        case .notFound: errorDescription ?? ""
        }
    }

    /// True for a read refused by permissions rather than a missing file.
    public static func isPermission(_ error: any Error) -> Bool {
        let ns = error as NSError
        if ns.domain == NSCocoaErrorDomain, ns.code == CocoaError.fileReadNoPermission.rawValue { return true }
        if ns.domain == NSPOSIXErrorDomain, ns.code == Int(EPERM) || ns.code == Int(EACCES) { return true }
        if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? NSError { return isPermission(underlying) }
        return false
    }
}

/// A meeting that matched a search, with the transcript lines that matched.
public struct SearchHit: Equatable, Sendable {
    public var meeting: MeetingRecord
    public var lines: [TranscriptLine]
}

/// One action item across meetings.
public struct ActionItemHit: Equatable, Sendable {
    public var meetingID: String
    public var meetingTitle: String
    public var startedAt: Date
    public var item: ActionItem
    public var status: String
}

/// Reads past meetings for the CLI, the MCP server and the brief. The index comes first; the meeting folder is read
/// only for a transcript the index lacks.
public struct MeetingLibrary: Sendable {
    public static let relatedWindow: TimeInterval = 180 * 24 * 3600
    public static let relatedLimit = 5
    /// Titles too generic to link meetings by title alone (spec 5.4), compared after `normalizedTitle`.
    public static let genericTitles: Set<String> = Set([
        "weekly sync", "standup", "stand up", "1:1", "one on one", "catch up", "check in", "intro call", "sync",
        "meeting", "call", "team meeting", "all hands",
    ].map(normalizedTitle))

    public let index: LibraryIndex
    public let store: SessionStore?

    public init(index: LibraryIndex, store: SessionStore?) {
        self.index = index
        self.store = store
    }

    /// Meetings newest first, optionally since a date and matching every word of `query` in the title, summary or
    /// attendee names.
    public func meetings(since: Date? = nil, query: String? = nil, limit: Int? = nil) -> [MeetingRecord] {
        let terms = Self.terms(query ?? "")
        let found = index.entries().map(\.record).filter { record in
            guard since.map({ record.startedAt >= $0 }) ?? true else { return false }
            let text = Self.fold(([record.title, record.summary] + record.attendees.map(\.name)).joined(separator: " "))
            return terms.allSatisfy(text.contains)
        }
        return Array(found.prefix(limit ?? found.count))
    }

    /// A meeting by id, by folder name, or "latest".
    public func meeting(id: String) -> MeetingRecord? {
        let records = index.entries().map(\.record)
        if id == "latest" { return records.first }
        return records.first { $0.id == id }
            ?? records.first { URL(filePath: $0.folder).lastPathComponent == id }
    }

    /// The transcript from the index, or from the meeting folder when the index has none. A folder macOS won't let
    /// this app read throws `LibraryError.folderNotReadable`.
    public func transcript(of meeting: MeetingRecord) throws -> [TranscriptLine] {
        let entry = index.entry(id: meeting.id)
        if let entry, !entry.transcript.isEmpty { return entry.transcript }
        let folder = store?.find(meeting.id).map { store!.folder($0) }
            ?? URL(filePath: meeting.folder, directoryHint: .isDirectory)
        do {
            let segments = try JSONFiles.readIfPresent([Segment].self, from: folder.appending(path: MeetingFile.transcript))
            var names: [Track: String] = [:]
            for (raw, name) in entry?.speakers ?? [:] { if let track = Track(rawValue: raw) { names[track] = name } }
            return TranscriptLine.lines(segments ?? [], names: names)
        } catch where LibraryError.isPermission(error) {
            throw LibraryError.folderNotReadable(folder.path)
        }
    }

    /// Meetings containing every word of `query` in their notes or transcript, best first, each with up to five
    /// matching lines.
    public func search(_ query: String, limit: Int = 10) -> [SearchHit] {
        let terms = Self.terms(query)
        guard !terms.isEmpty else { return [] }
        let scored: [(hit: SearchHit, score: Int)] = index.entries().compactMap { entry in
            let notes = Self.fold(Self.notesText(entry.record))
            let lines = entry.transcript.map { ($0, Self.fold($0.text)) }
            let all = notes + " " + lines.map(\.1).joined(separator: " ")
            guard terms.allSatisfy(all.contains) else { return nil }
            let matching = lines.map { line in (line.0, terms.filter(line.1.contains).count) }.filter { $0.1 > 0 }
            let best = matching.sorted { $0.1 > $1.1 }.prefix(5).map(\.0).sorted { $0.start < $1.start }
            let score = terms.filter(notes.contains).count * 3 + matching.reduce(0) { $0 + $1.1 }
            return (SearchHit(meeting: entry.record, lines: best), score)
        }
        let ranked = scored.sorted {
            $0.score != $1.score ? $0.score > $1.score : $0.hit.meeting.startedAt > $1.hit.meeting.startedAt
        }
        return ranked.prefix(max(0, limit)).map(\.hit)
    }

    /// Action items across meetings, newest meeting first. `owner` "me" means the user (their name, their first
    /// name, "me", or an item only they can do); any other owner matches by name.
    public func actionItems(owner: String? = nil, userName: String = "", since: Date? = nil,
                            limit: Int? = nil) -> [ActionItemHit] {
        let wanted = owner.map(Self.normalizedName)
        let hits = meetings(since: since).flatMap { record in
            record.items.compactMap { entry -> ActionItemHit? in
                if let wanted {
                    let matches = wanted == "me" ? Reminders.isUsers(entry.item, userName: userName)
                        : Self.normalizedName(entry.item.owner).contains(wanted)
                    guard matches else { return nil }
                }
                return ActionItemHit(meetingID: record.id, meetingTitle: record.title, startedAt: record.startedAt,
                                     item: entry.item, status: entry.status)
            }
        }
        return Array(hits.prefix(limit ?? hits.count))
    }

    /// Past meetings related to the current one (spec 5.4), newest first: from the last 180 days, at most five.
    /// - Parameters:
    ///   - event: the current calendar event, if any.
    ///   - title: the current meeting's title (typed, or the event's).
    ///   - userName: the user's name, never counted as a shared attendee.
    ///   - excluding: the current meeting's id.
    public func related(to event: CalendarEventInfo?, title: String?, userName: String = "", excluding: String? = nil,
                        now: Date) -> [MeetingRecord] {
        let others = event?.others ?? []
        let me = Set(([userName] + (event?.attendees.filter(\.isMe).map(\.name) ?? [])).map(Self.normalizedName))
            .filter { !$0.isEmpty }
        // The user's own address may not be marked isMe (a delegated calendar), so their name rules it out too.
        let keys = Set(others.filter { !me.contains(Self.normalizedName($0.name)) }.compactMap(\.email)
            .map(MeetingRecord.emailKey))
        let names = Set(others.map { Self.normalizedName($0.name) }).subtracting(me).filter { !$0.isEmpty }
        let current = Self.normalizedTitle(title ?? event.flatMap(CurrentEvent.eventTitle) ?? "")
        // The stoplist guards only the title-only rule; a v1 typed title matches even when generic (spec 5.4).
        let titleUsable = !current.isEmpty && !Self.isGenericTitle(current)
        let found = index.entries().map(\.record).filter { record in
            guard record.id != excluding, record.startedAt < now,
                  record.startedAt >= now.addingTimeInterval(-Self.relatedWindow) else { return false }
            if !keys.isDisjoint(with: record.attendeeKeys) { return true }
            if record.eventID == nil {
                let theirs = Set((record.notes?.attendees ?? []).map(Self.normalizedName)).subtracting(me)
                if !names.isDisjoint(with: theirs) { return true }
                if !current.isEmpty, let typed = record.typedTitle, Self.normalizedTitle(typed) == current { return true }
            }
            return others.isEmpty && titleUsable && Self.normalizedTitle(record.title) == current
        }
        return Array(found.prefix(Self.relatedLimit))
    }

    /// Lowercased, accents removed, punctuation turned into spaces, spaces collapsed: "Acme  Kick-off!" gives
    /// "acme kick off".
    public static func normalizedTitle(_ title: String) -> String {
        let folded = fold(title)
        let spaced = String(folded.map { $0.isLetter || $0.isNumber ? $0 : " " })
        return spaced.split(separator: " ").joined(separator: " ")
    }

    public static func isGenericTitle(_ title: String) -> Bool {
        let normal = normalizedTitle(title)
        return normal.isEmpty || genericTitles.contains(normal)
    }

    /// A name for comparing people: lowercased, accents removed, spaces collapsed.
    public static func normalizedName(_ name: String) -> String {
        fold(name).split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// "7d", "2w" or "24h" before `now`, or a date ("2026-10-01", start of that day in `timeZone`) or an ISO 8601
    /// time. Nil when it can't be read.
    public static func parseSince(_ text: String, now: Date = Date(), timeZone: TimeZone = .current) -> Date? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let match = trimmed.wholeMatch(of: /(\d{1,5})\s*([hdw])/), let count = Double(match.1) {
            let unit: Double = switch match.2 {
            case "h": 3600
            case "d": 86_400
            default: 7 * 86_400
            }
            return now.addingTimeInterval(-count * unit)
        }
        if trimmed.wholeMatch(of: /\d{4}-\d{2}-\d{2}/) != nil {
            return SessionStore.formatter("yyyy-MM-dd", timeZone).date(from: trimmed)
        }
        return ISO8601DateFormatter().date(from: text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }

    static func terms(_ query: String) -> [String] {
        fold(query).split(whereSeparator: \.isWhitespace).map(String.init)
    }

    static func notesText(_ record: MeetingRecord) -> String {
        let notes = record.notes
        let parts = [record.title, record.summary] + record.attendees.map(\.name) + record.decisions
            + (notes?.keyPoints ?? []) + (notes?.openQuestions ?? []) + (notes?.stillOpen ?? [])
            + (notes?.flaggedMoments.map(\.note) ?? []) + record.items.map { "\($0.item.task) \($0.item.owner)" }
        return parts.joined(separator: "\n")
    }
}
