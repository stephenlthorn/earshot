import Foundation
import Testing
@testable import EarshotKit

/// Meeting folders and a settings blob written by Earshot v0.1.0's own code (store, pipeline and fakes, at `main`),
/// so these tests prove v2 reads what v1 left on disk.
enum V1Fixtures {
    static let source = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appending(path: "Fixtures/v1", directoryHint: .isDirectory)

    /// A private copy of the meetings, so a test can't change the fixtures.
    static func store() throws -> SessionStore {
        let root = tempDir().appending(path: "meetings", directoryHint: .isDirectory)
        try FileManager.default.copyItem(at: source.appending(path: "meetings"), to: root)
        return SessionStore(root: root, timeZone: newYork)
    }

    static func session(_ store: SessionStore, _ title: String) throws -> Session {
        try #require(store.all().first { $0.folderName.hasSuffix(title) })
    }
}

struct FixtureTests {
    @Test func everyV1MeetingLoads() throws {
        let store = try V1Fixtures.store()
        let titles = store.all().map { String($0.folderName.dropFirst(16)) }
        #expect(titles == ["Initech onboarding", "Weekly sync", "Brain dump onboarding ideas", "Voice memo",
                           "Globex pricing review", "Acme kickoff"])
        for session in store.all() {
            #expect(session.flags.isEmpty && session.calendarEvent == nil && session.profile == nil)
            #expect(session.notesRevision == 0 && session.routineRuns.isEmpty)
        }
    }

    @Test func finishedMeetingsHaveNoNextStageAndTheRestResume() throws {
        let store = try V1Fixtures.store()
        for title in ["Acme kickoff", "Globex pricing review", "Voice memo", "Brain dump onboarding ideas"] {
            #expect(try V1Fixtures.session(store, title).nextStage == nil, "\(title)")
        }
        let interrupted = try V1Fixtures.session(store, "Weekly sync")
        #expect(interrupted.nextStage == .transcribe && !interrupted.recording)
        let failed = try V1Fixtures.session(store, "Initech onboarding")
        #expect(failed.nextStage == .dispatch && failed.stages[.dispatch]?.failures == 1)
        #expect(store.resumable().map(\.folderName).map { String($0.dropFirst(16)) } == ["Weekly sync", "Initech onboarding"])
        #expect(try store.recover().count == 6)
    }

    @Test func startedByComesFromTheTracks() throws {
        let store = try V1Fixtures.store()
        #expect(try V1Fixtures.session(store, "Brain dump onboarding ideas").startedBy == .importFile)
        #expect(try V1Fixtures.session(store, "Acme kickoff").startedBy == .manual)
    }

    @Test func notesDecodeAndRenderExactlyAsV1Did() throws {
        let store = try V1Fixtures.store()
        for title in ["Acme kickoff", "Globex pricing review", "Brain dump onboarding ideas", "Initech onboarding"] {
            let session = try V1Fixtures.session(store, title)
            let notes = try store.read(MeetingNotes.self, session, MeetingFile.notes)
            #expect(notes.flaggedMoments.isEmpty && notes.stillOpen.isEmpty)
            #expect(notes.actionItems.allSatisfy { $0.liveRef == nil && $0.source == nil })
            let markdown = NotesRenderer.markdown(notes, startedAt: session.startedAt, duration: session.duration,
                                                  timeZone: newYork)
            #expect(markdown == (try String(contentsOf: store.file(session, MeetingFile.notesMarkdown), encoding: .utf8)), "\(title)")
            #expect(try JSONDecoder().decode(MeetingNotes.self, from: JSONEncoder().encode(notes)) == notes)
        }
    }

    @Test func itemStatusesForV1Meetings() throws {
        let store = try V1Fixtures.store()
        func statuses(_ title: String) throws -> [String] {
            let session = try V1Fixtures.session(store, title)
            return MeetingRecord.load(session, from: store).statuses
        }
        #expect(try statuses("Globex pricing review") == ["Sent to Webhook", ItemStatus.notSent, ItemStatus.notSent])
        #expect(try statuses("Initech onboarding") == [ItemStatus.notSent, ItemStatus.notSent])
        #expect(try statuses("Acme kickoff") == [ItemStatus.notSentYet, ItemStatus.notSentYet])
        #expect(try statuses("Voice memo").isEmpty)
    }

    @Test func v1MeetingsAreIndexedListedAndSearched() throws {
        let store = try V1Fixtures.store()
        let index = LibraryIndex(url: tempDir())
        try index.reconcile(with: store, userName: "Stephen")
        let library = MeetingLibrary(index: index, store: store)
        #expect(library.meetings().count == 6)
        #expect(library.meetings(query: "acme").map(\.title) == ["Acme kickoff"])
        let hit = try #require(library.search("pilot Monday").first)
        #expect(hit.meeting.title == "Acme kickoff")
        #expect(hit.lines.map(\.start) == [2, 8.25, 20.25] && hit.lines.last?.speaker == "Them")
        #expect(library.actionItems(owner: "Mike").map(\.item.task) == ["Send the usage export"])
        #expect(library.meeting(id: "latest")?.title == "Initech onboarding")
        let acme = try #require(library.meetings(query: "acme").first)
        #expect(try library.transcript(of: acme).first == TranscriptLine(start: 2, speaker: "Stephen",
                                                                          text: "Dana, thanks for making time. I'll send the pilot scope by Friday."))
        let raw = try FileManager.default.contentsOfDirectory(at: index.url, includingPropertiesForKeys: nil)
        #expect(raw.count == 6)
    }

    @Test func v1MeetingsAreRelatedByNameAndTypedTitle() throws {
        let store = try V1Fixtures.store()
        let index = LibraryIndex(url: tempDir())
        try index.reconcile(with: store, userName: "Stephen")
        let library = MeetingLibrary(index: index, store: store)
        let now = try #require(MeetingLibrary.parseSince("2026-10-15", timeZone: newYork))
        let dana = CalendarEventInfo(id: "E", title: "Pilot review", start: now, end: now,
                                     attendees: [Attendee(name: "Stephen", email: "s@me.com", isMe: true),
                                                 Attendee(name: "Dana Smith", email: "dana@acme.com")])
        #expect(library.related(to: dana, title: nil, userName: "Stephen", now: now).map(\.title) == ["Acme kickoff"])
        let typed = library.related(to: nil, title: "Initech Onboarding", userName: "Stephen", now: now)
        #expect(typed.map(\.title) == ["Initech onboarding"])
        // A v1 typed title links even when it is generic (spec 5.4 keeps the stoplist for title-only matches), so a
        // recurring "Weekly sync" finds its earlier copies, with or without other attendees.
        let sync = CalendarEventInfo(id: "W", title: "Weekly sync", start: now, end: now,
                                     attendees: [Attendee(name: "Stephen", email: "s@me.com", isMe: true),
                                                 Attendee(name: "Pat Lee", email: "pat@me.com")])
        #expect(library.related(to: sync, title: nil, userName: "Stephen", now: now).map(\.title) == ["Weekly sync"])
        #expect(library.related(to: nil, title: "Weekly sync", now: now).map(\.title) == ["Weekly sync"])
    }

    @Test func theV1SettingsBlobLoads() throws {
        let blob = try Data(contentsOf: V1Fixtures.source.appending(path: "settings.json"))
        // A temp-folder suite, as in SettingsTests: a named suite would leave a plist in ~/Library/Preferences.
        let settings = try withFreshDefaults { defaults in
            defaults.set(blob, forKey: EarshotSettings.defaultsKey)
            return EarshotSettings.load(from: defaults)
        }
        #expect(settings.userName == "Stephen" && settings.style == .salesCall)
        #expect(settings.webhookOn && settings.webhookURL == "https://example.com/earshot")
        #expect(settings.saveFolder == "/Users/tester/Documents/Earshot" && settings.localeIdentifier == "en_US")
    }
}
