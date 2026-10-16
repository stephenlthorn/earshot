import Foundation

/// Meeting notes through any `ClaudeClient`: the user's Claude Code or their API key.
public struct ClaudeNotesWriter: NotesWriter {
    public static let maxTokens = 20_000

    public var client: any ClaudeClient
    public var model: String
    public var effort: String

    public init(client: any ClaudeClient, model: String = "claude-opus-5-5", effort: String = "medium") {
        self.client = client
        self.model = model
        self.effort = effort
    }

    public func request(for notes: NotesRequest) -> ClaudeRequest {
        ClaudeRequest(role: .notes, system: NotesPrompt.system(notes), user: NotesPrompt.user(notes),
                      schema: NotesSchema.json, model: model, effort: effort, maxTokens: Self.maxTokens)
    }

    public func write(_ request: NotesRequest) async throws -> MeetingNotes {
        let data = try await client.structured(self.request(for: request))
        guard let notes = try? JSONDecoder().decode(MeetingNotes.self, from: data) else {
            throw NotesError.badOutput("it did not match the notes format")
        }
        return notes
    }
}
