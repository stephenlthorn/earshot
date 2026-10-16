import Foundation
import Testing
@testable import EarshotKit

/// Returns fixed segments and records whether this process held the meeting's busy marker when it was called.
private struct MarkerCheckingTranscriber: Transcribing {
    let busyWhileTranscribing = Locked<[Bool]>([])
    let calls = Locked(0)
    /// The send stage as session.json had it while this ran: what the app would find after a kill -9 here.
    let dispatchWhileTranscribing = Locked<[StageState?]>([])
    /// Runs inside the call, before it returns; a test uses it to press Ctrl-C mid-stage.
    var during: @Sendable () throws -> Void = {}

    func transcribe(_ file: URL, track: Track, locale: Locale) async throws -> [Segment] {
        calls.update { $0 += 1 }
        let folder = file.deletingLastPathComponent()
        let marker = (try? String(contentsOf: folder.appending(path: MeetingFile.busy), encoding: .utf8)) ?? ""
        busyWhileTranscribing.update { $0.append(marker.hasPrefix("\(ProcessInfo.processInfo.processIdentifier) ")) }
        let session = try? JSONFiles.read(Session.self, from: folder.appending(path: MeetingFile.session))
        dispatchWhileTranscribing.update { $0.append(session?.stages[.dispatch]) }
        try during()
        return [Segment(track: .speaker, start: 2, end: 4, text: "Dana, I'll send the scope by Friday.")]
    }
}

/// Copies instead of encoding; every file lasts two minutes.
private struct CopyingCompressor: AudioCompressing {
    func compress(_ source: URL, to destination: URL) async throws {
        try FileManager.default.copyItem(at: source, to: destination)
    }

    func duration(of file: URL) throws -> Double { 120 }
}

struct CLIProcessTests {
    private func harness(_ change: (inout CLIHarness) -> Void = { _ in }) throws -> (CLIHarness, URL) {
        var h = CLIHarness()
        h.runner = FakeRunner(ProcessOutput(status: 0, stdout: claudeJSON(), stderr: "", timedOut: false))
        change(&h)
        let audio = h.home.appending(path: "memo.m4a")
        try Data("audio".utf8).write(to: audio)
        return (h, audio)
    }

    private func run(_ h: CLIHarness, transcriber: MarkerCheckingTranscriber = MarkerCheckingTranscriber(),
                     _ words: [String]) async -> (code: Int32, out: String, err: String) {
        let printed = Printed()
        var io = h.io(printed)
        io.transcriber = transcriber
        io.compressor = CopyingCompressor()
        let code = await EarshotCLI.main(["earshot", "process"] + words, io: io)
        return (code, printed.out.get, printed.err.get)
    }

    @Test func processWritesNotesHoldingTheBusyMarkerAndIndexesTheMeeting() async throws {
        let (h, audio) = try harness()
        let transcriber = MarkerCheckingTranscriber()
        let result = await run(h, transcriber: transcriber, [audio.path, "--title", "Acme kickoff", "--json"])
        #expect(result.code == 0, "\(result.err)")
        #expect(transcriber.busyWhileTranscribing.get == [true])
        let report = try JSONFiles.decoder().decode(EarshotCLI.ProcessReport.self, from: Data(result.out.utf8))
        #expect(report.title == "Acme kickoff" && report.finished && report.sent.isEmpty && report.error == nil)
        #expect(report.notes == report.folder + "/notes.md")
        let session = try #require(h.store.all().first)
        #expect(session.id == report.id && session.startedBy == .cli && session.mode == .notes && session.folderName.hasSuffix("Acme kickoff"))
        #expect(!FileManager.default.fileExists(atPath: h.store.file(session, MeetingFile.busy).path))
        #expect(!h.store.isBusy(session))
        let entry = try #require(h.index.entry(id: session.id))
        #expect(entry.record.notes?.title == "Acme kickoff" && entry.transcript.first?.text == "Dana, I'll send the scope by Friday.")
        #expect(FileManager.default.fileExists(atPath: h.indexURL.appending(path: LibraryIndex.remindersFile).path))
        // Notes went through the user's own claude with the allowlist environment.
        let call = try #require((h.runner as? FakeRunner)?.calls.first)
        #expect(call.executable == "/opt/fake/claude" && !call.inheritEnvironment && call.arguments.contains("--json-schema"))
        #expect(call.environment["ANTHROPIC_API_KEY"] == nil)
        #expect(result.err.contains("earshot: Transcribing...\n"))
    }

    @Test func processTakesLessonsFromTheLessonsFileItIsGiven() async throws {
        let lessons = tempDir().appending(path: "lessons.json")
        try LessonsStore(url: lessons).add(LessonDiff.instruction("Name the budget owner in every summary", style: .general,
                                                                  title: "Earlier", date: at1530))
        let (h, audio) = try harness { $0.environment["EARSHOT_LESSONS_FILE"] = lessons.path }
        let result = await run(h, [audio.path])
        #expect(result.code == 0, "\(result.err)")
        let call = try #require((h.runner as? FakeRunner)?.calls.first)
        #expect((call.stdin + call.arguments.joined(separator: "\n")).contains("Name the budget owner in every summary"))
        // The lessons under the run's home were never read or made.
        #expect(!FileManager.default.fileExists(atPath: LessonsStore.defaultURL(home: h.home).path))
    }

    @Test func processPrintsWhereTheNotesAre() async throws {
        let (h, audio) = try harness()
        let result = await run(h, [audio.path])
        #expect(result.code == 0)
        let session = try #require(h.store.all().first)
        // Untitled: the notes title names the folder, as in the app.
        #expect(result.out == "Acme kickoff: \(h.store.folder(session).path)\nNotes: \(h.store.file(session, "notes.md").path)\n")
    }

    @Test func processSendsToTheWebhookWithTheTokenFromTheEnvironment() async throws {
        let url = StubHTTP.url(path: "/hook", replies: [(200, "{}")])
        let (h, audio) = try harness { h in
            h.settings?.webhookOn = true
            h.settings?.webhookURL = url.absoluteString
            h.environment["EARSHOT_WEBHOOK_TOKEN"] = "tok-123"
        }
        let result = await run(h, [audio.path, "--send", "--target", "webhook", "--yes", "--json"])
        #expect(result.code == 0, "\(result.err)")
        let report = try JSONFiles.decoder().decode(EarshotCLI.ProcessReport.self, from: Data(result.out.utf8))
        #expect(report.sent == ["webhook"] && report.finished)
        let request = try #require(StubHTTP.requests(url).first)
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer tok-123")
        let payload = try JSONDecoder().decode(DoPayload.self, from: try #require(request.httpBody))
        #expect(payload.items.map(\.task) == ["Draft the pilot scope email to Dana"])  // the AI's items only
        #expect(try #require(h.store.all().first).mode == .notesAndDo)
    }

    @Test func processSendsToClaudeCodeOnlyInRestrictedMode() async throws {
        let work = tempDir()
        let envelope = #"{"type":"result","subtype":"success","is_error":false,"result":"Drafted.","permission_denials":[]}"#
        let (h, audio) = try harness { h in
            h.settings?.claudeCodeTargetOn = true
            h.settings?.claudeCodeFolder = work.path
            h.runner = FakeRunner(ProcessOutput(status: 0, stdout: claudeJSON(), stderr: "", timedOut: false),
                                  ProcessOutput(status: 0, stdout: envelope, stderr: "", timedOut: false))
        }
        let result = await run(h, [audio.path, "--send", "--target", "claude-code", "--yes"])
        #expect(result.code == 0, "\(result.err)")
        let calls = try #require((h.runner as? FakeRunner)?.calls)
        #expect(calls.count == 2 && calls[1].arguments.contains("--restricted") && calls[1].directory == work)
        #expect(result.out.contains("Sent to Claude Code."))
    }

    @Test func everySendRefusalStopsBeforeAnyWork() async throws {
        let refusals: [([String], String, (inout CLIHarness) -> Void)] = [
            (["--target", "webhook"], "--target and --yes work only with --send. Without --send, process never sends anything.", { _ in }),
            (["--yes"], "--target and --yes work only with --send. Without --send, process never sends anything.", { _ in }),
            (["--send", "--yes"], "--send needs --target <id>: webhook, routine or claude-code.", { _ in }),
            (["--send", "--target", "webhook"], "--send needs --yes to confirm that the AI's action items are sent without the confirm window.", { _ in }),
            (["--send", "--target", "command", "--yes"], "earshot process never sends to the Command target, because it runs a shell command. Use webhook, routine or claude-code.",
             { $0.settings?.commandOn = true; $0.settings?.command = "cat" }),
            (["--send", "--target", "slack", "--yes"], "There's no Do target \"slack\". Use webhook, routine or claude-code.", { _ in }),
            (["--send", "--target", "routine", "--yes"], "The routine target is off. Turn it on and set it up in Earshot Settings, Do.",
             { $0.environment["EARSHOT_ROUTINE_TOKEN"] = "sk-ant-oat01-x" }),
            (["--send", "--target", "claude-code", "--yes"], "earshot process sends to Claude Code only in restricted mode, and Earshot is set to bypassPermissions. Choose Restricted in Earshot Settings, Do.",
             { $0.settings?.claudeCodeTargetOn = true; $0.settings?.claudeCodeFolder = "/tmp"; $0.settings?.permissionMode = "bypassPermissions" }),
            (["--send", "--target", "webhook", "--yes"], "The webhook target is off. Turn it on and set it up in Earshot Settings, Do.", { _ in }),
            (["--send", "--target", "claude-code", "--yes"], EarshotSettings.noWorkFolder, { $0.settings?.claudeCodeTargetOn = true }),
            ([], "Earshot is set to use an API key, and earshot reads it only from ANTHROPIC_API_KEY. Set it, or switch to Claude Code in Settings.",
             { $0.settings?.provider = .claudeAPI }),
        ]
        for (words, message, change) in refusals {
            let (h, audio) = try harness(change)
            let transcriber = MarkerCheckingTranscriber()
            let result = await run(h, transcriber: transcriber, [audio.path] + words)
            #expect(result.code == 2, "\(words)")
            #expect(result.err.hasPrefix("earshot: \(message)\n"), "\(words): \(result.err)")
            #expect(h.store.all().isEmpty && transcriber.calls.get == 0, "\(words)")
            #expect((h.runner as? FakeRunner)?.calls.isEmpty == true, "\(words)")
        }
    }

    @Test func processNeedsAFileThatExists() async throws {
        let (h, _) = try harness()
        let missing = await run(h, ["/nowhere/memo.m4a"])
        #expect(missing.code == 1 && missing.err == "earshot: There's no audio file at /nowhere/memo.m4a.\n")
        #expect(await run(h, []).code == 2)
    }

    @Test func aFailedStageExitsOneAndStillClearsTheMarker() async throws {
        let (h, audio) = try harness { $0.runner = FakeRunner(ProcessOutput(status: 1, stdout: "", stderr: "boom", timedOut: false)) }
        let result = await run(h, [audio.path, "--json"])
        #expect(result.code == 1)
        let report = try JSONFiles.decoder().decode(EarshotCLI.ProcessReport.self, from: Data(result.out.utf8))
        #expect(!report.finished && report.notes == nil && report.error?.hasPrefix("Writing notes failed: ") == true)
        let session = try #require(h.store.all().first)
        #expect(!FileManager.default.fileExists(atPath: h.store.file(session, MeetingFile.busy).path))
        #expect(session.stages[.notes]?.status == .failed && h.index.entry(id: session.id) != nil)
    }

    @Test func processNeverSendsWithoutTheFlagsEvenWithTargetsOn() async throws {
        let url = StubHTTP.url(path: "/hook", replies: [(200, "{}")])
        let work = tempDir()
        let (h, audio) = try harness { h in
            h.settings?.webhookOn = true
            h.settings?.webhookURL = url.absoluteString
            h.environment["EARSHOT_WEBHOOK_TOKEN"] = "tok-123"
            h.settings?.claudeCodeTargetOn = true
            h.settings?.claudeCodeFolder = work.path
            h.settings?.permissionMode = ClaudeCodeTarget.restricted
        }
        let result = await run(h, [audio.path, "--json"])
        #expect(result.code == 0, "\(result.err)")
        let report = try JSONFiles.decoder().decode(EarshotCLI.ProcessReport.self, from: Data(result.out.utf8))
        #expect(report.sent.isEmpty && report.finished)
        #expect(StubHTTP.requests(url).isEmpty)
        let session = try #require(h.store.all().first)
        #expect(session.mode == .notes && session.sent.isEmpty)
        let calls = try #require((h.runner as? FakeRunner)?.calls)
        #expect(calls.count == 1 && calls[0].arguments.contains("--json-schema"))  // the notes call only
    }

    @Test func aFailedSendLeavesNoChosenItemsAndIsNeverResumedOnItsOwn() async throws {
        let url = StubHTTP.url(path: "/hook", replies: [(500, "{}")])
        let (h, audio) = try harness { h in
            h.settings?.webhookOn = true
            h.settings?.webhookURL = url.absoluteString
        }
        let result = await run(h, [audio.path, "--send", "--target", "webhook", "--yes", "--json"])
        #expect(result.code == 1)
        #expect(!StubHTTP.requests(url).isEmpty)
        let report = try JSONFiles.decoder().decode(EarshotCLI.ProcessReport.self, from: Data(result.out.utf8))
        #expect(!report.finished && report.sent.isEmpty && report.error?.hasPrefix("Sending failed: ") == true)
        let session = try #require(h.store.all().first)
        // The app must not send the AI's picks on its own later: no saved picks, and the stage is past the auto-resume stop.
        #expect(!FileManager.default.fileExists(atPath: h.store.file(session, "items.json").path))
        #expect(session.stages[.dispatch]?.status == .failed && (session.stages[.dispatch]?.failures ?? 0) >= 2)
        #expect(h.store.resumable().isEmpty && !h.store.isBusy(session))
    }

    @Test func aSendCutOffByCtrlCIsHeldForAPerson() async throws {
        let work = tempDir()
        var h = CLIHarness()
        let interrupt = h.interrupt
        h.runner = InterruptingRunner(first: ProcessOutput(status: 0, stdout: claudeJSON(), stderr: "", timedOut: false),
                                      press: { interrupt.get?() })
        h.settings?.claudeCodeTargetOn = true
        h.settings?.claudeCodeFolder = work.path
        h.settings?.permissionMode = ClaudeCodeTarget.restricted
        let audio = h.home.appending(path: "memo.m4a")
        try Data("audio".utf8).write(to: audio)
        let result = await run(h, [audio.path, "--send", "--target", "claude-code", "--yes", "--json"])
        #expect(result.code == 1)
        let report = try JSONFiles.decoder().decode(EarshotCLI.ProcessReport.self, from: Data(result.out.utf8))
        #expect(!report.finished && report.error == EarshotCLI.sendInterrupted)
        let session = try #require(h.store.all().first)
        #expect(!FileManager.default.fileExists(atPath: h.store.file(session, "items.json").path))
        #expect(session.stages[.dispatch] == StageState(status: .failed, error: EarshotCLI.sendInterrupted, failures: 2))
        #expect(h.store.resumable().isEmpty && !h.store.isBusy(session))
        #expect(h.interrupt.get == nil)  // the handler is removed when process is done
    }

    @Test func aSecondCtrlCDuringTheSendHoldsItBeforeQuitting() async throws {
        // The real tool quits (exit 130) right after the clean-up, so what is on disk then is what the app finds.
        let work = tempDir()
        var h = CLIHarness()
        let (force, store) = (h.force, h.store)
        let onDisk = Locked<(StageState?, Bool)?>(nil)
        h.runner = InterruptingRunner(first: ProcessOutput(status: 0, stdout: claudeJSON(), stderr: "", timedOut: false),
                                      press: {
                                          let before = store.all().first
                                          let picked = before.map { FileManager.default.fileExists(atPath: store.file($0, "items.json").path) }
                                          #expect(before?.stages[.dispatch]?.status == .running && picked == true)
                                          force.get?()
                                          let after = store.all().first
                                          onDisk.update { $0 = (after?.stages[.dispatch], after.map {
                                              FileManager.default.fileExists(atPath: store.file($0, "items.json").path) } ?? true) }
                                      })
        h.settings?.claudeCodeTargetOn = true
        h.settings?.claudeCodeFolder = work.path
        h.settings?.permissionMode = ClaudeCodeTarget.restricted
        let audio = h.home.appending(path: "memo.m4a")
        try Data("audio".utf8).write(to: audio)
        _ = await run(h, [audio.path, "--send", "--target", "claude-code", "--yes", "--json"])
        let (dispatch, itemsLeft) = try #require(onDisk.get)
        #expect(dispatch == StageState(status: .failed, error: EarshotCLI.sendInterrupted, failures: 2))
        #expect(!itemsLeft)
        #expect(h.force.get == nil)
    }

    @Test func aSecondCtrlCAfterTheSendLeavesTheSentMeetingAlone() async throws {
        let url = StubHTTP.url(path: "/hook", replies: [(200, "{}")])
        let (h, audio) = try harness { h in
            h.settings?.webhookOn = true
            h.settings?.webhookURL = url.absoluteString
        }
        let printed = Printed()
        var io = h.io(printed)
        io.transcriber = MarkerCheckingTranscriber()
        io.compressor = CopyingCompressor()
        // Ctrl-C twice while the report prints: the send is done, so its picks stay and nothing is marked failed.
        let (force, interrupt, out) = (h.force, h.interrupt, io.out)
        let trapped = Locked<[Bool]>([])
        io.out = { text in
            trapped.update { $0.append(interrupt.get != nil) }
            force.get?()
            out(text)
        }
        let code = await EarshotCLI.main(["earshot", "process", audio.path, "--send", "--target", "webhook", "--yes"], io: io)
        #expect(code == 0, "\(printed.err.get)")
        // Still trapped after the send was checked and held, so no Ctrl-C in between gets the default handling.
        #expect(trapped.get == [true])
        let session = try #require(h.store.all().first)
        #expect(session.stages[.dispatch] == StageState(status: .done) && session.sent == ["webhook"])
        #expect(FileManager.default.fileExists(atPath: h.store.file(session, "items.json").path))
    }

    @Test func eachCtrlCDoesMoreThanTheLast() {
        #expect(EarshotCLI.interruptAction(press: 1) == .stop)
        #expect(EarshotCLI.interruptAction(press: 2) == .cleanUpAndQuit)
        #expect(EarshotCLI.interruptAction(press: 3) == .quit)
        #expect(EarshotCLI.interruptAction(press: 9) == .quit)
    }

    @Test func whileProcessRunsTheSendIsMarkedNeverToResumeOnItsOwn() async throws {
        // A kill -9 leaves no chance to clean up, so the stop is on disk before any work starts.
        let url = StubHTTP.url(path: "/hook", replies: [(200, "{}")])
        let (h, audio) = try harness { h in
            h.settings?.webhookOn = true
            h.settings?.webhookURL = url.absoluteString
        }
        let transcriber = MarkerCheckingTranscriber()
        let result = await run(h, transcriber: transcriber, [audio.path, "--send", "--target", "webhook", "--yes"])
        #expect(result.code == 0, "\(result.err)")
        #expect(transcriber.dispatchWhileTranscribing.get.map { $0?.failures } == [2])
        #expect(try #require(h.store.all().first).stages[.dispatch] == StageState(status: .done))
        let plain = try harness()
        let notesOnly = MarkerCheckingTranscriber()
        _ = await run(plain.0, transcriber: notesOnly, [plain.1.path])
        #expect(notesOnly.dispatchWhileTranscribing.get.map { $0?.failures ?? 0 } == [0])
    }

    @Test func aMeetingLeftUnfinishedWithoutAFailureStillExitsOne() async throws {
        let (h, audio) = try harness()
        var transcriber = MarkerCheckingTranscriber()
        let interrupt = h.interrupt
        transcriber.during = {
            interrupt.get?()
            throw CancellationError()
        }
        let result = await run(h, transcriber: transcriber, [audio.path, "--json"])
        #expect(result.code == 1)
        let report = try JSONFiles.decoder().decode(EarshotCLI.ProcessReport.self, from: Data(result.out.utf8))
        #expect(!report.finished && report.error == EarshotCLI.notFinished)
        #expect(result.err.hasSuffix("earshot: \(EarshotCLI.notFinished)\n"))
    }

    @Test func theAPIProviderStillFindsClaudeForTheClaudeCodeTarget() async throws {
        let work = tempDir()
        let api = StubHTTP.url(replies: [(200, apiReply())])
        let envelope = #"{"type":"result","subtype":"success","is_error":false,"result":"Drafted.","permission_denials":[]}"#
        let (h, audio) = try harness { h in
            h.settings?.provider = .claudeAPI
            h.environment["ANTHROPIC_API_KEY"] = "sk-test"
            h.apiEndpoint = api
            h.settings?.claudeCodeTargetOn = true
            h.settings?.claudeCodeFolder = work.path
            h.settings?.permissionMode = ClaudeCodeTarget.restricted
            h.runner = FakeRunner(ProcessOutput(status: 0, stdout: envelope, stderr: "", timedOut: false))
        }
        let result = await run(h, [audio.path, "--send", "--target", "claude-code", "--yes"])
        #expect(result.code == 0, "\(result.err)")
        #expect(StubHTTP.requests(api).first?.value(forHTTPHeaderField: "x-api-key") == "sk-test")  // notes went by the API
        let calls = try #require((h.runner as? FakeRunner)?.calls)
        #expect(calls.count == 1 && calls[0].executable == "/opt/fake/claude" && calls[0].arguments.contains("--restricted"))
        #expect(calls[0].environment["ANTHROPIC_API_KEY"] == nil && !calls[0].inheritEnvironment)
        #expect(result.out.contains("Sent to Claude Code."))
    }
}

/// Answers the notes call, then presses Ctrl-C during the send and stops as ProcessRunner does when it is cancelled.
private final class InterruptingRunner: ProcessRunning, @unchecked Sendable {
    let first: ProcessOutput
    let press: @Sendable () -> Void
    private let calls = Locked(0)

    init(first: ProcessOutput, press: @escaping @Sendable () -> Void) {
        self.first = first
        self.press = press
    }

    func run(_ executable: String, _ arguments: [String], stdin: Data?, directory: URL?,
             environment: [String: String], inheritEnvironment: Bool, timeout: Duration) async throws -> ProcessOutput {
        var count = 0
        calls.update { $0 += 1; count = $0 }
        guard count > 1 else { return first }
        press()
        throw CancellationError()
    }
}
