import Foundation
import Testing
@testable import EarshotKit

/// Replies keyed by host and path, so each test's routine URL (its own `trig_` id) gets its own replies even though
/// every fire URL is on api.anthropic.com.
private final class FireStub: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var queued: [String: [(Int, String)]] = [:]
    nonisolated(unsafe) private static var seen: [String: [URLRequest]] = [:]

    static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [FireStub.self]
        return URLSession(configuration: config)
    }()

    static func key(_ url: URL?) -> String { (url?.host() ?? "") + (url?.path() ?? "") }

    /// A real fire URL with its own routine id.
    static func fireURL(_ replies: [(Int, String)]) -> String {
        let url = "https://api.anthropic.com/v1/claude_code/routines/trig_\(UUID().uuidString.filter(\.isLetter))/fire"
        lock.withLock { queued[key(URL(string: url))] = replies }
        return url
    }

    static func requests(_ url: String) -> [URLRequest] { lock.withLock { seen[key(URL(string: url))] ?? [] } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        var request = self.request
        if request.httpBody == nil, let stream = request.httpBodyStream { request.httpBody = StubHTTP.read(stream) }
        let key = Self.key(request.url)
        let reply: (Int, String) = Self.lock.withLock {
            Self.seen[key, default: []].append(request)
            guard var replies = Self.queued[key], !replies.isEmpty else { return (418, "") }
            let first = replies.removeFirst()
            Self.queued[key] = replies
            return first
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: reply.0, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(reply.1.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}

private struct OneLineTranscriber: Transcribing {
    func transcribe(_ file: URL, track: Track, locale: Locale) async throws -> [Segment] {
        [Segment(track: .speaker, start: 2, end: 4, text: "Dana, I'll send the scope by Friday.")]
    }
}

private struct CopyCompressor: AudioCompressing {
    func compress(_ source: URL, to destination: URL) async throws {
        try FileManager.default.copyItem(at: source, to: destination)
    }

    func duration(of file: URL) throws -> Double { 120 }
}

private let routineToken = "sk-ant-oat01-cliTOKEN_123"
private let runLink = "https://claude.ai/code/session_01CLI"
private let fired = #"{"type":"routine_fire","claude_code_session_id":"session_01CLI","claude_code_session_url":"https://claude.ai/code/session_01CLI"}"#

/// `earshot process --send` to the routine and webhook targets (spec 11.2 and 12).
struct CLISendTests {
    private func harness(_ change: (inout CLIHarness) -> Void = { _ in }) throws -> (CLIHarness, URL) {
        var h = CLIHarness()
        h.runner = FakeRunner(ProcessOutput(status: 0, stdout: claudeJSON(), stderr: "", timedOut: false))
        change(&h)
        let audio = h.home.appending(path: "memo.m4a")
        try Data("audio".utf8).write(to: audio)
        return (h, audio)
    }

    private func run(_ h: CLIHarness, _ words: [String]) async -> (code: Int32, out: String, err: String) {
        let printed = Printed()
        var io = h.io(printed)
        io.transcriber = OneLineTranscriber()
        io.compressor = CopyCompressor()
        io.urlSession = FireStub.session
        let code = await EarshotCLI.main(["earshot", "process"] + words, io: io)
        return (code, printed.out.get, printed.err.get)
    }

    private func routine(_ url: String, token: String? = routineToken) -> (inout CLIHarness) -> Void {
        { h in
            h.settings?.routineOn = true
            h.settings?.routineURL = url
            if let token { h.environment["EARSHOT_ROUTINE_TOKEN"] = token }
        }
    }

    @Test func processSendsToTheRoutineWithTheTokenFromTheEnvironment() async throws {
        let url = FireStub.fireURL([(200, fired)])
        let (h, audio) = try harness(routine(url))
        let result = await run(h, [audio.path, "--send", "--target", "routine", "--yes", "--json"])
        #expect(result.code == 0, "\(result.err)")
        let report = try JSONFiles.decoder().decode(EarshotCLI.ProcessReport.self, from: Data(result.out.utf8))
        #expect(report.sent == ["routine"] && report.finished && report.error == nil)
        let request = try #require(FireStub.requests(url).first)
        #expect(FireStub.requests(url).count == 1)
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer \(routineToken)")
        #expect(request.value(forHTTPHeaderField: "anthropic-beta") == RoutineTarget.betaHeader)
        let data = try #require(request.httpBody)
        let body = try JSONSerialization.jsonObject(with: data) as? [String: String]
        #expect(body?["text"]?.contains("1. Draft the pilot scope email to Dana") == true)
        let session = try #require(h.store.all().first)
        #expect(session.routineRuns == [session.id: runLink])
        // The index, and so `earshot items` and MCP, say the item started in the cloud.
        #expect(h.index.entry(id: session.id)?.record.statuses == [ItemStatus.startedInCloud, ItemStatus.notSent])
    }

    /// The token comes only from EARSHOT_ROUTINE_TOKEN: without it, earshot refuses before any work, whatever the
    /// Keychain holds.
    @Test func withoutTheEnvironmentTokenTheRoutineIsRefused() async throws {
        let url = FireStub.fireURL([(200, fired)])
        let (h, audio) = try harness(routine(url, token: nil))
        let result = await run(h, [audio.path, "--send", "--target", "routine", "--yes"])
        #expect(result.code == 2)
        #expect(result.err == "earshot: \(EarshotCLI.missingRoutineToken)\n")
        #expect(h.store.all().isEmpty && FireStub.requests(url).isEmpty)
        let (off, offAudio) = try harness { $0.environment["EARSHOT_ROUTINE_TOKEN"] = routineToken }
        let refused = await run(off, [offAudio.path, "--send", "--target", "routine", "--yes"])
        #expect(refused.code == 2 && refused.err.hasPrefix("earshot: The routine target is off."))
        let (bad, badAudio) = try harness(routine(url, token: "not-a-routine-token"))
        let wrong = await run(bad, [badAudio.path, "--send", "--target", "routine", "--yes"])
        #expect(wrong.code == 2 && wrong.err == "earshot: \(EarshotCLI.wrongRoutineToken)\n")
        #expect(EarshotCLI.wrongRoutineToken.hasPrefix("EARSHOT_ROUTINE_TOKEN should start with sk-ant-oat01-."))
    }

    /// A rejected token is the environment's to fix: the message names the variable and nothing is deleted.
    @Test func aRejectedTokenTellsTheUserToUpdateTheVariable() async throws {
        let url = FireStub.fireURL([(401, #"{"type":"error","error":{"type":"authentication_error","message":"bad"}}"#)])
        let (h, audio) = try harness(routine(url))
        let result = await run(h, [audio.path, "--send", "--target", "routine", "--yes", "--json"])
        #expect(result.code == 1)
        let report = try JSONFiles.decoder().decode(EarshotCLI.ProcessReport.self, from: Data(result.out.utf8))
        #expect(report.sent.isEmpty && !report.finished)
        #expect(report.error?.contains(EarshotCLI.rejectedRoutineToken) == true, "\(report.error ?? "")")
        #expect(EarshotCLI.rejectedRoutineToken.contains("EARSHOT_ROUTINE_TOKEN"))
        #expect(FireStub.requests(url).count == 1, "a 401 is never sent again")
    }

    @Test func theRoutineTargetBuiltForTheCLINeverTouchesTheKeychain() throws {
        var settings = EarshotSettings()
        settings.routineOn = true
        settings.routineURL = FireStub.fireURL([])
        var io = EarshotCLI.IO.standard
        io.environment = ["EARSHOT_ROUTINE_TOKEN": routineToken]
        io.urlSession = FireStub.session
        let target = try #require(try EarshotCLI.sendTarget("routine", settings: settings, claudePath: nil, io: io) as? RoutineTarget)
        #expect(target.token() == routineToken && target.session === FireStub.session)
        #expect(target.unauthorizedDetail == EarshotCLI.rejectedRoutineToken)
        try target.onUnauthorized()  // a no-op: it must not reach the Keychain
    }

    @Test func theUsageTextDescribesTheRoutineTarget() {
        #expect(EarshotCLI.usage.contains("EARSHOT_ROUTINE_TOKEN"))
        #expect(EarshotCLI.usage.contains("never from the Keychain"))
        #expect(!EarshotCLI.usage.contains("\u{2014}"))
    }

    /// The webhook follows the app's URL policy: plain http to a server on the internet is refused before any work.
    @Test func processRefusesAWebhookURLThePolicyRefuses() async throws {
        let (h, audio) = try harness { h in
            h.settings?.webhookOn = true
            h.settings?.webhookURL = "http://example.com/hook"
        }
        let result = await run(h, [audio.path, "--send", "--target", "webhook", "--yes"])
        #expect(result.code == 2 && result.err == "earshot: \(WebhookURLPolicy.wrongURL)\n")
        #expect(h.store.all().isEmpty)
    }

    /// `earshot process` writes notes under the same cross-process limit as the app, in its home's Application
    /// Support.
    @Test func processNotesHoldASlotInTheHomeFolder() async throws {
        let seen = Locked<[Bool]>([])
        let (h, audio) = try harness { h in
            let folder = ClaudeSlots.defaultFolder(home: h.home)
            h.runner = SlotWatchingRunner(files: [folder.appending(path: "structured-1.lock"),
                                                  folder.appending(path: "structured-2.lock")], seen: seen)
        }
        let result = await run(h, [audio.path])
        #expect(result.code == 0, "\(result.err)")
        #expect(seen.get == [true])
    }
}

/// Records whether one of `files` was locked by someone while `claude` ran.
private struct SlotWatchingRunner: ProcessRunning {
    let files: [URL]
    let seen: Locked<[Bool]>

    func run(_ executable: String, _ arguments: [String], stdin: Data?, directory: URL?,
             environment: [String: String], inheritEnvironment: Bool, timeout: Duration) async throws -> ProcessOutput {
        let held = files.contains { file in
            let descriptor = open(file.path, O_RDWR | O_CLOEXEC)
            guard descriptor >= 0 else { return false }
            defer { close(descriptor) }
            guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else { return true }
            flock(descriptor, LOCK_UN)
            return false
        }
        seen.update { $0.append(held) }
        return ProcessOutput(status: 0, stdout: claudeJSON(), stderr: "", timedOut: false)
    }
}
