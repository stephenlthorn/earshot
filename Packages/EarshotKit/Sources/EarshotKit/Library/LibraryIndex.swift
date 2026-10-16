import Foundation

/// One file in the index, `<id>.json` (spec 11.1): the meeting record, flat at the top level, plus its transcript
/// lines. Names and domains only, never full email addresses.
public struct IndexEntry: Codable, Equatable, Sendable, Identifiable {
    public static let currentVersion = 1

    public var version: Int
    public var record: MeetingRecord
    public var transcript: [TranscriptLine]
    /// Speaker names by track raw value, as used for `transcript`.
    public var speakers: [String: String]
    /// The newest modification time of the folder's files when this entry was written, to spot stale entries.
    public var stamp: Double?

    public var id: String { record.id }

    public init(record: MeetingRecord, transcript: [TranscriptLine], speakers: [String: String] = [:],
                stamp: Double? = nil) {
        version = Self.currentVersion
        self.record = record
        self.transcript = transcript
        self.speakers = speakers
        self.stamp = stamp
    }

    enum CodingKeys: String, CodingKey {
        case version, transcript, speakers, stamp, summary, decisions, items, attendeeKeys
    }

    /// The record's keys sit next to these ones in the same object. `attendeeKeys` is read back into the record.
    public init(from decoder: any Decoder) throws {
        record = try MeetingRecord(from: decoder)
        let c = try decoder.container(keyedBy: CodingKeys.self)
        record.attendeeKeys = c.lossy(String.self, .attendeeKeys)
        version = c.lenient(Int.self, .version) ?? Self.currentVersion
        transcript = c.lossy(TranscriptLine.self, .transcript)
        speakers = c.lenient([String: String].self, .speakers) ?? [:]
        stamp = c.lenient(Double.self, .stamp)
    }

    /// Also writes `summary`, `decisions` and `items` (with status) at the top level for readers of the raw file.
    public func encode(to encoder: any Encoder) throws {
        try record.encode(to: encoder)
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(version, forKey: .version)
        try c.encode(transcript, forKey: .transcript)
        try c.encode(speakers, forKey: .speakers)
        try c.encodeIfPresent(stamp, forKey: .stamp)
        try c.encode(record.attendeeKeys, forKey: .attendeeKeys)
        try c.encode(record.summary, forKey: .summary)
        try c.encode(record.decisions, forKey: .decisions)
        try c.encode(record.items.map { IndexItem(item: $0.item, status: $0.status) }, forKey: .items)
    }

    struct IndexItem: Encodable {
        let item: ActionItem
        let status: String
        enum CodingKeys: String, CodingKey { case task, owner, due, doer, status }
        func encode(to encoder: any Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(item.task, forKey: .task)
            try c.encode(item.owner, forKey: .owner)
            try c.encode(item.due, forKey: .due)
            try c.encode(item.doer, forKey: .doer)
            try c.encode(status, forKey: .status)
        }
    }
}

/// The read index in Application Support, which macOS doesn't protect, so the CLI and MCP server can read meetings
/// even when the save folder is in ~/Documents (spec 11.1).
public struct LibraryIndex: Sendable {
    public static let remindersFile = "reminders.json"

    public static var defaultURL: URL {
        URL.applicationSupportDirectory.appending(path: "Earshot/Index", directoryHint: .isDirectory)
    }

    public let url: URL

    public init(url: URL = LibraryIndex.defaultURL) {
        self.url = url
    }

    /// Writes (or replaces) the meeting's entry. The stale-entry stamp is taken now, so a caller that can should
    /// take it before reading the files and use `write(_:transcript:names:userName:stamp:)`.
    public func write(_ record: MeetingRecord, transcript: [Segment], names: [Track: String], userName: String) throws {
        try write(record, transcript: transcript, names: names, userName: userName,
                  stamp: Self.stamp(folder: URL(filePath: record.folder, directoryHint: .isDirectory)))
    }

    /// Writes the entry with a stamp taken before the record was read, so a file changed in between leaves the entry
    /// looking stale and `reconcile` rebuilds it.
    func write(_ record: MeetingRecord, transcript: [Segment], names: [Track: String], userName: String,
               stamp: Double?) throws {
        let lines = TranscriptLine.lines(transcript, names: names, userName: userName)
        let speakers = Dictionary(uniqueKeysWithValues: Track.allCases.map {
            ($0.rawValue, TranscriptLine.speaker($0, names: names, userName: userName))
        })
        let entry = IndexEntry(record: record, transcript: lines, speakers: speakers, stamp: stamp)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try JSONFiles.write(entry, to: file(record.id))
    }

    public func remove(id: String) throws {
        do {
            try FileManager.default.removeItem(at: file(id))
        } catch let error as CocoaError where error.code == .fileNoSuchFile {
            return
        }
    }

    /// Every readable entry, newest first.
    public func entries() -> [IndexEntry] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []
        return names.filter { $0.hasSuffix(".json") && $0 != Self.remindersFile }
            .compactMap { try? JSONFiles.read(IndexEntry.self, from: url.appending(path: $0)) }
            .sorted { $0.record.startedAt > $1.record.startedAt }
    }

    /// The entry for one meeting id, if there is one.
    public func entry(id: String) -> IndexEntry? {
        try? JSONFiles.read(IndexEntry.self, from: file(id))
    }

    /// Rebuilds entries that are missing or older than their folder, and drops entries whose folder is gone.
    /// Throws `LibraryError.folderNotReadable` when the save folder exists but can't be read, without dropping
    /// anything. A save folder that is missing or can't be listed for another reason (an unmounted volume) changes
    /// nothing: its meetings may come back. One entry that can't be written or removed doesn't stop the rest; the
    /// first such error is thrown at the end.
    public func reconcile(with store: SessionStore, userName: String) throws {
        do {
            _ = try FileManager.default.contentsOfDirectory(atPath: store.root.path)
        } catch let error where LibraryError.isPermission(error) {
            throw LibraryError.folderNotReadable(store.root.path)
        } catch {
            return
        }
        let sessions = store.all()
        let existing = Dictionary(entries().map { ($0.id, $0) }) { first, _ in first }
        let names: [Track: String] = userName.isEmpty ? [:] : [.me: userName]
        var firstError: (any Error)?
        for session in sessions {
            let folder = store.folder(session)
            // Taken before the files are read: a file written while they are read makes the entry stale.
            let stamp = Self.stamp(folder: folder)
            if let entry = existing[session.id], entry.record.folder == folder.path,
               let old = entry.stamp, old == stamp { continue }
            let transcript = (try? store.readIfPresent([Segment].self, session, MeetingFile.transcript)) ?? nil
            do {
                try write(MeetingRecord.load(session, from: store), transcript: transcript ?? [], names: names,
                          userName: userName, stamp: stamp)
            } catch {
                firstError = firstError ?? error
            }
        }
        let ids = Set(sessions.map(\.id))
        for entry in existing.values where !ids.contains(entry.id)
            && !FileManager.default.fileExists(atPath: entry.record.folder) {
            do { try remove(id: entry.id) } catch { firstError = firstError ?? error }
        }
        if let firstError { throw firstError }
    }

    /// Writes reminders.json from the index (spec 11.2).
    public func writeReminders(userName: String, now: Date) throws {
        let reminders = Reminders.compute(entries().map(\.record), userName: userName, now: now)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try JSONFiles.write(reminders, to: url.appending(path: Self.remindersFile))
    }

    /// reminders.json, or nil when it hasn't been written or can't be read.
    public func reminders() -> Reminders? {
        try? JSONFiles.read(Reminders.self, from: url.appending(path: Self.remindersFile))
    }

    func file(_ id: String) -> URL {
        // Ids are "yyyy-MM-dd-HHmm-xxxx"; anything else is made safe for a file name.
        let safe = id.map { $0.isLetter || $0.isNumber || $0 == "-" ? $0 : "_" }
        return url.appending(path: String(safe) + ".json")
    }

    /// The newest modification time among the files an entry is built from.
    static func stamp(folder: URL) -> Double? {
        let names = [MeetingFile.session, MeetingFile.notes, MeetingFile.items, MeetingFile.live, MeetingFile.brief,
                     MeetingFile.transcript]
        return names.compactMap {
            (try? FileManager.default.attributesOfItem(atPath: folder.appending(path: $0).path))?[.modificationDate]
                as? Date
        }.map(\.timeIntervalSince1970).max()
    }
}
