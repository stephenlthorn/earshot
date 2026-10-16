import Foundation
import Testing
@testable import EarshotKit

/// A chat completion as an OpenAI-compatible server sends it. `content` is any JSON value: text, or a list of parts.
func chatReply(_ content: Any, finish: String = "stop", refusal: Any = NSNull(), reasoning: String? = nil,
               promptTokens: Int? = nil) -> String {
    var message: [String: Any] = ["role": "assistant", "content": content, "refusal": refusal]
    if let reasoning { message["reasoning_content"] = reasoning }
    var object: [String: Any] = ["id": "chatcmpl-1", "object": "chat.completion", "model": "qwen3-8b",
                                 "choices": [["index": 0, "finish_reason": finish, "message": message]]]
    if let promptTokens { object["usage"] = ["prompt_tokens": promptTokens, "completion_tokens": 9, "total_tokens": promptTokens + 9] }
    return String(decoding: try! JSONSerialization.data(withJSONObject: object), as: UTF8.self)
}

/// The sample notes as the JSON text a model writes.
let notesText = String(decoding: try! JSONEncoder().encode(sampleNotes), as: UTF8.self)

private let okSchema = #"{"type":"object","required":["ok"],"properties":{"ok":{"type":"boolean"}}}"#

private func request(_ role: ClaudeRole = .ask, timeout: Duration = .seconds(600), user: String = "<transcript>hi</transcript>",
                     maxTokens: Int = 900) -> ClaudeRequest {
    ClaudeRequest(role: role, system: "Be brief.", user: user, schema: okSchema,
                  model: "qwen3:8b", effort: "low", maxTokens: maxTokens, timeout: timeout)
}

private func client(_ url: URL, gate: ClaudeGate = ClaudeGate(), delays: [Duration] = [.seconds(2)],
                    slept: Locked<[Duration]>? = nil) -> LocalModelClient {
    LocalModelClient(baseURL: url, session: StubHTTP.session, gate: gate, retryDelays: delays,
                     sleep: { duration in slept?.update { $0.append(duration) } })
}

private func body(_ sent: URLRequest) throws -> [String: Any] {
    try #require(try JSONSerialization.jsonObject(with: sent.httpBody ?? Data()) as? [String: Any])
}

private func answer(_ content: Any) async throws -> String {
    let url = StubHTTP.url(path: "/v1", replies: [(200, chatReply(content))])
    return String(decoding: try await client(url).structured(request()), as: UTF8.self)
}

struct LocalModelClientTests {
    @Test func sendsTheExactChatCompletionBody() async throws {
        let url = StubHTTP.url(path: "/v1", replies: [(200, chatReply(#"{"ok":true}"#))])
        let data = try await client(url).structured(request(timeout: .seconds(45)))
        #expect(String(decoding: data, as: UTF8.self) == #"{"ok":true}"#)
        let sent = try #require(StubHTTP.requests(url).first)
        #expect(sent.httpMethod == "POST" && sent.url?.path() == "/v1/chat/completions")
        #expect(sent.timeoutInterval == 300, "an ask call gets the local floor of 5 minutes")
        #expect(sent.value(forHTTPHeaderField: "content-type") == "application/json")
        for header in ["Authorization", "x-api-key", "anthropic-version"] {
            #expect(sent.value(forHTTPHeaderField: header) == nil, "\(header)")
        }
        let object = try body(sent)
        #expect(Set(object.keys) == ["model", "messages", "response_format", "temperature", "max_tokens", "stream"])
        #expect(object["model"] as? String == "qwen3:8b")
        #expect(object["temperature"] as? Double == 0.2 && object["max_tokens"] as? Int == 900)
        #expect(object["stream"] as? Bool == false)
        let messages = try #require(object["messages"] as? [[String: String]])
        #expect(messages.map { $0["role"] } == ["system", "user"])
        #expect(messages[0]["content"] == "Be brief.\n\n" + LocalModelClient.schemaInstruction + "\n" + okSchema)
        #expect(LocalModelClient.schemaInstruction == "Reply with one JSON object that matches this JSON Schema, and nothing else:")
        #expect(messages[1]["content"] == "<transcript>hi</transcript>")
        let format = try #require(object["response_format"] as? [String: Any])
        #expect(format["type"] as? String == "json_schema")
        let schema = try #require(format["json_schema"] as? [String: Any])
        #expect(schema["name"] as? String == "earshot" && schema["strict"] as? Bool == true)
        let expected = try #require(try JSONSerialization.jsonObject(with: Data(okSchema.utf8)) as? [String: Any])
        #expect(NSDictionary(dictionary: try #require(schema["schema"] as? [String: Any])).isEqual(to: expected))
    }

    @Test func joinsThePathWithOrWithoutATrailingSlash() async throws {
        for path in ["/v1", "/v1/", "/v1//"] {
            let url = StubHTTP.url(path: path, replies: [(200, chatReply(#"{"ok":true}"#))])
            _ = try await client(url).structured(request())
            #expect(StubHTTP.requests(url).first?.url?.path() == "/v1/chat/completions", "\(path)")
        }
        #expect(LocalModelClient.endpoint(URL(string: "http://localhost:1234")!, "models").absoluteString
                == "http://localhost:1234/models")
    }

    @Test func readsTheObjectOutOfWhateverTheModelWrapsItIn() async throws {
        #expect(try await answer(#"{"ok":true}"#) == #"{"ok":true}"#)
        #expect(try await answer("```json\n{\"ok\":true}\n```") == #"{"ok":true}"#)
        #expect(try await answer("```\n{\"ok\":true}\n```\n") == #"{"ok":true}"#)
        #expect(try await answer("<think>\nThe user wants {ok}.\n</think>\n\n{\"ok\":true}") == #"{"ok":true}"#)
        #expect(try await answer("<THINK>a</THINK><think>b {x}</think> {\"ok\":true}") == #"{"ok":true}"#)
        #expect(try await answer("Here it is:\n{\"ok\":true}\nHope that helps.") == #"{"ok":true}"#)
        #expect(try await answer([["type": "text", "text": "{\"ok\":"], ["type": "text", "text": "true}"]]) == #"{"ok":true}"#)
        // The template opened <think> in the prompt, so the reply has only the closing tag.
        #expect(try await answer("The user wants {ok}. Draft: {\"ok\":false}\n</think>\n\n{\"ok\":true}") == #"{"ok":true}"#)
        #expect(try await answer("```json {\"ok\":true}```") == #"{"ok":true}"#)
        #expect(try await answer("``` {\"ok\":true} ```") == #"{"ok":true}"#)
    }

    @Test func theReasoningIsIgnored() async throws {
        let url = StubHTTP.url(path: "/v1", replies: [(200, chatReply(#"{"ok":true}"#, reasoning: #"{"ok":false}"#))])
        #expect(String(decoding: try await client(url).structured(request()), as: UTF8.self) == #"{"ok":true}"#)
    }

    @Test func aCutOffAnswerOrARefusalIsAFailure() async {
        let cut = StubHTTP.url(path: "/v1", replies: [(200, chatReply(#"{"ok":"#, finish: "length"))])
        await #expect(throws: NotesError.truncated) { try await client(cut).structured(request()) }
        let refused = StubHTTP.url(path: "/v1", replies: [(200, chatReply("", refusal: "I can't help with that."))])
        await #expect(throws: NotesError.refused) { try await client(refused).structured(request()) }
    }

    @Test func textThatIsNotAnObjectIsBadOutput() async {
        for content in ["Sorry, no.", "[1, 2]", "{not json}"] {
            let url = StubHTTP.url(path: "/v1", replies: [(200, chatReply(content))])
            await #expect(throws: NotesError.badOutput(content)) { try await client(url).structured(request()) }
        }
        let long = String(repeating: "x", count: 500)
        let url = StubHTTP.url(path: "/v1", replies: [(200, chatReply(long))])
        await #expect(throws: NotesError.badOutput(String(long.prefix(200)))) { try await client(url).structured(request()) }
    }

    @Test func aServerWithoutStructuredOutputsGetsTheSameRequestWithoutTheFormat() async throws {
        let unsupported = #"{"error":{"message":"response_format type json_schema is not supported","type":"invalid_request_error"}}"#
        let url = StubHTTP.url(path: "/v1", replies: [(400, unsupported), (200, chatReply(#"{"ok":true}"#))])
        #expect(String(decoding: try await client(url).structured(request()), as: UTF8.self) == #"{"ok":true}"#)
        let sent = StubHTTP.requests(url)
        #expect(sent.count == 2)
        let first = try body(sent[0]), second = try body(sent[1])
        #expect(first["response_format"] != nil && second["response_format"] == nil)
        var trimmed = first
        trimmed["response_format"] = nil
        #expect(NSDictionary(dictionary: trimmed).isEqual(to: second))
    }

    @Test func theRequestWithoutTheFormatIsSentOnlyOnce() async throws {
        let unsupported = #"{"error":{"message":"response_format type json_schema is not supported"}}"#
        let url = StubHTTP.url(path: "/v1", replies: [(400, unsupported), (400, unsupported), (200, chatReply(#"{"ok":true}"#))])
        await #expect(throws: NotesError.local("The local model server returned 400: response_format type json_schema is not supported")) {
            try await client(url).structured(request())
        }
        let sent = StubHTTP.requests(url)
        #expect(sent.count == 2)
        #expect(try body(sent[1])["response_format"] == nil)
    }

    @Test func aMeetingTooLongForTheContextSaysSo() async {
        let llama = #"{"error":{"code":400,"message":"the request exceeds the available context size, try increasing it","type":"exceed_context_size_error"}}"#
        let lmStudio = #"{"error":"Trying to keep the first 9000 tokens when context the overflows. Context length is too long"}"#
        for (status, reply) in [(400, llama), (413, lmStudio)] {
            let url = StubHTTP.url(path: "/v1", replies: [(status, reply)])
            await #expect(throws: NotesError.local(LocalModelClient.contextTooSmall)) { try await client(url).structured(request()) }
            #expect(StubHTTP.requests(url).count == 1)
        }
        #expect(LocalModelClient.contextTooSmall == "The meeting is longer than the local model's context window. Give the model a bigger context (see the local models guide) or use a bigger model.")
    }

    @Test func aContextErrorIsTriedOnceMoreWithASmallerAnswer() async throws {
        let vllm = #"{"object":"error","message":"This model's maximum context length is 16384 tokens. However, you requested 17000 tokens (1000 in the messages, 16000 in the completion).","code":400}"#
        let fits = StubHTTP.url(path: "/v1", replies: [(400, vllm), (200, chatReply(#"{"ok":true}"#))])
        _ = try await client(fits).structured(request(maxTokens: 16_000))
        let sent = StubHTTP.requests(fits)
        #expect(sent.count == 2)
        #expect(try body(sent[0])["max_tokens"] as? Int == 16_000 && body(sent[1])["max_tokens"] as? Int == LocalModelClient.smallAnswer)
        let never = StubHTTP.url(path: "/v1", replies: [(400, vllm), (400, vllm), (200, chatReply(#"{"ok":true}"#))])
        await #expect(throws: NotesError.local(LocalModelClient.contextTooSmall)) {
            try await client(never).structured(request(maxTokens: 16_000))
        }
        #expect(StubHTTP.requests(never).count == 2)
    }

    @Test func aPromptTheServerCutShortIsAContextProblem() async throws {
        // Ollama keeps only num_ctx tokens of a long prompt and answers 200: usage.prompt_tokens gives it away.
        let meeting = String(repeating: "Ashley: we ship the proposal by Friday. ", count: 2_000)
        let cut = StubHTTP.url(path: "/v1", replies: [(200, chatReply(#"{"ok":true}"#, promptTokens: 4096))])
        await #expect(throws: NotesError.local(LocalModelClient.contextTooSmall)) {
            try await client(cut).structured(request(user: meeting))
        }
        let whole = StubHTTP.url(path: "/v1", replies: [(200, chatReply(#"{"ok":true}"#, promptTokens: 20_000))])
        #expect(String(decoding: try await client(whole).structured(request(user: meeting)), as: UTF8.self) == #"{"ok":true}"#)
        let short = StubHTTP.url(path: "/v1", replies: [(200, chatReply(#"{"ok":true}"#, promptTokens: 60))])
        _ = try await client(short).structured(request())
        let unknown = StubHTTP.url(path: "/v1", replies: [(200, chatReply(#"{"ok":true}"#, promptTokens: 0))])
        _ = try await client(unknown).structured(request(user: meeting))
    }

    @Test func aModelTheServerDoesntHaveIsNamed() async {
        let missing = NotesError.local("The local server has no model named \"qwen3:8b\". Pick one in Settings, Claude.")
        let ollama = #"{"error":{"message":"model \"qwen3:8b\" not found, try pulling it first","type":"api_error"}}"#
        let vllm = #"{"object":"error","message":"The model `qwen3:8b` does not exist.","type":"NotFoundError","code":404}"#
        for (status, reply) in [(404, ollama), (404, vllm), (400, #"{"error":"model 'qwen3:8b' not found"}"#)] {
            let url = StubHTTP.url(path: "/v1", replies: [(status, reply)])
            await #expect(throws: missing) { try await client(url).structured(request()) }
        }
    }

    @Test func anAddressWithoutTheChatEndpointSaysToCheckV1() async throws {
        // Ollama's own address without /v1 answers its plain 404 page.
        let url = StubHTTP.url(path: "", replies: [(404, "404 page not found")])
        await #expect(throws: NotesError.local("The local model server at \(url.absoluteString) has no chat endpoint. Check that the address ends in /v1.")) {
            try await client(url).structured(request())
        }
        #expect(StubHTTP.requests(url).count == 1)
    }

    @Test func aRedirectIsNeverFollowed() async throws {
        let elsewhere = "http://leak-\(UUID().uuidString.lowercased()).example.com/v1/chat/completions"
        let url = StubHTTP.url(path: "/v1", replies: [(307, elsewhere), (200, chatReply(#"{"ok":true}"#))])
        let host = try #require(url.host())
        await #expect(throws: NotesError.local("The local model server at \(host) redirected to another address. Earshot doesn't follow redirects; fix the address in Settings, Claude.")) {
            try await client(url).structured(request())
        }
        #expect(StubHTTP.requests(url).count == 1)
        #expect(StubHTTP.requests(try #require(URL(string: elsewhere))).isEmpty)
    }

    @Test func aServerThatWantsAKeyIsNamedAndNotRetried() async throws {
        for status in [401, 403] {
            let url = StubHTTP.url(path: "/v1", replies: [(status, #"{"error":"unauthorized"}"#)])
            let host = try #require(url.host())
            await #expect(throws: NotesError.local("The server at \(host) asked for an API key. Earshot's local model setting is for servers that run without one.")) {
                try await client(url).structured(request())
            }
            #expect(StubHTTP.requests(url).count == 1)
        }
    }

    @Test func overloadAndServerErrorsAreRetriedThenNamed() async throws {
        let busy = StubHTTP.url(path: "/v1", replies: [(503, #"{"error":"loading model"}"#), (200, chatReply(#"{"ok":true}"#))])
        _ = try await client(busy).structured(request())
        #expect(StubHTTP.requests(busy).count == 2)
        let boom = (500, #"{"error":{"message":"boom"}}"#)
        let slept = Locked<[Duration]>([])
        let thrice = StubHTTP.url(path: "/v1", replies: [boom, boom, boom, (200, chatReply(#"{"ok":true}"#))])
        await #expect(throws: NotesError.local("The local model server returned 500: boom")) {
            try await client(thrice, delays: [.seconds(1), .seconds(3)], slept: slept).structured(request())
        }
        #expect(slept.get == [.seconds(1), .seconds(3)])
        #expect(StubHTTP.requests(thrice).count == 3)
        let broken = StubHTTP.url(path: "/v1", replies: [(500, #"{"error":{"message":"boom"}}"#), (500, #"{"error":{"message":"boom"}}"#)])
        await #expect(throws: NotesError.local("The local model server returned 500: boom")) { try await client(broken).structured(request()) }
        #expect(StubHTTP.requests(broken).count == 2)
        let plain = StubHTTP.url(path: "/v1", replies: [(429, "Too many requests")])
        await #expect(throws: NotesError.local("The local model server returned 429: Too many requests")) {
            try await client(plain, delays: []).structured(request())
        }
        let other = StubHTTP.url(path: "/v1", replies: [(400, #"{"error":"bad temperature"}"#)])
        await #expect(throws: NotesError.local("The local model server returned 400: bad temperature")) { try await client(other).structured(request()) }
        #expect(StubHTTP.requests(other).count == 1)
    }

    @Test func aServerThatIsntRunningIsUnreachable() async throws {
        for code in [URLError.Code.cannotConnectToHost, .cannotFindHost, .networkConnectionLost, .notConnectedToInternet, .dnsLookupFailed] {
            let url = StubHTTP.url(path: "/v1", replies: [(code.rawValue, "")])
            await #expect(throws: NotesError.local("Can't reach the local model server at \(url.absoluteString). Start Ollama, LM Studio or your server, or fix the address in Settings, Claude.")) {
                try await client(url).structured(request())
            }
        }
    }

    @Test func aTimeoutNamesTheMinutes() async {
        let url = StubHTTP.url(path: "/v1", replies: [(URLError.Code.timedOut.rawValue, "")])
        await #expect(throws: NotesError.local("The local model didn't answer within 10 minutes. Try a smaller model.")) {
            try await client(url).structured(request(timeout: .seconds(600)))
        }
        #expect(LocalModelClient.timedOut(.seconds(45)) == "The local model didn't answer within 1 minute. Try a smaller model.")
        #expect(LocalModelClient.timedOut(.seconds(130)) == "The local model didn't answer within 3 minutes. Try a smaller model.")
    }

    @Test func aSlowLocalModelGetsAtLeastFiveMinutesExceptForALivePass() async throws {
        for (role, asked, expected) in [(ClaudeRole.brief, 60, 300), (.ask, 180, 300), (.notes, 600, 600), (.live, 120, 120)] {
            let url = StubHTTP.url(path: "/v1", replies: [(200, chatReply(#"{"ok":true}"#))])
            _ = try await client(url).structured(request(role, timeout: .seconds(asked)))
            #expect(StubHTTP.requests(url).first?.timeoutInterval == TimeInterval(expected), "\(role)")
        }
        let slow = StubHTTP.url(path: "/v1", replies: [(URLError.Code.timedOut.rawValue, "")])
        await #expect(throws: NotesError.local("The local model didn't answer within 5 minutes. Try a smaller model.")) {
            try await client(slow).structured(request(.brief, timeout: .seconds(60)))
        }
    }

    @Test func aCancelledCallIsCancelled() async {
        let url = StubHTTP.url(path: "/v1", replies: [(URLError.Code.cancelled.rawValue, "")])
        await #expect(throws: CancellationError.self) { try await client(url).structured(request()) }
    }

    @Test func aLivePassIsSkippedWhenEverySlotIsBusy() async throws {
        let gate = ClaudeGate(limit: 1)
        let url = StubHTTP.url(path: "/v1", replies: [(200, chatReply(#"{"ok":true}"#))])
        let held = try await gate.run(.notes, skipIfBusy: false) {
            await #expect(throws: ClaudeBusy.self) { try await client(url, gate: gate).structured(request(.live)) }
            return true
        }
        #expect(held == true && StubHTTP.requests(url).isEmpty)
        _ = try await client(url, gate: gate).structured(request(.live))
        #expect(StubHTTP.requests(url).count == 1)
    }

    @Test func notesAreWrittenEndToEndThroughTheServer() async throws {
        let url = StubHTTP.url(path: "/v1/", replies: [(200, chatReply("<think>ok</think>\n```json\n" + notesText + "\n```"))])
        let notes = try await ClaudeNotesWriter(client: client(url), model: "llama3.1:8b", effort: "medium").write(sampleRequest)
        #expect(notes == sampleNotes)
        let object = try body(try #require(StubHTTP.requests(url).first))
        #expect(object["model"] as? String == "llama3.1:8b" && object["max_tokens"] as? Int == ClaudeNotesWriter.maxTokens)
        let system = try #require((object["messages"] as? [[String: String]])?.first?["content"])
        #expect(system.contains("\"Stephen\"") && system.hasSuffix(NotesSchema.json))
    }

    @Test func noMessageHasAnEmDash() {
        let messages = [LocalModelClient.contextTooSmall, LocalModelClient.noModel("m"), LocalModelClient.wantsKey("h"),
                        LocalModelClient.unreachable("u"), LocalModelClient.timedOut(.seconds(60)), LocalModelClient.pickModel,
                        LocalModelClient.schemaInstruction, LocalModelClient.redirected("h"), LocalModelClient.noChatEndpoint("u")]
        #expect(messages.allSatisfy { !$0.contains("\u{2014}") })
        #expect(LocalModelClient.pickModel == "Pick a local model in Settings, Claude.")
    }
}

struct LocalModelAddressTests {
    @Test func usableAddresses() {
        for text in ["http://localhost:11434/v1", " http://127.0.0.1:1234/v1 ", "http://[::1]:8080/v1", "http://studio.local:1234/v1",
                     "http://192.168.1.20:11434/v1", "http://10.0.0.5/v1", "https://models.example.com/v1"] {
            #expect(LocalModelClient.addressProblem(text) == nil, "\(text)")
        }
        #expect(LocalModelClient.addressProblem(LocalModelClient.defaultURL) == nil)
        #expect(LocalModelClient.defaultURL == "http://localhost:11434/v1")
        #expect(LocalModelClient.presets.map(\.name) == ["Ollama", "LM Studio", "llama.cpp"])
        #expect(LocalModelClient.presets.map(\.url) == ["http://localhost:11434/v1", "http://localhost:1234/v1", "http://localhost:8080/v1"])
        #expect(LocalModelClient.presets.allSatisfy { LocalModelClient.addressProblem($0.url) == nil })
    }

    @Test func eachProblemHasItsOwnSentence() {
        let blank = "Type the address of your local model server in Settings, Claude."
        let scheme = "The local model address must start with http:// or https://."
        let credentials = "Take the user name and password out of the local model address."
        let plain = "Plain http:// works only for this Mac or your local network. Use https:// for anything else."
        let cases: [(String, String)] = [
            ("", blank), ("  \n", blank),
            ("localhost:11434/v1", scheme), ("ftp://localhost/v1", scheme), ("http://", scheme), ("not a url", scheme),
            ("http://user:pass@localhost:11434/v1", credentials), ("https://user@example.com/v1", credentials),
            ("http://example.com/v1", plain), ("http://8.8.8.8:11434/v1", plain),
        ]
        for (text, problem) in cases {
            #expect(LocalModelClient.addressProblem(text) == problem, "\(text)")
            #expect(!problem.contains("\u{2014}"))
        }
        // The webhook's own messages are unchanged.
        #expect(WebhookURLPolicy.problem("http://example.com/hook") == WebhookURLPolicy.wrongURL)
    }
}
