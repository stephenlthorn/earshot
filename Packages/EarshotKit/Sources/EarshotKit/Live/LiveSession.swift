import AVFoundation
import Foundation

/// A live transcriber as `LiveSession` uses it, so tests can speak through a fake.
public protocol LiveTranscribing: Sendable {
    var track: Track { get }
    var updates: AsyncStream<LiveUpdate> { get }
    func start() async throws
    func append(_ buffer: AVAudioPCMBuffer, hostTime: UInt64)
    func finalizeNow() async
    func finish() async
}

extension LiveTranscriber: LiveTranscribing {}

/// What a recording's live work tells the panel, in order.
public enum LiveEvent: Equatable, Sendable {
    /// Every live to-do, as live.json holds it.
    case items([LiveItem])
    case status(LiveStatus)
    /// Each track's tentative text, "" when there is none.
    case ticker(me: String, them: String)
    case flagged(Flag)
    /// A track's live transcription couldn't start; the recording itself is not affected.
    case transcriptionFailed(String)
}

/// The live work of one recording, off the main actor (spec 4 and 8): the live transcribers, the live transcript,
/// live.json, the to-do passes, spoken and pressed flags, and the one Start queue for the meeting. The App wires it
/// to capture and to the panel; nothing here touches AppKit.
public actor LiveSession {
    public static let claudeNotSetUp = "Claude isn't set up"

    /// The pause reason when there is no client: Claude, or the local model, isn't set up.
    public static func notSetUp(_ provider: NotesProvider) -> String {
        provider == .local ? LocalModelSetup.notSetUp : claudeNotSetUp
    }
    /// The longest `stop()` waits for the transcribers' last words before it saves what it has.
    public static let defaultStopLimit: Duration = .seconds(4)

    public nonisolated let events: AsyncStream<LiveEvent>
    public nonisolated let store: LiveStore
    /// The only Start queue for this meeting.
    public nonisolated let queue: LiveRunQueue
    public nonisolated let sessionID: String

    private let output: AsyncStream<LiveEvent>.Continuation
    private let sessions: SessionStore
    private let session: Session
    private let transcribers: [any LiveTranscribing]
    private let extractor: LiveExtractor?
    /// Why no pass can run, when there is no client: shown once as the pause reason.
    private let missingClient: String?
    private let voiceFlags: Bool
    private let offset: @Sendable () -> Double?
    private let stopLimit: Duration
    private let transcript = LiveTranscript()
    /// Final segments in the order they arrived; the extractor counts on this list only growing.
    private let arrivals = Locked<[Segment]>([])
    private var cursor = 0
    private var ticker = (me: "", them: "")
    /// Both tracks' results, through one consumer, so they are handled one at a time.
    private let merged: AsyncStream<LiveUpdate>
    private let mergedInput: AsyncStream<LiveUpdate>.Continuation
    /// A nudge to publish live.json's items and push them into the extractor.
    private let syncs: AsyncStream<Void>
    private let syncInput: AsyncStream<Void>.Continuation
    private var tasks: [Task<Void, Never>] = []
    private var consumer: Task<Void, Never>?
    private var extracting: Task<Void, Never>?
    private var started = false
    private var stopped = false
    /// The one stop; a later `stop()` waits for it.
    private var stopping: Task<Void, Never>?

    /// - Parameters:
    ///   - transcribers: one per capture track, or none when the live assistant is off.
    ///   - client: nil when Claude (or the local model) isn't set up; the panel then says so and no pass runs.
    ///   - offset: the meeting clock now (`CaptureSession.currentOffset`), nil before the first buffer.
    public init(store sessions: SessionStore, session: Session, transcribers: [any LiveTranscribing],
                client: (any ClaudeClient)?, settings: EarshotSettings, lessons: [Lesson] = [],
                offset: @escaping @Sendable () -> Double?, stopLimit: Duration = LiveSession.defaultStopLimit,
                cancelWindow: Duration = LiveStartPolicy.cancelWindow, lanes: TargetLanes = .shared,
                sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.sessions = sessions
        self.session = session
        sessionID = session.id
        self.transcribers = transcribers
        self.offset = offset
        self.stopLimit = stopLimit
        voiceFlags = settings.voiceFlags
        missingClient = client == nil && !transcribers.isEmpty ? Self.notSetUp(settings.provider) : nil
        let (events, output) = AsyncStream.makeStream(of: LiveEvent.self)
        let (syncs, syncInput) = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
        (self.events, self.output, self.syncs, self.syncInput) = (events, output, syncs, syncInput)
        (merged, mergedInput) = AsyncStream.makeStream(of: LiveUpdate.self)
        let live = LiveStore(store: sessions, session: session, now: now)
        store = live
        queue = LiveRunQueue(store: live, cancelWindow: cancelWindow, lanes: lanes, sleep: sleep,
                             onStatus: { _ in syncInput.yield() })
        guard let client, !transcribers.isEmpty else {
            extractor = nil
            return
        }
        let arrivals = arrivals
        extractor = LiveExtractor(
            client: client, model: settings.model(for: .live), effort: settings.effort(for: .live),
            interval: .seconds(max(settings.liveInterval, 1)),
            finals: { arrivals.get },
            finalize: { await Self.finalizeAll(transcribers) },
            now: { offset() ?? 0 },
            context: {
                LiveContext.meeting(session: Self.latest(sessions, session), settings: settings, lessons: lessons)
            },
            onItems: { items in
                live.replaceItems(items)
                syncInput.yield()
            },
            onStatus: { output.yield(.status($0)) },
            sleep: sleep)
    }

    /// Routes each capture buffer to its track's transcriber. Set it as `CaptureSession.liveFeed` before capture
    /// starts. Built here, not on the main actor, because the audio thread calls it (spec 17).
    public static func feed(for transcribers: [any LiveTranscribing])
        -> @Sendable (Track, AVAudioPCMBuffer, UInt64) -> Void {
        let byTrack = Dictionary(transcribers.map { ($0.track, $0) }, uniquingKeysWith: { first, _ in first })
        return { track, buffer, hostTime in byTrack[track]?.append(buffer, hostTime: hostTime) }
    }

    /// Starts the transcribers (a failure is reported, never thrown), reading their results, and the passes. Does
    /// nothing once `stop()` has been called, so a late start never leaves passes running.
    public func start() {
        guard !started, !stopped else { return }
        started = true
        if let missingClient { output.yield(.status(.paused(missingClient))) }
        let output = output, mergedInput = mergedInput
        for transcriber in transcribers {
            Task {
                do { try await transcriber.start() } catch {
                    output.yield(.transcriptionFailed(error.localizedDescription))
                }
            }
            tasks.append(Task { for await update in transcriber.updates { mergedInput.yield(update) } })
        }
        let merged = merged
        consumer = Task { for await update in merged { await self.handle(update) } }
        let syncs = syncs, store = store, extractor = extractor
        tasks.append(Task {
            for await _ in syncs {
                let items = store.items
                await extractor?.update(items)
                output.yield(.items(items))
            }
        })
        if let extractor { extracting = Task { await extractor.run() } }
    }

    /// One pass now, for tests; nil when there are no passes.
    @discardableResult
    public func passNow() async -> LiveExtractor.PassResult? {
        await extractor?.passNow()
    }

    /// Items whose row the pointer is over; a pass never changes them.
    public func setFrozen(_ ids: Set<String>) async {
        await extractor?.setFrozen(ids)
    }

    /// A flag from the hotkey or the panel, at the meeting clock now. Nil when it isn't saved: before the first
    /// buffer, within 10 s of another flag, past the cap, or when session.json can't be written.
    @discardableResult
    public func flag(_ source: FlagSource) -> Flag? {
        guard let now = offset() else { return nil }
        return save(at: now, source)
    }

    /// The payload Start sends for `row`, the row exactly as drawn, clicked at `time`.
    public func payload(for row: LiveItem, at time: Date) -> DoPayload {
        let latest = Self.latest(sessions, session)
        return LiveDispatch.payload(for: row, session: latest, folder: store.folder, event: latest.calendarEvent,
                                    at: time)
    }

    /// Queues `row` for `target`. False when it is already queued or started, or `queued` can't be saved.
    public func start(_ row: LiveItem, payload: DoPayload, target: any DoTarget, confirmed: Bool) async -> Bool {
        await queue.enqueue(snapshot: row, payload: payload, send: target, confirmed: confirmed)
    }

    @discardableResult
    public func cancel(_ id: String) async -> Bool {
        await queue.cancel(id)
    }

    /// Dismisses a suggested or failed item, written at once. Anything else is left alone.
    public func dismiss(_ id: String) throws {
        guard let item = store.items.first(where: { $0.id == id }), [.suggested, .failed].contains(item.status) else {
            return
        }
        try store.setStatus(id, .dismissed)
        syncInput.yield()
    }

    /// Ends the passes, finishes the transcribers and saves live.json. It never waits longer than its limit: what
    /// arrives later is still saved once it does. A second call waits for the first stop to finish and save.
    public func stop() async {
        if let stopping {
            await stopping.value
            return
        }
        stopped = true
        extracting?.cancel()
        let transcribers = transcribers, tasks = Array(tasks.prefix(transcribers.count))
        let mergedInput = mergedInput, consumer = consumer, store = store, limit = stopLimit
        let work = Task {
            await Self.within(limit) {
                await withTaskGroup(of: Void.self) { group in
                    for transcriber in transcribers { group.addTask { await transcriber.finish() } }
                }
                for task in tasks { await task.value }
                mergedInput.finish()
                await consumer?.value
                store.flush()
            }
            store.flush()
        }
        stopping = work
        await work.value
    }

    /// Once the queue is idle after stop: ends the event stream.
    public func close() {
        syncInput.finish()
        output.finish()
    }

    public func cancelQueued() async {
        for item in store.items where item.status == .queued { await queue.cancel(item.id) }
    }

    /// The recording stopped (spec 4.4): runs already going carry on, but nothing still queued goes out after the
    /// call. Queued to-dos go back to suggested, so the notes after the call offer them like any other item and they
    /// are never sent twice. Await it before the meeting's pipeline starts.
    public func takeBackQueued() async {
        queue.hold()
        await cancelQueued()
    }

    /// From now on nothing new is sent: a job still waiting stays queued, for `cancelQueued()` to take back. For
    /// quitting, before Earshot stops the programs it started.
    public nonisolated func hold() {
        queue.hold()
    }

    /// True once `start()` has set anything going, for tests.
    var isRunning: Bool { consumer != nil || extracting != nil || !tasks.isEmpty }

    public func waitUntilIdle() async {
        await queue.waitUntilIdle()
    }

    /// The targets of items being sent or run right now.
    public nonisolated func busyTargetIDs() -> [String] {
        Set(store.items.filter { [.sending, .running].contains($0.status) }.compactMap(\.target)).sorted()
    }

    /// True while an item is queued, being sent or running.
    public nonisolated func hasPendingWork() -> Bool {
        store.items.contains { [.queued, .sending, .running].contains($0.status) }
    }

    /// brief.json, once it has been written.
    public nonisolated func readBrief() -> MeetingBrief? {
        (try? sessions.readIfPresent(MeetingBrief.self, Self.latest(sessions, session), MeetingFile.brief)) ?? nil
    }

    /// The latest session.json, so flags and calendar details saved during the call are seen.
    public nonisolated func latestSession() -> Session {
        Self.latest(sessions, session)
    }

    private func handle(_ update: LiveUpdate) async {
        await transcript.apply(update)
        if update.isFinal {
            let (fresh, next) = await transcript.finals(after: cursor)
            cursor = next
            if !fresh.isEmpty {
                arrivals.update { $0 += fresh }
                store.appendSegments(fresh)
                if voiceFlags {
                    for segment in fresh where segment.track == .me && FlagRules.isVoiceFlag(segment.text) {
                        save(at: segment.end, .voice)
                    }
                }
            }
        }
        let now = (me: await transcript.volatileText(.me), them: await transcript.volatileText(.them))
        guard now != ticker else { return }
        ticker = now
        output.yield(.ticker(me: now.me, them: now.them))
    }

    @discardableResult
    private func save(at time: Double, _ source: FlagSource) -> Flag? {
        guard let flag = (try? LiveFlags.add(at: time, source: source, store: sessions, id: session.id)) ?? nil else {
            return nil
        }
        output.yield(.flagged(flag))
        return flag
    }

    private static func finalizeAll(_ transcribers: [any LiveTranscribing]) async {
        await withTaskGroup(of: Void.self) { group in
            for transcriber in transcribers { group.addTask { await transcriber.finalizeNow() } }
        }
    }

    static func latest(_ sessions: SessionStore, _ session: Session) -> Session {
        if let loaded = try? sessions.load(folderName: session.folderName), loaded.id == session.id { return loaded }
        return sessions.find(session.id) ?? session
    }

    /// Runs `work` and returns true if it finished within `limit`. Otherwise returns false at the limit and cancels
    /// it; work that ignores cancellation carries on in the background.
    @discardableResult
    public static func within(_ limit: Duration, _ work: @escaping @Sendable () async -> Void) async -> Bool {
        let once = Locked(false)
        let timer = Locked<Task<Void, Never>?>(nil)
        return await withCheckedContinuation { continuation in
            let claim: @Sendable (Bool) -> Bool = { value in
                var first = false
                once.update { if !$0 { $0 = true; first = true } }
                if first { continuation.resume(returning: value) }
                return first
            }
            let worker = Task {
                await work()
                if claim(true) { timer.get?.cancel() }
            }
            timer.update {
                $0 = Task {
                    try? await Task.sleep(for: limit)
                    if claim(false) { worker.cancel() }
                }
            }
        }
    }
}
