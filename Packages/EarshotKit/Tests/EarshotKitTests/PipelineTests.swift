import Foundation
import Testing
@testable import EarshotKit

struct FakeTranscriber: Transcribing {
    var segments: [Track: [Segment]]
    let calls = Locked(0)
    func transcribe(_ file: URL, track: Track, locale: Locale) async throws -> [Segment] {
        calls.update { $0 += 1 }
        return segments[track] ?? []
    }
}

final class FakeWriter: NotesWriter, @unchecked Sendable {
    let result = Locked<Result<MeetingNotes, NotesError>>(.success(sampleNotes))
    /// When set, `write` throws this instead of answering `result`.
    let failure = Locked<(any Error)?>(nil)
    let calls = Locked(0)
    /// While true, `write` waits, so a test can act while the notes stage is in flight.
    let held = Locked(false)
    func write(_ request: NotesRequest) async throws -> MeetingNotes {
        calls.update { $0 += 1 }
        while held.get { try await Task.sleep(for: .milliseconds(5)) }
        if let error = failure.get { throw error }
        return try result.get.get()
    }
}

/// Cancels the task that called it, then fails the way URLSession does when its task is cancelled.
struct CancelsItsCallerWriter: NotesWriter {
    func write(_ request: NotesRequest) async throws -> MeetingNotes {
        withUnsafeCurrentTask { $0?.cancel() }
        throw URLError(.cancelled)
    }
}

struct FakeCompressor: AudioCompressing {
    func compress(_ source: URL, to destination: URL) async throws {
        try FileManager.default.copyItem(at: source, to: destination)
    }
    func duration(of file: URL) throws -> Double { 2400 }
}

/// Copies like `FakeCompressor`, then makes `lockedFile` impossible to replace, as a full or failing disk would.
struct DiskFailsAfterCopyCompressor: AudioCompressing {
    let lockedFile: URL
    func compress(_ source: URL, to destination: URL) async throws {
        try FileManager.default.copyItem(at: source, to: destination)
        setLocked(true, lockedFile)
    }
    func duration(of file: URL) throws -> Double { 2400 }
}

/// Marks a file immutable (or not): replacing or saving over it fails until it is unlocked.
func setLocked(_ locked: Bool, _ file: URL) {
    try? FileManager.default.setAttributes([.immutable: locked], ofItemAtPath: file.path)
}

final class FakeTarget: DoTarget, @unchecked Sendable {
    let id: String
    let label: String
    let repeatsSafely: Bool
    let ok: Locked<Bool>
    /// When true, `send` reports that its program was stopped part-way, as quitting the app does.
    let interrupts = Locked(false)
    let sent = Locked<[DoPayload]>([])
    /// What session.json said was in flight while this target was sending.
    let inFlightWhileSending = Locked<[String]?>(nil)
    init(_ id: String, label: String? = nil, ok: Bool = true, repeatsSafely: Bool = false) {
        self.id = id
        self.label = label ?? id.capitalized
        self.repeatsSafely = repeatsSafely
        self.ok = Locked(ok)
    }
    func send(_ payload: DoPayload, json: Data, folder: URL) async -> DispatchResult {
        sent.update { $0.append(payload) }
        let onDisk = try? SessionStore(root: folder.deletingLastPathComponent()).load(folderName: folder.lastPathComponent)
        inFlightWhileSending.update { $0 = onDisk?.inFlight }
        if interrupts.get { return DispatchResult(ok: false, detail: "stopped", interrupted: true) }
        return DispatchResult(ok: ok.get, detail: ok.get ? "ok" : "down")
    }
}

/// What a crash in the middle of sending leaves, after the next launch's recover(): notes written, items chosen,
/// `inFlight` naming the targets that were sending, and the dispatch stage back to pending.
func crashedWhileSending(_ h: Harness, inFlight: [String]) throws -> Session {
    var s = try h.stoppedSession()
    try Pipeline.json(meetingSegments.values.flatMap { $0 }).write(to: h.store.file(s, "transcript.json"))
    try Pipeline.json(sampleNotes).write(to: h.store.file(s, "notes.json"))
    try Data("# Acme kickoff\n".utf8).write(to: h.store.file(s, "notes.md"))
    try Pipeline.json([sampleNotes.actionItems[0]]).write(to: h.store.file(s, "items.json"))
    s.stages[.transcribe] = StageState(status: .done)
    s.stages[.notes] = StageState(status: .done)
    s.stages[.dispatch] = StageState(status: .running)
    s.inFlight = inFlight
    try h.store.save(s)
    try h.store.recover()
    return s
}

let meetingSegments: [Track: [Segment]] = [
    .me: [Segment(track: .me, start: 1, end: 3, text: "Dana, I'll send the scope by Friday.")],
    .them: [Segment(track: .them, start: 4, end: 6, text: "Great, thanks.")],
]

struct Harness {
    let store = SessionStore(root: tempDir(), timeZone: newYork)
    var transcriber = FakeTranscriber(segments: meetingSegments)
    let writer = FakeWriter()
    var targets: [FakeTarget] = [FakeTarget("webhook")]
    let events = Locked<[PipelineEvent]>([])

    func pipeline(keepAudio: Bool = true, writer replacement: (any NotesWriter)? = nil,
                  confirm: @escaping Pipeline.Confirm = { _, notes in ActionItem.defaultSelection(notes.actionItems) }) -> Pipeline {
        let writer: any NotesWriter = replacement ?? self.writer, targets = self.targets, events = self.events
        return Pipeline(store: store, transcriber: transcriber, compressor: FakeCompressor(),
                        makeWriter: { writer }, makeTargets: { targets },
                        config: { PipelineConfig(userName: "Stephen", locale: Locale(identifier: "en-US"),
                                                 keepAudio: keepAudio, timeZone: newYork) },
                        confirm: confirm, events: { event in events.update { $0.append(event) } }, lanes: TargetLanes())
    }

    func stoppedSession(mode: Mode = .notesAndDo, title: String? = "Acme kickoff") throws -> Session {
        var session = try store.create(mode: mode, title: title, now: at1530)
        try Data("mic".utf8).write(to: store.file(session, "mic.caf"))
        try Data("sys".utf8).write(to: store.file(session, "system.caf"))
        session.tracks = [TrackFile(track: .me, file: "mic.caf", offset: 0), TrackFile(track: .them, file: "system.caf", offset: 0)]
        session.recording = false
        session.endedAt = at1530.addingTimeInterval(2400)
        try store.save(session)
        return session
    }
}

struct PipelineTests {
    @Test func notesAndDoRunsEveryStageInOrder() async throws {
        let h = Harness()
        let s = try h.stoppedSession()
        await h.pipeline().run(sessionID: s.id)
        let done = try h.store.load(folderName: s.folderName)
        #expect(done.isFinished)
        #expect(try String(contentsOf: h.store.file(done, "transcript.md"), encoding: .utf8)
                == "[00:00:01] Stephen: Dana, I'll send the scope by Friday.\n[00:00:04] Them: Great, thanks.\n")
        #expect(FileManager.default.fileExists(atPath: h.store.file(done, "notes.md").path))
        // The item carries its notes item ("n1") as `source` (v2, spec 6); receivers ignore the key.
        var first = sampleNotes.actionItems[0]
        first.source = "n1"
        #expect(h.targets[0].sent.get.first?.items == [first])
        #expect(done.sent == ["webhook"])
        #expect(done.tracks.map(\.file) == ["mic.m4a", "system.m4a"])
        #expect(!FileManager.default.fileExists(atPath: h.store.file(done, "mic.caf").path))
        #expect(h.events.get.first == .started(sessionID: s.id, stage: .transcribe))
        #expect(h.events.get.last == .finished(sessionID: s.id))
    }

    @Test func noSpeechSkipsClaudeAndDispatch() async throws {
        var h = Harness()
        h.transcriber = FakeTranscriber(segments: [:])
        let s = try h.stoppedSession(title: nil)
        await h.pipeline().run(sessionID: s.id)
        let done = try h.store.load(folderName: s.folderName)
        #expect(done.isFinished)
        #expect(h.writer.calls.get == 0)
        #expect(h.targets[0].sent.get.isEmpty)
        #expect(try JSONDecoder().decode(MeetingNotes.self, from: Data(contentsOf: h.store.file(done, "notes.json"))) == .noSpeech)
    }

    @Test func aFailedStageStopsCountsAndCanBeRetried() async throws {
        let h = Harness()
        h.writer.result.update { $0 = .failure(.badKey) }
        let s = try h.stoppedSession()
        let pipeline = h.pipeline()
        await pipeline.run(sessionID: s.id)
        var now = try h.store.load(folderName: s.folderName)
        #expect(now.stages[.notes] == StageState(status: .failed, error: NotesError.badKey.errorDescription, failures: 1))
        #expect(now.stages[.compress]?.status == .pending)
        #expect(h.events.get.contains(.failed(sessionID: s.id, stage: .notes, message: NotesError.badKey.errorDescription!)))
        await pipeline.run(sessionID: s.id)
        #expect(try h.store.load(folderName: s.folderName).stages[.notes]?.failures == 2)
        #expect(h.store.resumable().isEmpty)
        h.writer.result.update { $0 = .success(sampleNotes) }
        await pipeline.retry(sessionID: s.id)
        now = try h.store.load(folderName: s.folderName)
        #expect(now.isFinished)
    }

    @Test func retrySendsOnlyTheTargetsThatFailed() async throws {
        var h = Harness()
        let webhook = FakeTarget("webhook", ok: false), command = FakeTarget("command")
        h.targets = [webhook, command]
        let s = try h.stoppedSession()
        let confirms = Locked(0)
        let pipeline = h.pipeline(confirm: { _, notes in
            confirms.update { $0 += 1 }
            return ActionItem.defaultSelection(notes.actionItems)
        })
        await pipeline.run(sessionID: s.id)
        var now = try h.store.load(folderName: s.folderName)
        #expect(now.stages[.dispatch]?.status == .failed)
        #expect(now.stages[.dispatch]?.error == "Webhook: down")
        #expect(now.sent == ["command"])
        webhook.ok.update { $0 = true }
        await pipeline.retry(sessionID: s.id)
        now = try h.store.load(folderName: s.folderName)
        #expect(now.isFinished)
        #expect(webhook.sent.get.count == 2 && command.sent.get.count == 1)
        #expect(confirms.get == 1)
    }

    @Test func aTargetIsMarkedInFlightOnDiskBeforeItSends() async throws {
        let h = Harness()
        let s = try h.stoppedSession()
        await h.pipeline().run(sessionID: s.id)
        #expect(h.targets[0].inFlightWhileSending.get == ["webhook"])
        let done = try h.store.load(folderName: s.folderName)
        #expect(done.sent == ["webhook"] && done.inFlight.isEmpty)
    }

    @Test func claudeCodeCutOffMidSendIsNeverSentAgainOnItsOwn() async throws {
        var h = Harness()
        let claude = FakeTarget("claude-code", label: "Claude Code"), webhook = FakeTarget("webhook", repeatsSafely: true)
        h.targets = [claude, webhook]
        let s = try crashedWhileSending(h, inFlight: ["claude-code"])
        let pipeline = h.pipeline()
        await pipeline.resumeAll()
        var now = try h.store.load(folderName: s.folderName)
        #expect(claude.sent.get.isEmpty)
        #expect(now.stages[.dispatch]?.status == .failed)
        #expect(now.stages[.dispatch]?.error == "Interrupted while sending to Claude Code. Press Retry to send again.")
        #expect(h.events.get.contains(.failed(sessionID: s.id, stage: .dispatch,
                                              message: "Interrupted while sending to Claude Code. Press Retry to send again.")))
        // The other targets still go: the webhook had not been sent.
        #expect(webhook.sent.get.count == 1 && now.sent == ["webhook"])
        await pipeline.resumeAll()  // the next launch
        #expect(claude.sent.get.isEmpty)
        await pipeline.retry(sessionID: s.id)
        now = try h.store.load(folderName: s.folderName)
        #expect(claude.sent.get.count == 1 && webhook.sent.get.count == 1)
        #expect(now.isFinished && now.inFlight.isEmpty && Set(now.sent) == ["webhook", "claude-code"])
    }

    @Test func aCommandCutOffMidSendWaitsForRetryToo() async throws {
        var h = Harness()
        let command = FakeTarget("command")
        h.targets = [command]
        let s = try crashedWhileSending(h, inFlight: ["command"])
        await h.pipeline().resumeAll()
        #expect(command.sent.get.isEmpty)
        #expect(try h.store.load(folderName: s.folderName).stages[.dispatch]?.error
                == "Interrupted while sending to Command. Press Retry to send again.")
    }

    @Test func aWebhookCutOffMidSendIsSentAgainOnItsOwn() async throws {
        var h = Harness()
        let webhook = FakeTarget("webhook", repeatsSafely: true)
        h.targets = [webhook]
        let s = try crashedWhileSending(h, inFlight: ["webhook"])
        await h.pipeline().resumeAll()
        let done = try h.store.load(folderName: s.folderName)
        #expect(webhook.sent.get.count == 1)
        #expect(done.isFinished && done.sent == ["webhook"] && done.inFlight.isEmpty)
    }

    @Test func aSendStoppedByQuittingIsNotAFailureAndWaitsForRetry() async throws {
        var h = Harness()
        let claude = FakeTarget("claude-code", label: "Claude Code")
        claude.interrupts.update { $0 = true }
        h.targets = [claude]
        let s = try h.stoppedSession()
        let pipeline = h.pipeline()
        await pipeline.run(sessionID: s.id)
        let stopped = try h.store.load(folderName: s.folderName)
        #expect(stopped.stages[.dispatch] == StageState(status: .pending))
        #expect(stopped.inFlight == ["claude-code"] && stopped.sent.isEmpty)
        #expect(!h.events.get.contains { if case .failed = $0 { true } else { false } })
        claude.interrupts.update { $0 = false }
        await pipeline.resumeAll()  // the next launch
        #expect(claude.sent.get.count == 1)  // only the attempt that was stopped
        #expect(try h.store.load(folderName: s.folderName).stages[.dispatch]?.error
                == "Interrupted while sending to Claude Code. Press Retry to send again.")
    }

    @Test func aTargetThatCantRunFailsTheStageAndRetryWorksOnceItCan() async throws {
        let h = Harness()
        let s = try h.stoppedSession()
        let fixed = Locked(false)
        let claude = FakeTarget("claude-code", label: "Claude Code")
        let broken = UnavailableTarget(id: "claude-code", label: "Claude Code", reason: EarshotSettings.noWorkFolder)
        let pipeline = Pipeline(store: h.store, transcriber: h.transcriber, compressor: FakeCompressor(),
                                makeWriter: { h.writer }, makeTargets: { fixed.get ? [claude] : [broken] },
                                config: { PipelineConfig(userName: "Stephen", timeZone: newYork) },
                                confirm: { _, notes in ActionItem.defaultSelection(notes.actionItems) },
                                events: { event in h.events.update { $0.append(event) } }, lanes: TargetLanes())
        await pipeline.run(sessionID: s.id)
        let failed = try h.store.load(folderName: s.folderName)
        #expect(failed.stages[.dispatch]?.status == .failed)
        #expect(failed.stages[.dispatch]?.error == "Claude Code: Choose a work folder for Claude Code in Settings, Do.")
        fixed.update { $0 = true }
        await pipeline.retry(sessionID: s.id)
        #expect(try h.store.load(folderName: s.folderName).isFinished && claude.sent.get.count == 1)
    }

    @Test func sendingTargetsAreTheInFlightOnesWhileDispatchRuns() throws {
        let h = Harness()
        var s = try h.stoppedSession()
        s.inFlight = ["claude-code"]
        #expect(s.sendingTargets.isEmpty)  // left over from a crash: nothing is running
        s.stages[.dispatch] = StageState(status: .running)
        #expect(s.sendingTargets == ["claude-code"])
    }

    @Test func resumesFromTheFirstUnfinishedStage() async throws {
        let h = Harness()
        var s = try h.stoppedSession()
        try JSONEncoder().encode([Segment(track: .me, start: 0, end: 1, text: "Hello.")])
            .write(to: h.store.file(s, "transcript.json"))
        s.stages[.transcribe] = StageState(status: .done)
        try h.store.save(s)
        await h.pipeline().run(sessionID: s.id)
        #expect(h.transcriber.calls.get == 0)
        #expect(h.writer.calls.get == 1)
    }

    @Test func untitledMeetingsTakeTheNotesTitle() async throws {
        let h = Harness()
        let s = try h.stoppedSession(mode: .notes, title: nil)
        await h.pipeline().run(sessionID: s.id)
        let done = try #require(h.store.all().first)
        #expect(done.id == s.id)
        #expect(done.folderName == "2026-10-14 1530 Acme kickoff" && done.title == "Acme kickoff")
    }

    @Test func skippingTheConfirmSendsNothingAndSaysSo() async throws {
        let h = Harness()
        let s = try h.stoppedSession()
        await h.pipeline(confirm: { _, _ in nil }).run(sessionID: s.id)
        let done = try h.store.load(folderName: s.folderName)
        #expect(done.isFinished && h.targets[0].sent.get.isEmpty)
        #expect(done.warnings.contains("Sending was skipped."))
    }

    @Test func itemsWithNoTaskAreNeverSentAsAnEmptyPayload() async throws {
        let h = Harness()
        let s = try h.stoppedSession()
        // The payload drops items with a blank task, so these leave nothing to send.
        await h.pipeline(confirm: { _, _ in [ActionItem(task: "  ", owner: "Stephen", doer: .ai)] }).run(sessionID: s.id)
        let done = try h.store.load(folderName: s.folderName)
        #expect(done.isFinished && h.targets[0].sent.get.isEmpty)
        #expect(done.sent.isEmpty)
        #expect(done.warnings.contains("No action items were picked, so nothing was sent."))
    }

    @Test func everyTrackFileExistsOnceCompressionIsDone() async throws {
        let h = Harness()
        let s = try h.stoppedSession(mode: .record)
        await h.pipeline().run(sessionID: s.id)
        let done = try h.store.load(folderName: s.folderName)
        #expect(done.isFinished && done.tracks.map(\.file) == ["mic.m4a", "system.m4a"])
        #expect(done.tracks.allSatisfy { FileManager.default.fileExists(atPath: h.store.file(done, $0.file).path) })
        #expect(!FileManager.default.fileExists(atPath: h.store.file(done, "mic.caf").path))
    }

    @Test func aSaveThatFailsAfterCompressingKeepsTheOriginalAudio() async throws {
        let h = Harness()
        let s = try h.stoppedSession(mode: .record)
        let record = h.store.file(s, SessionStore.fileName)
        defer { setLocked(false, record) }
        let pipeline = Pipeline(store: h.store, transcriber: h.transcriber, compressor: DiskFailsAfterCopyCompressor(lockedFile: record),
                                makeWriter: { h.writer }, makeTargets: { [] },
                                config: { PipelineConfig(userName: "Stephen", timeZone: newYork) },
                                confirm: { _, _ in nil }, events: { _ in }, lanes: TargetLanes())
        await pipeline.run(sessionID: s.id)
        // session.json could not be updated, so it still names the .caf files, and they must still be there.
        let after = try h.store.load(folderName: s.folderName)
        #expect(after.tracks.allSatisfy { FileManager.default.fileExists(atPath: h.store.file(after, $0.file).path) })
        #expect(FileManager.default.fileExists(atPath: h.store.file(after, "mic.caf").path))
    }

    @Test func aRerunAfterACrashBetweenSavingAndDeletingKeepsTheCompressedFiles() async throws {
        let h = Harness()
        var s = try h.stoppedSession(mode: .record)
        // The crash left session.json pointing at the .m4a files, with the .caf files still beside them.
        try Data("done mic".utf8).write(to: h.store.file(s, "mic.m4a"))
        try Data("done sys".utf8).write(to: h.store.file(s, "system.m4a"))
        s.tracks = [TrackFile(track: .me, file: "mic.m4a", offset: 0), TrackFile(track: .them, file: "system.m4a", offset: 0)]
        try h.store.save(s)
        await h.pipeline().run(sessionID: s.id)
        let done = try h.store.load(folderName: s.folderName)
        #expect(done.isFinished && done.tracks.map(\.file) == ["mic.m4a", "system.m4a"])
        #expect(try Data(contentsOf: h.store.file(done, "mic.m4a")) == Data("done mic".utf8))
        #expect(try Data(contentsOf: h.store.file(done, "system.m4a")) == Data("done sys".utf8))
        // The stray originals the crash left behind are cleaned up.
        #expect(!FileManager.default.fileExists(atPath: h.store.file(done, "mic.caf").path))
        #expect(!FileManager.default.fileExists(atPath: h.store.file(done, "system.caf").path))
    }

    @Test func anOriginalIsKeptWhenItsCompressedFileIsMissing() async throws {
        let h = Harness()
        var s = try h.stoppedSession(mode: .record)
        // session.json names mic.m4a, but only mic.caf is on disk: that .caf is the only copy of the audio.
        s.tracks = [TrackFile(track: .me, file: "mic.m4a", offset: 0)]
        try h.store.save(s)
        await h.pipeline().run(sessionID: s.id)
        #expect(try Data(contentsOf: h.store.file(s, "mic.caf")) == Data("mic".utf8))
    }

    @Test func retryWhileTheMeetingIsRunningLeavesItAlone() async throws {
        let h = Harness()
        let s = try h.stoppedSession(mode: .notes)
        h.writer.held.update { $0 = true }
        let pipeline = h.pipeline()
        let first = Task { await pipeline.run(sessionID: s.id) }
        for _ in 0..<400 where h.writer.calls.get == 0 { try await Task.sleep(for: .milliseconds(5)) }
        #expect(h.writer.calls.get == 1)  // the notes stage is in flight
        await pipeline.retry(sessionID: s.id)
        #expect(try h.store.load(folderName: s.folderName).stages[.notes]?.status == .running)
        #expect(await pipeline.isRunning(s.id))
        h.writer.held.update { $0 = false }
        await first.value
        #expect(try h.store.load(folderName: s.folderName).isFinished)
        #expect(h.writer.calls.get == 1)
    }

    @Test func aFinishedMeetingIsNotAnnouncedAgain() async throws {
        let h = Harness()
        let s = try h.stoppedSession()
        let pipeline = h.pipeline()
        await pipeline.run(sessionID: s.id)
        let announced = h.events.get
        await pipeline.run(sessionID: s.id)
        #expect(h.events.get == announced)
        #expect(announced.filter { $0 == .finished(sessionID: s.id) }.count == 1)
    }

    @Test func aMeetingThatCannotBeSavedReportsTheFailure() async throws {
        let h = Harness()
        let s = try h.stoppedSession()
        let record = h.store.file(s, SessionStore.fileName)
        setLocked(true, record)
        defer { setLocked(false, record) }
        let pipeline = h.pipeline()
        await pipeline.run(sessionID: s.id)
        let failure = h.events.get.compactMap { event -> (Stage, String)? in
            if case let .failed(_, stage, message) = event { (stage, message) } else { nil }
        }
        #expect(failure.count == 1 && failure.first?.0 == .transcribe)
        // A sentence for the user, not an "Error Domain=..." dump with the file's full path.
        #expect(failure.first?.1.contains("session.json") == true && failure.first?.1.hasPrefix("Error Domain") == false)
        #expect(h.transcriber.calls.get == 0)
        #expect(!(await pipeline.isRunning(s.id)))
    }

    @Test func aCocoaErrorReadsAsAPlainSentence() async throws {
        let h = Harness()
        h.writer.failure.update { $0 = CocoaError(.fileWriteNoPermission) }
        let s = try h.stoppedSession(mode: .notes)
        await h.pipeline().run(sessionID: s.id)
        let plain = CocoaError(.fileWriteNoPermission).localizedDescription
        let stored = try #require(try h.store.load(folderName: s.folderName).stages[.notes]?.error)
        #expect(stored == plain && !stored.contains("Error Domain"))
        #expect(h.events.get.contains(.failed(sessionID: s.id, stage: .notes, message: plain)))
    }

    @Test func aFailureNoticeNeverCarriesWhatTheModelWrote() async throws {
        let h = Harness()
        let excerpt = #"{"summary": "Dana's salary is 90k"#
        h.writer.failure.update { $0 = NotesError.badOutput(excerpt) }
        let s = try h.stoppedSession(mode: .notes)
        await h.pipeline().run(sessionID: s.id)
        let notices = h.events.get.compactMap { event -> String? in
            if case let .failed(_, _, message) = event { message } else { nil }
        }
        #expect(notices == ["The notes came back in the wrong shape. Press Retry in Earshot to try again."])
        // The meeting's own record keeps the detail.
        #expect(try h.store.load(folderName: s.folderName).stages[.notes]?.error
                == NotesError.badOutput(excerpt).errorDescription)
    }

    @Test func aCancelledStageIsNotAFailure() async throws {
        let h = Harness()
        var s = try h.stoppedSession(mode: .notes)
        try JSONEncoder().encode([Segment(track: .me, start: 0, end: 1, text: "Hello.")])
            .write(to: h.store.file(s, "transcript.json"))
        s.stages[.transcribe] = StageState(status: .done)
        s.stages[.notes] = StageState(status: .failed, error: "earlier", failures: 1)
        try h.store.save(s)
        h.writer.failure.update { $0 = CancellationError() }
        await h.pipeline().run(sessionID: s.id)
        let after = try h.store.load(folderName: s.folderName)
        #expect(after.stages[.notes] == StageState(status: .pending, failures: 1))
        #expect(h.events.get == [.started(sessionID: s.id, stage: .notes)])
        #expect(h.store.resumable().map(\.id) == [s.id])
    }

    @Test func aCancelledCallerIsNotAFailureWhateverErrorTheWriterThrows() async throws {
        let h = Harness()
        let s = try h.stoppedSession(mode: .notes)
        let pipeline = h.pipeline(writer: CancelsItsCallerWriter())
        await Task { await pipeline.run(sessionID: s.id) }.value
        #expect(try h.store.load(folderName: s.folderName).stages[.notes] == StageState())
        #expect(!h.events.get.contains { if case .failed = $0 { true } else { false } })
        #expect(h.store.resumable().map(\.id) == [s.id])
    }

    @Test func audioIsDeletedAfterRealNotesWhenKeepAudioIsOff() async throws {
        let h = Harness()
        let s = try h.stoppedSession(mode: .notes)
        await h.pipeline(keepAudio: false).run(sessionID: s.id)
        let done = try h.store.load(folderName: s.folderName)
        #expect(done.isFinished && done.tracks.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: h.store.file(done, "mic.caf").path))
        #expect(!FileManager.default.fileExists(atPath: h.store.file(done, "system.caf").path))
        #expect(done.warnings.contains("The audio was deleted after the notes were written (Settings, Storage)."))
    }

    @Test func audioIsKeptWhenThereWasNoSpeechEvenIfKeepAudioIsOff() async throws {
        var h = Harness()
        h.transcriber = FakeTranscriber(segments: [:])
        let s = try h.stoppedSession(mode: .notes)
        await h.pipeline(keepAudio: false).run(sessionID: s.id)
        let done = try h.store.load(folderName: s.folderName)
        // With nothing transcribed, the recording is the only record of the meeting: it is compressed, not deleted.
        #expect(done.isFinished && done.tracks.map(\.file) == ["mic.m4a", "system.m4a"])
        #expect(done.tracks.allSatisfy { FileManager.default.fileExists(atPath: h.store.file(done, $0.file).path) })
        #expect(done.warnings.isEmpty)
    }

    @Test func recordingSessionsAreLeftAlone() async throws {
        let h = Harness()
        var s = try h.stoppedSession()
        s.recording = true
        try h.store.save(s)
        await h.pipeline().run(sessionID: s.id)
        #expect(h.transcriber.calls.get == 0)
    }

    @Test func importCopiesTheFileAsOneSpeakerTrack() throws {
        let store = SessionStore(root: tempDir(), timeZone: newYork)
        let source = tempDir().appending(path: "New Recording 12.m4a")
        try Data("memo".utf8).write(to: source)
        let s = try store.importAudio(from: source, mode: .notes, startedAt: at1530, duration: 600)
        #expect(s.tracks == [TrackFile(track: .speaker, file: "import.m4a", offset: 0)])
        #expect(!s.recording && s.duration == 600)
        #expect(try Data(contentsOf: store.file(s, "import.m4a")) == Data("memo".utf8))
    }

    @Test func aFailedImportLeavesNoMeetingBehind() throws {
        let store = SessionStore(root: tempDir(), timeZone: newYork)
        let missing = tempDir().appending(path: "gone.m4a")
        #expect(throws: (any Error).self) {
            try store.importAudio(from: missing, mode: .notes, startedAt: at1530, duration: 600)
        }
        #expect(store.all().isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: store.root.path).isEmpty)
    }
}
