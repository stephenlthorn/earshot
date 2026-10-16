import Foundation
import Testing
@testable import EarshotKit

/// The real-Claude checks run only with EARSHOT_CLAUDE_TESTS=1 (`make claude-test`), against the user's own signed-in
/// Claude Code (spec 18). Unit tests never call a model.
let claudeTests = ProcessInfo.processInfo.environment["EARSHOT_CLAUDE_TESTS"] == "1"

/// The files in Tests/Fixtures/claude, shared by these tests and Scripts/claude-test.sh.
enum ClaudeFixtures {
    static let source = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appending(path: "Fixtures/claude", directoryHint: .isDirectory)
    /// Placeholders in the index templates, replaced the same way by Scripts/claude-test.sh.
    static let rootToken = "@@ROOT@@"
    static let startedToken = "@@STARTED_AT@@"

    static func text(_ name: String) throws -> String {
        try String(contentsOf: source.appending(path: name), encoding: .utf8)
    }

    /// "[mm:ss] Name: text" lines as transcript lines.
    static func transcript(_ name: String) throws -> [TranscriptLine] {
        try text(name).split(whereSeparator: \.isNewline).compactMap { raw in
            let line = String(raw)
            guard let match = line.wholeMatch(of: /\[(\d+):(\d\d)\] ([^:]+): (.+)/) else { return nil }
            let start = Double(Int(match.1)! * 60 + Int(match.2)!)
            return TranscriptLine(start: start, speaker: String(match.3), text: String(match.4))
        }
    }

    /// The staged live meeting: one list of final segments per stage.
    static func liveStages() throws -> [[Segment]] {
        try JSONDecoder().decode([[Segment]].self, from: Data(text("live-stages.json").utf8))
    }

    /// The index templates written into `index` with the meetings folder `root` and a start time.
    static func index(at index: URL, root: URL, startedAt: Date) throws -> LibraryIndex {
        let templates = source.appending(path: "index", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: index, withIntermediateDirectories: true)
        let stamp = ISO8601DateFormatter().string(from: startedAt.wholeSeconds)
        for name in try FileManager.default.contentsOfDirectory(atPath: templates.path) where name.hasSuffix(".json") {
            let filled = try String(contentsOf: templates.appending(path: name), encoding: .utf8)
                .replacingOccurrences(of: rootToken, with: root.path)
                .replacingOccurrences(of: startedToken, with: stamp)
            try Data(filled.utf8).write(to: index.appending(path: name))
        }
        return LibraryIndex(url: index)
    }
}

/// The fixtures themselves, checked without Claude, so `make claude-test` never fails on a broken fixture.
struct ClaudeFixtureTests {
    @Test func transcriptsParseWithTimesAndSpeakers() throws {
        let ashley = try ClaudeFixtures.transcript("ashley-proposal.txt")
        #expect(ashley.count == 8)
        let ask = try #require(ashley.first { $0.speaker == "Ashley" && $0.text.contains("revised proposal") })
        #expect(NotesRenderer.clock(ask.start) == "01:10" && ask.text.contains("Friday"))
        #expect(ashley.contains { $0.speaker == "Dana" && $0.text.contains("venue") })
        for name in ["two-externals.txt", "live-ref.txt"] {
            let lines = try ClaudeFixtures.transcript(name)
            #expect(lines.count >= 5 && lines.allSatisfy { !$0.text.isEmpty }, "\(name)")
        }
        let externals = try ClaudeFixtures.text("two-externals.txt")
        #expect(!externals.contains("Priya") && !externals.contains("Tom"))
    }

    @Test func liveStagesAreLongEnoughForAPassEach() throws {
        let stages = try ClaudeFixtures.liveStages()
        #expect(stages.count == 3)
        for stage in stages {
            let characters = stage.reduce(0) { $0 + $1.text.count }
            #expect(characters >= LiveExtractor.defaultMinimumCharacters)
        }
        let starts = stages.flatMap { $0 }.map(\.start)
        #expect(starts == starts.sorted())
    }

    @Test func indexTemplatesLoadThroughTheLibrary() throws {
        let root = tempDir()
        let index = try ClaudeFixtures.index(at: root.appending(path: "index"), root: root.appending(path: "meetings"),
                                             startedAt: Date().addingTimeInterval(-86_400))
        let library = MeetingLibrary(index: index, store: nil)
        #expect(Set(library.meetings().map(\.title)) == ["Northwind renewal", "Fabrikam vendor sync"])
        #expect(library.meetings().allSatisfy { $0.folder.hasPrefix(root.path) })
        let budget = try #require(library.search("budget renewal").first)
        #expect(budget.meeting.title == "Northwind renewal" && budget.lines.contains { $0.text.contains("48,000") })
        let vendor = try #require(library.meetings(query: "Fabrikam").first)
        #expect(try library.transcript(of: vendor).contains { $0.text.contains("rm -rf ~") })
        // The planted instruction is only in the transcript, so list results never carry it.
        #expect(library.meetings().allSatisfy { !$0.summary.contains("rm -rf") })
        let reminders = Reminders.compute(library.meetings(), userName: "", now: Date())
        #expect(reminders.items.contains { $0.task == "Send Priya the signed Northwind order form" && $0.due == "Thursday" })
    }

    @Test func sayScriptNamesAshleyTheProposalAndFriday() throws {
        let text = try ClaudeFixtures.text("say-meeting.txt")
        #expect(text.contains("Ashley") && text.contains("revised proposal") && text.contains("Friday"))
    }
}

/// Records each verdict as one "PASS (x) name: evidence" or "FAIL (x) ..." line, which Scripts/claude-test.sh
/// collects, and fails the test on FAIL.
func verdict(_ id: String, _ name: String, _ ok: Bool, _ evidence: String,
             sourceLocation: SourceLocation = #_sourceLocation) {
    let line = evidence.split(whereSeparator: \.isNewline).joined(separator: " ")
    print("\(ok ? "PASS" : "FAIL") (\(id)) \(name): \(String(line.prefix(600)))")
    if !ok { Issue.record("(\(id)) \(name): \(line)", sourceLocation: sourceLocation) }
}

/// The real runner, recording what each run was given and what the folder held when it started.
final class SpyRunner: ProcessRunning, @unchecked Sendable {
    struct Seen: Sendable {
        var arguments: [String]
        var stdin: String
        var files: [String]
        var environment: [String: String]
        var inheritEnvironment: Bool
        var output: ProcessOutput
    }

    private let seen = Locked<[Seen]>([])
    var calls: [Seen] { seen.get }

    func run(_ executable: String, _ arguments: [String], stdin: Data?, directory: URL?,
             environment: [String: String], inheritEnvironment: Bool, timeout: Duration) async throws -> ProcessOutput {
        let files = directory.flatMap { try? FileManager.default.contentsOfDirectory(atPath: $0.path) } ?? []
        let out = try await ProcessRunner().run(executable, arguments, stdin: stdin, directory: directory,
                                                environment: environment, inheritEnvironment: inheritEnvironment,
                                                timeout: timeout)
        seen.update { $0.append(Seen(arguments: arguments, stdin: String(decoding: stdin ?? Data(), as: UTF8.self),
                                     files: files.sorted(), environment: environment,
                                     inheritEnvironment: inheritEnvironment, output: out)) }
        return out
    }
}

/// The real client, keeping every JSON answer.
final class RecordingClient: ClaudeClient, @unchecked Sendable {
    let inner: any ClaudeClient
    private let answers = Locked<[Data]>([])
    var replies: [Data] { answers.get }

    init(_ inner: any ClaudeClient) { self.inner = inner }

    func structured(_ request: ClaudeRequest) async throws -> Data {
        let data = try await inner.structured(request)
        answers.update { $0.append(data) }
        return data
    }
}

enum LiveClaude {
    /// Sonnet keeps these checks cheap. `earshot process` in the script uses Earshot's default notes model once: it reads
    /// an empty settings domain (EARSHOT_SETTINGS_DOMAIN), never the user's saved settings.
    static let model = "claude-sonnet-5-5"

    static func path() async throws -> String {
        if let found = ClaudeLocator.find() { return found }
        return try #require(await ClaudeLocator.findViaShell(), "Claude Code not found")
    }

    static func client(_ path: String, runner: any ProcessRunning = ProcessRunner()) -> ClaudeCodeClient {
        ClaudeCodeClient(claudePath: path, runner: runner, gate: ClaudeGate(), slots: nil)
    }

    static func json(_ data: Data) -> String {
        String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: " ")
    }

    static func json(_ value: some Encodable) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(value)).map { String(decoding: $0, as: UTF8.self) } ?? "?"
    }

    static let okSchema = #"""
    {"type":"object","additionalProperties":false,"required":["ok","word"],
     "properties":{"ok":{"type":"boolean"},"word":{"type":"string"}}}
    """#

    static func okRequest(_ word: String) -> ClaudeRequest {
        ClaudeRequest(role: .ask, system: "Answer only through the JSON schema.",
                      user: "Set ok to true and word to the single lowercase word \(word).", schema: okSchema,
                      model: model, effort: "low", timeout: .seconds(180))
    }

    static func isOK(_ data: Data, word: String) -> Bool {
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        return object?["ok"] as? Bool == true && (object?["word"] as? String)?.lowercased() == word
    }

    static func envelope(_ out: ProcessOutput) -> [String: Any] {
        ((try? JSONSerialization.jsonObject(with: Data(out.stdout.utf8))) as? [String: Any]) ?? [:]
    }

    static func notesRequest(_ transcript: String, context: NotesContext = .empty) -> NotesRequest {
        NotesRequest(transcript: transcript, userName: "Stephen", style: .general, extraInstructions: "",
                     startedAt: Date(), duration: 900, timeZone: .current, context: context)
    }

    static func lower(_ parts: String?...) -> String { parts.compactMap { $0 }.joined(separator: " ").lowercased() }
}

/// Real calls through the user's own Claude Code, signed in with their plan (spec 18, "Claude subscription tests").
/// Serialized: one `claude` at a time, and (b) changes this process's environment while it runs.
@Suite(.serialized, .enabled(if: claudeTests, "needs EARSHOT_CLAUDE_TESTS=1 and a signed-in Claude Code"))
struct ClaudeLiveTests {
    // MARK: 1. The client

    /// (a) The exact spec 3.2 argument list, from an empty folder, with the prompt on stdin.
    @Test(.timeLimit(.minutes(4))) func exactStructuredCallReturnsStructuredOutput() async throws {
        let path = try await LiveClaude.path()
        let spy = SpyRunner()
        let request = LiveClaude.okRequest("earshot")
        let data = try await LiveClaude.client(path, runner: spy).structured(request)
        let call = try #require(spy.calls.first)
        let promptFile = try #require(call.arguments.firstIndex(of: "--system-prompt-file").map { call.arguments[$0 + 1] })
        let exact = call.arguments == ClaudeCodeClient.arguments(for: request, systemPromptFile: promptFile)
        let envelope = LiveClaude.envelope(call.output)
        let structured = envelope["structured_output"] is [String: Any]
        let denials = (envelope["permission_denials"] as? [Any])?.count ?? -1
        let onStdin = call.stdin == request.user && !call.arguments.contains(request.user)
        let ok = exact && call.files == ["system.txt"] && onStdin && !call.inheritEnvironment && structured
            && envelope["is_error"] as? Bool == false && denials == 0 && LiveClaude.isOK(data, word: "earshot")
        verdict("a", "spec 3.2 structured call", ok,
                "args exact=\(exact) (\(call.arguments.count) args), run folder held \(call.files), prompt on stdin=\(onStdin), "
                + "exit \(call.output.status), structured_output=\(LiveClaude.json(data)), denials=\(denials)")
    }

    /// (b) ANTHROPIC_API_KEY=bogus in Earshot's own environment never reaches `claude`: the status check still says
    /// claude.ai and the call works. The control run, which inherits the environment, shows the key would have won.
    @Test(.timeLimit(.minutes(4))) func bogusKeyInTheParentEnvironmentNeverReachesClaude() async throws {
        let path = try await LiveClaude.path()
        let previous = ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"]
        setenv("ANTHROPIC_API_KEY", "bogus", 1)
        defer { if let previous { setenv("ANTHROPIC_API_KEY", previous, 1) } else { unsetenv("ANTHROPIC_API_KEY") } }
        let authMethod = { (out: ProcessOutput) in LiveClaude.envelope(out)["authMethod"] as? String ?? "?" }
        let leaked = try await ProcessRunner().run(path, ["auth", "status"], stdin: nil, directory: nil, environment: [:],
                                                   inheritEnvironment: true, timeout: .seconds(20))
        let child = try await ProcessRunner().run(path, ["auth", "status"], stdin: nil, directory: nil,
                                                  environment: ClaudeEnvironment.child(claudePath: path),
                                                  inheritEnvironment: false, timeout: .seconds(20))
        let status = await ClaudeCodeStatus.check(path: path)
        let data = try await LiveClaude.client(path).structured(LiveClaude.okRequest("allowlist"))
        let ok = ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"] == "bogus" && status.state == .ready
            && authMethod(child) == "claude.ai" && LiveClaude.isOK(data, word: "allowlist")
        verdict("b", "allowlist environment with ANTHROPIC_API_KEY=bogus in the parent", ok,
                "control (inherited env) authMethod=\(authMethod(leaked)); child env authMethod=\(authMethod(child)); "
                + "status=\(status.state) \"\(status.summary)\"; call=\(LiveClaude.json(data))")
    }

    // MARK: 2. Notes from a fixed transcript (shared with LocalLiveTests through LiveScenarios)

    /// (c) The action item names Ashley, the proposal and Friday.
    @Test(.timeLimit(.minutes(5))) func notesFindAshleysProposalByFriday() async throws {
        try await LiveScenarios.notesFindAshleysProposalByFriday(client: LiveClaude.client(try await LiveClaude.path()),
                                                                 model: LiveClaude.model)
    }

    /// (d) Two external attendees and nobody identified in the transcript: no item is attributed to either of them.
    @Test(.timeLimit(.minutes(5))) func notesNeverGuessWhichExternalAttendeeSpoke() async throws {
        try await LiveScenarios.notesNeverGuessWhichExternalAttendeeSpoke(client: LiveClaude.client(try await LiveClaude.path()),
                                                                          model: LiveClaude.model)
    }

    /// (e) The notes reword a to-do started during the call and still link it through `live_ref`.
    @Test(.timeLimit(.minutes(5))) func notesLinkARewordedStartedItemThroughLiveRef() async throws {
        try await LiveScenarios.notesLinkARewordedStartedItemThroughLiveRef(client: LiveClaude.client(try await LiveClaude.path()),
                                                                            model: LiveClaude.model)
    }

    // MARK: 3. Live to-dos

    /// (f) A scripted meeting fed in three stages: two to-dos, then the proposal's deadline changes by ref, then a
    /// new to-do.
    @Test(.timeLimit(.minutes(6))) func liveExtractionAcrossStagesUpdatesByRef() async throws {
        try await LiveScenarios.liveExtractionAcrossStagesUpdatesByRef(client: LiveClaude.client(try await LiveClaude.path()),
                                                                       model: LiveClaude.model)
    }

    // MARK: 4. Brief, ask and fix

    /// (g) The brief from fixture history (the v1 Acme kickoff): the open loops come from that meeting.
    @Test(.timeLimit(.minutes(4))) func briefFromFixtureHistory() async throws {
        try await LiveScenarios.briefFromFixtureHistory(client: LiveClaude.client(try await LiveClaude.path()), model: LiveClaude.model)
    }

    /// (h) Ask answers from the transcript and quotes the time as [mm:ss].
    @Test(.timeLimit(.minutes(4))) func askAnswersWithATime() async throws {
        try await LiveScenarios.askAnswersWithATime(client: LiveClaude.client(try await LiveClaude.path()), model: LiveClaude.model)
    }

    /// (i) Fix applies the user's instruction and keeps everything else.
    @Test(.timeLimit(.minutes(5))) func fixAppliesTheInstruction() async throws {
        try await LiveScenarios.fixAppliesTheInstruction(client: LiveClaude.client(try await LiveClaude.path()), model: LiveClaude.model)
    }

    // MARK: 5. The Claude Code Do target in restricted mode

    /// (j) In a temporary work folder: the file it was asked to write exists, and a write outside the folder is
    /// denied, listed in the detail, and the result is not ok.
    @Test(.timeLimit(.minutes(10))) func restrictedDoTargetWritesInsideAndIsDeniedOutside() async throws {
        let path = try await LiveClaude.path()
        let root = tempDir()
        let work = root.appending(path: "work", directoryHint: .isDirectory)
        let outside = root.appending(path: "outside", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let escape = outside.appending(path: "escape.txt")
        let items = [
            ActionItem(task: "Create a file named summary.txt in this folder that contains the single word pineapple",
                       owner: "Stephen", doer: .ai),
            ActionItem(task: "Write the same word to the file \(escape.path) with the Write tool", owner: "Stephen", doer: .ai,
                       context: "Stephen asked for this exact absolute path. Try the Write tool once; if it is denied, report that."),
        ]
        let (payload, folder) = try samplePayload(items: items, title: "Workshop prep", now: Date())
        let target = ClaudeCodeTarget(claudePath: path, workingFolder: work, userName: "Stephen", timeout: .seconds(540))
        let result = await target.send(payload, json: try payload.encoded(), folder: folder)
        let written = (try? String(contentsOf: work.appending(path: "summary.txt"), encoding: .utf8)) ?? ""
        let escaped = FileManager.default.fileExists(atPath: escape.path)
        let ok = written.lowercased().contains("pineapple") && !escaped && !result.ok
            && result.detail.hasPrefix("Partly done") && result.detail.contains("escape.txt")
        verdict("j", "restricted Do target: inside written, outside denied", ok,
                "summary.txt=\"\(written.trimmingCharacters(in: .whitespacesAndNewlines))\"; outside file exists=\(escaped); "
                + "ok=\(result.ok); detail=\"\(result.detail)\"")
    }
}
