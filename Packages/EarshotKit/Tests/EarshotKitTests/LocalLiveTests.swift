import Foundation
import Testing
@testable import EarshotKit

/// The local model checks run only with EARSHOT_LOCAL_TESTS=1 (`make local-test`), against the server at
/// EARSHOT_LOCAL_URL with the model EARSHOT_LOCAL_MODEL. Unit tests never call a model.
let localTests = ProcessInfo.processInfo.environment["EARSHOT_LOCAL_TESTS"] == "1"

enum LiveLocal {
    static var environment: [String: String] { ProcessInfo.processInfo.environment }

    static var model: String {
        (environment["EARSHOT_LOCAL_MODEL"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// A client of its own gate, so these checks never wait on another suite's calls.
    static func client() throws -> LocalModelClient {
        let address = (environment["EARSHOT_LOCAL_URL"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if let problem = LocalModelClient.addressProblem(address) { throw LocalSetup(message: "EARSHOT_LOCAL_URL: \(problem)") }
        guard !model.isEmpty else { throw LocalSetup(message: "Set EARSHOT_LOCAL_MODEL to the model's name on the server.") }
        let url = try #require(URL(string: address))
        return LocalModelClient(baseURL: url, gate: ClaudeGate())
    }

    /// The client for (c) to (i). The writers fix their own timeouts (the brief 60 s, a live pass 120 s, Ask 180 s),
    /// so each call gets the full 10 minutes here: a slow model fails a check on its answer, never on the clock.
    static func patientClient() throws -> TimeoutFloor {
        TimeoutFloor(inner: try client(), floor: .seconds(600))
    }

    /// Raises every request's timeout to at least `floor`.
    struct TimeoutFloor: ClaudeClient {
        let inner: any ClaudeClient
        let floor: Duration

        func structured(_ request: ClaudeRequest) async throws -> Data {
            var patient = request
            patient.timeout = max(request.timeout, floor)
            return try await inner.structured(patient)
        }
    }

    struct LocalSetup: Error, CustomStringConvertible {
        let message: String
        var description: String { message }
    }
}

/// Real calls to a local OpenAI-compatible server (Ollama, LM Studio, llama.cpp): (a) one structured call, then the
/// same checks (c) to (i) the Claude suite runs, through `LiveScenarios`. Serialized: one call at a time, and local
/// models are slow, so each check gets 10 minutes.
@Suite(.serialized, .enabled(if: localTests, "needs EARSHOT_LOCAL_TESTS=1, EARSHOT_LOCAL_URL and EARSHOT_LOCAL_MODEL"))
struct LocalLiveTests {
    /// (a) The ok schema comes back as one JSON object with ok=true and the word.
    @Test(.timeLimit(.minutes(10))) func localStructuredCallReturnsJSON() async throws {
        let client = try LiveLocal.client()
        var request = LiveClaude.okRequest("earshot")
        request.model = LiveLocal.model
        request.timeout = .seconds(600)
        let started = Date()
        let data = try await client.structured(request)
        let seconds = Int(Date().timeIntervalSince(started))
        verdict("a", "local structured call", LiveClaude.isOK(data, word: "earshot"),
                "server=\(client.baseURL.absoluteString), model=\(LiveLocal.model), answer=\(LiveClaude.json(data)), \(seconds)s")
    }

    /// (c) The action item names Ashley, the proposal and Friday.
    @Test(.timeLimit(.minutes(10))) func notesFindAshleysProposalByFriday() async throws {
        try await LiveScenarios.notesFindAshleysProposalByFriday(client: LiveLocal.patientClient(), model: LiveLocal.model)
    }

    /// (d) Nothing is attributed to an external attendee who wasn't identified.
    @Test(.timeLimit(.minutes(10))) func notesNeverGuessWhichExternalAttendeeSpoke() async throws {
        try await LiveScenarios.notesNeverGuessWhichExternalAttendeeSpoke(client: LiveLocal.patientClient(), model: LiveLocal.model)
    }

    /// (e) A reworded to-do started during the call still links through `live_ref`.
    @Test(.timeLimit(.minutes(10))) func notesLinkARewordedStartedItemThroughLiveRef() async throws {
        try await LiveScenarios.notesLinkARewordedStartedItemThroughLiveRef(client: LiveLocal.patientClient(), model: LiveLocal.model)
    }

    /// (f) Live to-dos fed in three stages, updated by ref.
    @Test(.timeLimit(.minutes(10))) func liveExtractionAcrossStagesUpdatesByRef() async throws {
        try await LiveScenarios.liveExtractionAcrossStagesUpdatesByRef(client: LiveLocal.patientClient(), model: LiveLocal.model)
    }

    /// (g) The brief from fixture history.
    @Test(.timeLimit(.minutes(10))) func briefFromFixtureHistory() async throws {
        try await LiveScenarios.briefFromFixtureHistory(client: LiveLocal.patientClient(), model: LiveLocal.model)
    }

    /// (h) Ask answers with a [mm:ss] time.
    @Test(.timeLimit(.minutes(10))) func askAnswersWithATime() async throws {
        try await LiveScenarios.askAnswersWithATime(client: LiveLocal.patientClient(), model: LiveLocal.model)
    }

    /// (i) Fix applies an instruction and keeps everything else.
    @Test(.timeLimit(.minutes(10))) func fixAppliesTheInstruction() async throws {
        try await LiveScenarios.fixAppliesTheInstruction(client: LiveLocal.patientClient(), model: LiveLocal.model)
    }
}

/// Unit test, no model: the 10 minutes the local checks allow reach every call, whatever timeout the writer set.
struct LocalLiveSetupTests {
    private struct Timer: ClaudeClient {
        let seen: Locked<[Duration]>

        func structured(_ request: ClaudeRequest) async throws -> Data {
            seen.update { $0.append(request.timeout) }
            return Data("{}".utf8)
        }
    }

    @Test func everyCallInTheLocalChecksGetsTenMinutes() async throws {
        let seen = Locked<[Duration]>([])
        let client = LiveLocal.TimeoutFloor(inner: Timer(seen: seen), floor: .seconds(600))
        for writer in [BriefWriter.timeout, LivePrompt.timeout, MeetingQA.timeout, .seconds(900)] {
            _ = try await client.structured(ClaudeRequest(role: .ask, system: "s", user: "u", schema: "{}", model: "m",
                                                          effort: "low", timeout: writer))
        }
        #expect(seen.get == [.seconds(600), .seconds(600), .seconds(600), .seconds(900)])
    }
}
