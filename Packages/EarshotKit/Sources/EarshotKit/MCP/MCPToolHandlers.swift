import Foundation

/// What each tool does. Arguments are checked here; a problem the model can fix comes back with `isError`.
extension MCPServer {
    func listMeetings(_ arguments: [String: Any]) -> ToolResult {
        let since: Date?
        switch self.since(arguments) {
        case let .success(date): since = date
        case let .failure(problem): return .failure(problem.message)
        }
        let limit = Self.number(arguments, "limit", default: Self.listDefault, range: 1...Self.listMax)
        let records = library.meetings(since: since, query: Self.text(arguments, "query"), limit: limit)
        let summary = records.isEmpty ? "No meetings found." : "\(records.count) meeting\(records.count == 1 ? "" : "s"), newest first."
        let body = records.map { record in
            meetingLine(record) + (record.summary.isEmpty ? "" : "\n  \(Self.excerpt(record.summary))")
        }
        return ToolResult(text: framed(summary, body),
                          structured: ["meetings": records.map(meetingObject)])
    }

    func getMeeting(_ arguments: [String: Any]) -> ToolResult {
        guard let id = Self.text(arguments, "id") else {
            return .failure("Give the meeting id. Call list_meetings or search_meetings to find ids.")
        }
        guard let record = library.meeting(id: id) else {
            return .failure("No meeting with id \"\(id)\". Call list_meetings or search_meetings to find ids.")
        }
        var structured = meetingObject(record)
        structured["summary"] = record.summary
        structured["notes"] = notesObject(record)
        structured["flags"] = record.flags.map { flag -> [String: Any] in
            ["offset": flag.offset.isFinite ? flag.offset : 0, "clock": NotesRenderer.clock(flag.offset),
             "source": flag.source.rawValue]
        }
        structured["live_items"] = record.live.map { item -> [String: Any] in
            ["task": item.task, "owner": item.owner, "due": Self.orNull(item.due), "status": item.status.rawValue]
        }
        if let brief = record.brief {
            structured["brief"] = ["headline": brief.headline, "points": brief.points,
                                   "open_loops": brief.openLoops.map { ["owner": $0.owner, "task": $0.task] }] as [String: Any]
        } else {
            structured["brief"] = NSNull()
        }
        var body = Self.meetingBody(record, timeZone: timeZone)
        var summary = "Meeting \(record.id)."
        if Self.flag(arguments, "include_transcript") {
            let lines: [TranscriptLine]
            do {
                lines = try library.transcript(of: record)
            } catch let error as LibraryError {
                return .failure(error.message(app: app))
            } catch {
                return .failure("The transcript couldn't be read: \(error.localizedDescription)")
            }
            let offset = Self.number(arguments, "transcript_offset", default: 0, range: 0...Int.max - 1)
            let limit = Self.number(arguments, "transcript_limit", default: Self.transcriptDefault, range: 1...Self.transcriptMax)
            let page = Array(lines.dropFirst(offset).prefix(limit))
            let next = offset + page.count < lines.count ? offset + page.count : nil
            var transcript: [String: Any] = ["offset": offset, "limit": limit, "total": lines.count,
                                             "lines": page.map(Self.lineObject)]
            transcript["next_offset"] = next ?? NSNull()
            structured["transcript"] = transcript
            body += ["", "## Transcript"] + page.map(Self.lineText)
            summary += page.isEmpty ? " The transcript has no lines at offset \(offset) (\(lines.count) in all)."
                : " Transcript lines \(offset) to \(offset + page.count - 1) of \(lines.count)."
            if let next { summary += " Pass transcript_offset \(next) for more." }
        } else {
            summary += " The transcript is left out; pass include_transcript true to read it."
        }
        return ToolResult(text: framed(summary, body), structured: structured)
    }

    func notesObject(_ record: MeetingRecord) -> [String: Any] {
        let notes = record.notes
        return ["summary": record.summary, "key_points": notes?.keyPoints ?? [], "decisions": record.decisions,
                "action_items": record.items.map { Self.itemObject($0.item, status: $0.status) },
                "open_questions": notes?.openQuestions ?? [], "still_open": notes?.stillOpen ?? [],
                "flagged_moments": (notes?.flaggedMoments ?? []).map { ["clock": NotesRenderer.clock($0.seconds), "note": $0.note] }]
    }

    /// The meeting as Markdown lines, for inside the labelled block (and for `earshot show`).
    static func meetingBody(_ record: MeetingRecord, timeZone: TimeZone) -> [String] {
        var out = ["# \(record.title)", "\(local(record.startedAt, timeZone)), \(NotesRenderer.lengthText(record.duration))"]
        if !record.attendees.isEmpty { out.append("Attendees: \(Self.people(record.attendees))") }
        func section(_ title: String, _ lines: [String]) {
            guard !lines.isEmpty else { return }
            out += ["", "## \(title)"] + lines
        }
        let notes = record.notes
        section("Summary", record.summary.isEmpty ? [] : [record.summary])
        section("Still open from before", (notes?.stillOpen ?? []).map { "- \($0)" })
        section("Key points", (notes?.keyPoints ?? []).map { "- \($0)" })
        section("Decisions", record.decisions.map { "- \($0)" })
        section("Action items", record.items.map { Self.itemLine($0.item, status: $0.status) })
        section("Open questions", (notes?.openQuestions ?? []).map { "- \($0)" })
        section("Flagged moments", (notes?.flaggedMoments ?? []).map { "- [\(NotesRenderer.clock($0.seconds))] \($0.note)" })
        section("Flags", record.flags.map { "- [\(NotesRenderer.clock($0.offset))] \($0.source.rawValue)" })
        if let brief = record.brief {
            section("Brief", [brief.headline] + brief.points.map { "- \($0)" }
                    + brief.openLoops.map { "- Open: \($0.task) (\($0.owner))" })
        }
        section("Live to-dos", record.live.map { "- \($0.task) (owner \($0.owner); \($0.status.rawValue))" })
        return out
    }

    func searchMeetings(_ arguments: [String: Any]) -> ToolResult {
        guard let query = Self.text(arguments, "query") else { return .failure("Give a query to search for.") }
        let limit = Self.number(arguments, "limit", default: Self.searchDefault, range: 1...Self.searchMax)
        let hits = library.search(query, limit: limit)
        let summary = hits.isEmpty ? "No meetings match." : "\(hits.count) meeting\(hits.count == 1 ? "" : "s") match, best first."
        let body = hits.flatMap { hit in [meetingLine(hit.meeting)] + hit.lines.map { "  " + Self.lineText($0) } }
        let meetings: [[String: Any]] = hits.map { hit in
            var object = meetingObject(hit.meeting)
            object["lines"] = hit.lines.map(Self.lineObject)
            return object
        }
        return ToolResult(text: framed(summary, body), structured: ["meetings": meetings])
    }

    func listActionItems(_ arguments: [String: Any]) -> ToolResult {
        let since: Date?
        switch self.since(arguments, default: Self.itemsSince) {
        case let .success(date): since = date
        case let .failure(problem): return .failure(problem.message)
        }
        let limit = Self.number(arguments, "limit", default: Self.itemsDefault, range: 1...Self.itemsMax)
        let hits = library.actionItems(owner: Self.text(arguments, "owner"), userName: userName, since: since, limit: limit)
        let summary = hits.isEmpty ? "No action items found." : "\(hits.count) action item\(hits.count == 1 ? "" : "s"), newest meeting first."
        let body = hits.map { hit in Self.itemLine(hit.item, status: hit.status) + " from \(hit.meetingTitle) [id \(hit.meetingID)]" }
        let items: [[String: Any]] = hits.map { hit in
            var object = Self.itemObject(hit.item, status: hit.status)
            object["meeting_id"] = hit.meetingID
            object["meeting_title"] = hit.meetingTitle
            object["started_at"] = iso(hit.startedAt)
            return object
        }
        return ToolResult(text: framed(summary, body), structured: ["items": items])
    }

    func meetingPrep(_ arguments: [String: Any]) -> ToolResult {
        let attendee = Self.text(arguments, "attendee"), title = Self.text(arguments, "title")
        guard attendee != nil || title != nil else { return .failure("Give an attendee (a name or an email address), a title, or both.") }
        let now = now()
        let event = attendee.map { person in
            let isAddress = person.contains("@")
            return CalendarEventInfo(id: "mcp-meeting-prep", title: title ?? "", start: now, end: now,
                                     attendees: [Attendee(name: isAddress ? "" : person, email: isAddress ? person : nil)])
        }
        let related = relatedMeetings(event: event, attendee: attendee, title: title, now: now)
        let summary = related.isEmpty ? "No related past meetings found."
            : "\(related.count) related past meeting\(related.count == 1 ? "" : "s"), newest first, with their open items."
        var body: [String] = []
        let meetings: [[String: Any]] = related.map { record in
            let open = record.items.filter { Reminders.isOpen($0.status) }
            body.append(meetingLine(record))
            if !record.summary.isEmpty { body.append("  \(Self.excerpt(record.summary))") }
            body += open.map { "  " + Self.itemLine($0.item, status: $0.status) }
            var object = meetingObject(record)
            object["open_items"] = open.map { Self.itemObject($0.item, status: $0.status) }
            return object
        }
        return ToolResult(text: framed(summary, body), structured: ["meetings": meetings])
    }

    /// The spec 5.4 rules, plus, for a name, past meetings that list a person with that full name: a caller often
    /// knows only the name, and 5.4 matches names only for v1 meetings. Same window and limit, newest first.
    func relatedMeetings(event: CalendarEventInfo?, attendee: String?, title: String?, now: Date) -> [MeetingRecord] {
        let byRules = library.related(to: event, title: title, userName: userName, now: now)
        guard let attendee, !attendee.contains("@") else { return byRules }
        let key = MeetingLibrary.normalizedName(attendee)
        guard !key.isEmpty, key != MeetingLibrary.normalizedName(userName) else { return byRules }
        let byName = library.meetings(since: now.addingTimeInterval(-MeetingLibrary.relatedWindow)).filter { record in
            record.startedAt < now && record.attendees.contains { MeetingLibrary.normalizedName($0.name) == key }
        }
        var seen = Set<String>()
        let merged = (byRules + byName).filter { seen.insert($0.id).inserted }.sorted { $0.startedAt > $1.startedAt }
        return Array(merged.prefix(MeetingLibrary.relatedLimit))
    }
}
