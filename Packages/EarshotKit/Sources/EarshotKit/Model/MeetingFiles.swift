import Foundation

/// The names of the files in a meeting folder.
public enum MeetingFile {
    public static let session = "session.json"
    public static let transcript = "transcript.json"
    public static let transcriptMarkdown = "transcript.md"
    public static let notes = "notes.json"
    public static let notesMarkdown = "notes.md"
    public static let notesPage = "notes.html"
    public static let items = "items.json"
    public static let live = "live.json"
    public static let brief = "brief.json"
    public static let screen = "screen.json"
    /// Folder for kept screenshots (only with "Keep screenshots").
    public static let screenFolder = "screen"
    public static let qa = "qa.json"
    /// The `flock` target for `SessionStore.update`.
    public static let lock = ".lock"
    /// Holds the PID of the process working on the meeting (`earshot process`).
    public static let busy = ".busy"

    /// The kept copy of notes revision `n`: "notes-r1.json".
    public static func notesRevision(_ n: Int) -> String { "notes-r\(n).json" }

    /// A Do target's log: "do-webhook.log".
    public static func doLog(_ targetID: String) -> String { "do-\(targetID).log" }
}

/// live.json: the live controller's to-dos and final live transcript (spec 4.5).
public struct LiveFile: Codable, Equatable, Sendable {
    public var version: Int
    public var items: [LiveItem]
    public var segments: [Segment]

    public init(version: Int = 1, items: [LiveItem] = [], segments: [Segment] = []) {
        self.version = version
        self.items = items
        self.segments = segments
    }

    enum CodingKeys: String, CodingKey { case version, items, segments }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = c.lenient(Int.self, .version) ?? 1
        items = c.lossy(LiveItem.self, .items)
        segments = c.lossy(Segment.self, .segments)
    }
}

/// A to-do found during the call (spec 4.3 and 14.2). `firstSeen` and `updated` are seconds on the meeting clock.
public struct LiveItem: Codable, Equatable, Sendable, Identifiable {
    public enum Status: String, Codable, CaseIterable, Sendable, FallbackDecodable {
        case suggested, queued, sending, running, done, sent, startedInCloud, failed, interrupted, dismissed
        /// A case from a newer version: treated as possibly sent, so it is never sent again on its own.
        public static let fallback = Status.interrupted

        /// The statuses that mean the work went out, or may have (spec 14.4 rule 1).
        public var isStarted: Bool {
            switch self {
            case .sending, .running, .done, .sent, .startedInCloud, .interrupted: true
            case .suggested, .queued, .failed, .dismissed: false
            }
        }
    }

    /// "L1", "L2" and so on.
    public var id: String
    public var task: String
    public var owner: String
    public var due: String?
    public var aiDoable: Bool
    /// One line, in the model's words, on why this is a task.
    public var why: String
    public var firstSeen: Double
    public var updated: Double
    public var status: Status
    /// The Do target id it was sent to.
    public var target: String?
    public var detail: String?
    /// For example the routine run URL.
    public var link: String?

    public init(id: String, task: String, owner: String, due: String? = nil, aiDoable: Bool, why: String = "",
                firstSeen: Double, updated: Double? = nil, status: Status = .suggested, target: String? = nil,
                detail: String? = nil, link: String? = nil) {
        self.id = id
        self.task = task
        self.owner = owner
        self.due = due
        self.aiDoable = aiDoable
        self.why = why
        self.firstSeen = firstSeen
        self.updated = updated ?? firstSeen
        self.status = status
        self.target = target
        self.detail = detail
        self.link = link
    }

    enum CodingKeys: String, CodingKey {
        case id, task, owner, due, aiDoable, why, firstSeen, updated, status, target, detail, link
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let firstSeen = c.lenient(Double.self, .firstSeen) ?? 0
        self.init(id: try c.decode(String.self, forKey: .id), task: try c.decode(String.self, forKey: .task),
                  owner: c.lenient(String.self, .owner) ?? "Unassigned", due: c.lenient(String.self, .due),
                  aiDoable: c.lenient(Bool.self, .aiDoable) ?? false, why: c.lenient(String.self, .why) ?? "",
                  firstSeen: firstSeen, updated: c.lenient(Double.self, .updated) ?? firstSeen,
                  status: c.lenient(Status.self, .status) ?? .interrupted, target: c.lenient(String.self, .target),
                  detail: c.lenient(String.self, .detail), link: c.lenient(String.self, .link))
    }
}

/// An action item from an earlier meeting with the same people (spec 5.5).
public struct OpenLoop: Codable, Equatable, Hashable, Sendable {
    public var owner: String
    public var task: String
    /// Where it came from, for example "Acme kickoff, 5 Oct".
    public var from: String

    public init(owner: String, task: String, from: String) {
        self.owner = owner
        self.task = task
        self.from = from
    }
}

/// brief.json (spec 5.5).
public struct MeetingBrief: Codable, Equatable, Sendable {
    public var version: Int
    public var eventID: String?
    public var model: String
    public var createdAt: Date
    public var headline: String
    public var points: [String]
    public var openLoops: [OpenLoop]
    /// Ids of the past meetings it was written from.
    public var sources: [String]

    public init(version: Int = 1, eventID: String?, model: String, createdAt: Date, headline: String,
                points: [String] = [], openLoops: [OpenLoop] = [], sources: [String] = []) {
        self.version = version
        self.eventID = eventID
        self.model = model
        self.createdAt = createdAt
        self.headline = headline
        self.points = points
        self.openLoops = openLoops
        self.sources = sources
    }

    enum CodingKeys: String, CodingKey { case version, eventID, model, createdAt, headline, points, openLoops, sources }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(version: c.lenient(Int.self, .version) ?? 1, eventID: c.lenient(String.self, .eventID),
                  model: c.lenient(String.self, .model) ?? "",
                  createdAt: try c.decode(Date.self, forKey: .createdAt),
                  headline: try c.decode(String.self, forKey: .headline), points: c.lossy(String.self, .points),
                  openLoops: c.lossy(OpenLoop.self, .openLoops), sources: c.lossy(String.self, .sources))
    }
}

/// Text read from the shared screen at `offset` seconds on the meeting clock (spec 9).
public struct ScreenMoment: Codable, Equatable, Sendable {
    public var offset: Double
    public var text: String
    /// File name under `screen/`, only with "Keep screenshots".
    public var image: String?

    public init(offset: Double, text: String, image: String? = nil) {
        self.offset = offset
        self.text = text
        self.image = image
    }
}

/// screen.json.
public struct ScreenFile: Codable, Equatable, Sendable {
    public var version: Int
    public var moments: [ScreenMoment]

    public init(version: Int = 1, moments: [ScreenMoment] = []) {
        self.version = version
        self.moments = moments
    }

    enum CodingKeys: String, CodingKey { case version, moments }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = c.lenient(Int.self, .version) ?? 1
        moments = c.lossy(ScreenMoment.self, .moments)
    }
}

/// One question about a meeting and its answer (spec 8).
public struct QAEntry: Codable, Equatable, Sendable {
    public var question: String
    public var answer: String
    public var askedAt: Date
    public var model: String

    public init(question: String, answer: String, askedAt: Date, model: String) {
        self.question = question
        self.answer = answer
        self.askedAt = askedAt
        self.model = model
    }
}

/// qa.json.
public struct QAFile: Codable, Equatable, Sendable {
    public var version: Int
    public var entries: [QAEntry]

    public init(version: Int = 1, entries: [QAEntry] = []) {
        self.version = version
        self.entries = entries
    }

    enum CodingKeys: String, CodingKey { case version, entries }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = c.lenient(Int.self, .version) ?? 1
        entries = c.lossy(QAEntry.self, .entries)
    }
}
