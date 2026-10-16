import Foundation
import Testing
@testable import EarshotKit

/// A Do target that records what it was sent, and what live.json said about the item at that moment.
private final class RecordingTarget: DoTarget, @unchecked Sendable {
    let id: String
    let label: String
    let result: DispatchResult
    let latch: Latch?
    let sent = Locked<[DoPayload]>([])
    let onDisk = Locked<[LiveItem?]>([])

    init(_ id: String, result: DispatchResult = DispatchResult(ok: true, detail: "ok"), holding latch: Latch? = nil) {
        self.id = id
        self.label = id
        self.result = result
        self.latch = latch
    }

    func send(_ payload: DoPayload, json: Data, folder: URL) async -> DispatchResult {
        let ref = payload.items.first?.source
        let file = try? JSONFiles.read(LiveFile.self, from: folder.appending(path: MeetingFile.live))
        onDisk.update { $0.append(file?.items.first { $0.id == ref }) }
        sent.update { $0.append(payload) }
        if let latch { await latch.hold() }
        return result
    }
}

/// A sleep that waits until the test wakes it.
private final class Sleeper: @unchecked Sendable {
    private let waiting = Locked<[CheckedContinuation<Void, Never>]>([])
    let durations = Locked<[Duration]>([])

    var count: Int { waiting.get.count }

    func sleep(_ duration: Duration) async {
        durations.update { $0.append(duration) }
        await withCheckedContinuation { continuation in waiting.update { $0.append(continuation) } }
    }

    func wake() {
        var all: [CheckedContinuation<Void, Never>] = []
        waiting.update { all = $0; $0 = [] }
        all.forEach { $0.resume() }
    }

    /// Wakes only the sleep that began first.
    func wakeFirst() {
        var first: CheckedContinuation<Void, Never>?
        waiting.update { if !$0.isEmpty { first = $0.removeFirst() } }
        first?.resume()
    }
}

private struct QueueHarness {
    let store = SessionStore(root: tempDir(), timeZone: newYork)
    let session: Session
    let live: LiveStore
    let sleeper = Sleeper()
    let updates = Locked<[LiveRunQueue.Update]>([])
    let queue: LiveRunQueue

    init(items: [LiveItem] = (1...4).map { LiveItem(id: "L\($0)", task: "Task \($0)", owner: "Stephen", aiDoable: true,
                                                     why: "said so", firstSeen: 5) }) throws {
        session = try store.create(mode: .notesAndDo, title: "Acme kickoff", now: at1530)
        live = LiveStore(store: store, session: session)
        live.replaceItems(items)
        let sleeper = self.sleeper
        let updates = self.updates
        queue = LiveRunQueue(store: live, lanes: TargetLanes(), sleep: { await sleeper.sleep($0) },
                             onStatus: { update in updates.update { $0.append(update) } })
    }

    func payload(_ id: String) -> DoPayload {
        let item = live.items.first { $0.id == id }!
        return LiveDispatch.payload(for: item, session: session, folder: store.folder(session), event: nil,
                                    at: at1530.addingTimeInterval(60))
    }

    func snapshot(_ id: String) -> LiveItem { live.items.first { $0.id == id }! }

    func statuses(_ id: String) -> [LiveItem.Status] { updates.get.filter { $0.id == id }.map(\.status) }

    func onDisk(_ id: String) throws -> LiveItem? {
        try store.read(LiveFile.self, session, MeetingFile.live).items.first { $0.id == id }
    }
}

private struct FixedTarget: DoTarget {
    let id: String
    let label: String
    func send(_ payload: DoPayload, json: Data, folder: URL) async -> DispatchResult { DispatchResult(ok: true, detail: "") }
}

private func settings(_ change: (inout EarshotSettings) -> Void = { _ in }) -> EarshotSettings {
    var settings = EarshotSettings()
    settings.liveAssistant = true
    change(&settings)
    return settings
}

struct LiveStartPolicyTests {
    @Test func restrictedClaudeCodeAndWebhooksStartInOneClick() {
        #expect(LiveStartPolicy.decide(target: .claudeCode, permissionMode: "restricted", allowRoutine: false) == .oneClick)
        #expect(LiveStartPolicy.decide(target: .webhook, permissionMode: "auto", allowRoutine: false) == .oneClick)
        #expect(LiveStartPolicy.cancelWindow == .seconds(3))
    }

    @Test func otherClaudeCodeModesOpenTheSheet() {
        for mode in ["acceptEdits", "auto", "bypassPermissions", "default", ""] {
            #expect(LiveStartPolicy.decide(target: .claudeCode, permissionMode: mode, allowRoutine: true) == .confirmSheet)
        }
    }

    @Test func aCommandAlwaysOpensTheSheet() {
        #expect(LiveStartPolicy.decide(target: .command, permissionMode: "restricted", allowRoutine: true) == .confirmSheet)
    }

    @Test func aRoutineStartsOnlyWhenAllowed() {
        #expect(LiveStartPolicy.decide(target: .routine, permissionMode: "restricted", allowRoutine: true) == .oneClick)
        guard case let .unavailable(reason) = LiveStartPolicy.decide(target: .routine, permissionMode: "restricted",
                                                                      allowRoutine: false) else {
            Issue.record("a routine without the setting must be unavailable")
            return
        }
        #expect(reason == "Turn on Allow Start during calls in Settings to start routines from the panel.")
    }

    @Test func targetKindsComeFromTheTargetIds() {
        #expect(LiveStartPolicy.TargetKind(id: "claude-code") == .claudeCode)
        #expect(LiveStartPolicy.TargetKind(id: "webhook") == .webhook)
        #expect(LiveStartPolicy.TargetKind(id: "command") == .command)
        #expect(LiveStartPolicy.TargetKind(id: "routine") == .routine)
        #expect(LiveStartPolicy.TargetKind(id: "fax") == nil)
    }

    @Test func startNeedsNotesAndDoAndTheLiveAssistant() {
        let targets: [any DoTarget] = [FixedTarget(id: "webhook", label: "Webhook")]
        #expect(LiveStartPolicy.startAvailable(mode: .notesAndDo, settings: settings(), targets: targets))
        #expect(!LiveStartPolicy.startAvailable(mode: .notes, settings: settings(), targets: targets))
        #expect(!LiveStartPolicy.startAvailable(mode: .record, settings: settings(), targets: targets))
        #expect(!LiveStartPolicy.startAvailable(mode: .notesAndDo, settings: settings { $0.liveAssistant = false },
                                                targets: targets))
    }

    @Test func startNeedsALiveTargetThatWorks() {
        let unavailable = UnavailableTarget(id: "claude-code", label: "Claude Code", reason: "No folder")
        let webhook = FixedTarget(id: "webhook", label: "Webhook")
        #expect(!LiveStartPolicy.startAvailable(mode: .notesAndDo, settings: settings(), targets: []))
        #expect(!LiveStartPolicy.startAvailable(mode: .notesAndDo, settings: settings(), targets: [unavailable]))
        // With no live target chosen, the first target that can run is used.
        #expect(LiveStartPolicy.liveTarget(settings: settings(), targets: [unavailable, webhook])?.id == "webhook")
        #expect(LiveStartPolicy.startAvailable(mode: .notesAndDo, settings: settings(), targets: [unavailable, webhook]))
        // A chosen target that can't run falls back to the first working one (spec 4.4 as adopted); with none
        // working, Start isn't offered.
        let chosen = settings { $0.liveTarget = "claude-code" }
        #expect(LiveStartPolicy.liveTarget(settings: chosen, targets: [unavailable, webhook])?.id == "webhook")
        #expect(LiveStartPolicy.startAvailable(mode: .notesAndDo, settings: chosen, targets: [unavailable, webhook]))
        #expect(LiveStartPolicy.liveTarget(settings: chosen, targets: [unavailable]) == nil)
        #expect(!LiveStartPolicy.startAvailable(mode: .notesAndDo, settings: chosen, targets: [unavailable]))
        let command = settings { $0.liveTarget = "command" }
        let commandTarget = FixedTarget(id: "command", label: "Command")
        #expect(LiveStartPolicy.liveTarget(settings: command, targets: [webhook, commandTarget])?.id == "command")
    }

    @Test func theDecisionFollowsTheLiveTargetAndItsSettings() {
        let claude = FixedTarget(id: "claude-code", label: "Claude Code")
        let routine = FixedTarget(id: "routine", label: "Claude Code routine")
        #expect(LiveStartPolicy.decision(settings: settings(), targets: [claude]) == .oneClick)
        #expect(LiveStartPolicy.decision(settings: settings { $0.permissionMode = "auto" }, targets: [claude]) == .confirmSheet)
        #expect(LiveStartPolicy.decision(settings: settings(), targets: [routine])
                == .unavailable("Turn on Allow Start during calls in Settings to start routines from the panel."))
        #expect(!LiveStartPolicy.startAvailable(mode: .notesAndDo, settings: settings(), targets: [routine]))
        #expect(LiveStartPolicy.startAvailable(mode: .notesAndDo, settings: settings { $0.allowRoutineLiveStart = true },
                                               targets: [routine]))
        #expect(LiveStartPolicy.decision(settings: settings(), targets: []) == .unavailable(LiveStartPolicy.setUpTarget))
        #expect(LiveStartPolicy.decision(settings: settings(), targets: [FixedTarget(id: "fax", label: "Fax")])
                == .unavailable(LiveStartPolicy.setUpTarget))
        #expect(LiveStartPolicy.setUpTarget == "Set up a Do target")
    }
}

struct LiveRunQueueTests {
    @Test(.timeLimit(.minutes(1))) func sendingIsSavedBeforeTheTargetIsCalled() async throws {
        let h = try QueueHarness()
        let webhook = RecordingTarget("webhook")
        #expect(await h.queue.enqueue(snapshot: h.snapshot("L1"), payload: h.payload("L1"), send: webhook))
        #expect(try h.onDisk("L1")?.status == .queued)
        await pollUntil { h.sleeper.count == 1 }
        #expect(h.sleeper.durations.get == [.seconds(3)])
        h.sleeper.wake()
        await h.queue.waitUntilIdle()
        let seen = try #require(webhook.onDisk.get.first ?? nil)
        #expect(seen.status == .sending && seen.target == "webhook")
        #expect(try h.onDisk("L1")?.status == .sent)
        #expect(h.statuses("L1") == [.queued, .sending, .sent])
    }

    @Test(.timeLimit(.minutes(1))) func claudeCodeIsRunningWhileItWorksThenDone() async throws {
        let h = try QueueHarness()
        let claude = RecordingTarget("claude-code", result: DispatchResult(ok: true, detail: "Wrote scope.md"))
        await h.queue.enqueue(snapshot: h.snapshot("L1"), payload: h.payload("L1"), send: claude, confirmed: true)
        await h.queue.waitUntilIdle()
        #expect(h.sleeper.durations.get.isEmpty)
        #expect((claude.onDisk.get.first ?? nil)?.status == .running)
        let done = try #require(try h.onDisk("L1"))
        #expect(done.status == .done && done.detail == "Wrote scope.md" && done.target == "claude-code")
        #expect(h.statuses("L1") == [.queued, .sending, .running, .done])
    }

    @Test(.timeLimit(.minutes(1))) func resultsBecomeTheRightStatus() async throws {
        let h = try QueueHarness()
        let routine = RecordingTarget("routine", result: DispatchResult(ok: true, detail: "Run created",
                                                                         link: "https://claude.ai/code/session_1"))
        let failing = RecordingTarget("webhook", result: DispatchResult(ok: false, detail: "HTTP 500"))
        let cut = RecordingTarget("command", result: DispatchResult(ok: false, detail: "stopped", interrupted: true))
        await h.queue.enqueue(snapshot: h.snapshot("L1"), payload: h.payload("L1"), send: routine, confirmed: true)
        await h.queue.enqueue(snapshot: h.snapshot("L2"), payload: h.payload("L2"), send: failing, confirmed: true)
        await h.queue.enqueue(snapshot: h.snapshot("L3"), payload: h.payload("L3"), send: cut, confirmed: true)
        await h.queue.waitUntilIdle()
        let started = try #require(try h.onDisk("L1"))
        #expect(started.status == .startedInCloud && started.link == "https://claude.ai/code/session_1")
        #expect(try h.onDisk("L2")?.status == .failed && h.onDisk("L2")?.detail == "HTTP 500")
        #expect(try h.onDisk("L3")?.status == .interrupted)
        #expect(h.updates.get.last { $0.id == "L1" }?.link == "https://claude.ai/code/session_1")
    }

    @Test(.timeLimit(.minutes(1))) func oneRunAtATimePerTargetInTheOrderPressed() async throws {
        let h = try QueueHarness()
        let latch = Latch()
        let webhook = RecordingTarget("webhook", holding: latch)
        let claude = RecordingTarget("claude-code")
        for id in ["L1", "L2", "L3"] {
            await h.queue.enqueue(snapshot: h.snapshot(id), payload: h.payload(id), send: webhook, confirmed: true)
        }
        await pollUntil { latch.entered.get == 1 }
        #expect(webhook.sent.get.map { $0.items[0].source } == ["L1"])
        #expect(try h.onDisk("L2")?.status == .queued)
        // Another target is not held up.
        await h.queue.enqueue(snapshot: h.snapshot("L4"), payload: h.payload("L4"), send: claude, confirmed: true)
        await pollUntil { claude.sent.get.count == 1 }
        #expect(claude.sent.get.count == 1)
        latch.open()
        await h.queue.waitUntilIdle()
        #expect(webhook.sent.get.map { $0.items[0].source } == ["L1", "L2", "L3"])
    }

    @Test(.timeLimit(.minutes(1))) func cancelInsideTheWindowSendsNothing() async throws {
        let h = try QueueHarness()
        let webhook = RecordingTarget("webhook")
        await h.queue.enqueue(snapshot: h.snapshot("L1"), payload: h.payload("L1"), send: webhook)
        await pollUntil { h.sleeper.count == 1 }
        #expect(await h.queue.cancel("L1"))
        #expect(try h.onDisk("L1")?.status == .suggested && h.onDisk("L1")?.target == nil)
        h.sleeper.wake()
        await h.queue.waitUntilIdle()
        #expect(webhook.sent.get.isEmpty)
        #expect(h.statuses("L1") == [.queued, .suggested])
        #expect(await h.queue.cancel("L1") == false)
    }

    @Test(.timeLimit(.minutes(1))) func cancelAfterTheSendBeganDoesNothing() async throws {
        let h = try QueueHarness()
        let latch = Latch()
        let webhook = RecordingTarget("webhook", holding: latch)
        await h.queue.enqueue(snapshot: h.snapshot("L1"), payload: h.payload("L1"), send: webhook, confirmed: true)
        await pollUntil { latch.entered.get == 1 }
        #expect(await h.queue.cancel("L1") == false)
        latch.open()
        await h.queue.waitUntilIdle()
        #expect(try h.onDisk("L1")?.status == .sent)
    }

    @Test(.timeLimit(.minutes(1))) func anItemAlreadyQueuedOrStartedIsNotQueuedAgain() async throws {
        let h = try QueueHarness()
        let webhook = RecordingTarget("webhook")
        #expect(await h.queue.enqueue(snapshot: h.snapshot("L1"), payload: h.payload("L1"), send: webhook))
        #expect(await h.queue.enqueue(snapshot: h.snapshot("L1"), payload: h.payload("L1"), send: webhook) == false)
        await pollUntil { h.sleeper.count == 1 }
        h.sleeper.wake()
        await h.queue.waitUntilIdle()
        #expect(await h.queue.enqueue(snapshot: h.snapshot("L1"), payload: h.payload("L1"), send: webhook) == false)
        #expect(webhook.sent.get.count == 1)
    }

    @Test(.timeLimit(.minutes(1))) func nothingIsSentWhenSendingCantBeSaved() async throws {
        let h = try QueueHarness()
        let webhook = RecordingTarget("webhook")
        await h.queue.enqueue(snapshot: h.snapshot("L1"), payload: h.payload("L1"), send: webhook)
        await pollUntil { h.sleeper.count == 1 }
        let url = h.store.file(h.session, MeetingFile.live)
        try FileManager.default.removeItem(at: url)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        h.sleeper.wake()
        await h.queue.waitUntilIdle()
        #expect(webhook.sent.get.isEmpty)
        let last = try #require(h.updates.get.last)
        #expect(last.status == .failed && last.detail == LiveRunQueue.notSaved)
    }

    @Test(.timeLimit(.minutes(1))) func aCancelledWindowNeverSendsALaterPress() async throws {
        let h = try QueueHarness()
        let webhook = RecordingTarget("webhook")
        await h.queue.enqueue(snapshot: h.snapshot("L1"), payload: h.payload("L1"), send: webhook)
        await pollUntil { h.sleeper.count == 1 }
        #expect(await h.queue.cancel("L1"))
        #expect(await h.queue.enqueue(snapshot: h.snapshot("L1"), payload: h.payload("L1"), send: webhook))
        await pollUntil { h.sleeper.count == 2 }
        // The first press's window ends: the second press still has its own 3 seconds.
        h.sleeper.wakeFirst()
        await pollUntil { await h.queue.trackedCount == 1 }
        #expect(await h.queue.trackedCount == 1)
        #expect(webhook.sent.get.isEmpty)
        #expect(try h.onDisk("L1")?.status == .queued)
        h.sleeper.wake()
        await h.queue.waitUntilIdle()
        #expect(webhook.sent.get.count == 1)
        #expect(h.statuses("L1") == [.queued, .suggested, .queued, .sending, .sent])
    }

    @Test(.timeLimit(.minutes(1))) func cancellingTheFirstInALaneStartsTheReadyOneBehindIt() async throws {
        let h = try QueueHarness()
        let webhook = RecordingTarget("webhook")
        await h.queue.enqueue(snapshot: h.snapshot("L1"), payload: h.payload("L1"), send: webhook)
        await pollUntil { h.sleeper.count == 1 }
        // Confirmed in the sheet (the permission mode changed during the call), so it waits only for L1.
        await h.queue.enqueue(snapshot: h.snapshot("L2"), payload: h.payload("L2"), send: webhook, confirmed: true)
        #expect(webhook.sent.get.isEmpty)
        #expect(await h.queue.cancel("L1"))
        await pollUntil { webhook.sent.get.count == 1 }
        #expect(webhook.sent.get.map { $0.items[0].source } == ["L2"])
        h.sleeper.wake()
        await h.queue.waitUntilIdle()
        #expect(try h.onDisk("L2")?.status == .sent && h.onDisk("L1")?.status == .suggested)
        #expect(webhook.sent.get.count == 1)
    }

    @Test(.timeLimit(.minutes(1))) func aQueuedStatusThatCouldNotBeClearedDoesNotBlockAnotherStart() async throws {
        let h = try QueueHarness()
        let webhook = RecordingTarget("webhook")
        await h.queue.enqueue(snapshot: h.snapshot("L1"), payload: h.payload("L1"), send: webhook)
        await pollUntil { h.sleeper.count == 1 }
        let url = h.store.file(h.session, MeetingFile.live)
        try FileManager.default.removeItem(at: url)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        h.sleeper.wake()
        await h.queue.waitUntilIdle()
        // Neither sending nor the failure could be saved, so the store still says queued. The disk recovers.
        #expect(h.live.items.first { $0.id == "L1" }?.status == .queued)
        try FileManager.default.removeItem(at: url)
        #expect(await h.queue.enqueue(snapshot: h.snapshot("L1"), payload: h.payload("L1"), send: webhook))
        await pollUntil { h.sleeper.count == 1 }
        h.sleeper.wake()
        await h.queue.waitUntilIdle()
        #expect(webhook.sent.get.count == 1)
        #expect(try h.onDisk("L1")?.status == .sent)
    }

    @Test(.timeLimit(.minutes(1))) func theStoredRowIsTheTextThatWasSent() async throws {
        let h = try QueueHarness()
        var drawn = h.snapshot("L1")
        drawn.task = "Draft the pilot scope email"
        drawn.owner = "Dana"
        drawn.due = "Friday"
        drawn.why = "Dana asked for it"
        let payload = LiveDispatch.payload(for: drawn, session: h.session, folder: h.store.folder(h.session), event: nil)
        let webhook = RecordingTarget("webhook")
        await h.queue.enqueue(snapshot: drawn, payload: payload, send: webhook, confirmed: true)
        await h.queue.waitUntilIdle()
        let stored = try #require(try h.onDisk("L1"))
        #expect(stored.task == "Draft the pilot scope email" && stored.owner == "Dana")
        #expect(stored.due == "Friday" && stored.why == "Dana asked for it" && stored.status == .sent)
        #expect(stored.firstSeen == 5)
    }
}

struct LiveDispatchTests {
    private func setUp(why: String = "Dana needs the scope in writing", task: String = "Draft the pilot scope email",
                       title: String? = "Acme kickoff", owner: String = "Stephen")
        throws -> (DoPayload, Session, URL) {
        let store = SessionStore(root: tempDir(), timeZone: newYork)
        let session = try store.create(mode: .notesAndDo, title: title, now: at1530)
        let folder = store.folder(session)
        let secret = "Dana said the budget is 48 thousand and the password is hunter2"
        try store.write(LiveFile(segments: [Segment(track: .them, start: 0, end: 5, text: secret)]), session, MeetingFile.live)
        try TranscriptRenderer.markdown([Segment(track: .them, start: 0, end: 5, text: secret)], names: [:])
            .write(to: folder.appending(path: "transcript.md"), atomically: true, encoding: .utf8)
        let item = LiveItem(id: "L3", task: task, owner: owner, due: "Friday", aiDoable: true, why: why, firstSeen: 40)
        let event = CalendarEventInfo(id: "e1", title: "Acme weekly", start: at1530, end: at1530.addingTimeInterval(1800),
                                      attendees: [Attendee(name: "Dana Lee", email: "dana@acme.com"),
                                                  Attendee(name: "Stephen", email: "s@me.com", isMe: true)])
        let payload = LiveDispatch.payload(for: item, session: session, folder: folder, event: event,
                                           at: at1530.addingTimeInterval(600))
        return (payload, session, folder)
    }

    @Test func thePayloadFollowsTheSpec() throws {
        let (payload, session, folder) = try setUp()
        #expect(payload.version == 1)
        #expect(payload.session.id == "\(session.id)-live-3")
        #expect(payload.session.title == "Acme kickoff (live)")
        #expect(payload.session.endedAt == ISO8601DateFormatter().string(from: at1530.addingTimeInterval(600)))
        #expect(payload.session.durationS == 600 && payload.session.folder == folder.path)
        #expect(payload.notes == MeetingNotes(title: "Acme kickoff (live)",
                                              summary: "Started during the call. Why: Dana needs the scope in writing",
                                              attendees: ["Dana Lee", "Stephen"]))
        #expect(payload.notesMarkdown == "Started during the call. Why: Dana needs the scope in writing")
        #expect(payload.transcriptPath == folder.appending(path: "live.json").path)
        #expect(payload.items == [ActionItem(task: "Draft the pilot scope email", owner: "Stephen", due: "Friday",
                                             doer: .ai, context: "Dana needs the scope in writing", source: "L3")])
    }

    @Test func anUntitledMeetingSendsTheEventTitleCleaned() throws {
        let store = SessionStore(root: tempDir(), timeZone: newYork)
        let session = try store.create(mode: .notesAndDo, title: nil, now: at1530)
        let item = LiveItem(id: "L1", task: "Send the deck", owner: "Stephen", due: nil, aiDoable: true, why: "Asked",
                            firstSeen: 10)
        for (raw, expected) in [("Intro call with dana.smith@acme.com", "Intro call with [address at acme.com] (live)"),
                                ("Zoom https://zoom.us/j/8123456789?pwd=Xy12 passcode 4411", "Meeting (live)")] {
            let event = CalendarEventInfo(id: "e1", title: raw, start: at1530, end: at1530.addingTimeInterval(1800))
            let payload = LiveDispatch.payload(for: item, session: session, folder: store.folder(session), event: event)
            #expect(payload.session.title == expected && payload.notes.title == expected)
            let json = String(decoding: try payload.encoded(), as: UTF8.self)
            #expect(!json.contains("dana.smith@") && !json.contains("pwd=") && !json.contains("4411"))
        }
    }

    @Test func noTranscriptTextIsSent() throws {
        let (payload, _, _) = try setUp()
        let json = String(decoding: try payload.encoded(), as: UTF8.self)
        #expect(!json.contains("hunter2") && !json.contains("48 thousand"))
        #expect(!json.contains("dana@acme.com"))
    }

    @Test func theLimitsAreFitted() throws {
        let (payload, _, _) = try setUp(why: String(repeating: "why ", count: 1500),
                                        task: String(repeating: "task ", count: 100),
                                        title: String(repeating: "T", count: 250), owner: "   ")
        #expect(receiverLength(payload.session.title) <= DoPayload.maxTitle)
        #expect(payload.session.title.hasSuffix(" (live)") && payload.notes.title == payload.session.title)
        #expect(receiverLength(payload.notes.summary) <= DoPayload.maxSummary)
        #expect(payload.notesMarkdown == payload.notes.summary)
        #expect(receiverLength(payload.items[0].task) <= DoPayload.maxTask)
        #expect(payload.items[0].owner == "Unassigned")
        #expect(payload.items[0].context.unicodeScalars.count <= LiveDispatch.maxContext)
        let id = payload.session.id
        #expect(id.count <= 64 && id.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") })
    }

    @Test func anUntitledMeetingUsesTheEventTitle() throws {
        let (payload, _, _) = try setUp(title: nil)
        #expect(payload.session.title == "Acme weekly (live)")
    }

    @Test func linkedUsesLiveRefFirst() {
        let live = [LiveItem(id: "L1", task: "Draft the pilot scope email", owner: "S", aiDoable: true, firstSeen: 0,
                             status: .done),
                    LiveItem(id: "L2", task: "Book the venue", owner: "S", aiDoable: true, firstSeen: 0, status: .sent),
                    LiveItem(id: "L3", task: "Research pricing", owner: "S", aiDoable: true, firstSeen: 0,
                             status: .suggested)]
        let notes = [ActionItem(task: "Write up what Dana asked for", owner: "S", doer: .ai, liveRef: "L1"),
                     ActionItem(task: "Draft the pilot scope email", owner: "S", doer: .ai, liveRef: "L2"),
                     ActionItem(task: "Draft the pilot scope email today", owner: "S", doer: .ai, liveRef: "L3"),
                     ActionItem(task: "Call the venue", owner: "S", doer: .me)]
        // Item 0 links to L1 through live_ref though the words differ. Item 1 reads like L1 but its live_ref (L2) wins.
        // Item 2 reads like the started L1 but points at L3, which was never started, so it links to nothing: there
        // is no similarity fallback when live_ref is set.
        #expect(TranscriptMerger.similarity(notes[2].task, live[0].task) >= ItemStatus.similarityThreshold)
        #expect(LiveDispatch.linked(notes, live: live) == [0, 1])
        #expect(ItemStatus.linkedLiveItem(notes[1], live: live.filter(\.status.isStarted))?.id == "L2")
    }

    @Test func payloadIdsUseOnlyASCIIDigitsAndStayShort() throws {
        func number(_ id: String) -> String {
            LiveDispatch.number(of: LiveItem(id: id, task: "t", owner: "S", aiDoable: true, firstSeen: 0))
        }
        #expect(number("L3") == "3")
        #expect(number("L\u{0663}") == "L")
        #expect(number("L\u{00B2}") == "L")
        #expect(number("L\u{00BD}") == "L")
        #expect(number("L" + String(repeating: "7", count: 40)) == String(repeating: "7", count: 16))
        for id in ["L\u{0663}", "L\u{00B2}", "L" + String(repeating: "9", count: 80)] {
            let suffix = number(id)
            #expect(!suffix.isEmpty && suffix.count <= 16 && suffix.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) })
        }
    }

    @Test func linkedFallsBackToSimilarityOnlyForStartedItems() {
        let statuses: [LiveItem.Status] = [.sending, .running, .done, .sent, .startedInCloud, .interrupted]
        for status in statuses {
            let live = [LiveItem(id: "L1", task: "Draft the pilot scope email to Dana", owner: "S", aiDoable: true,
                                 firstSeen: 0, status: status)]
            let notes = [ActionItem(task: "Draft the pilot scope email for Dana", owner: "S", doer: .ai),
                         ActionItem(task: "Call the venue", owner: "S", doer: .me)]
            #expect(LiveDispatch.linked(notes, live: live) == [0], "status \(status)")
        }
        for status in [LiveItem.Status.suggested, .queued, .failed, .dismissed] {
            let live = [LiveItem(id: "L1", task: "Draft the pilot scope email to Dana", owner: "S", aiDoable: true,
                                 firstSeen: 0, status: status)]
            let notes = [ActionItem(task: "Draft the pilot scope email for Dana", owner: "S", doer: .ai)]
            #expect(LiveDispatch.linked(notes, live: live).isEmpty, "status \(status)")
        }
    }
}
