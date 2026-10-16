import Foundation
import Testing
@testable import EarshotKit

func samplePayload(items: [ActionItem] = [sampleNotes.actionItems[0]], title: String? = "Acme kickoff",
                   notes: MeetingNotes = sampleNotes, now: Date = at1530) throws -> (DoPayload, URL) {
    let store = SessionStore(root: tempDir(), timeZone: newYork)
    var session = try store.create(mode: .notesAndDo, title: title, now: now)
    session.recording = false
    session.endedAt = now.addingTimeInterval(2400)
    let folder = store.folder(session)
    return (DoPayload(session: session, folder: folder, notes: notes, notesMarkdown: "# Acme kickoff\n",
                      transcriptPath: folder.appending(path: "transcript.md").path, items: items), folder)
}

/// The length the Do receiver checks, worked out the way it does: runs of whitespace become one space, "MEDIA:" (any
/// case) gets a space before its colon, every "[" followed by "[" gets a space after it, then code points are counted.
func receiverLength(_ text: String) -> Int {
    let collapsed = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    let media = collapsed.replacing(/(?i)MEDIA:/) { match in "\(match.output.dropLast()) :" }
    return media.replacing(/\[(?=\[)/, with: "[ ").unicodeScalars.count
}

struct TargetsTests {
    @Test func payloadMatchesVersionOne() throws {
        let (payload, folder) = try samplePayload()
        let json = try #require(try JSONSerialization.jsonObject(with: payload.encoded()) as? [String: Any])
        #expect(json["version"] as? Int == 1)
        let session = try #require(json["session"] as? [String: Any])
        #expect(session["title"] as? String == "Acme kickoff")
        #expect(session["started_at"] as? String == "2026-10-14T19:30:00Z")
        #expect(session["duration_s"] as? Int == 2400)
        #expect(session["folder"] as? String == folder.path)
        #expect(json["notes_markdown"] as? String == "# Acme kickoff\n")
        let items = try #require(json["items"] as? [[String: Any]])
        #expect(items[0]["doer"] as? String == "ai" && items[0]["due"] as? String == "Friday")
    }

    @Test func payloadKeepsToTheLimitsReceiversCheck() throws {
        let long = ActionItem(task: String(repeating: "x", count: 400), owner: String(repeating: "o", count: 150), doer: .ai)
        let (payload, _) = try samplePayload(items: Array(repeating: long, count: 25))
        #expect(payload.items.count == 20)
        #expect(payload.items[0].task.count == 300 && payload.items[0].owner.count == 100)
    }

    @Test func payloadClipsByCodePointsBecauseTheReceiverCountsThem() throws {
        // Decomposed é is 1 Character but 2 code points, so 150 of them are 300 code points.
        let decomposed = "e\u{0301}"
        let item = ActionItem(task: String(repeating: decomposed, count: 200),
                              owner: String(repeating: decomposed, count: 80), doer: .ai)
        var notes = sampleNotes
        notes.summary = String(repeating: decomposed, count: 3000)
        let (payload, _) = try samplePayload(items: [item], title: String(repeating: decomposed, count: 150), notes: notes)
        #expect(payload.session.title.unicodeScalars.count <= 200 && payload.session.title.count == 100)
        #expect(payload.items[0].task.unicodeScalars.count <= 300 && payload.items[0].task.count == 150)
        #expect(payload.items[0].owner.unicodeScalars.count <= 100 && payload.items[0].owner.count == 50)
        #expect(payload.notes.summary.unicodeScalars.count <= 4000 && payload.notes.summary.count == 2000)
    }

    @Test func fieldsFullOfTagsTheReceiverDefusesStayWithinItsLimits() throws {
        let item = ActionItem(task: String(repeating: "Send media:/tmp/x [[now]] ", count: 40),
                              owner: String(repeating: "[[", count: 80), doer: .ai)
        var notes = sampleNotes
        notes.summary = String(repeating: "Media: ", count: 1000)
        let (payload, _) = try samplePayload(items: [item], title: "MEDIA:" + String(repeating: "x", count: 300), notes: notes)
        #expect(receiverLength(payload.session.title) <= 200)
        #expect(receiverLength(payload.items[0].task) <= 300)
        #expect(receiverLength(payload.items[0].owner) <= 100)
        #expect(receiverLength(payload.notes.summary) <= 4000)
        // Only the room the tags need is given up.
        #expect(payload.session.title.unicodeScalars.count == 199 && receiverLength(payload.session.title) == 200)
        #expect(payload.items[0].owner == String(repeating: "[", count: 50))
        // Text without tags still gets the whole limit.
        #expect(try samplePayload(title: String(repeating: "y", count: 300)).0.session.title.unicodeScalars.count == 200)
    }

    @Test func receiverLengthCountsWhatTheReceiverAdds() {
        #expect("plain".receiverLength == 5)
        #expect("MEDIA:a media:b".receiverLength == 17)
        #expect("[[[".receiverLength == 5 && "[x[".receiverLength == 3)
        // Python's re.IGNORECASE also matches the dotless and dotted capital i for "I".
        #expect("MED\u{0131}A:".receiverLength == 7 && "MED\u{0130}A:".receiverLength == 7)
    }

    @Test func aSingleCharacterLongerThanTheLimitIsStillCutAndNeverLeftBlank() throws {
        let zalgo = "e" + String(repeating: "\u{0301}", count: 500)  // one Character, 501 code points
        var notes = sampleNotes
        notes.title = zalgo  // reaches the payload through the blank session title; the store can't make a folder from it
        let (payload, _) = try samplePayload(items: [ActionItem(task: zalgo, owner: zalgo, doer: .ai)], title: " ", notes: notes)
        #expect(payload.session.title.unicodeScalars.count == 200)
        #expect(payload.items[0].task.unicodeScalars.count == 300)
        #expect(payload.items[0].owner.unicodeScalars.count == 100)
    }

    @Test func titleFallsBackPastBlanksAndIsTrimmed() throws {
        var blankNotes = sampleNotes
        blankNotes.title = "  \n"
        #expect(try samplePayload(title: "   ").0.session.title == "Acme kickoff")
        #expect(try samplePayload(title: "").0.session.title == "Acme kickoff")
        #expect(try samplePayload(title: "  Board review \n").0.session.title == "Board review")
        #expect(try samplePayload(title: "   ", notes: blankNotes).0.session.title == "Meeting")
        #expect(try samplePayload(title: nil, notes: blankNotes).0.session.title == "Meeting")
    }

    @Test func blankOwnersBecomeUnassignedAndBlankTasksAreDroppedBeforeTheCap() throws {
        let blank = ActionItem(task: "  \n", owner: "Stephen", doer: .ai)
        let good = ActionItem(task: "  Send the invoice ", owner: "  ", doer: .ai)
        let (payload, _) = try samplePayload(items: [blank, good])
        #expect(payload.items.count == 1)
        #expect(payload.items[0].task == "Send the invoice" && payload.items[0].owner == "Unassigned")

        let (capped, _) = try samplePayload(items: Array(repeating: blank, count: 5) + Array(repeating: good, count: 20))
        #expect(capped.items.count == 20 && capped.items.allSatisfy { $0.task == "Send the invoice" })
    }

    @Test func aBlankSummaryGetsAPlaceholder() throws {
        var notes = sampleNotes
        notes.summary = "  \n"
        #expect(try samplePayload(notes: notes).0.notes.summary == "No summary.")
        // Leading blanks must not eat the 4000 code points the receiver will count after it strips.
        notes.summary = String(repeating: " ", count: 5000) + "Agreed a pilot."
        #expect(try samplePayload(notes: notes).0.notes.summary == "Agreed a pilot.")
    }

    @Test func anItemWithNoDueEncodesNull() throws {
        let item = ActionItem(task: "Call the venue", owner: "Stephen", due: nil, doer: .me)
        let (payload, _) = try samplePayload(items: [item])
        let json = try #require(try JSONSerialization.jsonObject(with: payload.encoded()) as? [String: Any])
        let items = try #require(json["items"] as? [[String: Any]])
        #expect(items[0].keys.contains("due") && items[0]["due"] is NSNull)
    }

    @Test func defaultSelectionIsTheAIItems() {
        #expect(ActionItem.defaultSelection(sampleNotes.actionItems) == [sampleNotes.actionItems[0]])
    }

    @Test func doPromptCarriesTheRulesAndItems() throws {
        let (payload, _) = try samplePayload()
        let text = DoPrompt.text(payload, userName: "Stephen")
        #expect(text.contains("Never send it."))
        #expect(text.contains("1. Draft the pilot scope email to Dana (Stephen, due Friday)\n"))
        #expect(text.contains("<meeting_notes>\nItem 1 context: Dana wants the scope in writing."))
        #expect(text.hasSuffix("# Acme kickoff\n</meeting_notes>"))
    }

    @Test func doPromptDatesTheMeetingInTheLocalTimeZone() throws {
        // 8 pm in New York is already the next day in UTC; the payload keeps UTC, the prompt shows the local date.
        let (payload, _) = try samplePayload(now: at1530.addingTimeInterval(4.5 * 3600))
        #expect(payload.session.startedAt == "2026-10-15T00:00:00Z")
        #expect(DoPrompt.text(payload, userName: "Stephen", timeZone: newYork).contains("\"Acme kickoff\" (2026-10-14)."))
        let tokyo = try #require(TimeZone(identifier: "Asia/Tokyo"))
        #expect(DoPrompt.text(payload, userName: "Stephen", timeZone: tokyo).contains("\"Acme kickoff\" (2026-10-15)."))
    }

    @Test func webhookRetriesThenSucceedsWithTheToken() async throws {
        let (payload, folder) = try samplePayload()
        let url = StubHTTP.url(path: "/earshot", replies: [(503, "{}"), (200, #"{"ok":true}"#)])
        let target = WebhookTarget(url: url, token: { "secret-token" }, session: StubHTTP.session, sleep: { _ in })
        let result = await target.send(payload, json: try payload.encoded(), folder: folder)
        #expect(result.ok)
        let requests = StubHTTP.requests(url)
        #expect(requests.count == 2)
        #expect(requests[1].value(forHTTPHeaderField: "Authorization") == "Bearer secret-token")
        #expect(requests[1].httpBody == (try payload.encoded()))
        let log = try String(contentsOf: folder.appending(path: "do-webhook.log"), encoding: .utf8)
        #expect(log.contains("503") && log.contains("200") && !log.contains("secret-token"))
    }

    @Test func webhookDoesNotRetryARefusedRequest() async throws {
        let (payload, folder) = try samplePayload()
        let url = StubHTTP.url(path: "/earshot", replies: [(400, #"{"error":"items: must be a list"}"#)])
        let result = await WebhookTarget(url: url, token: { nil }, session: StubHTTP.session, sleep: { _ in })
            .send(payload, json: try payload.encoded(), folder: folder)
        #expect(!result.ok && result.detail.contains("400"))
        #expect(StubHTTP.requests(url).count == 1)
    }

    @Test func webhookNeverFollowsARedirectWithTheToken() async throws {
        let (payload, folder) = try samplePayload()
        let elsewhere = StubHTTP.url(path: "/steal", replies: [(200, #"{"ok":true}"#)])
        for status in [301, 302, 307, 308] {
            let url = StubHTTP.url(path: "/earshot", replies: [(status, elsewhere.absoluteString)])
            let result = await WebhookTarget(url: url, token: { "secret-token" }, session: StubHTTP.session, sleep: { _ in })
                .send(payload, json: try payload.encoded(), folder: folder)
            #expect(result == DispatchResult(ok: false, detail: WebhookTarget.redirected), "\(status)")
            #expect(StubHTTP.requests(url).count == 1, "a redirect is not retried (\(status))")
        }
        #expect(StubHTTP.requests(elsewhere).isEmpty, "the token never reaches the redirect's address")
        let log = try String(contentsOf: folder.appending(path: "do-webhook.log"), encoding: .utf8)
        #expect(log.contains("302") && !log.contains("secret-token"))
    }

    @Test func webhookWithoutATokenStillRefusesARedirect() async throws {
        let (payload, folder) = try samplePayload()
        let elsewhere = StubHTTP.url(path: "/other", replies: [(200, "{}")])
        let url = StubHTTP.url(path: "/earshot", replies: [(302, elsewhere.absoluteString)])
        let result = await WebhookTarget(url: url, token: { nil }, session: StubHTTP.session, sleep: { _ in })
            .send(payload, json: try payload.encoded(), folder: folder)
        #expect(result == DispatchResult(ok: false, detail: WebhookTarget.redirectedNoToken))
        #expect(StubHTTP.requests(elsewhere).isEmpty)
    }

    @Test func webhookGivesUpAfterFourTries() async throws {
        let (payload, folder) = try samplePayload()
        let url = StubHTTP.url(path: "/earshot", replies: Array(repeating: (500, "{}"), count: 5))
        let result = await WebhookTarget(url: url, token: { nil }, session: StubHTTP.session, sleep: { _ in })
            .send(payload, json: try payload.encoded(), folder: folder)
        #expect(!result.ok)
        #expect(StubHTTP.requests(url).count == 4)
    }

    @Test func commandGetsThePayloadOnStdinAndTheFolder() async throws {
        let (payload, folder) = try samplePayload()
        let target = CommandTarget(command: #"cat > "$EARSHOT_SESSION_DIR/got.json""#, runner: ProcessRunner())
        let result = await target.send(payload, json: try payload.encoded(), folder: folder)
        #expect(result.ok)
        #expect(try Data(contentsOf: folder.appending(path: "got.json")) == (try payload.encoded()))
        let failing = await CommandTarget(command: "echo nope >&2; exit 3", runner: ProcessRunner())
            .send(payload, json: try payload.encoded(), folder: folder)
        #expect(!failing.ok && failing.detail.hasPrefix("exit 3: ") && failing.detail.hasSuffix("nope"))
    }

    @Test func onlyTheWebhookIsRepeatedAfterAnInterruption() {
        #expect(WebhookTarget(url: URL(string: "https://example.com/hook")!, token: { nil }).repeatsSafely)
        #expect(!CommandTarget(command: "true").repeatsSafely)
        #expect(!ClaudeCodeTarget(claudePath: "/bin/claude", workingFolder: tempDir(), userName: "Alex").repeatsSafely)
    }

    @Test func aProgramStoppedPartWayReportsAnInterruptedSend() async throws {
        let (payload, folder) = try samplePayload()
        let json = try payload.encoded()
        let stopped = ThrowingRunner(error: CancellationError())
        let claude = await ClaudeCodeTarget(claudePath: "/bin/claude", workingFolder: tempDir(), userName: "Alex",
                                            runner: stopped).send(payload, json: json, folder: folder)
        #expect(!claude.ok && claude.interrupted)
        let command = await CommandTarget(command: "true", runner: stopped).send(payload, json: json, folder: folder)
        #expect(!command.ok && command.interrupted)
        // Any other error is an ordinary failure.
        let broken = await CommandTarget(command: "true", runner: ThrowingRunner(error: CocoaError(.fileNoSuchFile)))
            .send(payload, json: json, folder: folder)
        #expect(!broken.ok && !broken.interrupted)
    }

    @Test func claudeCodeRunsInTheChosenFolderWithThePermissionMode() async throws {
        let (payload, folder) = try samplePayload()
        let work = tempDir()
        let runner = FakeRunner(ProcessOutput(status: 0, stdout: "1. Drafted scope-email.md\n", stderr: "", timedOut: false))
        let target = ClaudeCodeTarget(claudePath: "/bin/claude", workingFolder: work, permissionMode: "acceptEdits",
                                      userName: "Stephen", runner: runner)
        let result = await target.send(payload, json: try payload.encoded(), folder: folder)
        #expect(result.ok && result.detail == "1. Drafted scope-email.md")
        let call = try #require(runner.calls.first)
        // The user's own setup (hooks, plugins, MCP, CLAUDE.md) applies to the Do run, so no --safe-mode here.
        #expect(call.arguments == ["-p", "--permission-mode", "acceptEdits", "--output-format", "text"])
        #expect(call.directory == work)
        #expect(call.environment["PATH"]?.hasPrefix("/bin:/opt/homebrew/bin:/usr/local/bin") == true)
        #expect(call.stdin.contains("Draft the pilot scope email to Dana"))
        #expect(FileManager.default.fileExists(atPath: folder.appending(path: "do-claude-code.log").path))
    }

    @Test func everyModeKeepsItsArgumentsAndGetsOnlyTheAllowlist() async throws {
        let (payload, folder) = try samplePayload()
        let expected: [String: [String]] = [
            "restricted": ["-p", "--restricted", "--permission-mode", "acceptEdits", "--tools", "Read,Edit,Write,Glob,Grep",
                           "--permission-prompts", "none", "--strict-mcp-config", "--disallowedTools", "mcp__*",
                           "--no-session-persistence", "--output-format", "json"],
            "acceptEdits": ["-p", "--permission-mode", "acceptEdits", "--output-format", "text"],
            "auto": ["-p", "--permission-mode", "auto", "--output-format", "text"],
            "bypassPermissions": ["-p", "--permission-mode", "bypassPermissions", "--output-format", "text"],
        ]
        for (mode, arguments) in expected {
            let runner = FakeRunner(claudeOutput(restrictedEnvelope()))
            _ = await ClaudeCodeTarget(claudePath: "/bin/claude", workingFolder: tempDir(), permissionMode: mode,
                                       userName: "Stephen", runner: runner).send(payload, json: try payload.encoded(), folder: folder)
            let call = try #require(runner.calls.first)
            #expect(call.arguments == arguments, "\(mode)")
            #expect(!call.inheritEnvironment, "\(mode)")
            #expect(Set(call.environment.keys).isSubset(of: Set(ClaudeEnvironment.allowlist + ["PATH"])), "\(mode)")
        }
        #expect(ClaudeCodeTarget(claudePath: "/bin/claude", workingFolder: tempDir(), userName: "A").permissionMode == "restricted")
    }

    @Test func restrictedModeReadsTheEnvelope() async throws {
        let (payload, folder) = try samplePayload()
        let runner = FakeRunner(claudeOutput(restrictedEnvelope(result: "Drafted scope-email.md")))
        let result = await ClaudeCodeTarget(claudePath: "/bin/claude", workingFolder: tempDir(), userName: "Stephen",
                                            runner: runner).send(payload, json: try payload.encoded(), folder: folder)
        #expect(result == DispatchResult(ok: true, detail: "Drafted scope-email.md"))
    }

    @Test func restrictedModeDenialsMakeTheSendFailAndNameThePaths() async throws {
        let (payload, folder) = try samplePayload()
        let denials: [[String: Any]] = [
            ["tool_name": "Write", "tool_use_id": "toolu_1", "tool_input": ["file_path": "/Users/alex/outside.txt", "content": "hi"]],
            ["tool_name": "Bash", "tool_use_id": "toolu_2", "tool_input": ["command": "ls"]],
        ]
        let runner = FakeRunner(claudeOutput(restrictedEnvelope(result: "Wrote one file; one was blocked.", denials: denials)))
        let result = await ClaudeCodeTarget(claudePath: "/bin/claude", workingFolder: tempDir(), userName: "Stephen",
                                            runner: runner).send(payload, json: try payload.encoded(), folder: folder)
        #expect(!result.ok && !result.interrupted)
        #expect(result.detail == "Partly done. Denied: /Users/alex/outside.txt, Bash")
        let log = try String(contentsOf: folder.appending(path: "do-claude-code.log"), encoding: .utf8)
        #expect(log.contains("denied: /Users/alex/outside.txt, Bash"))
    }

    @Test func restrictedModeErrorsAndOtherSubtypesFail() async throws {
        let (payload, folder) = try samplePayload()
        // Sign-in, usage-limit and old-CLI failures get the same plain lines as notes (spec 3.1 and 16); the raw
        // text stays in the log. Anything else keeps what Claude Code said.
        let outputs = [
            claudeOutput(restrictedEnvelope(result: "Not logged in", isError: true)),
            claudeOutput(restrictedEnvelope(result: "Claude AI usage limit reached|1760000000", isError: true), status: 1),
            claudeOutput(restrictedEnvelope(result: "", subtype: "error_max_turns")),
            claudeOutput("", status: 1, stderr: "error: unknown option '--permission-prompts'"),
            claudeOutput(restrictedEnvelope(result: "Something broke", isError: true), status: 1),
            claudeOutput("", status: 2, stderr: "boom"),
            ProcessOutput(status: -1, stdout: "", stderr: "", timedOut: true),
        ]
        let details = ["Claude Code is not signed in: run `claude` in Terminal and log in.",
                       "Your Claude usage limit is reached. Press Retry later.", "error_max_turns",
                       "Claude Code is too old; update it.", "Something broke", "exit 2: boom", "timed out"]
        for (output, detail) in zip(outputs, details) {
            let result = await ClaudeCodeTarget(claudePath: "/bin/claude", workingFolder: tempDir(), userName: "Stephen",
                                                runner: FakeRunner(output)).send(payload, json: try payload.encoded(), folder: folder)
            #expect(result == DispatchResult(ok: false, detail: detail))
        }
    }

    @Test func aDispatchResultHasNoLinkUnlessGivenOne() {
        #expect(DispatchResult(ok: true, detail: "x").link == nil)
        #expect(DispatchResult(ok: true, detail: "x", link: "https://claude.ai/code/session_1").link == "https://claude.ai/code/session_1")
    }
}

/// What `claude -p --output-format json` prints at the end of an agentic run.
func restrictedEnvelope(result: String = "done", isError: Bool = false, subtype: String = "success",
                        denials: [[String: Any]] = []) -> String {
    claudeEnvelope(["type": "result", "subtype": subtype, "is_error": isError, "result": result,
                    "permission_denials": denials])
}
