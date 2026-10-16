import Foundation

/// Structured calls through a local OpenAI-compatible server: Ollama, LM Studio, llama.cpp, vLLM.
///
/// It posts to `<base>/chat/completions` with a strict JSON Schema `response_format`, and puts the schema in the
/// system prompt too, so a server that ignores `response_format` (mlx_lm.server) still answers in shape. A server that
/// rejects `response_format` gets the same request once more without it. It never sends an Anthropic key and never
/// reads the Keychain. Calls take a `ClaudeGate` slot like Claude Code's: a live pass is skipped when every slot is
/// busy. Settings hands it `serverGate`, one call at a time, since many local servers run one request at a time and
/// a queued request's timer runs while it waits on the server. There are no cross-process slots. Effort is ignored.
/// Redirects are never followed, so the transcript goes only to the address the user set.
public struct LocalModelClient: ClaudeClient {
    /// Ollama's address.
    public static let defaultURL = "http://localhost:11434/v1"
    public static let presets: [(name: String, url: String)] = [("Ollama", "http://localhost:11434/v1"),
        ("LM Studio", "http://localhost:1234/v1"), ("llama.cpp", "http://localhost:8080/v1")]
    public static let pickModel = "Pick a local model in Settings, Claude."
    static let schemaInstruction = "Reply with one JSON object that matches this JSON Schema, and nothing else:"
    static let contextTooSmall = "The meeting is longer than the local model's context window. Give the model a bigger context (see the local models guide) or use a bigger model."
    /// One call at a time to the local server: a live pass during the notes is skipped, and the brief and Ask wait
    /// here, where no timer runs, instead of in the server's queue.
    public static let serverGate = ClaudeGate(limit: 1)
    /// Local models are slower than Claude: every call but a live pass gets at least this long.
    static let timeoutFloor: Duration = .seconds(300)
    /// The answer size asked for once more after a context error, for servers that count `max_tokens` against the
    /// context (vLLM).
    static let smallAnswer = 4096

    public var baseURL: URL
    public var session: URLSession
    public var gate: ClaudeGate
    public var retryDelays: [Duration]
    public var sleep: @Sendable (Duration) async throws -> Void

    public init(baseURL: URL, session: URLSession = .shared, gate: ClaudeGate = .shared,
                retryDelays: [Duration] = [.seconds(2)],
                sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) {
        self.baseURL = baseURL
        self.session = session
        self.gate = gate
        self.retryDelays = retryDelays
        self.sleep = sleep
    }

    public func structured(_ request: ClaudeRequest) async throws -> Data {
        let result = try await gate.run(request.role, skipIfBusy: request.role == .live) { try await self.call(request) }
        guard let data = result else { throw ClaudeBusy() }
        return data
    }

    /// One call: retried after an overload or a server error, and sent once more without `response_format` when the
    /// server says it can't do structured outputs.
    func call(_ asked: ClaudeRequest) async throws -> Data {
        var request = asked
        var structuredOutputs = true
        var attempt = 0
        let timeout = Self.timeout(for: request)
        while true {
            var http = URLRequest(url: Self.endpoint(baseURL, "chat/completions"),
                                  timeoutInterval: ClaudeAPIClient.seconds(timeout))
            http.httpMethod = "POST"
            http.setValue("application/json", forHTTPHeaderField: "content-type")
            http.httpBody = try Self.body(for: request, structuredOutputs: structuredOutputs)
            let (data, status) = try await post(http, timeout: timeout)
            if status == 200 { return try LocalModelReply.json(from: data, sentBytes: Self.promptBytes(request)) }
            let message = LocalModelReply.errorMessage(data)
            switch LocalModelReply.failure(status: status, message: message, structuredOutputs: structuredOutputs) {
            case .withoutResponseFormat:
                structuredOutputs = false
            case .retry where attempt < retryDelays.count:
                try await sleep(retryDelays[attempt])
                attempt += 1
            case .context where request.maxTokens > Self.smallAnswer:
                request.maxTokens = Self.smallAnswer
            case .context:
                throw NotesError.local(Self.contextTooSmall)
            case .model:
                throw NotesError.local(Self.noModel(request.model))
            case .endpoint:
                throw NotesError.local(Self.noChatEndpoint(baseURL.absoluteString))
            case .redirect:
                throw NotesError.local(Self.redirected(Self.displayHost(baseURL)))
            case .key:
                throw NotesError.local(Self.wantsKey(Self.displayHost(baseURL)))
            case .retry, .other:
                throw NotesError.local("The local model server returned \(status): \(message)")
            }
        }
    }

    /// How long a call may take: the request's own time, and at least `timeoutFloor` for everything but a live pass,
    /// which is skipped and tried again at the next check anyway.
    static func timeout(for request: ClaudeRequest) -> Duration {
        request.role == .live ? request.timeout : max(request.timeout, timeoutFloor)
    }

    /// The UTF-8 size of the prompt text sent, to tell when the server kept only part of it.
    static func promptBytes(_ request: ClaudeRequest) -> Int {
        [request.system, schemaInstruction, request.schema, request.user].reduce(0) { $0 + $1.utf8.count }
    }

    /// The reply and its status. A server that isn't there, or doesn't answer in time, is a `NotesError.local`; a
    /// cancelled request is a `CancellationError`. A redirect is never followed: its 3xx reply comes back as is.
    private func post(_ http: URLRequest, timeout: Duration) async throws -> (Data, Int) {
        do {
            let (data, response) = try await session.data(for: http, delegate: NoRedirects())
            return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
        } catch let error as URLError {
            switch error.code {
            case .cancelled:
                throw CancellationError()
            case .timedOut:
                throw NotesError.local(Self.timedOut(timeout))
            case .cannotConnectToHost, .cannotFindHost, .networkConnectionLost, .notConnectedToInternet, .dnsLookupFailed:
                throw NotesError.local(Self.unreachable(baseURL.absoluteString))
            default:
                throw NotesError.local("Earshot couldn't talk to the local model server at \(baseURL.absoluteString): \(error.localizedDescription)")
            }
        }
    }

    /// The chat completion request. The schema goes in the system prompt as well as in `response_format`.
    static func body(for request: ClaudeRequest, structuredOutputs: Bool) throws -> Data {
        guard let schema = try? JSONSerialization.jsonObject(with: Data(request.schema.utf8)) as? [String: Any] else {
            throw NotesError.badOutput("the answer format is not valid JSON")
        }
        var object: [String: Any] = [
            "model": request.model,
            "messages": [["role": "system", "content": request.system + "\n\n" + schemaInstruction + "\n" + request.schema],
                         ["role": "user", "content": request.user]],
            "temperature": 0.2,
            "max_tokens": request.maxTokens,
            "stream": false,
        ]
        if structuredOutputs {
            object["response_format"] = ["type": "json_schema",
                                         "json_schema": ["name": "earshot", "strict": true, "schema": schema] as [String: Any]]
        }
        return try JSONSerialization.data(withJSONObject: object)
    }

    /// `path` after the base address, with or without a trailing slash on the base.
    static func endpoint(_ base: URL, _ path: String) -> URL {
        var text = base.absoluteString
        while text.hasSuffix("/") { text.removeLast() }
        return URL(string: text + "/" + path) ?? base.appending(path: path)
    }

    /// The host and port, as the user typed them in the address: "localhost:11434".
    static func displayHost(_ url: URL) -> String {
        let host = WebhookURLPolicy.host(of: url) ?? url.absoluteString
        let shown = host.contains(":") ? "[\(host)]" : host
        return url.port.map { "\(shown):\($0)" } ?? shown
    }

    // MARK: What the user sees

    static func noModel(_ model: String) -> String {
        "The local server has no model named \"\(model)\". Pick one in Settings, Claude."
    }

    static func wantsKey(_ host: String) -> String {
        "The server at \(host) asked for an API key. Earshot's local model setting is for servers that run without one."
    }

    static func noChatEndpoint(_ base: String) -> String {
        "The local model server at \(base) has no chat endpoint. Check that the address ends in /v1."
    }

    static func redirected(_ host: String) -> String {
        "The local model server at \(host) redirected to another address. Earshot doesn't follow redirects; fix the address in Settings, Claude."
    }

    static func unreachable(_ base: String) -> String {
        "Can't reach the local model server at \(base). Start Ollama, LM Studio or your server, or fix the address in Settings, Claude."
    }

    static func timedOut(_ timeout: Duration) -> String {
        let minutes = max(1, Int((ClaudeAPIClient.seconds(timeout) / 60).rounded(.up)))
        return "The local model didn't answer within \(minutes) minute\(minutes == 1 ? "" : "s"). Try a smaller model."
    }

    // MARK: The address

    static let blankAddress = "Type the address of your local model server in Settings, Claude."
    static let wrongScheme = "The local model address must start with http:// or https://."
    static let credentials = "Take the user name and password out of the local model address."
    static let plainHTTP = "Plain http:// works only for this Mac or your local network. Use https:// for anything else."

    /// Why the address typed in Settings can't be used, or nil when it can. Spaces around it are ignored. The host
    /// rules are the webhook's (`WebhookURLPolicy`): https anywhere, plain http only to this Mac or the local network.
    public static func addressProblem(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return blankAddress }
        guard let url = URL(string: trimmed) else { return wrongScheme }
        let scheme = url.scheme?.lowercased() ?? ""
        guard scheme == "https" || scheme == "http", let host = WebhookURLPolicy.host(of: url) else { return wrongScheme }
        if url.user(percentEncoded: true) != nil || url.password(percentEncoded: true) != nil { return credentials }
        return scheme == "https" || WebhookURLPolicy.isLocal(host) ? nil : plainHTTP
    }
}
