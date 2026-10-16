import Foundation
import Testing
@testable import EarshotKit

/// Records every notes request, so a test can check the context the pipeline built.
final class RecordingWriter: NotesWriter, @unchecked Sendable {
    let requests = Locked<[NotesRequest]>([])
    let notes = Locked(sampleNotes)
    /// While true, `write` waits, so a test can act while the notes stage is in flight.
    let held = Locked(false)
    func write(_ request: NotesRequest) async throws -> MeetingNotes {
        requests.update { $0.append(request) }
        while held.get { try await Task.sleep(for: .milliseconds(5)) }
        return notes.get
    }
}

/// A routine-like target: it succeeds and returns `link`.
final class LinkTarget: DoTarget, @unchecked Sendable {
    let id = "routine"
    let label = "Claude Code routine"
    let link: String?
    let sent = Locked<[DoPayload]>([])
    init(link: String?) { self.link = link }
    func send(_ payload: DoPayload, json: Data, folder: URL) async -> DispatchResult {
        sent.update { $0.append(payload) }
        return DispatchResult(ok: true, detail: "created", link: link)
    }
}

/// A v2 pipeline world in temp folders: meetings, the index and lessons.
struct V2World {
    static let link = "https://claude.ai/code/session_01ABC"

    let store = SessionStore(root: tempDir(), timeZone: newYork)
    var index: LibraryIndex? = LibraryIndex(url: tempDir().appending(path: "Index", directoryHint: .isDirectory))
    let lessons = LessonsStore(url: tempDir().appending(path: "Earshot/lessons.json"))
    let writer = RecordingWriter()
    var targets: [any DoTarget] = [FakeTarget("webhook")]
    var learnFromEdits = true
    let events = Locked<[PipelineEvent]>([])
    /// This world's own lanes, so tests running side by side never wait on each other's targets.
    var lanes = TargetLanes()

    var config: PipelineConfig {
        PipelineConfig(userName: "Stephen", locale: Locale(identifier: "en-US"), timeZone: newYork, lessons: lessons,
                       learnFromEdits: learnFromEdits, index: index, myDomains: "northwind.com",
                       now: { at1530.addingTimeInterval(3600) })
    }

    func pipeline(store: SessionStore? = nil,
                  confirm: @escaping Pipeline.Confirm = { _, notes in ActionItem.defaultSelection(notes.actionItems) })
        -> Pipeline {
        let writer = self.writer, targets = self.targets, events = self.events, config = self.config
        return Pipeline(store: store ?? self.store, transcriber: FakeTranscriber(segments: meetingSegments),
                        compressor: FakeCompressor(), makeWriter: { writer }, makeTargets: { targets },
                        config: { config }, confirm: confirm,
                        events: { event in events.update { $0.append(event) } }, lanes: lanes)
    }

    static let event = NotesContextBuilderTests.event

    /// A stopped meeting with two tracks, ready for its stages.
    func meeting(mode: Mode = .notesAndDo, title: String? = "Acme follow-up", event: CalendarEventInfo? = nil,
                 flags: [Flag] = []) throws -> Session {
        let session = try store.create(mode: mode, title: title, now: at1530)
        try Data("mic".utf8).write(to: store.file(session, "mic.caf"))
        try Data("sys".utf8).write(to: store.file(session, "system.caf"))
        return try store.update(session.id) { s in
            s.tracks = [TrackFile(track: .me, file: "mic.caf", offset: 0), TrackFile(track: .them, file: "system.caf", offset: 0)]
            s.recording = false
            s.endedAt = at1530.addingTimeInterval(2400)
            s.calendarEvent = event
            s.profile = event == nil ? nil : .external
            s.flags = flags
        }
    }

    /// A finished Notes + Do meeting, run through this world's pipeline.
    func finished(confirm: @escaping Pipeline.Confirm = { _, notes in ActionItem.defaultSelection(notes.actionItems) })
        async throws -> (Pipeline, Session) {
        let s = try meeting()
        let pipeline = self.pipeline(confirm: confirm)
        await pipeline.run(sessionID: s.id)
        return (pipeline, try #require(store.find(s.id)))
    }

    func notes(_ s: Session) throws -> MeetingNotes { try store.read(MeetingNotes.self, s, MeetingFile.notes) }
    func items(_ s: Session) throws -> [ActionItem] { try store.read([ActionItem].self, s, MeetingFile.items) }
    func page(_ s: Session) throws -> String { try String(contentsOf: store.file(s, MeetingFile.notesPage), encoding: .utf8) }
    func fresh(_ s: Session) throws -> Session { try #require(store.find(s.id)) }
}

struct PipelineV2Tests {
    // MARK: The notes context

    @Test func theNotesStageSendsTheContextFromTheMeetingFiles() async throws {
        let w = V2World()
        let s = try w.meeting(event: V2World.event, flags: [Flag(offset: 3, source: .hotkey)])
        let loops = [OpenLoop(owner: "Dana", task: "Send the pricing sheet", from: "Acme pricing, 7 Oct")]
        try w.store.write(MeetingBrief(eventID: "e1", model: "m", createdAt: at1530, headline: "Pricing", openLoops: loops),
                          s, MeetingFile.brief)
        try w.store.write(LiveFile(items: [
            LiveItem(id: "L1", task: "Draft the pilot scope email", owner: "Stephen", aiDoable: true, firstSeen: 2, status: .done),
            LiveItem(id: "L2", task: "Book the room", owner: "Stephen", aiDoable: false, firstSeen: 3),
        ]), s, MeetingFile.live)
        try w.store.write(ScreenFile(moments: [ScreenMoment(offset: 5, text: "Q4 price per seat on this slide")]),
                          s, MeetingFile.screen)
        try w.lessons.add(Lesson(date: at1530, style: .general, kind: .notSent,
                                 before: Lesson.Item(task: "Book the venue", owner: "Stephen"), meetingTitle: "Old"))
        await w.pipeline().run(sessionID: s.id)
        let context = try #require(w.writer.requests.get.first?.context)
        #expect(context.attendees == [ContextAttendee(name: "Stephen Thorn", side: .me),
                                      ContextAttendee(name: "Dana Lee", side: .external),
                                      ContextAttendee(name: "Lee Park", side: .internal)])
        #expect(context.profile == .external)
        #expect(context.agenda == "Pricing follow-up\nJoin: [link]")
        #expect(context.openLoops == loops)
        #expect(context.lessons.map(\.before?.task) == ["Book the venue"])
        #expect(context.flags == [Excerpt(offset: 3, text: "[00:00:01] Stephen: Dana, I'll send the scope by Friday.\n"
                                          + "[00:00:04] Them: Great, thanks.")])
        #expect(context.screen.map(\.offset) == [5])
        #expect(context.started == [NotesContext.StartedItem(id: "L1", task: "Draft the pilot scope email")])
    }

    @Test func withoutACompleteBriefTheLoopsComeFromRelatedMeetings() async throws {
        let w = V2World()
        let index = try #require(w.index)
        let pastStore = SessionStore(root: tempDir(), timeZone: newYork)
        var past = try pastStore.create(mode: .notes, title: "Acme pricing", now: at1530.addingTimeInterval(-7 * 86_400))
        past.calendarEvent = CalendarEventInfo(id: "e0", title: "Acme pricing", start: past.startedAt,
                                               end: past.startedAt, attendees: [Attendee(name: "Dana Lee", email: "dana@acme.com")])
        let pastNotes = MeetingNotes(title: "Acme pricing", summary: "Pricing.",
                                     actionItems: [ActionItem(task: "Send the pricing sheet", owner: "Dana Lee", doer: .someoneElse)])
        try index.write(MeetingRecord(session: past, folder: pastStore.folder(past), notes: pastNotes), transcript: [],
                        names: [:], userName: "Stephen")
        let s = try w.meeting(event: V2World.event)
        // A brief that lost an open loop to lenient decoding is not complete.
        try Data(#"{"version":1,"model":"m","createdAt":"2026-10-14T19:30:00Z","headline":"h","openLoops":[{"owner":"Dana"}]}"#.utf8)
            .write(to: w.store.file(s, MeetingFile.brief))
        await w.pipeline().run(sessionID: s.id)
        let context = try #require(w.writer.requests.get.first?.context)
        #expect(context.openLoops == [OpenLoop(owner: "Dana Lee", task: "Send the pricing sheet", from: "Acme pricing, 7 Oct")])
    }

    @Test func lessonsAreLeftOutWhenLearningIsOff() async throws {
        var w = V2World()
        w.learnFromEdits = false
        try w.lessons.add(Lesson(date: at1530, style: .general, kind: .instruction, instruction: "Shorter", meetingTitle: "Old"))
        let s = try w.meeting(mode: .notes)
        await w.pipeline().run(sessionID: s.id)
        #expect(w.writer.requests.get.first?.context == .empty)
    }

    @Test func aFlagAddedWhileTheNotesAreWrittenIsKept() async throws {
        let w = V2World()
        let s = try w.meeting(mode: .notes)
        w.writer.held.update { $0 = true }
        let pipeline = w.pipeline()
        let run = Task { await pipeline.run(sessionID: s.id) }
        for _ in 0..<400 where w.writer.requests.get.isEmpty { try await Task.sleep(for: .milliseconds(5)) }
        try w.store.update(s.id) { $0.flags.append(Flag(offset: 9, source: .panel)) }
        w.writer.held.update { $0 = false }
        await run.value
        let done = try w.fresh(s)
        #expect(done.isFinished && done.flags == [Flag(offset: 9, source: .panel)])
    }

    // MARK: The page and the index

    @Test func thePageAndTheIndexAreWrittenWithTheNotes() async throws {
        let w = V2World()
        let s = try w.meeting(mode: .notes)
        await w.pipeline().run(sessionID: s.id)
        let done = try w.fresh(s)
        #expect(try w.page(done).contains("<title>Acme kickoff</title>"))
        let entry = try #require(w.index?.entry(id: s.id))
        #expect(entry.record.notes?.title == "Acme kickoff" && entry.record.finished)
        #expect(entry.transcript.map(\.speaker) == ["Stephen", "Them"])
        #expect(w.index?.reminders()?.items.map(\.task) == ["Draft the pilot scope email to Dana", "Call the venue"])
        #expect(done.warnings.isEmpty)
    }

    @Test func anIndexThatCantBeWrittenIsAWarningNotAFailure() async throws {
        var w = V2World()
        let blocked = tempDir().appending(path: "Index")
        try Data("not a folder".utf8).write(to: blocked)
        w.index = LibraryIndex(url: blocked)
        let s = try w.meeting(mode: .notes)
        await w.pipeline().run(sessionID: s.id)
        let done = try w.fresh(s)
        #expect(done.isFinished && done.stages[.notes]?.status == .done)
        #expect(done.warnings.contains { $0.hasPrefix("The meeting index that other apps read couldn't be updated") })
        #expect(done.warnings.filter { $0.hasPrefix("The meeting index") }.count == 1)
        #expect(FileManager.default.fileExists(atPath: w.store.file(done, MeetingFile.notesPage).path))
    }

    // MARK: Dispatch

    @Test func confirmedItemsAreSavedWithTheirNotesSource() async throws {
        let w = V2World()
        let (_, done) = try await w.finished(confirm: { _, notes in
            [notes.actionItems[1], ActionItem(task: "Draft the pilot scope email to Dana Lee", owner: "Stephen",
                                              due: "Friday", doer: .ai)]
        })
        #expect(try w.items(done).map(\.source) == ["n2", "n1"])
        // The app's own tag wins over a match.
        let tagged = V2World()
        let (_, other) = try await tagged.finished(confirm: { _, notes in
            var item = notes.actionItems[0]
            item.source = "n1"
            return [item]
        })
        #expect(try tagged.items(other).map(\.source) == ["n1"])
    }

    @Test func itemsStartedDuringTheCallAreNeverSent() async throws {
        let w = V2World()
        var linked = sampleNotes
        linked.actionItems[0].liveRef = "L1"
        w.writer.notes.update { $0 = linked }
        let s = try w.meeting()
        try w.store.write(LiveFile(items: [LiveItem(id: "L1", task: "Scope email", owner: "Stephen", aiDoable: true,
                                                    firstSeen: 2, status: .startedInCloud)]), s, MeetingFile.live)
        let target = FakeTarget("webhook")
        var world = w
        world.targets = [target]
        // The confirm window returned every item, the started one too.
        await world.pipeline(confirm: { _, notes in notes.actionItems }).run(sessionID: s.id)
        #expect(target.sent.get.first?.items.map(\.task) == ["Call the venue"])
        #expect(try w.items(w.fresh(s)).map(\.task) == ["Call the venue"])
    }

    @Test func aSavedChoiceNeverSendsAnItemStartedDuringTheCall() async throws {
        var w = V2World()
        let target = FakeTarget("webhook")
        w.targets = [target]
        var linked = sampleNotes
        linked.actionItems[0].liveRef = "L1"
        let s = try w.meeting()
        try Pipeline.json(meetingSegments.values.flatMap { $0 }).write(to: w.store.file(s, MeetingFile.transcript))
        try Pipeline.json(linked).write(to: w.store.file(s, MeetingFile.notes))
        // Chosen on an earlier try, before the live to-do was known to have gone out.
        try Pipeline.json(linked.actionItems).write(to: w.store.file(s, MeetingFile.items))
        try w.store.write(LiveFile(items: [LiveItem(id: "L1", task: "Scope email", owner: "Stephen", aiDoable: true,
                                                    firstSeen: 2, status: .interrupted)]), s, MeetingFile.live)
        try w.store.update(s.id) { $0.stages[.transcribe] = StageState(status: .done); $0.stages[.notes] = StageState(status: .done) }
        await w.pipeline(confirm: { _, _ in nil }).run(sessionID: s.id)
        #expect(target.sent.get.first?.items.map(\.task) == ["Call the venue"])
    }

    @Test func anUnreadableLiveFileHoldsBackItemsThatPointAtLiveToDos() async throws {
        var w = V2World()
        let target = FakeTarget("webhook")
        w.targets = [target]
        var linked = sampleNotes
        linked.actionItems[0].liveRef = "L1"
        w.writer.notes.update { $0 = linked }
        let s = try w.meeting()
        try Data("garbage".utf8).write(to: w.store.file(s, MeetingFile.live))
        await w.pipeline(confirm: { _, notes in notes.actionItems }).run(sessionID: s.id)
        #expect(target.sent.get.first?.items.map(\.task) == ["Call the venue"])
    }

    @Test func editsInTheConfirmWindowWriteANotesRevisionBeforeSending() async throws {
        var w = V2World()
        let target = FakeTarget("webhook")
        w.targets = [target]
        let (_, done) = try await w.finished(confirm: { _, notes in
            var item = notes.actionItems[0]
            item.task = "Draft the pilot scope email to Dana and Lee"
            item.due = "Thursday"
            item.source = "n1"
            return [item]
        })
        #expect(done.notesRevision == 1)
        let kept = try w.store.read(MeetingNotes.self, done, MeetingFile.notesRevision(0))
        #expect(kept == sampleNotes)
        let revised = try w.notes(done)
        #expect(revised.actionItems[0].task == "Draft the pilot scope email to Dana and Lee")
        #expect(revised.actionItems[0].due == "Thursday" && revised.actionItems[0].source == nil)
        #expect(revised.actionItems[1] == sampleNotes.actionItems[1])
        #expect(try String(contentsOf: w.store.file(done, MeetingFile.notesMarkdown), encoding: .utf8)
            .contains("Draft the pilot scope email to Dana and Lee (Stephen, due Thursday)"))
        #expect(try w.page(done).contains("Draft the pilot scope email to Dana and Lee"))
        #expect(target.sent.get.first?.notes.actionItems[0].task == "Draft the pilot scope email to Dana and Lee")
        let entry = try #require(w.index?.entry(id: done.id))
        #expect(entry.record.items.first?.item.task == "Draft the pilot scope email to Dana and Lee")
        #expect(entry.record.statuses.first == "Sent to Webhook")
    }

    @Test func sendingWithoutEditsWritesNoRevision() async throws {
        let w = V2World()
        let (_, done) = try await w.finished()
        #expect(done.notesRevision == 0)
        #expect(!FileManager.default.fileExists(atPath: w.store.file(done, MeetingFile.notesRevision(0)).path))
        #expect(try w.page(done).contains("Sent to Webhook"))
    }

    @Test func aRoutineRunLinkIsRecordedAndTheIndexShowsTheSend() async throws {
        var w = V2World()
        w.targets = [LinkTarget(link: V2World.link)]
        let (_, done) = try await w.finished()
        #expect(done.routineRuns == [done.id: V2World.link])
        #expect(w.index?.entry(id: done.id)?.record.routineRuns == [done.id: V2World.link])
        // The routine started a run for the item, so it shows as started in the cloud, with the run on the page.
        #expect(w.index?.entry(id: done.id)?.record.statuses.first == ItemStatus.startedInCloud)
        #expect(try w.page(done).contains(">Started in the cloud</span><a class=\"run\" href=\"\(V2World.link)\">Open run</a>"))
        // A run created without a link is still a send, with nothing to record.
        var bare = V2World()
        bare.targets = [LinkTarget(link: nil)]
        let (_, other) = try await bare.finished()
        #expect(other.isFinished && other.sent == ["routine"] && other.routineRuns.isEmpty)
        #expect(bare.index?.entry(id: other.id)?.record.statuses.first == "Sent to Claude Code routine")
    }

    @Test func aChoiceSavedByTheCommandLineIsAskedAgainOnRetry() async throws {
        var w = V2World()
        let target = FakeTarget("webhook")
        w.targets = [target]
        let s = try w.meeting()
        try w.store.update(s.id) { $0.startedBy = .cli }
        let asked = Locked(0)
        let pipeline = w.pipeline(confirm: { _, notes in
            asked.update { $0 += 1 }
            return [notes.actionItems[1]]
        })
        target.ok.update { $0 = false }
        // `earshot process` holds the meeting while it runs, so its pick is the AI's, not a person's.
        try w.store.markBusy(s)
        await pipeline.run(sessionID: s.id)
        w.store.clearBusy(s)
        target.ok.update { $0 = true }
        await pipeline.retry(sessionID: s.id)
        #expect(asked.get == 2)
        #expect(target.sent.get.last?.items.map(\.task) == ["Call the venue"])
    }

    // MARK: v1 meetings

    @Test func v1MeetingsRunExactlyAsBefore() async throws {
        let w = V2World()
        let store = try V1Fixtures.store()
        let target = FakeTarget("webhook")
        var world = w
        world.targets = [target]
        let asked = Locked(0)
        let pipeline = world.pipeline(store: store, confirm: { _, _ in
            asked.update { $0 += 1 }
            return nil
        })
        // Finished meetings are left exactly as they are.
        let acme = try V1Fixtures.session(store, "Acme kickoff")
        await pipeline.run(sessionID: acme.id)
        #expect(!FileManager.default.fileExists(atPath: store.file(acme, MeetingFile.notesPage).path))
        // The interrupted one gets v1's prompt, with no context.
        let weekly = try V1Fixtures.session(store, "Weekly sync")
        await pipeline.run(sessionID: weekly.id)
        let request = try #require(w.writer.requests.get.first)
        #expect(request.context == .empty)
        #expect(NotesPrompt.system(request) == NotesPrompt.system(NotesRequest(
            transcript: request.transcript, userName: "Stephen", style: .general, extraInstructions: "",
            startedAt: weekly.startedAt, duration: weekly.duration, timeZone: newYork)))
        #expect(store.find(weekly.id)?.isFinished == true)
        // The failed send retries with the items v1 chose, unchanged and without asking.
        let initech = try V1Fixtures.session(store, "Initech onboarding")
        let saved = try Data(contentsOf: store.file(initech, MeetingFile.items))
        await pipeline.retry(sessionID: initech.id)
        #expect(asked.get == 0)
        #expect(try Data(contentsOf: store.file(initech, MeetingFile.items)) == saved)
        #expect(target.sent.get.map(\.session.id) == [initech.id])
        #expect(target.sent.get.first?.items == [ActionItem(task: "Prepare the Initech onboarding plan", owner: "Stephen",
                                                           due: "Thursday", doer: .ai,
                                                           context: "Two admins, quarter-end deadline.")])
        let done = try #require(store.find(initech.id))
        #expect(done.isFinished && done.sent == ["webhook"] && done.notesRevision == 0)
    }

    // MARK: Revisions, extra sends and reindex

    @Test func saveRevisionKeepsEachOldVersionAndStoresTheLesson() async throws {
        let w = V2World()
        let (pipeline, done) = try await w.finished()
        var fixed = sampleNotes
        fixed.summary = "A three-week pilot."
        let lesson = LessonDiff.instruction("Say three weeks", style: .general, title: "Acme kickoff", date: at1530)
        try await pipeline.saveRevision(sessionID: done.id, notes: fixed, lesson: lesson)
        var now = try w.fresh(done)
        #expect(now.notesRevision == 1)
        #expect(try w.store.read(MeetingNotes.self, now, MeetingFile.notesRevision(0)) == sampleNotes)
        #expect(try w.notes(now).summary == "A three-week pilot.")
        #expect(try String(contentsOf: w.store.file(now, MeetingFile.notesMarkdown), encoding: .utf8).contains("A three-week pilot."))
        #expect(try w.page(now).contains("A three-week pilot."))
        #expect(w.index?.entry(id: now.id)?.record.summary == "A three-week pilot.")
        #expect(w.lessons.all().map(\.instruction) == ["Say three weeks"])
        fixed.summary = "A four-week pilot."
        try await pipeline.saveRevision(sessionID: done.id, notes: fixed, lesson: nil)
        now = try w.fresh(done)
        #expect(now.notesRevision == 2)
        #expect(try w.store.read(MeetingNotes.self, now, MeetingFile.notesRevision(1)).summary == "A three-week pilot.")
        #expect(try w.store.read(MeetingNotes.self, now, MeetingFile.notesRevision(0)) == sampleNotes)
        #expect(w.lessons.all().count == 1)
    }

    @Test func saveRevisionStoresNoLessonWhenLearningIsOff() async throws {
        var w = V2World()
        w.learnFromEdits = false
        let (pipeline, done) = try await w.finished()
        let lesson = LessonDiff.instruction("Shorter", style: .general, title: "Acme kickoff", date: at1530)
        try await pipeline.saveRevision(sessionID: done.id, notes: sampleNotes, lesson: lesson)
        #expect(w.lessons.all().isEmpty)
        #expect(try w.fresh(done).notesRevision == 1)
    }

    @Test func saveRevisionAndSendExtraThrowWhileTheMeetingRuns() async throws {
        let w = V2World()
        let s = try w.meeting(mode: .notes)
        w.writer.held.update { $0 = true }
        let pipeline = w.pipeline()
        let run = Task { await pipeline.run(sessionID: s.id) }
        for _ in 0..<400 where w.writer.requests.get.isEmpty { try await Task.sleep(for: .milliseconds(5)) }
        await #expect(throws: PipelineError.meetingBusy) {
            try await pipeline.saveRevision(sessionID: s.id, notes: sampleNotes, lesson: nil)
        }
        await #expect(throws: PipelineError.meetingBusy) {
            _ = try await pipeline.sendExtra(sessionID: s.id, items: sampleNotes.actionItems)
        }
        w.writer.held.update { $0 = false }
        await run.value
        #expect(try w.fresh(s).notesRevision == 0)
        // A meeting still recording can't be revised either.
        let recording = try w.store.create(mode: .notes, title: "Live", now: at1530)
        await #expect(throws: PipelineError.meetingBusy) {
            try await pipeline.saveRevision(sessionID: recording.id, notes: sampleNotes, lesson: nil)
        }
    }

    @Test func sendExtraUsesTheRevisionPayloadIDAndRecordsTheRun() async throws {
        var w = V2World()
        let routine = LinkTarget(link: V2World.link)
        w.targets = [routine]
        let (pipeline, done) = try await w.finished()
        var fixed = sampleNotes
        fixed.actionItems.append(ActionItem(task: "Summarise the pilot risks", owner: "Stephen", doer: .ai))
        try await pipeline.saveRevision(sessionID: done.id, notes: fixed, lesson: nil)
        let results = try await pipeline.sendExtra(sessionID: done.id, items: [fixed.actionItems[2]])
        #expect(results == ["routine": DispatchResult(ok: true, detail: "created", link: V2World.link)])
        let payload = try #require(routine.sent.get.last)
        let extraID = Pipeline.extraPayloadID(sessionID: done.id, revision: 1, items: [fixed.actionItems[2]])
        #expect(payload.session.id == extraID)
        #expect(payload.items.map(\.source) == ["n3"])
        let now = try w.fresh(done)
        #expect(now.routineRuns[extraID] == V2World.link)
        #expect(try w.items(now).map(\.source) == ["n1", "n3"])
        // Both sends started routine runs, so both items show as started in the cloud (spec 12).
        #expect(w.index?.entry(id: done.id)?.record.statuses == [ItemStatus.startedInCloud, ItemStatus.notSent,
                                                                   ItemStatus.startedInCloud])
    }

    @Test func reindexRewritesThePageAndTheEntry() async throws {
        let w = V2World()
        let (pipeline, done) = try await w.finished()
        try FileManager.default.removeItem(at: w.store.file(done, MeetingFile.notesPage))
        try w.index?.remove(id: done.id)
        await pipeline.reindex(sessionID: done.id)
        #expect(try w.page(done).contains("Acme kickoff"))
        #expect(w.index?.entry(id: done.id)?.record.statuses.first == "Sent to Webhook")
    }

    // MARK: Settings

    @Test func settingsFillTheNewConfigFields() {
        var settings = EarshotSettings()
        settings.learnFromEdits = false
        settings.myDomains = "northwind.com, acme.io"
        let config = settings.pipelineConfig
        #expect(!config.learnFromEdits && config.myDomains == "northwind.com, acme.io")
        #expect(config.lessons?.url == LessonsStore.defaultURL && config.index?.url == LibraryIndex.defaultURL)
        let plain = PipelineConfig()
        #expect(plain.lessons == nil && plain.index == nil && plain.learnFromEdits && plain.myDomains.isEmpty)
    }
}

/// The notes follow the meeting's profile (spec 5.3), like the live pass does.
struct NotesStyleTests {
    @Test func anExternalMeetingWithASalesWordGetsSalesCallNotesAndLessons() async throws {
        let w = V2World()
        try w.lessons.add(Lesson(date: at1530, style: .salesCall, kind: .instruction, instruction: "Lead with budget",
                                 meetingTitle: "Old"))
        // Newer, so it would come first if the notes used General.
        try w.lessons.add(Lesson(date: at1530.addingTimeInterval(60), style: .general, kind: .instruction,
                                 instruction: "Shorter", meetingTitle: "Old"))
        let s = try w.meeting(title: "Acme pricing demo", event: V2World.event)
        #expect(s.profile == .external)
        await w.pipeline().run(sessionID: s.id)
        let request = try #require(w.writer.requests.get.first)
        #expect(request.style == .salesCall)
        #expect(request.context.lessons.compactMap(\.instruction) == ["Lead with budget", "Shorter"],
                "the Sales call lessons come first")
        // The live pass works the style out the same way.
        #expect(LiveContext.meeting(session: s, settings: EarshotSettings(), lessons: []).style == .salesCall)
    }

    @Test func anInternalMeetingGetsGeneralWhateverTheDefault() throws {
        let store = SessionStore(root: tempDir(), timeZone: newYork)
        var s = try store.create(mode: .notes, title: "Standup", now: at1530)
        s.profile = .internal
        var config = PipelineConfig(style: .salesCall)
        #expect(config.style(for: s) == .general)
        s.profile = nil  // "Use my calendar" off: the default style
        #expect(config.style(for: s) == .salesCall)
        s.profile = .external
        s.title = "Acme kickoff"
        config.salesKeywords = "kickoff"
        #expect(config.style(for: s) == .salesCall, "Settings' sales words decide")
        config.salesKeywords = "pricing"
        #expect(config.style(for: s) == .general)
    }
}
