import Foundation
import Testing
@testable import EarshotKit

/// A Claude client that answers with one JSON string, or throws, and counts its calls.
private final class StartBriefClient: ClaudeClient, @unchecked Sendable {
    let answer: String
    let error: NotesError?
    /// Runs while Claude is "working": the recording stops, or the job is cancelled.
    let meanwhile: @Sendable () -> Void
    let requests = Locked<[ClaudeRequest]>([])

    init(_ answer: String = StartTests.briefReply, error: NotesError? = nil, meanwhile: @escaping @Sendable () -> Void = {}) {
        self.answer = answer
        self.error = error
        self.meanwhile = meanwhile
    }

    func structured(_ request: ClaudeRequest) async throws -> Data {
        requests.update { $0.append(request) }
        meanwhile()
        if let error { throw error }
        return Data(answer.utf8)
    }
}

/// The brief started at recording start (spec 5.5): only when it should be written, atomically, never throwing.
extension StartTests {
    static let briefReply = #"{"headline":"Dana wants the pilot scope.","points":["Two week pilot"],"open_loops":[]}"#

    @Suite struct BriefJobTests {
        let h = LibraryHarness()

        fileprivate func job(_ client: StartBriefClient, settings: EarshotSettings = StartTests.settings { $0.userName = "Stephen" },
                 makeFails: Bool = false) -> BriefJob {
            BriefJob(store: h.store, library: h.library, settings: settings,
                     makeClient: { if makeFails { throw NotesError.claudeNotFound }; return client },
                     now: { at1530.addingTimeInterval(60) }, timeZone: newYork)
        }

        func recording(mode: Mode = .notes, event: CalendarEventInfo?) throws -> Session {
            var session = try h.store.create(mode: mode, title: event?.title, now: at1530, startedBy: .manual)
            session.calendarEvent = event
            try h.store.save(session)
            return session
        }

        @Test func writesBriefJSONWithTheQuickModelFromTheEventAndHistory() async throws {
            let event = LibraryHarness.event("Acme pricing", [("Dana Smith", "dana@acme.com")])
            let past = try h.meeting("Acme kickoff", daysAgo: 3, notes: LibraryHarness.notes("Acme kickoff"), event: event)
            let session = try recording(event: event)
            let client = StartBriefClient()
            var settings = StartTests.settings { $0.userName = "Stephen" }
            settings.quickModel = "quick-model"
            let outcome = await job(client, settings: settings).run(sessionID: session.id)
            let brief = try #require(try h.store.readIfPresent(MeetingBrief.self, session, MeetingFile.brief))
            #expect(outcome == .written(brief))
            #expect(brief.headline == "Dana wants the pilot scope.")
            #expect(brief.sources == [past.id])
            #expect(brief.eventID == event.id)
            #expect(brief.model == "quick-model")
            #expect(client.requests.get.map(\.model) == ["quick-model"])
            #expect(client.requests.get.map(\.role) == [.brief])
        }

        @Test func skippedWithoutAgendaOrHistoryForRecordOrWithTheBriefOff() async throws {
            let client = StartBriefClient()
            let bare = try recording(event: LibraryHarness.event("Acme pricing", [("Dana Smith", "dana@acme.com")]))
            #expect(await job(client).run(sessionID: bare.id) == .skipped)
            let agenda = CalendarEventInfo(id: "a", title: "Plan", start: at1530, end: at1530.addingTimeInterval(600),
                                           attendees: [LibraryHarness.me], agenda: "Q4 pricing and scope")
            let record = try recording(mode: .record, event: agenda)
            #expect(await job(client).run(sessionID: record.id) == .skipped)
            let off = try recording(event: agenda)
            #expect(await job(client, settings: StartTests.settings { $0.briefEnabled = false }).run(sessionID: off.id) == .skipped)
            #expect(await job(client, settings: StartTests.settings(calendar: false)).run(sessionID: off.id) == .skipped)
            #expect(client.requests.get.isEmpty)
            #expect(!FileManager.default.fileExists(atPath: h.store.file(off, MeetingFile.brief).path))
        }

        @Test func failuresAreReturnedNotThrownAndWriteNothing() async throws {
            let agenda = CalendarEventInfo(id: "a", title: "Plan", start: at1530, end: at1530.addingTimeInterval(600),
                                           attendees: [LibraryHarness.me], agenda: "Q4 pricing and scope")
            let session = try recording(event: agenda)
            let limited = await job(StartBriefClient(error: .usageLimit("limit"))).run(sessionID: session.id)
            guard case .failed = limited else { Issue.record("expected a failure, got \(limited)"); return }
            let noClaude = await job(StartBriefClient(), makeFails: true).run(sessionID: session.id)
            guard case .failed = noClaude else { Issue.record("expected a failure, got \(noClaude)"); return }
            let missing = await job(StartBriefClient()).run(sessionID: "nope")
            guard case .failed = missing else { Issue.record("expected a failure, got \(missing)"); return }
            #expect(!FileManager.default.fileExists(atPath: h.store.file(session, MeetingFile.brief).path))
        }

        func agendaRecording() throws -> Session {
            try recording(event: CalendarEventInfo(id: "a", title: "Plan", start: at1530, end: at1530.addingTimeInterval(600),
                                                   attendees: [LibraryHarness.me], agenda: "Q4 pricing and scope"))
        }

        /// The notes stage reads brief.json, so a brief that arrives after Stop is dropped: a retried notes stage then
        /// sees the same input as the first run (spec 5.5).
        @Test func aBriefThatArrivesAfterStopIsNeverWritten() async throws {
            let session = try agendaRecording()
            let store = h.store
            let client = StartBriefClient(meanwhile: {
                _ = try? store.update(session.id) { $0.recording = false }
            })
            #expect(await job(client).run(sessionID: session.id) == .skipped)
            #expect(client.requests.get.count == 1)
            #expect(!FileManager.default.fileExists(atPath: h.store.file(session, MeetingFile.brief).path))
        }

        @Test func aCancelledBriefIsNeverWritten() async throws {
            let session = try agendaRecording()
            let client = StartBriefClient(meanwhile: { withUnsafeCurrentTask { $0?.cancel() } })
            let job = job(client)
            let outcome = await Task { await job.run(sessionID: session.id) }.value
            #expect(outcome == .skipped)
            #expect(!FileManager.default.fileExists(atPath: h.store.file(session, MeetingFile.brief).path))
        }

        @Test func aStoppedRecordingGetsNoBrief() async throws {
            let session = try agendaRecording()
            _ = try h.store.update(session.id) { $0.recording = false }
            let client = StartBriefClient()
            #expect(await job(client).run(sessionID: session.id) == .skipped)
            #expect(client.requests.get.isEmpty)
        }
    }
}
