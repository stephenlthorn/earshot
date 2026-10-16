import Foundation

/// Structured calls through the Anthropic Messages API with the user's own API key (raw HTTP: there is no
/// official Swift SDK).
public struct ClaudeAPIClient: ClaudeClient {
    public static let defaultEndpoint = URL(string: "https://api.anthropic.com/v1/messages")!

    public var apiKey: @Sendable () -> String?
    public var endpoint: URL
    public var session: URLSession
    public var retryDelays: [Duration]
    public var sleep: @Sendable (Duration) async throws -> Void

    public init(apiKey: @escaping @Sendable () -> String?, endpoint: URL = Self.defaultEndpoint,
                session: URLSession = .shared, retryDelays: [Duration] = [.seconds(2), .seconds(4)],
                sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) {
        self.apiKey = apiKey
        self.endpoint = endpoint
        self.session = session
        self.retryDelays = retryDelays
        self.sleep = sleep
    }

    public func structured(_ request: ClaudeRequest) async throws -> Data {
        guard let key = apiKey()?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty else {
            throw NotesError.missingKey
        }
        var http = URLRequest(url: endpoint, timeoutInterval: Self.seconds(request.timeout))
        http.httpMethod = "POST"
        http.setValue("application/json", forHTTPHeaderField: "content-type")
        http.setValue(key, forHTTPHeaderField: "x-api-key")
        http.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        http.httpBody = try Self.body(for: request)
        var attempt = 0
        while true {
            let (data, response) = try await session.data(for: http)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if status == 200 { return try Self.parse(data) }
            if status == 401 || status == 403 { throw NotesError.badKey }
            let message = Self.errorMessage(data)
            if status == 400 || status == 404, ClaudeFailure.isModelProblem(message.lowercased()) {
                throw NotesError.modelUnavailable(request.model)
            }
            if status == 429 || (500...599).contains(status), attempt < retryDelays.count {
                try await sleep(retryDelays[attempt])
                attempt += 1
                continue
            }
            throw NotesError.http(status: status, message: message)
        }
    }

    static func body(for request: ClaudeRequest) throws -> Data {
        guard let schema = try? JSONSerialization.jsonObject(with: Data(request.schema.utf8)) as? [String: Any] else {
            throw NotesError.badOutput("the answer format is not valid JSON")
        }
        let object: [String: Any] = [
            "model": request.model,
            "max_tokens": request.maxTokens,
            "system": request.system,
            "messages": [["role": "user", "content": request.user]],
            "output_config": ["effort": request.effort, "format": ["type": "json_schema", "schema": schema]],
        ]
        return try JSONSerialization.data(withJSONObject: object)
    }

    /// The JSON the model wrote. A refusal or a cut-off answer is a failure, never half an object.
    static func parse(_ data: Data) throws -> Data {
        struct Reply: Decodable {
            struct Block: Decodable { let type: String; let text: String? }
            let content: [Block]
            let stop_reason: String?
        }
        guard let reply = try? JSONDecoder().decode(Reply.self, from: data) else {
            throw NotesError.badOutput("unreadable API response")
        }
        switch reply.stop_reason {
        case "refusal": throw NotesError.refused
        case "max_tokens": throw NotesError.truncated
        default: break
        }
        let text = reply.content.filter { $0.type == "text" }.compactMap(\.text).joined()
        guard (try? JSONSerialization.jsonObject(with: Data(text.utf8))) is [String: Any] else {
            throw NotesError.badOutput(String(text.prefix(200)))
        }
        return Data(text.utf8)
    }

    static func errorMessage(_ data: Data) -> String {
        struct Failure: Decodable { struct Inner: Decodable { let message: String }; let error: Inner }
        return (try? JSONDecoder().decode(Failure.self, from: data).error.message)
            ?? String(decoding: data.prefix(300), as: UTF8.self)
    }

    static func seconds(_ duration: Duration) -> TimeInterval {
        let parts = duration.components
        return TimeInterval(parts.seconds) + TimeInterval(parts.attoseconds) / 1e18
    }
}
