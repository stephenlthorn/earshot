import Foundation

public protocol Transcribing: Sendable {
    func transcribe(_ file: URL, track: Track, locale: Locale) async throws -> [Segment]
}

public protocol AudioCompressing: Sendable {
    /// Writes an AAC .m4a copy of `source` at `destination`.
    func compress(_ source: URL, to destination: URL) async throws
    /// Length of an audio file in seconds.
    func duration(of file: URL) throws -> Double
}

public struct PipelineConfig: Sendable {
    public var userName: String
    public var style: NotesStyle
    public var extraInstructions: String
    public var locale: Locale
    public var keepAudio: Bool
    public var timeZone: TimeZone
    /// Where lessons are read for the notes prompt and where `saveRevision` stores one; nil for none.
    public var lessons: LessonsStore?
    /// "Learn from my edits" (spec 6): off, lessons are neither used nor stored.
    public var learnFromEdits: Bool
    /// The read index (spec 11.1) to keep up to date; nil to leave it alone.
    public var index: LibraryIndex?
    /// The company domains the user typed in Settings, for who is internal or external.
    public var myDomains: String
    /// Settings' sales words: an external meeting with one in its title gets Sales call notes (spec 5.3).
    public var salesKeywords: String
    /// The clock, for reminders.json.
    public var now: @Sendable () -> Date

    public init(userName: String = "", style: NotesStyle = .general, extraInstructions: String = "",
                locale: Locale = .current, keepAudio: Bool = true, timeZone: TimeZone = .current,
                lessons: LessonsStore? = nil, learnFromEdits: Bool = true, index: LibraryIndex? = nil,
                myDomains: String = "", salesKeywords: String = EarshotSettings.defaultSalesKeywords,
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.userName = userName
        self.style = style
        self.extraInstructions = extraInstructions
        self.locale = locale
        self.keepAudio = keepAudio
        self.timeZone = timeZone
        self.lessons = lessons
        self.learnFromEdits = learnFromEdits
        self.index = index
        self.myDomains = myDomains
        self.salesKeywords = salesKeywords
        self.now = now
    }

    /// The meeting's notes style: its profile's (`ProfileRules.style`), or `style` without a profile.
    func style(for session: Session) -> NotesStyle {
        ProfileRules.style(session: session, salesKeywords: salesKeywords, defaultStyle: style)
    }

    var names: [Track: String] { userName.isEmpty ? [:] : [.me: userName] }
    var displayName: String { userName.isEmpty ? Track.me.defaultName : userName }
}

public enum PipelineEvent: Equatable, Sendable {
    case started(sessionID: String, stage: Stage)
    /// `message` is shown in a notification, so it never carries meeting text. session.json keeps the full detail.
    case failed(sessionID: String, stage: Stage, message: String)
    /// `notes` is what the notification opens: notes.html, or notes.md when the page couldn't be written.
    case notesReady(sessionID: String, notes: URL)
    case finished(sessionID: String)
}

public enum PipelineError: Error, Equatable, LocalizedError {
    case dispatchFailed(String)
    case compressMismatch(String)
    /// The meeting is recording, or its stages are running here or in `earshot process`.
    case meetingBusy
    /// Extra items can't go out while the meeting's own send is waiting or failed: Retry would send them again.
    case sendNotFinished
    /// "Write notes" works only for a Record meeting whose stages are all done.
    case notAFinishedRecording

    public var errorDescription: String? {
        switch self {
        case let .dispatchFailed(detail): detail
        case let .compressMismatch(file): "The compressed copy of \(file) came out a different length, so the original was kept."
        case .meetingBusy: "Earshot is still working on this meeting. Try again when it's done."
        case .sendNotFinished: "This meeting's first send hasn't finished. Press Retry before sending more."
        case .notAFinishedRecording: "Notes can be written only for a finished recording."
        }
    }
}

/// Runs each meeting's remaining stages in order and records every step in its session.json. Every save goes through
/// `SessionStore.update` (spec 14.3), so a flag added while a stage runs, or a Fix revision, is never overwritten.
public actor Pipeline {
    /// Which action items to send; nil means the user chose not to send.
    public typealias Confirm = @Sendable (Session, MeetingNotes) async -> [ActionItem]?

    let store: SessionStore
    let transcriber: any Transcribing
    let compressor: any AudioCompressing
    let makeWriter: @Sendable () throws -> any NotesWriter
    let makeTargets: @Sendable () -> [any DoTarget]
    let config: @Sendable () -> PipelineConfig
    let confirm: Confirm
    let events: @Sendable (PipelineEvent) -> Void
    /// One run at a time per target, shared with every live Start queue (spec 3.2).
    let lanes: TargetLanes
    /// Meetings whose stages, revision or extra send are in progress here.
    var running: Set<String> = []

    public init(store: SessionStore, transcriber: any Transcribing, compressor: any AudioCompressing,
                makeWriter: @escaping @Sendable () throws -> any NotesWriter,
                makeTargets: @escaping @Sendable () -> [any DoTarget],
                config: @escaping @Sendable () -> PipelineConfig, confirm: @escaping Confirm,
                events: @escaping @Sendable (PipelineEvent) -> Void, lanes: TargetLanes = .shared) {
        self.store = store
        self.transcriber = transcriber
        self.compressor = compressor
        self.makeWriter = makeWriter
        self.makeTargets = makeTargets
        self.config = config
        self.confirm = confirm
        self.events = events
        self.lanes = lanes
    }

    public func isRunning(_ sessionID: String) -> Bool { running.contains(sessionID) }

    public func resumeAll() async {
        for session in store.resumable() { await run(sessionID: session.id) }
    }

    /// The user pressed Retry: clear the failure count on the stopped stage and run again.
    /// A meeting that is running is left alone: its stage is in flight, and resetting it would run it twice.
    /// Retry is also the user's go-ahead to send again to a target that a quit or crash cut off.
    public func retry(sessionID: String) async {
        guard !running.contains(sessionID), let session = find(sessionID), session.nextStage != nil else { return }
        _ = try? store.update(sessionID) { current in
            guard let next = current.nextStage else { return }
            current.stages[next] = StageState()
            current.inFlight = []
        }
        await run(sessionID: sessionID, throughHeld: true)
    }

    /// Runs the meeting's remaining stages. A later stage held at `SessionStore.autoResumeLimit` failures (the send
    /// `earshot process` held back for a person) is not run: it is marked failed, so it waits for Retry.
    public func run(sessionID: String) async {
        await run(sessionID: sessionID, throughHeld: false)
    }

    /// - Parameter throughHeld: true for Retry, the user's go-ahead, and for `earshot process` running its own send.
    func run(sessionID: String, throughHeld: Bool) async {
        guard !running.contains(sessionID), var session = find(sessionID), !session.recording,
              session.nextStage != nil else { return }
        running.insert(sessionID)
        defer { running.remove(sessionID) }
        while let stage = session.nextStage {
            var failures = 0
            var held = false
            do {
                session = try store.update(sessionID) { current in
                    failures = current.stages[stage]?.failures ?? 0
                    if !throughHeld, failures >= SessionStore.autoResumeLimit {
                        held = true
                        current.stages[stage] = StageState(status: .failed, error: SessionStore.interruptedError,
                                                           failures: failures)
                    } else {
                        current.stages[stage] = StageState(status: .running, failures: failures)
                    }
                }
            } catch {
                // Without a saved record there is nothing to resume from, but the user must still hear about it.
                events(.failed(sessionID: sessionID, stage: stage, message: Self.describe(error)))
                return
            }
            if held {
                events(.failed(sessionID: sessionID, stage: stage, message: SessionStore.interruptedError))
                return
            }
            events(.started(sessionID: sessionID, stage: stage))
            do {
                session = try await perform(stage, on: session)
                session = try store.update(sessionID) { $0.stages[stage] = StageState(status: .done) }
                if stage == .notes { events(.notesReady(sessionID: sessionID, notes: notesToOpen(session))) }
            } catch where error is CancellationError || Task.isCancelled {
                // Cancelled, not broken: leave the stage to be picked up again, with no failure counted and no alarm.
                // `Task.isCancelled` also covers errors that only look like failures, such as URLSession's cancelled.
                _ = try? store.update(sessionID) { $0.stages[stage] = StageState(status: .pending, failures: failures) }
                return
            } catch {
                // `update` re-reads, so anything the stage saved before it failed is kept.
                let message = Self.describe(error)
                _ = try? store.update(sessionID) {
                    $0.stages[stage] = StageState(status: .failed, error: message, failures: failures + 1)
                }
                events(.failed(sessionID: sessionID, stage: stage, message: Self.notice(error)))
                return
            }
        }
        // The entry written with the notes was taken before the meeting finished; this one says it is finished.
        _ = try? warn(session, publish(session, config: config()))
        events(.finished(sessionID: sessionID))
    }

    func find(_ sessionID: String) -> Session? { store.find(sessionID) }

    /// What the Notes ready notification opens: the notes page, like the meeting rows (`MeetingOpener`), or
    /// notes.md when notes.html couldn't be written.
    func notesToOpen(_ session: Session) -> URL {
        let page = store.file(session, MeetingFile.notesPage)
        return FileManager.default.fileExists(atPath: page.path) ? page : store.file(session, MeetingFile.notesMarkdown)
    }

    func perform(_ stage: Stage, on session: Session) async throws -> Session {
        switch stage {
        case .transcribe: try await transcribe(session)
        case .notes: try await writeNotes(session)
        case .dispatch: try await dispatch(session)
        case .compress: try await compress(session)
        }
    }

    /// Re-reads, changes and saves the meeting under its folder lock, and returns what was saved.
    @discardableResult
    func save(_ session: Session, _ mutate: (inout Session) throws -> Void) throws -> Session {
        try store.update(session.id, mutate)
    }

    /// Adds each warning the meeting doesn't already have.
    func warn(_ session: Session, _ warnings: [String]) throws -> Session {
        guard !warnings.isEmpty else { return session }
        return try save(session) { current in
            for warning in warnings where !current.warnings.contains(warning) { current.warnings.append(warning) }
        }
    }

    func transcribe(_ session: Session) async throws -> Session {
        let config = config()
        var segments: [Segment] = []
        for track in session.tracks {
            let url = store.file(session, track.file)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }  // a track that never started
            segments += try await transcriber.transcribe(url, track: track.track, locale: config.locale)
        }
        let offsets = Dictionary(session.tracks.map { ($0.track, $0.offset) }, uniquingKeysWith: { first, _ in first })
        let merged = TranscriptMerger.merge(segments, offsets: offsets)
        try Self.json(merged).write(to: store.file(session, "transcript.json"), options: .atomic)
        try Data(TranscriptRenderer.markdown(merged, names: config.names).utf8)
            .write(to: store.file(session, "transcript.md"), options: .atomic)
        return session
    }

    static func interrupted(_ label: String) -> String {
        "Interrupted while sending to \(label). Press Retry to send again."
    }

    func compress(_ session: Session) async throws -> Session {
        var session = session
        if hasNotesToReplaceAudio(session) {
            for track in session.tracks { try? FileManager.default.removeItem(at: store.file(session, track.file)) }
            return try save(session) { current in
                current.tracks = []
                current.warnings.append("The audio was deleted after the notes were written (Settings, Storage).")
            }
        }
        for index in session.tracks.indices {
            let source = store.file(session, session.tracks[index].file)
            if source.pathExtension == "m4a", FileManager.default.fileExists(atPath: source.path) {
                // Already compressed. A .caf beside it is what a crash between saving and deleting left behind. It is
                // only removed while the .m4a is there, so the last copy of the audio is never deleted.
                try? FileManager.default.removeItem(at: source.deletingPathExtension().appendingPathExtension("caf"))
                continue
            }
            guard source.pathExtension == "caf", FileManager.default.fileExists(atPath: source.path) else { continue }
            let name = source.deletingPathExtension().lastPathComponent + ".m4a"
            let destination = store.file(session, name)
            try? FileManager.default.removeItem(at: destination)  // a half-written copy from an earlier crash
            try await compressor.compress(source, to: destination)
            let written = try compressor.duration(of: destination), original = try compressor.duration(of: source)
            guard abs(written - original) <= 1 else { throw PipelineError.compressMismatch(session.tracks[index].file) }
            // Point the session at the .m4a before the .caf goes. A crash in between leaves a stray .caf, never a
            // track whose file is gone; the stray one is harmless, so a failed delete does not fail the stage.
            let old = session.tracks[index].file
            session = try save(session) { current in
                for i in current.tracks.indices where current.tracks[i].file == old { current.tracks[i].file = name }
            }
            try? FileManager.default.removeItem(at: source)
        }
        return session
    }

    /// True when "keep audio" is off and real notes exist. A recording with no speech keeps its audio: with nothing
    /// transcribed, the audio is the only record of the meeting.
    func hasNotesToReplaceAudio(_ session: Session) -> Bool {
        guard !config().keepAudio, session.mode != .record,
              FileManager.default.fileExists(atPath: store.file(session, "notes.md").path),
              let notes = try? JSONDecoder().decode(MeetingNotes.self, from: Data(contentsOf: store.file(session, "notes.json")))
        else { return false }
        return notes != .noSpeech
    }

    static func json(_ value: some Encodable) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(value)
    }

    /// The failure as a notification says it. Notifications can show on the lock screen and on other devices, so
    /// notes in the wrong shape, whose detail is an excerpt of what the model wrote, get a generic sentence.
    static func notice(_ error: any Error) -> String {
        if case .badOutput? = error as? NotesError {
            return "The notes came back in the wrong shape. Press Retry in Earshot to try again."
        }
        return describe(error)
    }

    /// One plain sentence for session.json and notifications. `localizedDescription` never dumps an NSError's
    /// domain, user info or file paths the way `String(describing:)` does.
    static func describe(_ error: any Error) -> String {
        String(((error as? LocalizedError)?.errorDescription ?? error.localizedDescription).prefix(300))
    }
}
