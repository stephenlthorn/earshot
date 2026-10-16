import Foundation

/// The notes stage, and what is written whenever notes are written or revised: notes.html and the index (spec 10 and
/// 11.1).
extension Pipeline {
    static func pageWarning(_ error: any Error) -> String {
        "The notes page (notes.html) couldn't be written: \(describe(error))"
    }

    static func indexWarning(_ error: any Error) -> String {
        "The meeting index that other apps read couldn't be updated: \(describe(error))"
    }

    func writeNotes(_ session: Session) async throws -> Session {
        let config = config()
        let merged = try JSONDecoder().decode([Segment].self, from: Data(contentsOf: store.file(session, "transcript.json")))
        var session = session
        let notes: MeetingNotes
        if merged.isEmpty {
            notes = .noSpeech
        } else {
            notes = try await makeWriter().write(NotesRequest(
                transcript: TranscriptRenderer.markdown(merged, names: config.names), userName: config.displayName,
                style: config.style(for: session), extraInstructions: config.extraInstructions, startedAt: session.startedAt,
                duration: session.duration, timeZone: config.timeZone,
                context: notesContext(session, transcript: merged, config: config)))
            if (session.title ?? "").isEmpty { session = try retitle(session, to: notes.title) }
        }
        try writeNotesFiles(notes, for: session, config: config)
        return try warn(session, publish(session, config: config))
    }

    /// Names an untitled meeting after its notes. The folder is renamed too, unless a live Start run is still
    /// sending or running: that run was handed the folder's path (a command's EARSHOT_SESSION_DIR, the
    /// do-<target>.log it writes when it ends), so the folder keeps its name and only the title is saved.
    func retitle(_ session: Session, to title: String) throws -> Session {
        let live = readOptional(LiveFile.self, session, MeetingFile.live)?.items ?? []
        guard live.contains(where: { [.sending, .running].contains($0.status) }) else {
            return try store.retitle(session, to: title)
        }
        return try save(session) { $0.title = title }
    }

    /// notes.json and notes.md.
    func writeNotesFiles(_ notes: MeetingNotes, for session: Session, config: PipelineConfig) throws {
        try Self.json(notes).write(to: store.file(session, "notes.json"), options: .atomic)
        let markdown = NotesRenderer.markdown(notes, startedAt: session.startedAt, duration: session.duration,
                                              timeZone: config.timeZone)
        try Data(markdown.utf8).write(to: store.file(session, "notes.md"), options: .atomic)
    }

    /// The context from the meeting's files. A file that is missing or can't be read is left out, so it never stops
    /// the notes. Every input is on disk before the stage starts, so a resumed notes stage sees the same context.
    func notesContext(_ session: Session, transcript: [Segment], config: PipelineConfig) -> NotesContext {
        let brief = (try? Data(contentsOf: store.file(session, MeetingFile.brief)))
            .flatMap(NotesContextBuilder.completeBrief(from:))
        let history = brief == nil && session.calendarEvent != nil ? related(session, config: config) : []
        return NotesContextBuilder.build(NotesContextBuilder.Input(
            session: session, transcript: transcript, names: config.names, brief: brief, history: history,
            lessons: config.learnFromEdits ? (config.lessons?.all() ?? []) : [],
            learnFromEdits: config.learnFromEdits, style: config.style(for: session), myDomains: config.myDomains,
            screen: readOptional(ScreenFile.self, session, MeetingFile.screen)?.moments ?? [],
            live: readOptional(LiveFile.self, session, MeetingFile.live)?.items ?? [], timeZone: config.timeZone))
    }

    /// Past meetings with the same people, from the index. "Now" is the meeting's start, so only meetings before it
    /// count and a resumed stage finds the same ones.
    func related(_ session: Session, config: PipelineConfig) -> [MeetingRecord] {
        guard let index = config.index else { return [] }
        return MeetingHistory.related(to: session, library: MeetingLibrary(index: index, store: store),
                                      userName: config.userName, now: session.startedAt)
    }

    /// Re-renders notes.html (when there are notes) and rewrites the meeting's index entry and reminders.json (when
    /// there is an index). Best effort: each failure comes back as a warning and nothing throws.
    func publish(_ session: Session, config: PipelineConfig) -> [String] {
        var warnings: [String] = []
        // Taken before the files are read: a file written while they are read leaves the entry stale for reconcile.
        let stamp = LibraryIndex.stamp(folder: store.folder(session))
        let notes = readOptional(MeetingNotes.self, session, MeetingFile.notes)
        let transcript = readOptional([Segment].self, session, MeetingFile.transcript)
        let items = readOptional([ActionItem].self, session, MeetingFile.items)
        let live = readOptional(LiveFile.self, session, MeetingFile.live)?.items ?? []
        let brief = readOptional(MeetingBrief.self, session, MeetingFile.brief)
        if let notes {
            let runs = ItemStatus.cloudRuns(notes: notes, items: items, session: session)
            let page = NotesPageRenderer.html(NotesPageInput(
                notes: notes, session: session, transcript: transcript ?? [], names: config.names, brief: brief,
                liveItems: live, screenMoments: readOptional(ScreenFile.self, session, MeetingFile.screen)?.moments ?? [],
                statuses: ItemStatus.compute(notes: notes, items: items, sent: session.sent, live: live, cloudRuns: runs),
                cloudRuns: runs, timeZone: config.timeZone))
            do {
                try Data(page.utf8).write(to: store.file(session, MeetingFile.notesPage), options: .atomic)
            } catch {
                warnings.append(Self.pageWarning(error))
            }
        }
        if let index = config.index {
            let hasTranscript = FileManager.default.fileExists(atPath: store.file(session, MeetingFile.transcript).path)
            let record = MeetingRecord(session: session, folder: store.folder(session), notes: notes, items: items,
                                       live: live, brief: brief, hasTranscript: hasTranscript)
            do {
                try index.write(record, transcript: transcript ?? [], names: config.names, userName: config.userName,
                                stamp: stamp)
                try index.writeReminders(userName: config.userName, now: config.now())
            } catch {
                warnings.append(Self.indexWarning(error))
            }
        }
        return warnings
    }

    /// The file decoded, or nil when it is missing or can't be read.
    func readOptional<T: Decodable>(_ type: T.Type, _ session: Session, _ name: String) -> T? {
        (try? store.readIfPresent(type, session, name)) ?? nil
    }
}
