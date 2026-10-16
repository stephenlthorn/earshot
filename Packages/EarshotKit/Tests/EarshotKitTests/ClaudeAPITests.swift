import Foundation
import Testing
@testable import EarshotKit

struct ClaudeAPITests {
    func client(_ url: URL, key: String? = "sk-test") -> ClaudeAPIClient {
        ClaudeAPIClient(apiKey: { key }, endpoint: url, session: StubHTTP.session, sleep: { _ in })
    }

    func writer(_ url: URL, key: String? = "sk-test") -> ClaudeNotesWriter {
        ClaudeNotesWriter(client: client(url, key: key), model: "claude-opus-5-5", effort: "medium")
    }

    @Test func sendsTheSchemaAndReadsTheTextBlock() async throws {
        let url = StubHTTP.url(replies: [(200, apiReply())])
        let notes = try await writer(url).write(sampleRequest)
        #expect(notes == sampleNotes)
        let sent = try #require(StubHTTP.requests(url).first)
        #expect(sent.httpMethod == "POST")
        #expect(sent.value(forHTTPHeaderField: "x-api-key") == "sk-test")
        #expect(sent.value(forHTTPHeaderField: "anthropic-version") == "2023-06-01")
        let body = try #require(try JSONSerialization.jsonObject(with: sent.httpBody ?? Data()) as? [String: Any])
        #expect(body["model"] as? String == "claude-opus-5-5")
        #expect(body["max_tokens"] as? Int == 20_000)
        #expect(body["thinking"] == nil)
        let config = try #require(body["output_config"] as? [String: Any])
        #expect(config["effort"] as? String == "medium")
        let format = try #require(config["format"] as? [String: Any])
        #expect(format["type"] as? String == "json_schema")
        #expect(NSDictionary(dictionary: try #require(format["schema"] as? [String: Any]))
                .isEqual(to: try #require(try JSONSerialization.jsonObject(with: Data(NotesSchema.json.utf8)) as? [String: Any])))
        #expect((body["system"] as? String)?.contains("\"Stephen\"") == true)
        let messages = try #require(body["messages"] as? [[String: Any]])
        #expect((messages[0]["content"] as? String)?.contains("I'll send the scope by Friday") == true)
    }

    @Test func retriesOverloadThenSucceeds() async throws {
        let url = StubHTTP.url(replies: [(529, apiError), (429, apiError), (200, apiReply())])
        #expect(try await writer(url).write(sampleRequest) == sampleNotes)
        #expect(StubHTTP.requests(url).count == 3)
    }

    @Test func stopsWhenTheRetriesRunOut() async {
        let url = StubHTTP.url(replies: [(500, apiError), (500, apiError), (500, apiError)])
        await #expect(throws: NotesError.http(status: 500, message: "boom")) { try await writer(url).write(sampleRequest) }
    }

    @Test func aBadKeyIsNamedAndNotRetried() async {
        let url = StubHTTP.url(replies: [(401, apiError)])
        await #expect(throws: NotesError.badKey) { try await writer(url).write(sampleRequest) }
        #expect(StubHTTP.requests(url).count == 1)
    }

    @Test func refusalAndTruncationAreFailures() async {
        let refused = StubHTTP.url(replies: [(200, apiReply(stop: "refusal"))])
        await #expect(throws: NotesError.refused) { try await writer(refused).write(sampleRequest) }
        let cut = StubHTTP.url(replies: [(200, apiReply(stop: "max_tokens"))])
        await #expect(throws: NotesError.truncated) { try await writer(cut).write(sampleRequest) }
    }

    @Test func noKeyFailsWithoutCallingTheAPI() async {
        let url = StubHTTP.url(replies: [])
        await #expect(throws: NotesError.missingKey) { try await writer(url, key: "  ").write(sampleRequest) }
        #expect(StubHTTP.requests(url).isEmpty)
    }

    @Test func aStructuredCallSendsItsOwnModelEffortAndLimit() async throws {
        let url = StubHTTP.url(replies: [(200, apiReply())])
        let request = ClaudeRequest(role: .brief, system: "Brief", user: "<agenda>x</agenda>",
                                    schema: #"{"type":"object"}"#, model: "claude-sonnet-5-5", effort: "low", maxTokens: 900,
                                    timeout: .seconds(45))
        _ = try await client(url).structured(request)
        let sent = try #require(StubHTTP.requests(url).first)
        #expect(sent.timeoutInterval == 45)
        let body = try #require(try JSONSerialization.jsonObject(with: sent.httpBody ?? Data()) as? [String: Any])
        #expect(body["model"] as? String == "claude-sonnet-5-5" && body["max_tokens"] as? Int == 900)
        #expect(body["system"] as? String == "Brief")
        #expect((body["output_config"] as? [String: Any])?["effort"] as? String == "low")
    }

    @Test func aModelTheKeyCantUseIsNamed() async {
        let notFound = #"{"type":"error","error":{"type":"not_found_error","message":"model: claude-nope not found"}}"#
        let url = StubHTTP.url(replies: [(404, notFound)])
        await #expect(throws: NotesError.modelUnavailable("claude-opus-5-5")) { try await writer(url).write(sampleRequest) }
        #expect(StubHTTP.requests(url).count == 1)
    }

    @Test func textThatIsNotJSONIsBadOutput() async {
        let reply = #"{"content":[{"type":"text","text":"Sorry, no."}],"stop_reason":"end_turn"}"#
        let url = StubHTTP.url(replies: [(200, reply)])
        await #expect(throws: NotesError.badOutput("Sorry, no.")) { try await writer(url).write(sampleRequest) }
    }

    @Test func promptCarriesStyleAndExtraInstructions() {
        var request = sampleRequest
        request.style = .salesCall
        request.extraInstructions = "Use British spelling."
        let system = NotesPrompt.system(request)
        #expect(system.contains("sales call") && system.contains("Use British spelling."))
        #expect(NotesPrompt.user(request).contains("<transcript>\n[00:00:01] Stephen:"))
        #expect(NotesPrompt.user(request).contains("Wed 14 Oct 2026, 15:30"))
    }
}
