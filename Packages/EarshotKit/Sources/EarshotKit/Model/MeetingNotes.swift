import Foundation

public struct ActionItem: Codable, Equatable, Hashable, Sendable {
    public enum Doer: String, Codable, CaseIterable, Sendable {
        case ai, me
        case someoneElse = "someone_else"
    }

    public var task: String
    public var owner: String
    public var due: String?
    public var doer: Doer
    public var context: String
    /// The live to-do ("L3") the notes model linked this item to, or nil (spec 4.4).
    public var liveRef: String?
    /// Code-side only, in items.json: "n<k>" for notes item k (from 1), or the live item's id (spec 6).
    public var source: String?
    /// Code-side only, in items.json: the id of the payload that carried this item ("<meeting id>" for the
    /// meeting's own send, "<id>-r<n>-<hash>" for a later one), so its routine run is `routineRuns[payload]` (spec 12).
    /// Nil in v1 and earlier v2 files.
    public var payload: String?

    public init(task: String, owner: String, due: String? = nil, doer: Doer, context: String = "",
                liveRef: String? = nil, source: String? = nil, payload: String? = nil) {
        self.task = task
        self.owner = owner
        self.due = due
        self.doer = doer
        self.context = context
        self.liveRef = liveRef
        self.source = source
        self.payload = payload
    }

    enum CodingKeys: String, CodingKey {
        case task, owner, due, doer, context, source, payload
        case liveRef = "live_ref"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        task = try container.decode(String.self, forKey: .task)
        owner = try container.decode(String.self, forKey: .owner)
        due = try container.decodeIfPresent(String.self, forKey: .due)
        doer = try container.decode(Doer.self, forKey: .doer)
        context = try container.decodeIfPresent(String.self, forKey: .context) ?? ""
        liveRef = container.lenient(String.self, .liveRef)
        source = container.lenient(String.self, .source)
        payload = container.lenient(String.self, .payload)
    }

    /// Writes "due": null and "live_ref": null instead of leaving the keys out, so receivers always see every
    /// field. `source` and `payload` are written only when set.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(task, forKey: .task)
        try container.encode(owner, forKey: .owner)
        try container.encode(due, forKey: .due)
        try container.encode(doer, forKey: .doer)
        try container.encode(context, forKey: .context)
        try container.encode(liveRef, forKey: .liveRef)
        try container.encodeIfPresent(source, forKey: .source)
        try container.encodeIfPresent(payload, forKey: .payload)
    }
}

public struct MeetingNotes: Codable, Equatable, Sendable {
    public var title: String
    public var summary: String
    public var attendees: [String]
    public var keyPoints: [String]
    public var decisions: [String]
    public var actionItems: [ActionItem]
    public var openQuestions: [String]
    /// One note per flagged moment (spec 8).
    public var flaggedMoments: [FlaggedMoment]
    /// Loops from earlier meetings that are still open (spec 5.5).
    public var stillOpen: [String]

    enum CodingKeys: String, CodingKey {
        case title, summary, attendees, decisions
        case keyPoints = "key_points"
        case actionItems = "action_items"
        case openQuestions = "open_questions"
        case flaggedMoments = "flagged_moments"
        case stillOpen = "still_open"
    }

    public init(title: String, summary: String, attendees: [String] = [], keyPoints: [String] = [],
                decisions: [String] = [], actionItems: [ActionItem] = [], openQuestions: [String] = [],
                flaggedMoments: [FlaggedMoment] = [], stillOpen: [String] = []) {
        self.title = title
        self.summary = summary
        self.attendees = attendees
        self.keyPoints = keyPoints
        self.decisions = decisions
        self.actionItems = actionItems
        self.openQuestions = openQuestions
        self.flaggedMoments = flaggedMoments
        self.stillOpen = stillOpen
    }

    /// Title and summary are required; a missing list is empty, so notes.json from v1 (or with a newer key
    /// missing) still loads.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        title = try container.decode(String.self, forKey: .title)
        summary = try container.decode(String.self, forKey: .summary)
        attendees = try container.decodeIfPresent([String].self, forKey: .attendees) ?? []
        keyPoints = try container.decodeIfPresent([String].self, forKey: .keyPoints) ?? []
        decisions = try container.decodeIfPresent([String].self, forKey: .decisions) ?? []
        actionItems = try container.decodeIfPresent([ActionItem].self, forKey: .actionItems) ?? []
        openQuestions = try container.decodeIfPresent([String].self, forKey: .openQuestions) ?? []
        flaggedMoments = container.lossy(FlaggedMoment.self, .flaggedMoments)
        stillOpen = container.lossy(String.self, .stillOpen)
    }

    /// Written without calling Claude when the transcript is empty.
    public static let noSpeech = MeetingNotes(
        title: "No speech detected",
        summary: "The recording had no speech that Earshot could transcribe.")
}

/// The JSON schema Claude must answer in. Every object is closed and every property required (structured outputs).
public enum NotesSchema {
    public static let json = #"""
    {"type":"object","additionalProperties":false,
     "required":["title","summary","attendees","key_points","decisions","action_items","open_questions","flagged_moments","still_open"],
     "properties":{
      "title":{"type":"string","description":"Short and specific, like: Acme kickoff: scope and pilot dates"},
      "summary":{"type":"string","description":"3 to 6 sentences"},
      "attendees":{"type":"array","items":{"type":"string"}},
      "key_points":{"type":"array","items":{"type":"string"}},
      "decisions":{"type":"array","items":{"type":"string"}},
      "action_items":{"type":"array","items":{"type":"object","additionalProperties":false,
        "required":["task","owner","due","doer","context","live_ref"],
        "properties":{
         "task":{"type":"string","description":"Starts with a verb and makes sense on its own"},
         "owner":{"type":"string","description":"The person who will do it, or Unassigned"},
         "due":{"anyOf":[{"type":"string"},{"type":"null"}],"description":"The deadline as said; null if none was said"},
         "doer":{"type":"string","enum":["ai","me","someone_else"],"description":"ai: an AI agent with computer access could finish it without the user. me: the user must do it. someone_else: another person owns it"},
         "context":{"type":"string","description":"1 or 2 facts from the meeting the doer needs"},
         "live_ref":{"anyOf":[{"type":"string"},{"type":"null"}],"description":"The id (like L2) of the already started to-do this item is, or null"}}}},
      "open_questions":{"type":"array","items":{"type":"string"}},
      "flagged_moments":{"type":"array","items":{"type":"object","additionalProperties":false,
        "required":["seconds","note"],
        "properties":{
         "seconds":{"type":"number","description":"The flag's time in seconds from the start"},
         "note":{"type":"string","description":"What was said or shown at that moment, in 1 or 2 sentences"}}},
        "description":"One entry per flagged moment; empty when there are none"},
      "still_open":{"type":"array","items":{"type":"string"},"description":"Open loops from earlier meetings that are still open, each with its owner; empty when there are none"}}}
    """#

    public static var object: Any {
        // The literal above is fixed and tested, so a parse failure is a programming error.
        try! JSONSerialization.jsonObject(with: Data(json.utf8))
    }
}
