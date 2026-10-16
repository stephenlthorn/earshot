import Foundation

/// What happens after Stop. Each mode runs its stages in this order.
public enum Mode: String, Codable, CaseIterable, Sendable {
    case record
    case notes
    case notesAndDo = "notes_and_do"

    public var stages: [Stage] {
        switch self {
        case .record: [.compress]
        case .notes: [.transcribe, .notes, .compress]
        case .notesAndDo: [.transcribe, .notes, .dispatch, .compress]
        }
    }

    public var label: String {
        switch self {
        case .record: "Record"
        case .notes: "Notes"
        case .notesAndDo: "Notes + Do"
        }
    }
}

public enum Stage: String, Codable, CodingKeyRepresentable, CaseIterable, Sendable {
    case transcribe, notes, dispatch, compress
}

public struct StageState: Codable, Equatable, Sendable {
    public enum Status: String, Codable, Sendable { case pending, running, done, failed }
    public var status: Status
    public var error: String?
    /// Failures in a row. At 2 the pipeline stops retrying on its own until the user presses Retry.
    public var failures: Int

    public init(status: Status = .pending, error: String? = nil, failures: Int = 0) {
        self.status = status
        self.error = error
        self.failures = failures
    }
}

public enum Track: String, Codable, CodingKeyRepresentable, CaseIterable, Sendable {
    case me, them, speaker

    public var defaultName: String {
        switch self {
        case .me: "Me"
        case .them: "Them"
        case .speaker: "Speaker"
        }
    }
}

public struct TrackFile: Codable, Equatable, Sendable {
    public var track: Track
    /// File name inside the meeting folder: "mic.caf" while recording, "mic.m4a" once compressed.
    public var file: String
    /// Seconds from the earliest track's first buffer to this track's first buffer.
    public var offset: Double

    public init(track: Track, file: String, offset: Double) {
        self.track = track
        self.file = file
        self.offset = offset
    }
}

public struct Session: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var folderName: String
    public var title: String?
    public var mode: Mode
    public var startedAt: Date
    public var endedAt: Date?
    public var recording: Bool
    public var tracks: [TrackFile]
    public var stages: [Stage: StageState]
    /// Do targets that already succeeded, by target id, so a retry only re-sends the ones that failed.
    public var sent: [String]
    /// Do targets whose send started and has not finished, by target id. Saved before each send, so after a quit or
    /// crash part-way the pipeline knows the target may already have done the work.
    public var inFlight: [String] = []
    public var warnings: [String]
    /// The calendar event this meeting was recorded during (spec 5.2).
    public var calendarEvent: CalendarEventInfo? = nil
    /// Who the meeting is with; nil for v1 meetings and for a value this version doesn't know.
    public var profile: MeetingProfile? = nil
    /// Moments the user flagged, oldest first, at most `Flag.maxCount`.
    public var flags: [Flag] = []
    public var startedBy: StartTrigger = .manual
    /// How many times the notes were revised (Send with edits, or Fix); 0 for the first notes.
    public var notesRevision: Int = 0
    /// Routine run URLs by Do payload id (spec 12).
    public var routineRuns: [String: String] = [:]

    public var duration: TimeInterval { (endedAt ?? startedAt).timeIntervalSince(startedAt) }
    public var nextStage: Stage? { mode.stages.first { stages[$0]?.status != .done } }
    public var isFinished: Bool { !recording && nextStage == nil }
    /// Targets sending right now. An in-flight mark left by a crash is not one: its dispatch stage isn't running.
    public var sendingTargets: [String] { stages[.dispatch]?.status == .running ? inFlight : [] }
}

extension Session {
    enum CodingKeys: String, CodingKey {
        case id, folderName, title, mode, startedAt, endedAt, recording, tracks, stages, sent, inFlight, warnings
        case calendarEvent, profile, flags, startedBy, notesRevision, routineRuns
    }

    /// Written out so that a session.json from an earlier version, without the newer keys, still loads.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        folderName = try container.decode(String.self, forKey: .folderName)
        title = try container.decodeIfPresent(String.self, forKey: .title)
        mode = try container.decode(Mode.self, forKey: .mode)
        startedAt = try container.decode(Date.self, forKey: .startedAt)
        endedAt = try container.decodeIfPresent(Date.self, forKey: .endedAt)
        recording = try container.decode(Bool.self, forKey: .recording)
        tracks = try container.decode([TrackFile].self, forKey: .tracks)
        stages = try container.decode([Stage: StageState].self, forKey: .stages)
        sent = try container.decode([String].self, forKey: .sent)
        inFlight = try container.decodeIfPresent([String].self, forKey: .inFlight) ?? []
        warnings = try container.decode([String].self, forKey: .warnings)
        // v2 fields: each is optional, and a value this version can't read is dropped rather than failing the load.
        calendarEvent = container.lenient(CalendarEventInfo.self, .calendarEvent)
        profile = container.lenientCase(MeetingProfile.self, .profile)
        flags = container.lossy(Flag.self, .flags)
        startedBy = container.lenientCase(StartTrigger.self, .startedBy) ?? Self.defaultTrigger(for: tracks)
        notesRevision = container.lenient(Int.self, .notesRevision) ?? 0
        routineRuns = container.lenient([String: String].self, .routineRuns) ?? [:]
    }

    /// What started a meeting whose file doesn't say: an import when its only track is the imported "Speaker".
    static func defaultTrigger(for tracks: [TrackFile]) -> StartTrigger {
        !tracks.isEmpty && tracks.allSatisfy { $0.track == .speaker } ? .importFile : .manual
    }
}

extension Date {
    /// session.json stores ISO 8601 without fractions, so dates are kept to whole seconds.
    public var wholeSeconds: Date { Date(timeIntervalSince1970: timeIntervalSince1970.rounded(.down)) }
}
