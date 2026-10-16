import Foundation

/// The five read-only tools (spec 11.3). Each returns Markdown text plus `structuredContent`. Meeting text sits in a
/// block labelled `MCPServer.contentLabel`; in `structuredContent` it sits under the `untrusted_meeting_content` key,
/// beside a `notice` with that label. People are names and domains, never full addresses.
extension MCPServer {
    static let listDefault = 20, listMax = 100
    static let searchDefault = 10, searchMax = 50
    static let itemsDefault = 50, itemsMax = 200
    static let transcriptDefault = 400, transcriptMax = 1000
    static let itemsSince = "30d"
    static let excerptLength = 280
    static let contentTag: PromptFraming.Tag = "untrusted_meeting_content"

    /// What `tools/list` returns. Computed, because a `[String: Any]` constant isn't concurrency-safe.
    static var tools: [[String: Any]] {
        [
            tool("list_meetings", "List meetings",
                 "List the user's recorded meetings, newest first, with title, start, length, attendees and a summary excerpt.",
                 ["since": string("Only meetings since then: 7d, 2w, 24h or a date like 2026-10-01."),
                  "query": string("Only meetings whose title, summary or attendee names contain every word."),
                  "limit": integer("How many meetings, default \(listDefault).", max: listMax)]),
            tool("get_meeting", "Get a meeting",
                 "Read one meeting: notes, decisions, action items with status, flags, the brief and live to-dos. The transcript is left out unless include_transcript is true; it is paged.",
                 ["id": string("A meeting id from list_meetings or search_meetings, a folder name, or latest."),
                  "include_transcript": ["type": "boolean", "description": "Include a page of the transcript. Default false."],
                  "transcript_offset": ["type": "integer", "minimum": 0, "description": "The first transcript line, default 0."],
                  "transcript_limit": integer("Transcript lines per page, default \(transcriptDefault).", max: transcriptMax)],
                 required: ["id"]),
            tool("search_meetings", "Search meetings",
                 "Full-text search over meeting notes and transcripts. Returns meetings and the transcript lines that match, with times.",
                 ["query": string("Words that must all appear."),
                  "limit": integer("How many meetings, default \(searchDefault).", max: searchMax)],
                 required: ["query"]),
            tool("list_action_items", "List action items",
                 "Action items across meetings, newest meeting first, with owner, due date and status.",
                 ["owner": string("me for the user's own items, or a person's name."),
                  "since": string("Only meetings since then, default \(itemsSince)."),
                  "limit": integer("How many items, default \(itemsDefault).", max: itemsMax)]),
            tool("meeting_prep", "Prepare for a meeting",
                 "Past meetings related to a person or a title, with their open action items. Give an attendee (a name or an email address), a title, or both.",
                 ["attendee": string("A person's name or email address."),
                  "title": string("The meeting's title.")]),
        ]
    }

    static func tool(_ name: String, _ title: String, _ description: String, _ properties: [String: Any],
                     required: [String] = []) -> [String: Any] {
        var schema: [String: Any] = ["type": "object", "properties": properties, "additionalProperties": false]
        if !required.isEmpty { schema["required"] = required }
        return ["name": name, "title": title, "description": description, "inputSchema": schema,
                "annotations": ["title": title, "readOnlyHint": true, "openWorldHint": false]]
    }

    /// A JSON null for a missing value.
    static func orNull(_ value: String?) -> Any { value.map { $0 as Any } ?? NSNull() }

    static func string(_ description: String) -> [String: Any] { ["type": "string", "description": description] }

    static func integer(_ description: String, max: Int) -> [String: Any] {
        ["type": "integer", "minimum": 1, "maximum": max, "description": description]
    }

    /// A tool's answer: Markdown for the model and the same facts as structured content.
    struct ToolResult {
        var text: String
        var structured: [String: Any]?
        var isError = false

        var object: [String: Any] {
            var out: [String: Any] = ["content": [["type": "text", "text": text]], "isError": isError]
            if let structured { out["structuredContent"] = structured }
            return out
        }

        static func failure(_ text: String) -> ToolResult { ToolResult(text: text, structured: nil, isError: true) }
    }

    /// Runs a tool, or nil when there is no tool by that name. Every string in the answer has full addresses
    /// replaced by their domain, except an address the caller passed in.
    func call(_ name: String, arguments: [String: Any]) -> ToolResult? {
        let result: ToolResult
        switch name {
        case "list_meetings": result = listMeetings(arguments)
        case "get_meeting": result = getMeeting(arguments)
        case "search_meetings": result = searchMeetings(arguments)
        case "list_action_items": result = listActionItems(arguments)
        case "meeting_prep": result = meetingPrep(arguments)
        default: return nil
        }
        let keep = (arguments["attendee"] as? String).map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            .flatMap { $0.contains("@") ? $0 : nil }
        let structured = result.structured.map { Self.framedStructure(Self.scrub($0, keep: keep) as? [String: Any] ?? $0) }
        return ToolResult(text: Self.scrub(result.text, keep: keep), structured: structured, isError: result.isError)
    }

    /// JSON can't be wrapped in the tag, so every fact goes under one key named for it, with the label beside it.
    /// A client that hands `structuredContent` to the model then gives it framed text too (spec 11.3).
    static func framedStructure(_ facts: [String: Any]) -> [String: Any] {
        ["notice": contentLabel, contentTag.rawValue: facts]
    }

    // MARK: Arguments

    static func text(_ arguments: [String: Any], _ key: String) -> String? {
        guard let value = arguments[key] as? String else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    static func number(_ arguments: [String: Any], _ key: String, default value: Int, range: ClosedRange<Int>) -> Int {
        let raw: Int? = switch arguments[key] {
        case let number as NSNumber where CFGetTypeID(number) != CFBooleanGetTypeID(): number.intValue
        case let text as String: Int(text)
        default: nil
        }
        return min(max(raw ?? value, range.lowerBound), range.upperBound)
    }

    static func flag(_ arguments: [String: Any], _ key: String) -> Bool {
        switch arguments[key] {
        case let number as NSNumber: number.boolValue
        case let text as String: text.lowercased() == "true"
        default: false
        }
    }

    /// The `since` argument as a date, or a failure the model can correct.
    func since(_ arguments: [String: Any], default fallback: String? = nil) -> Result<Date?, MCPServer.Problem> {
        guard let text = Self.text(arguments, "since") ?? fallback else { return .success(nil) }
        guard let date = MeetingLibrary.parseSince(text, now: now(), timeZone: timeZone) else {
            return .failure(Problem(code: 0, message: "Couldn't read since \"\(text)\". Use 7d, 2w, 24h or a date like 2026-10-01."))
        }
        return .success(date)
    }

    // MARK: Output helpers

    /// `summary` (facts about the answer, never meeting text), then the meeting text in its labelled block.
    func framed(_ summary: String, _ body: [String]) -> String {
        guard !body.isEmpty else { return summary }
        return summary + "\n\n" + Self.contentLabel + "\n" + PromptFraming.wrap(tag: Self.contentTag, text: body.joined(separator: "\n"))
    }

    func iso(_ date: Date) -> String { ISO8601DateFormatter().string(from: date) }

    func local(_ date: Date) -> String { Self.local(date, timeZone) }

    static func local(_ date: Date, _ timeZone: TimeZone) -> String {
        SessionStore.formatter("yyyy-MM-dd HH:mm", timeZone).string(from: date)
    }

    static func excerpt(_ text: String) -> String {
        let flat = text.split(whereSeparator: \.isNewline).joined(separator: " ")
        return flat.count > excerptLength ? String(flat.prefix(excerptLength - 3)) + "..." : flat
    }

    static func people(_ attendees: [RecordAttendee]) -> String {
        attendees.map { person in person.domain.map { "\(person.name) (\($0))" } ?? person.name }.joined(separator: ", ")
    }

    static func attendeeObjects(_ attendees: [RecordAttendee]) -> [[String: Any]] {
        attendees.map { ["name": $0.name, "domain": orNull($0.domain)] }
    }

    func meetingObject(_ record: MeetingRecord) -> [String: Any] {
        ["id": record.id, "title": record.title, "started_at": iso(record.startedAt),
         "duration_s": NotesRenderer.wholeSeconds(record.duration), "attendees": Self.attendeeObjects(record.attendees),
         "summary": Self.excerpt(record.summary)]
    }

    func meetingLine(_ record: MeetingRecord) -> String {
        let who = record.attendees.isEmpty ? "" : "; with \(Self.people(record.attendees))"
        return "- \(record.title) [id \(record.id)] \(local(record.startedAt)), \(NotesRenderer.lengthText(record.duration))\(who)"
    }

    static func itemObject(_ item: ActionItem, status: String) -> [String: Any] {
        ["task": item.task, "owner": item.owner, "due": orNull(item.due), "doer": item.doer.rawValue, "status": status]
    }

    static func itemLine(_ item: ActionItem, status: String) -> String {
        "- \(item.task) (owner \(item.owner)\(item.due.map { "; due \($0)" } ?? ""); \(status))"
    }

    static func lineObject(_ line: TranscriptLine) -> [String: Any] {
        ["start": line.start.isFinite ? line.start : 0, "clock": NotesRenderer.clock(line.start),
         "speaker": line.speaker, "text": line.text]
    }

    static func lineText(_ line: TranscriptLine) -> String {
        "[\(NotesRenderer.clock(line.start))] \(line.speaker): \(line.text)"
    }

    // MARK: Addresses

    /// Full email addresses become their domain, except `keep` (the address the caller passed, lowercased).
    static func scrub(_ text: String, keep: String?) -> String {
        guard text.contains("@"),
              let regex = try? NSRegularExpression(pattern: #"[A-Za-z0-9._%+\-]+@([A-Za-z0-9\-]+(?:\.[A-Za-z0-9\-]+)+)"#)
        else { return text }
        let ns = text as NSString
        var out = ""
        var last = 0
        for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            out += ns.substring(with: NSRange(location: last, length: match.range.location - last))
            let address = ns.substring(with: match.range)
            out += address.lowercased() == keep ? address : ns.substring(with: match.range(at: 1))
            last = match.range.location + match.range.length
        }
        return out + ns.substring(from: last)
    }

    static func scrub(_ value: Any, keep: String?) -> Any {
        switch value {
        case let text as String: scrub(text, keep: keep)
        case let array as [Any]: array.map { scrub($0, keep: keep) }
        case let object as [String: Any]: object.mapValues { scrub($0, keep: keep) }
        default: value
        }
    }
}
