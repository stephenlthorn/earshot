import Foundation
@testable import EarshotKit

func tempDir() -> URL {
    let url = FileManager.default.temporaryDirectory
        .appending(path: "earshot-\(UUID().uuidString)", directoryHint: .isDirectory)
    try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

let newYork = TimeZone(identifier: "America/New_York")!
/// 2026-10-14 15:30 in New York.
let at1530 = Date(timeIntervalSince1970: 1_792_006_200)

let sampleNotes = MeetingNotes(
    title: "Acme kickoff",
    summary: "Agreed a two-week pilot starting Monday.",
    attendees: ["Stephen", "Dana"],
    keyPoints: ["Dana's team logs jobs by hand"],
    decisions: ["Pilot starts Monday"],
    actionItems: [
        ActionItem(task: "Draft the pilot scope email to Dana", owner: "Stephen", due: "Friday", doer: .ai,
                   context: "Dana wants the scope in writing."),
        ActionItem(task: "Call the venue", owner: "Stephen", due: nil, doer: .me, context: ""),
    ],
    openQuestions: ["Who signs off on the budget?"])

/// URLProtocol stub. Each test gets its own host, so tests running in parallel never share replies. A 3xx reply
/// redirects to the address in its body. A negative status fails the request with that `URLError.Code` (for example
/// `URLError.Code.timedOut.rawValue`), as a dead server or a timeout would.
final class StubHTTP: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var queued: [String: [(Int, Data)]] = [:]
    nonisolated(unsafe) private static var seen: [String: [URLRequest]] = [:]

    static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubHTTP.self]
        return URLSession(configuration: config)
    }()

    static func url(path: String = "/v1/messages", replies: [(Int, String)]) -> URL {
        let host = "stub-\(UUID().uuidString.lowercased()).test"
        lock.withLock { queued[host] = replies.map { ($0.0, Data($0.1.utf8)) } }
        return URL(string: "https://\(host)\(path)")!
    }

    static func requests(_ url: URL) -> [URLRequest] { lock.withLock { seen[url.host() ?? ""] ?? [] } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        var request = self.request
        if request.httpBody == nil, let stream = request.httpBodyStream { request.httpBody = Self.read(stream) }
        let host = request.url?.host() ?? ""
        let reply: (Int, Data) = Self.lock.withLock {
            Self.seen[host, default: []].append(request)
            guard var replies = Self.queued[host], !replies.isEmpty else { return (418, Data()) }
            let first = replies.removeFirst()
            Self.queued[host] = replies
            return first
        }
        if reply.0 < 0 {
            client?.urlProtocol(self, didFailWithError: URLError(URLError.Code(rawValue: reply.0)))
            return
        }
        if (300..<400).contains(reply.0), let next = URL(string: String(decoding: reply.1, as: UTF8.self)) {
            // A redirect: the reply's body is the Location. The session follows it unless a delegate refuses.
            let response = HTTPURLResponse(url: request.url!, statusCode: reply.0, httpVersion: "HTTP/1.1",
                                           headerFields: ["Location": next.absoluteString])!
            var redirected = request
            redirected.url = next
            client?.urlProtocol(self, wasRedirectedTo: redirected, redirectResponse: response)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: reply.0, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: reply.1)
        client?.urlProtocolDidFinishLoading(self)
    }

    static func read(_ stream: InputStream) -> Data {
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 16_384)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            data.append(buffer, count: count)
        }
        return data
    }
}

/// A Messages API reply: a thinking block, then the notes as JSON text.
func apiReply(_ notes: MeetingNotes = sampleNotes, stop: String = "end_turn") -> String {
    let text = String(decoding: try! JSONEncoder().encode(notes), as: UTF8.self)
    let object: [String: Any] = [
        "id": "msg_1", "type": "message", "role": "assistant", "model": "claude-opus-5-5", "stop_reason": stop,
        "content": [["type": "thinking", "thinking": "Reading the transcript.", "signature": "sig"],
                    ["type": "text", "text": text]],
    ]
    return String(decoding: try! JSONSerialization.data(withJSONObject: object), as: UTF8.self)
}

let apiError = #"{"type":"error","error":{"type":"api_error","message":"boom"}}"#

let sampleRequest = NotesRequest(
    transcript: "[00:00:01] Stephen: Dana, I'll send the scope by Friday.\n", userName: "Stephen", style: .general,
    extraInstructions: "", startedAt: at1530, duration: 2400, timeZone: newYork)

final class FakeRunner: ProcessRunning, @unchecked Sendable {
    struct Call: Sendable {
        var executable: String
        var arguments: [String]
        var stdin: String
        var directory: URL?
        var environment: [String: String]
        var inheritEnvironment: Bool = true
        var timeout: Duration = .zero
    }

    private let lock = NSLock()
    private var recorded: [Call] = []
    private var outputs: [ProcessOutput]

    init(_ outputs: ProcessOutput...) { self.outputs = outputs }

    var calls: [Call] { lock.withLock { recorded } }

    func run(_ executable: String, _ arguments: [String], stdin: Data?, directory: URL?,
             environment: [String: String], inheritEnvironment: Bool, timeout: Duration) async throws -> ProcessOutput {
        lock.withLock {
            recorded.append(Call(executable: executable, arguments: arguments,
                                 stdin: String(decoding: stdin ?? Data(), as: UTF8.self),
                                 directory: directory, environment: environment, inheritEnvironment: inheritEnvironment,
                                 timeout: timeout))
            return outputs.isEmpty ? ProcessOutput(status: 0, stdout: "", stderr: "", timedOut: false) : outputs.removeFirst()
        }
    }
}

/// What `claude -p --output-format json --json-schema ...` prints (shape verified with Claude Code 2.1.296).
func claudeJSON(_ notes: MeetingNotes = sampleNotes, isError: Bool = false) -> String {
    let object = try! JSONSerialization.jsonObject(with: JSONEncoder().encode(notes))
    let reply: [String: Any] = ["type": "result", "subtype": "success", "is_error": isError,
                                "result": isError ? "Credit balance too low" : "{}", "structured_output": object]
    return String(decoding: try! JSONSerialization.data(withJSONObject: reply), as: UTF8.self)
}

/// A runner whose program never gets to finish: `run` throws `error`, as ProcessRunner does when it is cancelled or
/// the app is quitting.
struct ThrowingRunner: ProcessRunning {
    let error: any Error & Sendable
    func run(_ executable: String, _ arguments: [String], stdin: Data?, directory: URL?,
             environment: [String: String], inheritEnvironment: Bool, timeout: Duration) async throws -> ProcessOutput {
        throw error
    }
}
