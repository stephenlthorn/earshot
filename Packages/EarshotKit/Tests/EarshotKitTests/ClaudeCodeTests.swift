import Foundation
import Testing
@testable import EarshotKit

struct ProcessRunnerTests {
    @Test func passesStdinAndCollectsBothStreamsAndTheExitCode() async throws {
        let out = try await ProcessRunner().run("/bin/sh", ["-c", "cat; echo err >&2; exit 3"], stdin: Data("hi".utf8),
                                                directory: nil, environment: [:], timeout: .seconds(10))
        #expect(out == ProcessOutput(status: 3, stdout: "hi", stderr: "err\n", timedOut: false))
    }

    @Test func setsTheFolderAndEnvironment() async throws {
        let folder = tempDir()
        let out = try await ProcessRunner().run("/bin/sh", ["-c", "echo \"$EARSHOT_TEST\" && pwd -P"], stdin: nil,
                                                directory: folder, environment: ["EARSHOT_TEST": "yes"], timeout: .seconds(10))
        // `pwd -P` prints the real path. URL.resolvingSymlinksInPath() strips /private, so use realpath(3).
        let real = folder.path.withCString { realpath($0, nil) }.map { pointer -> String in
            defer { free(pointer) }
            return String(cString: pointer)
        }
        #expect(out.stdout == "yes\n\(try #require(real))\n")
    }

    @Test func withoutInheritingTheChildGetsOnlyTheGivenEnvironment() async throws {
        let out = try await ProcessRunner().run("/usr/bin/env", [], stdin: nil, directory: nil,
                                                environment: ["EARSHOT_ONLY": "1", "HOME": "/tmp/home"],
                                                inheritEnvironment: false, timeout: .seconds(10))
        let keys = out.stdout.split(separator: "\n").compactMap { $0.split(separator: "=", maxSplits: 1).first.map(String.init) }
        #expect(Set(keys) == ["EARSHOT_ONLY", "HOME"])
        // The old signature still merges over Earshot's own environment.
        let merged = try await ProcessRunner().run("/usr/bin/env", [], stdin: nil, directory: nil,
                                                   environment: ["EARSHOT_ONLY": "1"], timeout: .seconds(10))
        #expect(merged.stdout.contains("EARSHOT_ONLY=1") && merged.stdout.contains("PATH="))
    }

    @Test func stopsAProgramThatRunsTooLong() async throws {
        let clock = ContinuousClock()
        let started = clock.now
        let out = try await ProcessRunner().run("/bin/sleep", ["30"], stdin: nil, directory: nil, environment: [:],
                                                timeout: .milliseconds(300))
        #expect(out.timedOut)
        #expect(clock.now - started < .seconds(10))
    }

    @Test func stopsAProgramThatNeverReadsItsInput() async throws {
        let clock = ContinuousClock()
        let started = clock.now
        let out = try await ProcessRunner().run("/bin/sleep", ["30"], stdin: Data(repeating: 65, count: 1_000_000),
                                                directory: nil, environment: [:], timeout: .milliseconds(300))
        #expect(out.timedOut)
        #expect(clock.now - started < .seconds(10))
    }

    @Test func holdsItsTimeoutWhenManyProgramsRunAtOnce() async throws {
        let clock = ContinuousClock()
        let started = clock.now
        let outputs = try await withThrowingTaskGroup(of: ProcessOutput.self) { group in
            for _ in 0..<12 {
                group.addTask {
                    try await ProcessRunner().run("/bin/sleep", ["8"], stdin: nil, directory: nil, environment: [:],
                                                  timeout: .milliseconds(300))
                }
            }
            return try await group.reduce(into: []) { $0.append($1) }
        }
        #expect(outputs.count == 12)
        #expect(outputs.allSatisfy { $0.timedOut })
        #expect(clock.now - started < .seconds(3))
    }

    @Test func cancellingTheCallerStopsTheProgramAtOnce() async throws {
        let marker = "5.\(Int.random(in: 100_000...999_999))"  // a unique argument, so pgrep finds only this child
        let task = Task {
            try await ProcessRunner().run("/bin/sleep", [marker], stdin: nil, directory: nil, environment: [:],
                                          timeout: .seconds(20))
        }
        try await Task.sleep(for: .milliseconds(300))
        let clock = ContinuousClock()
        let cancelled = clock.now
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(clock.now - cancelled < .seconds(1))
        let search = try await ProcessRunner().run("/usr/bin/pgrep", ["-f", marker], stdin: nil, directory: nil,
                                                   environment: [:], timeout: .seconds(10))
        #expect(search.status == 1, "the child is still running: \(search.stdout)")
    }

    @Test func doesNotWaitForABackgroundChildThatKeepsThePipesOpen() async throws {
        let clock = ContinuousClock()
        let started = clock.now
        // The child keeps the pipes open for 30 s; returning well inside that proves the runner doesn't wait for it,
        // with room for slow CI runners.
        let out = try await ProcessRunner().run("/bin/sh", ["-c", "sleep 30 & echo done"], stdin: nil, directory: nil,
                                                environment: [:], timeout: .seconds(60))
        #expect(out == ProcessOutput(status: 0, stdout: "done\n", stderr: "", timedOut: false))
        #expect(clock.now - started < .seconds(10))
    }

    @Test func terminateAllStopsEveryRunningProgramAndStartsNoMore() async throws {
        let registry = ProcessRegistry()
        let runner = ProcessRunner(registry: registry)
        let marker = "6.\(Int.random(in: 100_000...999_999))"  // a unique argument, so pgrep finds only this child
        let task = Task {
            try await runner.run("/bin/sleep", [marker], stdin: nil, directory: nil, environment: [:], timeout: .seconds(20))
        }
        for _ in 0..<300 where registry.count == 0 { try await Task.sleep(for: .milliseconds(10)) }
        #expect(registry.count == 1)
        let clock = ContinuousClock()
        let started = clock.now
        registry.terminateAll()
        // The caller learns its program was stopped, not that it finished: a Do target must not count it as done.
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(clock.now - started < .seconds(5))
        #expect(registry.count == 0)
        let search = try await ProcessRunner().run("/usr/bin/pgrep", ["-f", marker], stdin: nil, directory: nil,
                                                   environment: [:], timeout: .seconds(10))
        #expect(search.status == 1, "the child is still running: \(search.stdout)")
        await #expect(throws: CancellationError.self) {
            try await runner.run("/usr/bin/true", [], stdin: nil, directory: nil, environment: [:], timeout: .seconds(5))
        }
    }

    @Test func aProgramThatIgnoresStdinDoesNotCrashUs() async throws {
        let out = try await ProcessRunner().run("/usr/bin/true", [], stdin: Data(repeating: 65, count: 1_000_000),
                                                directory: nil, environment: [:], timeout: .seconds(10))
        #expect(out.status == 0)
    }
}

/// A runner that looks at the run folder while the program would be running, as `claude` sees it.
final class FolderPeekingRunner: ProcessRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var seen: (files: [String], system: String?)?
    let output: ProcessOutput

    init(_ output: ProcessOutput) { self.output = output }

    var peeked: (files: [String], system: String?)? { lock.withLock { seen } }

    func run(_ executable: String, _ arguments: [String], stdin: Data?, directory: URL?,
             environment: [String: String], inheritEnvironment: Bool, timeout: Duration) async throws -> ProcessOutput {
        let files = directory.flatMap { try? FileManager.default.contentsOfDirectory(atPath: $0.path) } ?? []
        let file = arguments.firstIndex(of: "--system-prompt-file").map { arguments[$0 + 1] }
        let system = file.flatMap { try? String(contentsOfFile: $0, encoding: .utf8) }
        lock.withLock { seen = (files.sorted(), system) }
        return output
    }
}

func claudeOutput(_ stdout: String, status: Int32 = 0, stderr: String = "") -> ProcessOutput {
    ProcessOutput(status: status, stdout: stdout, stderr: stderr, timedOut: false)
}

func codeClient(_ runner: any ProcessRunning, apiKey: String? = nil) -> ClaudeCodeClient {
    ClaudeCodeClient(claudePath: "/bin/claude", runner: runner, gate: ClaudeGate(), slots: nil, apiKey: apiKey)
}

func notesRequest(model: String = "claude-opus-5-5", effort: String = "medium") -> ClaudeRequest {
    ClaudeNotesWriter(client: codeClient(FakeRunner()), model: model, effort: effort).request(for: sampleRequest)
}

struct ClaudeCodeTests {
    @Test func locatorPrefersTheOverrideThenKnownPlaces() {
        let home = URL(fileURLWithPath: "/Users/test")
        #expect(ClaudeLocator.find(override: "/custom/claude", home: home, isExecutable: { $0 == "/custom/claude" }) == "/custom/claude")
        #expect(ClaudeLocator.find(override: "/missing", home: home, isExecutable: { $0 == "/Users/test/.local/bin/claude" })
                == "/Users/test/.local/bin/claude")
        #expect(ClaudeLocator.find(override: nil, home: home, isExecutable: { _ in false }) == nil)
    }

    @Test func locatorAlsoLooksWhereNpmBunAndVoltaInstall() {
        let home = URL(fileURLWithPath: "/Users/test")
        for place in [".npm-global/bin/claude", ".bun/bin/claude", ".volta/bin/claude"] {
            let path = "/Users/test/" + place
            #expect(ClaudeLocator.find(home: home, isExecutable: { $0 == path }) == path)
        }
    }

    @Test func theLoginShellIsAskedWithWhenceAndItsLastPathCounts() async throws {
        let runner = FakeRunner(claudeOutput("Welcome back!\n/Users/test/.nvm/versions/node/v22/bin/claude\n"))
        #expect(await ClaudeLocator.findViaShell(runner: runner) == "/Users/test/.nvm/versions/node/v22/bin/claude")
        let call = try #require(runner.calls.first)
        #expect(call.executable == "/bin/zsh" && call.arguments == ["-lc", "whence -p claude"])
        #expect(call.timeout == .seconds(5))
        #expect(await ClaudeLocator.findViaShell(runner: FakeRunner(claudeOutput("", status: 1))) == nil)
        #expect(await ClaudeLocator.findViaShell(runner: FakeRunner(claudeOutput("claude not found\n"))) == nil)
        #expect(await ClaudeLocator.findViaShell(runner: ThrowingRunner(error: CancellationError())) == nil)
    }

    @Test func theStructuredCallUsesExactlyTheVerifiedArguments() {
        let request = ClaudeRequest(role: .brief, system: "S", user: "U", schema: #"{"type":"object"}"#,
                                    model: "claude-sonnet-5-5", effort: "low")
        #expect(ClaudeCodeClient.arguments(for: request, systemPromptFile: "/tmp/x/system.txt") == [
            "-p", "--output-format", "json", "--json-schema", #"{"type":"object"}"#,
            "--system-prompt-file", "/tmp/x/system.txt", "--tools", "", "--strict-mcp-config",
            "--safe-mode", "--restricted", "--permission-mode", "dontAsk", "--permission-prompts", "none",
            "--no-session-persistence", "--model", "claude-sonnet-5-5", "--effort", "low",
        ])
    }

    @Test func notesRunFromAnEmptyFolderWithThePromptOnStdin() async throws {
        let runner = FakeRunner(claudeOutput(claudeJSON()))
        let writer = ClaudeNotesWriter(client: codeClient(runner), model: "claude-opus-5-5", effort: "medium")
        #expect(try await writer.write(sampleRequest) == sampleNotes)
        let call = try #require(runner.calls.first)
        #expect(call.executable == "/bin/claude")
        let folder = try #require(call.directory)
        #expect(call.arguments == ClaudeCodeClient.arguments(for: writer.request(for: sampleRequest),
                                                             systemPromptFile: folder.appending(path: "system.txt").path))
        #expect(call.arguments[call.arguments.firstIndex(of: "--json-schema")! + 1] == NotesSchema.json)
        #expect(call.stdin.contains("I'll send the scope by Friday"))
        #expect(!FileManager.default.fileExists(atPath: folder.path), "the run folder is removed afterwards")
    }

    @Test func theSystemPromptIsTheOnlyFileInTheRunFolder() async throws {
        let runner = FolderPeekingRunner(claudeOutput(claudeJSON()))
        _ = try await ClaudeNotesWriter(client: codeClient(runner)).write(sampleRequest)
        let peeked = try #require(runner.peeked)
        #expect(peeked.files == ["system.txt"])
        #expect(peeked.system == NotesPrompt.system(sampleRequest))
    }

    @Test func claudeGetsOnlyTheAllowlistedEnvironment() async throws {
        let runner = FakeRunner(claudeOutput(claudeJSON()))
        _ = try await ClaudeNotesWriter(client: ClaudeCodeClient(
            claudePath: "/Users/alex/.nvm/versions/node/v22/bin/claude", runner: runner, gate: ClaudeGate(), slots: nil)).write(sampleRequest)
        let call = try #require(runner.calls.first)
        #expect(!call.inheritEnvironment)
        #expect(Set(call.environment.keys).isSubset(of: Set(ClaudeEnvironment.allowlist + ["PATH"])))
        #expect(call.environment["ANTHROPIC_API_KEY"] == nil)
        #expect(call.environment["HOME"] != nil)
        let path = try #require(call.environment["PATH"])
        #expect(path.hasPrefix("/Users/alex/.nvm/versions/node/v22/bin:/opt/homebrew/bin:/usr/local/bin"))
    }

    @Test func theAPIKeyProviderAddsOnlyItsKey() async throws {
        let runner = FakeRunner(claudeOutput(claudeJSON()))
        _ = try await ClaudeNotesWriter(client: codeClient(runner, apiKey: "sk-ant-api03-user")).write(sampleRequest)
        let environment = try #require(runner.calls.first?.environment)
        #expect(environment["ANTHROPIC_API_KEY"] == "sk-ant-api03-user")
        #expect(Set(environment.keys).isSubset(of: Set(ClaudeEnvironment.allowlist + ["PATH", "ANTHROPIC_API_KEY"])))
    }

    @Test func theChildEnvironmentDropsCredentialsProvidersAndSessionMarkers() {
        let inherited = [
            "HOME": "/Users/alex", "USER": "alex", "LOGNAME": "alex", "SHELL": "/bin/zsh", "TMPDIR": "/var/tmp/",
            "LANG": "en_US.UTF-8", "LC_ALL": "C", "LC_CTYPE": "UTF-8", "__CF_USER_TEXT_ENCODING": "0x1F5:0x0:0x0",
            "PATH": "/usr/bin:/bin", "ANTHROPIC_API_KEY": "sk-leak", "ANTHROPIC_AUTH_TOKEN": "t",
            "ANTHROPIC_BASE_URL": "https://proxy", "CLAUDE_CODE_OAUTH_TOKEN": "oat", "CLAUDE_CODE_USE_BEDROCK": "1",
            "CLAUDE_CONFIG_DIR": "/elsewhere", "CLAUDECODE": "1", "CLAUDE_CODE_ENTRYPOINT": "cli", "SECRET": "x",
        ]
        let child = ClaudeEnvironment.child(claudePath: "/opt/homebrew/bin/claude", apiKey: nil, from: inherited,
                                            resolve: { _ in nil })
        var expected = inherited.filter { ClaudeEnvironment.allowlist.contains($0.key) }
        expected["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
        #expect(child == expected)
        let keyed = ClaudeEnvironment.child(claudePath: "/opt/homebrew/bin/claude", apiKey: " sk-mine ", from: inherited,
                                            resolve: { _ in nil })
        #expect(keyed["ANTHROPIC_API_KEY"] == "sk-mine")
        #expect(ClaudeEnvironment.child(claudePath: "/c", apiKey: "  ", from: [:], resolve: { _ in nil })["ANTHROPIC_API_KEY"] == nil)
        #expect(ClaudeEnvironment.child(claudePath: "/c", apiKey: nil, from: [:], resolve: { _ in nil })["HOME"] == NSHomeDirectory())
    }

    @Test func theUsersOwnConfigFolderIsPassedThroughButNeverSet() {
        // A location, not a credential: without it, a user with a custom config folder looks signed out.
        let inherited = ["HOME": "/Users/alex", "CLAUDE_CONFIG_DIR": "/Users/alex/.claude-work", "PATH": "/usr/bin"]
        let child = ClaudeEnvironment.child(claudePath: "/c/claude", apiKey: nil, from: inherited, resolve: { _ in nil })
        #expect(child["CLAUDE_CONFIG_DIR"] == "/Users/alex/.claude-work")
        // Earshot never sets it itself: not when it is missing, and not when it is blank.
        #expect(ClaudeEnvironment.child(claudePath: "/c/claude", apiKey: nil, from: ["HOME": "/h"],
                                        resolve: { _ in nil })["CLAUDE_CONFIG_DIR"] == nil)
        #expect(ClaudeEnvironment.child(claudePath: "/c/claude", apiKey: nil, from: ["HOME": "/h", "CLAUDE_CONFIG_DIR": " "],
                                        resolve: { _ in nil })["CLAUDE_CONFIG_DIR"] == nil)
    }

    @Test func claudePathPutsClaudesFoldersAndHomebrewFirst() {
        // npm: the command is a symlink to cli.js, which starts with `#!/usr/bin/env node`.
        let npm = ClaudeEnvironment.path(claude: "/Users/alex/.nvm/versions/node/v22/bin/claude", inherited: "/usr/bin:/bin",
                                         resolve: { _ in "/Users/alex/.nvm/versions/node/v22/lib/node_modules/@anthropic-ai/claude-code/cli.js" })
        #expect(npm == "/Users/alex/.nvm/versions/node/v22/bin:/Users/alex/.nvm/versions/node/v22/lib/node_modules/@anthropic-ai/claude-code"
                + ":/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin")
        // Each folder once, in the first place it comes; an unresolvable path and a missing PATH are fine.
        #expect(ClaudeEnvironment.path(claude: "/opt/homebrew/bin/claude", inherited: "/usr/local/bin:/usr/bin::/opt/homebrew/bin",
                                       resolve: { _ in "/opt/homebrew/bin/claude" })
                == "/opt/homebrew/bin:/usr/local/bin:/usr/bin")
        #expect(ClaudeEnvironment.path(claude: "/usr/local/bin/claude", inherited: nil, resolve: { _ in nil })
                == "/usr/local/bin:/opt/homebrew/bin")
    }

    @Test func anUnknownOptionMeansTooOldAndIsNeverRetried() async {
        let runner = FakeRunner(claudeOutput("", status: 1, stderr: "error: unknown option '--permission-prompts'\n"),
                                claudeOutput(claudeJSON()))
        await #expect(throws: NotesError.claudeTooOld("error: unknown option '--permission-prompts'")) {
            try await ClaudeNotesWriter(client: codeClient(runner)).write(sampleRequest)
        }
        #expect(runner.calls.count == 1)
    }

    @Test func failuresAreMappedToWhatTheUserCanDo() {
        let cases: [(String, NotesError)] = [
            ("Claude AI usage limit reached|1760000000", .usageLimit("Claude AI usage limit reached|1760000000")),
            ("API Error: Rate limit exceeded", .usageLimit("API Error: Rate limit exceeded")),
            ("5-hour limit reached, resets 3pm", .usageLimit("5-hour limit reached, resets 3pm")),
            ("Not logged in. Please run /login", .notSignedIn("Not logged in. Please run /login")),
            ("Login expired", .notSignedIn("Login expired")),
            ("Invalid API key. Fix external API key", .notSignedIn("Invalid API key. Fix external API key")),
            ("There's an issue with the selected model (claude-x). It may not exist or you may not have access to it.",
             .modelUnavailable("claude-opus-5-5")),
            ("model claude-x is not available on your plan", .modelUnavailable("claude-opus-5-5")),
            ("model claude-x not found", .modelUnavailable("claude-opus-5-5")),
            ("Please run `/login` to sign in again", .notSignedIn("Please run `/login` to sign in again")),
            ("ENOENT: /Users/loginov/.claude/settings.json", .claudeFailed(status: 1, message: "ENOENT: /Users/loginov/.claude/settings.json")),
            ("cannot open /var/login/x", .claudeFailed(status: 1, message: "cannot open /var/login/x")),
            ("Segmentation fault", .claudeFailed(status: 1, message: "Segmentation fault")),
            ("error: unknown option '--effort'", .claudeTooOld("error: unknown option '--effort'")),
        ]
        for (said, expected) in cases {
            #expect(ClaudeFailure.error(said, status: 1, model: "claude-opus-5-5") == expected, "\(said)")
        }
    }

    @Test func theRunnerGetsTheRequestTimeout() async throws {
        let runner = FakeRunner(claudeOutput(claudeJSON()))
        var request = notesRequest()
        request.timeout = .seconds(45)
        _ = try await codeClient(runner).structured(request)
        #expect(runner.calls.map(\.timeout) == [.seconds(45)])
    }

    @Test func anErrorResultIsMappedWhateverTheExitCode() async {
        let limit = claudeEnvelope(["is_error": true, "subtype": "success", "result": "Claude AI usage limit reached|1760000000"])
        for status: Int32 in [0, 1] {
            await #expect(throws: NotesError.usageLimit("Claude AI usage limit reached|1760000000")) {
                try await codeClient(FakeRunner(claudeOutput(limit, status: status))).structured(notesRequest())
            }
        }
        let other = FakeRunner(claudeOutput(claudeJSON(isError: true)))
        await #expect(throws: NotesError.claudeFailed(status: 1, message: "Credit balance too low")) {
            try await codeClient(other).structured(notesRequest())
        }
    }

    @Test func otherFailuresAreNamed() async {
        await #expect(throws: NotesError.claudeFailed(status: 2, message: "boom")) {
            try await codeClient(FakeRunner(claudeOutput("", status: 2, stderr: "boom\n"))).structured(notesRequest())
        }
        let slow = FakeRunner(ProcessOutput(status: -1, stdout: "", stderr: "", timedOut: true))
        await #expect(throws: NotesError.claudeFailed(status: -1, message: "timed out")) {
            try await codeClient(slow).structured(notesRequest())
        }
        await #expect(throws: NotesError.badOutput("Claude Code printed no JSON")) {
            try await codeClient(FakeRunner(claudeOutput("not json"))).structured(notesRequest())
        }
        let wrongShape = FakeRunner(claudeOutput(claudeEnvelope(["is_error": false, "result": "Here are your notes!"])))
        await #expect(throws: NotesError.self) { try await codeClient(wrongShape).structured(notesRequest()) }
    }

    @Test func fallsBackToTheResultText() async throws {
        let text = String(decoding: try JSONEncoder().encode(sampleNotes), as: UTF8.self)
        let runner = FakeRunner(claudeOutput(claudeEnvelope(["type": "result", "is_error": false, "result": text])))
        #expect(try await ClaudeNotesWriter(client: codeClient(runner)).write(sampleRequest) == sampleNotes)
    }

    @Test func notesInTheWrongShapeAreBadOutput() async {
        let runner = FakeRunner(claudeOutput(claudeEnvelope(["is_error": false, "structured_output": ["title": "x"]])))
        await #expect(throws: NotesError.badOutput("it did not match the notes format")) {
            try await ClaudeNotesWriter(client: codeClient(runner)).write(sampleRequest)
        }
    }
}

func claudeEnvelope(_ object: [String: Any]) -> String {
    String(decoding: try! JSONSerialization.data(withJSONObject: object), as: UTF8.self)
}
