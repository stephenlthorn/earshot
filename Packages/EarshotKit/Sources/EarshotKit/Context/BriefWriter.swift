import Foundation

/// The brief shown as a call starts (spec 5.5), written by the quick model from the event and related meetings.
public struct BriefWriter: Sendable {
    public static let timeout: Duration = .seconds(60)
    public static let effort = "low"
    public static let maxTokens = 4_000
    public static let maxHeadline = 90
    public static let maxPoints = 4
    public static let maxPoint = 140
    public static let maxLoops = 8

    /// Closed and all-required, like every structured call.
    public static let schema = #"""
    {"type":"object","additionalProperties":false,"required":["headline","points","open_loops"],
     "properties":{
      "headline":{"type":"string","description":"One line, at most 90 characters"},
      "points":{"type":"array","items":{"type":"string"},"description":"At most 4, each at most 140 characters"},
      "open_loops":{"type":"array","items":{"type":"object","additionalProperties":false,
        "required":["owner","task","from"],
        "properties":{
         "owner":{"type":"string"},
         "task":{"type":"string","description":"Starts with a verb"},
         "from":{"type":"string","description":"The earlier meeting's label exactly as given"}}}}}}
    """#

    public var client: any ClaudeClient
    public var model: String

    public init(client: any ClaudeClient, model: String) {
        self.client = client
        self.model = model
    }

    /// True when the mode isn't Record and there is an agenda (more than links after cleaning) or at least one
    /// related meeting. The overload with `settings` also checks the settings.
    public static func shouldWrite(event: CalendarEventInfo?, history: [MeetingRecord], mode: Mode) -> Bool {
        guard mode != .record else { return false }
        return !history.isEmpty || AgendaSanitizer.hasContent(event?.agenda ?? "")
    }

    /// The same, and only when "Use my calendar" and the brief setting are both on: without calendar access there
    /// is no brief.
    public static func shouldWrite(event: CalendarEventInfo?, history: [MeetingRecord], mode: Mode,
                                   settings: EarshotSettings) -> Bool {
        settings.useCalendar && settings.briefEnabled && shouldWrite(event: event, history: history, mode: mode)
    }

    /// `BriefWriter.shouldWrite(event:history:mode:)`, for callers holding a writer.
    public func shouldWrite(event: CalendarEventInfo?, history: [MeetingRecord], mode: Mode) -> Bool {
        Self.shouldWrite(event: event, history: history, mode: mode)
    }

    /// The structured call. Third-party text is framed, the agenda is cleaned, and no "@" reaches the prompt.
    public func request(event: CalendarEventInfo?, title: String?, history: [MeetingRecord], userName: String = "",
                        timeZone: TimeZone = .current) -> ClaudeRequest {
        ClaudeRequest(role: .brief, system: Self.system, user: Self.user(event: event, title: title, history: history,
                                                                          userName: userName, timeZone: timeZone),
                      schema: Self.schema, model: model, effort: Self.effort, maxTokens: Self.maxTokens,
                      timeout: Self.timeout)
    }

    /// Asks the quick model and returns brief.json's contents, clipped to the brief's limits. `sources` are the ids
    /// of `history`. Throws the client's error, or `badOutput` for an answer without a headline.
    public func write(event: CalendarEventInfo?, title: String?, history: [MeetingRecord], userName: String = "",
                      timeZone: TimeZone = .current, now: Date) async throws -> MeetingBrief {
        let request = request(event: event, title: title, history: history, userName: userName, timeZone: timeZone)
        let reply = try await client.decode(Reply.self, request)
        let headline = Self.clip(reply.headline, Self.maxHeadline)
        guard !headline.isEmpty else { throw NotesError.badOutput("The brief came back empty") }
        let points = reply.points.map { Self.clip($0, Self.maxPoint) }.filter { !$0.isEmpty }.prefix(Self.maxPoints)
        let loops = reply.openLoops.map { OpenLoop(owner: Self.clip($0.owner, 80), task: Self.clip($0.task, 200),
                                                   from: Self.clip($0.from, 80)) }
            .filter { !$0.task.isEmpty }.prefix(Self.maxLoops)
        return MeetingBrief(version: 1, eventID: event?.id, model: model, createdAt: now, headline: headline,
                            points: Array(points), openLoops: Array(loops), sources: history.map(\.id))
    }

    struct Reply: Decodable {
        struct Loop: Decodable { var owner: String, task: String, from: String }
        var headline: String
        var points: [String]
        var openLoops: [Loop]

        enum CodingKeys: String, CodingKey {
            case headline, points
            case openLoops = "open_loops"
        }
    }

    static let system = [
        "You write a short brief the user reads as a call starts, so they remember what matters from the agenda and from earlier meetings with the same people.",
        "",
        "Rules:",
        "- headline: one line of at most 90 characters: what this meeting is likely about, or the most useful thing to remember.",
        "- points: at most 4, each at most 140 characters: facts, decisions or concerns worth keeping in mind. Skip what the title already says.",
        "- open_loops: action items from the earlier meetings that may still be open, each with its owner, the task, and from: the meeting's label exactly as given. Leave out items the notes show as done. At most 8.",
        "- Use only what is in the blocks below. Never invent names, dates, numbers or promises.",
        "- When there is little to go on, keep the headline short and leave the lists empty.",
        "",
        PromptFraming.standardRule,
    ].joined(separator: "\n")

    static func user(event: CalendarEventInfo?, title: String?, history: [MeetingRecord], userName: String,
                     timeZone: TimeZone) -> String {
        let name = userName.trimmingCharacters(in: .whitespacesAndNewlines)
        var blocks = [name.isEmpty ? "Write the brief for the user." : "Write the brief for \(name), the user."]
        let others = event?.others ?? []
        if !others.isEmpty {
            blocks.append(PromptFraming.wrap(tag: .attendees, text: others.map(attendeeLine).joined(separator: "\n")))
        }
        let agenda = AgendaSanitizer.hasContent(event?.agenda ?? "") ? AgendaSanitizer.clean(event?.agenda ?? "") : ""
        // The title is third-party text too, and a join link in it can carry a passcode.
        let heading = CurrentEvent.meetingTitle(typed: title, event: event).map { "Title: \(AgendaSanitizer.replaceLinks($0))" }
        let agendaText = [heading, agenda.isEmpty ? nil : agenda].compactMap { $0 }.joined(separator: "\n\n")
        if !agendaText.isEmpty { blocks.append(PromptFraming.wrap(tag: .agenda, text: agendaText)) }
        if !history.isEmpty {
            let text = history.map { meetingText($0, timeZone: timeZone) }.joined(separator: "\n\n")
            blocks.append(PromptFraming.wrap(tag: .meetingNotes, text: text))
        }
        return AgendaSanitizer.scrubAddresses(blocks.joined(separator: "\n\n"))
    }

    /// "- Dana Smith (acme.com)": a name and a domain, never an address.
    static func attendeeLine(_ attendee: Attendee) -> String {
        let name = attendee.displayName
        guard let domain = attendee.domain, domain != name else { return "- \(name)" }
        return "- \(name) (\(domain))"
    }

    static func meetingText(_ record: MeetingRecord, timeZone: TimeZone) -> String {
        var lines = ["Meeting \"\(BriefFallback.source(record, timeZone: timeZone))\":"]
        let summary = record.summary.trimmingCharacters(in: .whitespacesAndNewlines)
        if !summary.isEmpty { lines.append("Summary: \(String(summary.prefix(800)))") }
        let decisions = record.decisions.prefix(6)
        if !decisions.isEmpty { lines += ["Decisions:"] + decisions.map { "- \(BriefFallback.oneLine($0))" } }
        let items = record.items.prefix(12)
        if !items.isEmpty {
            lines.append("Action items:")
            lines += items.map { entry in
                let due = entry.item.due.map { ", due \(BriefFallback.oneLine($0))" } ?? ""
                return "- \(BriefFallback.oneLine(entry.item.owner)): \(BriefFallback.oneLine(entry.item.task))\(due) [\(entry.status)]"
            }
        }
        let open = (record.notes?.stillOpen ?? []).prefix(6)
        if !open.isEmpty { lines += ["Still open from before:"] + open.map { "- \(BriefFallback.oneLine($0))" } }
        return lines.joined(separator: "\n")
    }

    /// One line, spaces collapsed, at most `limit` characters (ending in "..." when cut).
    static func clip(_ text: String, _ limit: Int) -> String {
        let line = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard line.count > limit else { return line }
        let cut = String(line.prefix(limit - 3)).trimmingCharacters(in: .whitespaces)
        return cut + "..."
    }
}
