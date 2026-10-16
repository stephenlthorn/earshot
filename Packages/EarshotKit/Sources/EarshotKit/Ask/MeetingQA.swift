import Foundation

/// Answers a question about one meeting from its transcript, notes and flags, with the quick model at medium effort
/// (spec 8). Answers quote times as [mm:ss].
public struct MeetingQA: Sendable {
    /// The transcript sent with a question (or a fix) is clipped to this many characters.
    public static let transcriptLimit = 300_000
    public static let effort = "medium"
    public static let maxTokens = 4_000
    public static let timeout: Duration = .seconds(180)

    public static let schema = #"""
    {"type":"object","additionalProperties":false,"required":["answer"],
     "properties":{"answer":{"type":"string","description":"The answer in plain text, quoting times as [mm:ss]"}}}
    """#

    public static let system = [
        "You answer questions about one meeting, using only its transcript, its notes and the moments the user flagged.",
        "",
        "Rules:",
        "- When you rely on something that was said, quote its time from the transcript as [mm:ss].",
        "- Never invent names, dates, numbers or commitments. If the meeting doesn't answer the question, say so.",
        "- Answer in a few short sentences or a short list, in plain text.",
        "",
        PromptFraming.standardRule,
    ].joined(separator: "\n")

    public var client: any ClaudeClient
    public var model: String

    public init(client: any ClaudeClient, model: String = "claude-sonnet-5-5") {
        self.client = client
        self.model = model
    }

    public func request(question: String, notes: MeetingNotes?, transcript: [TranscriptLine],
                        flags: [Flag]) -> ClaudeRequest {
        // The question goes last, after the long meeting text, where the model answers it best.
        let parts = (notes.map { [Self.notesBlock($0)] } ?? [])
            + (Self.flagsBlock(flags).map { [$0] } ?? [])
            + Self.transcriptBlocks(transcript)
            + ["Question: \(question.trimmingCharacters(in: .whitespacesAndNewlines))"]
        return ClaudeRequest(role: .ask, system: Self.system, user: parts.joined(separator: "\n\n"),
                             schema: Self.schema, model: model, effort: Self.effort, maxTokens: Self.maxTokens,
                             timeout: Self.timeout)
    }

    /// The answer, trimmed. A blank answer is `NotesError.badOutput`.
    public func ask(question: String, notes: MeetingNotes?, transcript: [TranscriptLine],
                    flags: [Flag] = []) async throws -> String {
        let reply = try await client.decode(Reply.self, request(question: question, notes: notes,
                                                                transcript: transcript, flags: flags))
        let answer = reply.answer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !answer.isEmpty else { throw NotesError.badOutput("the answer was empty") }
        return answer
    }

    struct Reply: Decodable { let answer: String }

    // MARK: Shared with NotesFixer

    /// `text` cut to at most `limit` characters, at the end of a line when there is one to cut at.
    public static func clip(_ text: String, limit: Int = transcriptLimit) -> String {
        guard text.count > limit else { return text }
        let head = text.prefix(limit)
        guard let newline = head.lastIndex(of: "\n") else { return String(head) }
        return String(head[...newline])
    }

    /// The transcript as "[mm:ss] Speaker: text" lines inside `<transcript>`, and a line saying so when it was
    /// clipped. The limit counts the framed text (framing tags in it already defused), so it holds for what is sent.
    static func transcriptBlocks(_ lines: [TranscriptLine]) -> [String] {
        let text = lines.map { "[\(NotesRenderer.clock($0.start))] \($0.speaker): \($0.text)\n" }.joined()
        let framed = PromptFraming.escape(text, extra: .transcript)
        let clipped = clip(framed)
        let block = PromptFraming.wrap(tag: .transcript, text: clipped)
        guard clipped.count < framed.count else { return [block] }
        return [block, "The transcript was clipped to its first \(clipped.count) characters; the rest of the meeting is not shown."]
    }

    /// The notes as JSON inside `<meeting_notes>`. The code-side `source` field is left out.
    static func notesBlock(_ notes: MeetingNotes) -> String {
        var notes = notes
        notes.actionItems = notes.actionItems.map { item in
            var item = item
            item.source = nil
            return item
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let json = (try? encoder.encode(notes)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
        return PromptFraming.wrap(tag: .meetingNotes, text: json)
    }

    /// "Flag at mm:ss" lines inside `<flagged_moments>`, or nil when there are no flags.
    static func flagsBlock(_ flags: [Flag]) -> String? {
        guard !flags.isEmpty else { return nil }
        let lines = flags.sorted { $0.offset < $1.offset }.map { "Flag at \(NotesRenderer.clock($0.offset))" }
        return PromptFraming.wrap(tag: .flaggedMoments, text: lines.joined(separator: "\n"))
    }
}
