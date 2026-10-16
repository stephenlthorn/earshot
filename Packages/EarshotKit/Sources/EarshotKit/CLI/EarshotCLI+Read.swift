import Foundation

/// `list`, `show`, `search`, `items` and `reminders`: they read the index (spec 11.1), and only `show --transcript`
/// falls back to the meeting folder. AI apps run these commands themselves, so, as in MCP, everything they print
/// has full email addresses replaced by their domain (spec 2).
extension EarshotCLI {
    static let listSince = "7d"
    static let itemsSince = "14d"

    /// `earshot show --json`.
    struct ShowOutput: Codable, Equatable {
        var meeting: MeetingRecord
        var transcript: [TranscriptLine]?
    }

    /// One `earshot search --json` hit.
    struct SearchOutput: Codable, Equatable {
        var meeting: MeetingRecord
        var lines: [TranscriptLine]
    }

    /// One `earshot items --json` row.
    struct ItemOutput: Codable, Equatable {
        var meetingID: String
        var meetingTitle: String
        var startedAt: Date
        var task: String
        var owner: String
        var due: String?
        var doer: ActionItem.Doer
        var status: String
    }

    static func list(_ arguments: Arguments, io: IO) throws -> Int32 {
        let context = Context(arguments, io: io)
        let since = try sinceDate(arguments.options["since"] ?? listSince, io: io)
        let limit = try count(arguments.options["limit"], name: "limit")
        let records = context.library.meetings(since: since, limit: limit)
        if arguments.has("json") {
            io.out(try readJSON(records))
        } else if records.isEmpty {
            say(io, "No meetings found.\n")
        } else {
            say(io, records.map { line($0, timeZone: io.timeZone) }.joined(separator: "\n") + "\n")
        }
        return 0
    }

    static func show(_ arguments: Arguments, io: IO) throws -> Int32 {
        guard arguments.positionals.count == 1, let id = arguments.positionals.first else {
            throw UsageError("show needs one meeting: an id, a folder name or latest.")
        }
        let context = Context(arguments, io: io)
        guard let record = context.library.meeting(id: id) else {
            io.err("earshot: \(LibraryError.notFound(id).errorDescription ?? "")\n")
            return 1
        }
        var transcript: [TranscriptLine]?
        if arguments.has("transcript") {
            do {
                transcript = try context.library.transcript(of: record)
            } catch let error as LibraryError {
                io.err("earshot: \(error.message(app: context.app))\n")
                return 1
            }
        }
        if arguments.has("json") {
            io.out(try readJSON(ShowOutput(meeting: record, transcript: transcript)))
            return 0
        }
        var lines = MCPServer.meetingBody(record, timeZone: io.timeZone)
        lines.insert("id \(record.id), folder \(record.folder)", at: 2)
        if let transcript {
            lines += ["", "## Transcript"] + (transcript.isEmpty ? ["(no transcript)"] : transcript.map(MCPServer.lineText))
        }
        say(io, lines.joined(separator: "\n") + "\n")
        return 0
    }

    static func search(_ arguments: Arguments, io: IO) throws -> Int32 {
        let query = arguments.positionals.joined(separator: " ").trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { throw UsageError("search needs words to look for.") }
        let limit = try count(arguments.options["limit"], name: "limit") ?? 10
        let hits = Context(arguments, io: io).library.search(query, limit: limit)
        if arguments.has("json") {
            io.out(try readJSON(hits.map { SearchOutput(meeting: $0.meeting, lines: $0.lines) }))
        } else if hits.isEmpty {
            say(io, "No meetings match.\n")
        } else {
            let lines = hits.flatMap { hit in [line(hit.meeting, timeZone: io.timeZone)] + hit.lines.map { "  " + MCPServer.lineText($0) } }
            say(io, lines.joined(separator: "\n") + "\n")
        }
        return 0
    }

    static func items(_ arguments: Arguments, io: IO) throws -> Int32 {
        let context = Context(arguments, io: io)
        let since = try sinceDate(arguments.options["since"] ?? itemsSince, io: io)
        let hits = context.library.actionItems(owner: arguments.options["owner"], userName: context.settings.userName,
                                               since: since)
        if arguments.has("json") {
            io.out(try readJSON(hits.map {
                ItemOutput(meetingID: $0.meetingID, meetingTitle: $0.meetingTitle, startedAt: $0.startedAt, task: $0.item.task,
                           owner: $0.item.owner, due: $0.item.due, doer: $0.item.doer, status: $0.status)
            }))
        } else if hits.isEmpty {
            say(io, "No action items found.\n")
        } else {
            let lines = hits.map { MCPServer.itemLine($0.item, status: $0.status) + " from \($0.meetingTitle) [\($0.meetingID)]" }
            say(io, lines.joined(separator: "\n") + "\n")
        }
        return 0
    }

    /// Up to five of the user's own items from the last seven days, from reminders.json or else the index. The
    /// text is cleaned again here, whatever wrote the file. Prints nothing when there are none and always exits 0,
    /// because a session-start hook runs it.
    static func reminders(_ words: ArraySlice<String>, io: IO) -> Int32 {
        let arguments = (try? Arguments.parse(words)) ?? Arguments()
        let context = Context(arguments, io: io)
        let now = io.now()
        let saved = context.index.reminders()?.items
        let items = saved ?? Reminders.compute(context.index.entries().map(\.record), userName: context.settings.userName,
                                               now: now).items
        let clean = items.filter { $0.startedAt <= now && $0.startedAt >= now.addingTimeInterval(-Reminders.window) }
            .compactMap { item -> Reminders.Reminder? in
                let task = Reminders.clean(item.task)
                guard !task.isEmpty else { return nil }
                let due = item.due.map(Reminders.clean).flatMap { $0.isEmpty ? nil : $0 }
                return Reminders.Reminder(task: task, due: due, meeting: Reminders.clean(item.meeting),
                                          meetingID: item.meetingID, startedAt: item.startedAt)
            }
        say(io, Reminders(createdAt: now, items: Array(clean.prefix(Reminders.maxItems))).text)
        return 0
    }

    /// Read output for people and AI apps alike, with full addresses as their domain.
    static func say(_ io: IO, _ text: String) {
        io.out(MCPServer.scrub(text, keep: nil))
    }

    /// `--json` read output with full addresses as their domain. Rewritten only when it holds an address, because
    /// scrubbing the encoded text could break its escapes.
    static func readJSON(_ value: some Encodable) throws -> String {
        let text = try json(value)
        guard text.contains("@") else { return text }
        let object = try JSONSerialization.jsonObject(with: Data(text.utf8), options: .fragmentsAllowed)
        let data = try JSONSerialization.data(withJSONObject: MCPServer.scrub(object, keep: nil),
                                              options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes, .fragmentsAllowed])
        return String(decoding: data, as: UTF8.self) + "\n"
    }

    static func line(_ record: MeetingRecord, timeZone: TimeZone) -> String {
        "\(record.id)  \(MCPServer.local(record.startedAt, timeZone))  \(NotesRenderer.lengthText(record.duration))  \(record.title)"
    }

    static func sinceDate(_ text: String?, io: IO) throws -> Date? {
        guard let text else { return nil }
        guard let date = MeetingLibrary.parseSince(text, now: io.now(), timeZone: io.timeZone) else {
            throw UsageError("Couldn't read --since \(text). Use 7d, 2w, 24h or a date like 2026-10-01.")
        }
        return date
    }

    static func count(_ text: String?, name: String) throws -> Int? {
        guard let text else { return nil }
        guard let value = Int(text), value > 0 else { throw UsageError("--\(name) needs a whole number above 0.") }
        return value
    }
}
