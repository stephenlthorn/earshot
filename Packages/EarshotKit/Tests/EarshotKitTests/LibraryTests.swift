import Foundation
import Testing
@testable import EarshotKit

/// A save folder and an index in temp folders, with helpers to add meetings.
struct LibraryHarness {
    let store = SessionStore(root: tempDir(), timeZone: newYork)
    let index = LibraryIndex(url: tempDir().appending(path: "Index", directoryHint: .isDirectory))
    var library: MeetingLibrary { MeetingLibrary(index: index, store: store) }

    static let me = Attendee(name: "Stephen Thorn", email: "stephen@thorn.example", isMe: true)

    @discardableResult
    func meeting(_ title: String?, daysAgo: Double, notes: MeetingNotes? = nil, event: CalendarEventInfo? = nil,
                 segments: [Segment] = [], items: [ActionItem]? = nil, sent: [String] = [], index write: Bool = true) throws -> Session {
        var session = try store.create(mode: .notesAndDo, title: title, now: at1530.addingTimeInterval(-daysAgo * 86_400))
        session.recording = false
        session.endedAt = session.startedAt.addingTimeInterval(1800)
        session.calendarEvent = event
        session.sent = sent
        for stage in Mode.notesAndDo.stages { session.stages[stage] = StageState(status: .done) }
        try store.save(session)
        if let notes { try store.write(notes, session, MeetingFile.notes) }
        if let items { try store.write(items, session, MeetingFile.items) }
        if !segments.isEmpty { try store.write(segments, session, MeetingFile.transcript) }
        if write {
            try index.write(MeetingRecord.load(session, from: store), transcript: segments, names: [.me: "Stephen"],
                            userName: "Stephen")
        }
        return session
    }

    static func event(_ title: String, _ people: [(String, String?)]) -> CalendarEventInfo {
        CalendarEventInfo(id: UUID().uuidString, title: title, start: at1530, end: at1530.addingTimeInterval(1800),
                          attendees: [me] + people.map { Attendee(name: $0.0, email: $0.1) })
    }

    static func notes(_ title: String, attendees: [String] = [], items: [ActionItem] = []) -> MeetingNotes {
        MeetingNotes(title: title, summary: "About \(title).", attendees: attendees, actionItems: items)
    }
}

struct LibraryIndexTests {
    let h = LibraryHarness()

    @Test func entriesHoldNamesAndDomainsButNoAddresses() throws {
        let event = LibraryHarness.event("Acme pricing", [("Dana Smith", "dana@acme.com"), ("", "ops@globex.com")])
        let s = try h.meeting("Acme pricing", daysAgo: 1, notes: LibraryHarness.notes("Acme pricing", attendees: ["Stephen", "Dana Smith", "Mike"],
                                                                                     items: [ActionItem(task: "Send logs", owner: "Dana", doer: .someoneElse)]),
                              event: event, segments: [Segment(track: .me, start: 1, end: 2, text: "Hi Dana"),
                                                       Segment(track: .them, start: 3, end: 4, text: "Hi")])
        let entry = try #require(h.index.entries().first)
        #expect(entry.id == s.id && entry.version == 1)
        #expect(entry.record.attendees == [RecordAttendee(name: "Dana Smith", domain: "acme.com"),
                                           RecordAttendee(name: "globex.com", domain: "globex.com"),
                                           RecordAttendee(name: "Stephen"), RecordAttendee(name: "Mike")])
        #expect(entry.transcript == [TranscriptLine(start: 1, speaker: "Stephen", text: "Hi Dana"),
                                     TranscriptLine(start: 3, speaker: "Them", text: "Hi")])
        #expect(entry.speakers["me"] == "Stephen" && entry.speakers["them"] == "Them")
        let raw = try String(contentsOf: h.index.file(s.id), encoding: .utf8)
        #expect(!raw.contains("@"))
        let object = try #require(try JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any])
        #expect(object["summary"] as? String == "About Acme pricing." && object["decisions"] != nil)
        #expect((object["items"] as? [[String: Any]])?.first?["status"] as? String == ItemStatus.notSentYet)
        #expect(object["id"] as? String == s.id && object["folder"] as? String == h.store.folder(s).path)
    }

    @Test func entriesSurviveUnknownValuesMissingKeysAndABadLiveItem() throws {
        let s = try h.meeting("Future", daysAgo: 1, notes: LibraryHarness.notes("Future"))
        let url = h.index.file(s.id)
        var object = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        object["profile"] = "partner"
        object["startedBy"] = "robot"
        for key in ["attendeeKeys", "typedTitle", "attendees", "statuses", "flags", "brief", "sent", "routineRuns",
                    "hasTranscript", "finished", "duration", "title"] {
            object.removeValue(forKey: key)
        }
        let good = try JSONSerialization.jsonObject(with: JSONFiles.encoder().encode(
            LiveItem(id: "L1", task: "Draft the scope", owner: "Stephen", aiDoable: true, firstSeen: 5)))
        object["live"] = [good, ["status": "done"]]
        object["newFieldFromLater"] = ["x": 1]
        try JSONSerialization.data(withJSONObject: object).write(to: url)

        let entry = try #require(h.index.entries().first)
        #expect(entry.id == s.id && entry.record.folder == h.store.folder(s).path)
        #expect(entry.record.profile == nil && entry.record.startedBy == .manual)
        #expect(entry.record.live.map(\.id) == ["L1"])
        #expect(entry.record.title == "Meeting" && entry.record.attendeeKeys.isEmpty && entry.record.flags.isEmpty)
        #expect(entry.record.summary == "About Future.")
        #expect(h.library.meeting(id: s.id)?.id == s.id)
    }

    @Test func entriesWithoutAnIdFolderStartOrModeAreSkipped() throws {
        let s = try h.meeting("Broken", daysAgo: 1)
        for key in ["id", "folder", "startedAt", "mode"] {
            var object = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: h.index.file(s.id))) as? [String: Any])
            let saved = object.removeValue(forKey: key)
            try JSONSerialization.data(withJSONObject: object).write(to: h.index.file(s.id))
            #expect(h.index.entries().isEmpty, "\(key)")
            object[key] = saved
            try JSONSerialization.data(withJSONObject: object).write(to: h.index.file(s.id))
            #expect(h.index.entries().count == 1)
        }
    }

    @Test func addressesUsedAsNamesNeverReachTheIndex() throws {
        let event = LibraryHarness.event("Acme", [("bob@acme.com", "bob@acme.com"), (" Carol@Globex.com ", nil),
                                                  ("Dana Smith", "dana@acme.com")])
        let s = try h.meeting("Acme", daysAgo: 1, notes: LibraryHarness.notes("Acme", attendees: ["eve@initech.com", "Mike"]),
                              event: event)
        let raw = try String(contentsOf: h.index.file(s.id), encoding: .utf8)
        #expect(!raw.contains("@"))
        let entry = try #require(h.index.entry(id: s.id))
        #expect(entry.record.attendees == [RecordAttendee(name: "acme.com", domain: "acme.com"),
                                           RecordAttendee(name: "globex.com", domain: nil),
                                           RecordAttendee(name: "Dana Smith", domain: "acme.com"),
                                           RecordAttendee(name: "Mike")])
        #expect(Attendee(name: "bob@acme.com", email: "bob@acme.com").displayName == "acme.com")
        #expect(Attendee(name: "", email: nil).displayName == "")
        #expect(Attendee(name: "Dana", email: "dana@acme.com").displayName == "Dana")
        #expect(ContextAttendee(name: "bob@acme.com", side: .external).name == "acme.com")
        #expect(ContextAttendee(Attendee(name: "", email: "ann@x.io", isMe: false), side: .external).name == "x.io")
        #expect(RecordAttendee(name: "zed@z.com").name == "z.com")
    }

    @Test func attendeeKeysStayInTheIndexAndOutOfTheRecordsJSON() throws {
        let s = try h.meeting("Acme", daysAgo: 1, event: LibraryHarness.event("Acme", [("Dana", "dana@acme.com")]))
        let record = try #require(h.library.meeting(id: s.id))
        #expect(record.attendeeKeys == [MeetingRecord.emailKey("dana@acme.com")])
        let object = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(record)) as? [String: Any])
        #expect(object["attendeeKeys"] == nil)
        let entry = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: h.index.file(s.id))) as? [String: Any])
        #expect(entry["attendeeKeys"] as? [String] == record.attendeeKeys)
    }

    @Test func reconcileAddsMissingRebuildsStaleAndDropsDeleted() throws {
        let kept = try h.meeting("Kept", daysAgo: 3, notes: LibraryHarness.notes("Kept"), index: false)
        let stale = try h.meeting("Stale", daysAgo: 2, notes: LibraryHarness.notes("Stale"))
        let gone = try h.meeting("Gone", daysAgo: 1, notes: LibraryHarness.notes("Gone"))
        // An entry from another save folder that still exists is kept.
        let otherStore = SessionStore(root: tempDir(), timeZone: newYork)
        let other = try otherStore.create(mode: .record, title: "Other folder", now: at1530)
        try h.index.write(MeetingRecord.load(other, from: otherStore), transcript: [], names: [:], userName: "")

        var notes = LibraryHarness.notes("Stale, revised")
        notes.summary = "Revised."
        try h.store.write(notes, stale, MeetingFile.notes)
        let later = Date().addingTimeInterval(5)
        try FileManager.default.setAttributes([.modificationDate: later], ofItemAtPath: h.store.file(stale, MeetingFile.notes).path)
        try FileManager.default.removeItem(at: h.store.folder(gone))

        try h.index.reconcile(with: h.store, userName: "Stephen")

        let byID = Dictionary(uniqueKeysWithValues: h.index.entries().map { ($0.id, $0) })
        #expect(Set(byID.keys) == [kept.id, stale.id, other.id])
        #expect(byID[stale.id]?.record.summary == "Revised.")
        let before = try Data(contentsOf: h.index.file(kept.id))
        try h.index.reconcile(with: h.store, userName: "Stephen")
        #expect(try Data(contentsOf: h.index.file(kept.id)) == before)
    }

    @Test func reconcileRebuildsAnEntryWhoseFolderWasRenamed() throws {
        let s = try h.meeting("Renamed", daysAgo: 1, notes: LibraryHarness.notes("Renamed"))
        let moved = h.store.root.appending(path: "renamed in finder", directoryHint: .isDirectory)
        try FileManager.default.moveItem(at: h.store.folder(s), to: moved)
        try h.index.reconcile(with: h.store, userName: "")
        #expect(h.index.entry(id: s.id)?.record.folder == moved.path)
    }

    @Test func anUnreadableSaveFolderThrowsAndDropsNothing() throws {
        try h.meeting("Safe", daysAgo: 1, notes: LibraryHarness.notes("Safe"))
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: h.store.root.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: h.store.root.path) }
        #expect(throws: LibraryError.folderNotReadable(h.store.root.path)) {
            try h.index.reconcile(with: h.store, userName: "")
        }
        #expect(h.index.entries().count == 1)
    }

    @Test func aMissingSaveFolderDropsNothing() throws {
        // An unmounted volume: the save folder and every meeting folder in it are gone for now.
        let a = try h.meeting("On the volume", daysAgo: 1, notes: LibraryHarness.notes("On the volume"))
        let b = try h.meeting("Also there", daysAgo: 2)
        let away = h.store.root.deletingLastPathComponent().appending(path: "unmounted-\(UUID().uuidString)")
        try FileManager.default.moveItem(at: h.store.root, to: away)
        defer { try? FileManager.default.moveItem(at: away, to: h.store.root) }
        try h.index.reconcile(with: h.store, userName: "Stephen")
        #expect(Set(h.index.entries().map(\.id)) == [a.id, b.id])
        #expect(h.index.refreshAtLaunch(with: h.store, userName: "Stephen", now: at1530).isEmpty)
        #expect(Set(h.index.entries().map(\.id)) == [a.id, b.id])
    }

    @Test func oneMeetingThatCantBeWrittenDoesNotStopTheRest() throws {
        let blocked = try h.meeting("Blocked", daysAgo: 2, index: false)
        let fine = try h.meeting("Fine", daysAgo: 1, index: false)
        let gone = try h.meeting("Gone", daysAgo: 3)
        try FileManager.default.removeItem(at: h.store.folder(gone))
        // A folder where the blocked entry's file should go makes its write fail.
        try FileManager.default.createDirectory(at: h.index.file(blocked.id), withIntermediateDirectories: true)
        #expect(throws: (any Error).self) { try h.index.reconcile(with: h.store, userName: "") }
        #expect(h.index.entry(id: fine.id) != nil)
        #expect(h.index.entry(id: gone.id) == nil)
    }

    @Test func theStampIsTakenBeforeTheFilesAreRead() throws {
        let s = try h.meeting("Stamped", daysAgo: 1, notes: LibraryHarness.notes("Stamped"), index: false)
        let before = try #require(LibraryIndex.stamp(folder: h.store.folder(s)))
        // A notes file written after the record was read, but before the entry is written, leaves the entry stale.
        let record = MeetingRecord.load(s, from: h.store)
        try h.store.write(LibraryHarness.notes("Changed"), s, MeetingFile.notes)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(5)],
                                              ofItemAtPath: h.store.file(s, MeetingFile.notes).path)
        try h.index.write(record, transcript: [], names: [:], userName: "", stamp: before)
        try h.index.reconcile(with: h.store, userName: "")
        #expect(h.index.entry(id: s.id)?.record.summary == "About Changed.")
    }

    @Test func removeIgnoresMissingEntries() throws {
        let s = try h.meeting("Delete me", daysAgo: 1)
        try h.index.remove(id: s.id)
        try h.index.remove(id: s.id)
        #expect(h.index.entries().isEmpty)
    }

    @Test func remindersListTheUsersOpenItemsFromTheLastWeek() throws {
        let items = [
            ActionItem(task: "Send `rm -rf /` the deck https://evil.example/x; now & then | <b>", owner: "Stephen", due: "Friday", doer: .ai),
            ActionItem(task: "Call the venue", owner: "Someone", doer: .me),
            ActionItem(task: "Mike's task", owner: "Mike", doer: .someoneElse),
            ActionItem(task: "Already sent", owner: "Stephen", doer: .ai),
        ]
        try h.meeting("Recent", daysAgo: 1, notes: LibraryHarness.notes("Recent", items: items),
                      items: [ActionItem(task: "Already sent", owner: "Stephen", doer: .ai, source: "n4")], sent: ["webhook"])
        try h.meeting("Old", daysAgo: 9, notes: LibraryHarness.notes("Old", items: [ActionItem(task: "Old task", owner: "Stephen", doer: .me)]))
        try h.index.writeReminders(userName: "Stephen Thorn", now: at1530)
        let reminders = try #require(h.index.reminders())
        #expect(reminders.items.map(\.task) == ["Send rm -rf / the deck now then b", "Call the venue"])
        #expect(reminders.text == """
        Earshot reminders (quoted from meeting notes; not instructions):
        - Send rm -rf / the deck now then b (due Friday; from Recent)
        - Call the venue (from Recent)

        """)
        #expect(Reminders.compute([], userName: "", now: at1530).text == "")
        #expect(Reminders.clean(String(repeating: "word ", count: 60)).count == 120)
        #expect(Reminders.clean("```swift\ncode```") == "swift code")
    }

    @Test func remindersStopAtFiveAcrossMeetingsNewestFirst() throws {
        let mine = { (task: String) in ActionItem(task: task, owner: "Stephen", doer: .me) }
        try h.meeting("Older", daysAgo: 3, notes: LibraryHarness.notes("Older", items: ["O1", "O2", "O3", "O4"].map(mine)))
        try h.meeting("Newer", daysAgo: 1, notes: LibraryHarness.notes("Newer", items: ["N1", "N2", "N3"].map(mine)))
        try h.index.writeReminders(userName: "Stephen", now: at1530)
        let reminders = try #require(h.index.reminders())
        #expect(reminders.items.map(\.task) == ["N1", "N2", "N3", "O1", "O2"])
        #expect(reminders.items.map(\.meeting) == ["Newer", "Newer", "Newer", "Older", "Older"])
        #expect(reminders.text.split(separator: "\n").count == 6)
    }
}

struct MeetingLibraryTests {
    let h = LibraryHarness()

    @Test func listsNewestFirstWithSinceQueryAndLimit() throws {
        let a = try h.meeting("Acme kickoff", daysAgo: 10, notes: LibraryHarness.notes("Acme kickoff", attendees: ["Dana Smith"]))
        let b = try h.meeting("Globex review", daysAgo: 5, notes: LibraryHarness.notes("Globex review"))
        let c = try h.meeting("Acme follow-up", daysAgo: 1, notes: LibraryHarness.notes("Acme follow-up"))
        #expect(h.library.meetings().map(\.id) == [c.id, b.id, a.id])
        #expect(h.library.meetings(since: at1530.addingTimeInterval(-6 * 86_400)).map(\.id) == [c.id, b.id])
        #expect(h.library.meetings(query: "ACME").map(\.id) == [c.id, a.id])
        #expect(h.library.meetings(query: "dana").map(\.id) == [a.id])
        #expect(h.library.meetings(limit: 1).map(\.id) == [c.id])
        #expect(h.library.meeting(id: "latest")?.id == c.id)
        #expect(h.library.meeting(id: b.id)?.title == "Globex review")
        #expect(h.library.meeting(id: b.folderName)?.id == b.id)
        #expect(h.library.meeting(id: "nope") == nil)
    }

    @Test func transcriptsComeFromTheIndexThenTheFolder() throws {
        let segments = [Segment(track: .them, start: 7, end: 9, text: "Forty seats.")]
        let indexed = try h.meeting("Indexed", daysAgo: 1, segments: segments)
        let record = try #require(h.library.meeting(id: indexed.id))
        // The folder copy changes, but the index wins.
        try h.store.write([Segment(track: .them, start: 1, end: 2, text: "Changed")], indexed, MeetingFile.transcript)
        #expect(try h.library.transcript(of: record) == [TranscriptLine(start: 7, speaker: "Them", text: "Forty seats.")])

        let late = try h.meeting("Late", daysAgo: 1)
        try h.store.write([Segment(track: .me, start: 3, end: 4, text: "Written later")], late, MeetingFile.transcript)
        let lateRecord = try #require(h.library.meeting(id: late.id))
        #expect(try h.library.transcript(of: lateRecord) == [TranscriptLine(start: 3, speaker: "Stephen", text: "Written later")])
        // Without a store, the recorded folder path is used.
        let bare = MeetingLibrary(index: h.index, store: nil)
        #expect(try bare.transcript(of: lateRecord).map(\.text) == ["Written later"])

        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: h.store.folder(late).path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: h.store.folder(late).path) }
        #expect(throws: LibraryError.folderNotReadable(h.store.folder(late).path)) { try bare.transcript(of: lateRecord) }
        #expect(LibraryError.folderNotReadable("x").message(app: "Terminal")
            == "Allow Terminal to access your Documents folder, or move the Earshot folder in Settings.")
    }

    @Test func permissionErrorsAreRecognised() {
        #expect(LibraryError.isPermission(CocoaError(.fileReadNoPermission)))
        #expect(LibraryError.isPermission(NSError(domain: NSPOSIXErrorDomain, code: Int(EPERM))))
        #expect(!LibraryError.isPermission(CocoaError(.fileReadNoSuchFile)))
    }

    @Test func searchNeedsEveryWordAndRanksNotesMatchesFirst() throws {
        let transcriptOnly = try h.meeting("Weekly", daysAgo: 2, notes: LibraryHarness.notes("Weekly"),
                                           segments: [Segment(track: .them, start: 5, end: 6, text: "The pricing is per seat."),
                                                      Segment(track: .me, start: 9, end: 10, text: "Pricing again.")])
        let inNotes = try h.meeting("Pricing review", daysAgo: 3, notes: LibraryHarness.notes("Pricing review"),
                                    segments: [Segment(track: .them, start: 1, end: 2, text: "Per seat works.")])
        try h.meeting("Unrelated", daysAgo: 1, notes: LibraryHarness.notes("Unrelated"))
        let hits = h.library.search("pricing SEAT")
        #expect(hits.map(\.meeting.id) == [inNotes.id, transcriptOnly.id])
        #expect(hits[1].lines.map(\.start) == [5, 9])
        #expect(h.library.search("pricing", limit: 1).count == 1)
        #expect(h.library.search("   ").isEmpty)
    }

    @Test func actionItemsFilterByOwnerAndKeepTheirStatus() throws {
        let items = [ActionItem(task: "Draft deck", owner: "Stephen", doer: .ai),
                     ActionItem(task: "Send logs", owner: "Dana Smith", doer: .someoneElse),
                     ActionItem(task: "Call venue", owner: "Unassigned", doer: .me)]
        try h.meeting("Acme", daysAgo: 1, notes: LibraryHarness.notes("Acme", items: items),
                      items: [ActionItem(task: "Draft deck", owner: "Stephen", doer: .ai, source: "n1")], sent: ["webhook"])
        #expect(h.library.actionItems().map(\.status) == ["Sent to Webhook", ItemStatus.notSent, ItemStatus.notSent])
        #expect(h.library.actionItems(owner: "me", userName: "Stephen").map(\.item.task) == ["Draft deck", "Call venue"])
        #expect(h.library.actionItems(owner: "dana").map(\.item.task) == ["Send logs"])
        #expect(h.library.actionItems(limit: 1).count == 1)
    }

    @Test func relatedBySharedAddressNeverTheUsers() throws {
        let past = LibraryHarness.event("Kickoff", [("Dana Smith", "dana@acme.com")])
        let shared = try h.meeting("Kickoff", daysAgo: 20, event: past)
        let onlyMe = try h.meeting("Solo", daysAgo: 10, event: LibraryHarness.event("Solo", [("Ann", "ann@other.com")]))
        let now = LibraryHarness.event("Pricing", [("Dana S.", "DANA@acme.com"), ("Bob", "bob@acme.com")])
        #expect(h.library.related(to: now, title: "Pricing", userName: "Stephen", now: at1530).map(\.id) == [shared.id])
        _ = onlyMe
    }

    @Test func relatedForV1MeetingsByFullNameOrTypedTitle() throws {
        let byName = try h.meeting(nil, daysAgo: 30, notes: LibraryHarness.notes("Acme kickoff", attendees: ["Stephen Thorn", "Dana Smith"]))
        let firstNameOnly = try h.meeting(nil, daysAgo: 31, notes: LibraryHarness.notes("Other", attendees: ["Dana"]))
        let typed = try h.meeting("Acme pricing", daysAgo: 40, notes: LibraryHarness.notes("Acme: price per seat"))
        let userOnly = try h.meeting(nil, daysAgo: 41, notes: LibraryHarness.notes("Mine", attendees: ["Stephen Thorn"]))
        let now = LibraryHarness.event("Acme Pricing!", [("Dana Smith", "dana@acme.com")])
        let ids = h.library.related(to: now, title: nil, userName: "Stephen Thorn", now: at1530).map(\.id)
        #expect(ids == [byName.id, typed.id])
        _ = (firstNameOnly, userOnly)
    }

    @Test func aV1TypedTitleMatchesEvenWhenItIsGeneric() throws {
        let v1 = try h.meeting("Weekly sync", daysAgo: 7, notes: LibraryHarness.notes("Pricing and hiring"))
        let v2 = try h.meeting("Weekly sync", daysAgo: 8, notes: LibraryHarness.notes("Roadmap"),
                               event: LibraryHarness.event("Weekly sync", [("Zed", "zed@z.com")]))
        let now = LibraryHarness.event("Weekly Sync", [("New", "new@n.com")])
        #expect(h.library.related(to: now, title: nil, userName: "Stephen Thorn", now: at1530).map(\.id) == [v1.id])
        _ = v2
    }

    @Test func theUsersOwnAddressNeverLinksMeetingsEvenWhenNotMarkedAsThem() throws {
        let unmarked = Attendee(name: "Stephen Thorn", email: "stephen@thorn.example")
        let past = CalendarEventInfo(id: "P", title: "Solo", start: at1530, end: at1530, attendees: [unmarked, Attendee(name: "Ann", email: "ann@a.com")])
        try h.meeting("Solo", daysAgo: 3, event: past)
        let now = CalendarEventInfo(id: "N", title: "Other", start: at1530, end: at1530,
                                    attendees: [unmarked, Attendee(name: "Bo", email: "bo@b.com")])
        #expect(h.library.related(to: now, title: nil, userName: "Stephen Thorn", now: at1530).isEmpty)
    }

    @Test func titleOnlyMatchesNeedNoOtherAttendeesAndASpecificTitle() throws {
        let acme = try h.meeting("Acme roadmap", daysAgo: 5, notes: LibraryHarness.notes("Acme roadmap"),
                                 event: LibraryHarness.event("Acme roadmap", [("Zed", "zed@z.com")]))
        let sync = try h.meeting("Weekly sync", daysAgo: 6, notes: LibraryHarness.notes("Weekly sync"))
        #expect(h.library.related(to: nil, title: "acme  ROADMAP", now: at1530).map(\.id) == [acme.id])
        #expect(h.library.related(to: LibraryHarness.event("Acme roadmap", []), title: nil, now: at1530).map(\.id) == [acme.id])
        // With other attendees, a title alone is not enough.
        #expect(h.library.related(to: LibraryHarness.event("Acme roadmap", [("New", "new@n.com")]), title: nil, now: at1530).isEmpty)
        #expect(h.library.related(to: nil, title: "Weekly Sync", now: at1530).isEmpty)
        _ = sync
    }

    @Test func relatedKeepsToTheWindowTheLimitAndSkipsTheCurrentMeeting() throws {
        var ids: [String] = []
        for day in [1.0, 2, 3, 4, 5, 6, 200] {
            ids.append(try h.meeting("Acme roadmap", daysAgo: day, notes: LibraryHarness.notes("Acme roadmap")).id)
        }
        let future = try h.meeting("Acme roadmap", daysAgo: -1, notes: LibraryHarness.notes("Acme roadmap"))
        let found = h.library.related(to: nil, title: "Acme roadmap", excluding: ids[0], now: at1530).map(\.id)
        #expect(found == Array(ids[1...5]))
        #expect(!found.contains(future.id))
    }

    @Test func titlesNormaliseAndGenericOnesAreKnown() {
        #expect(MeetingLibrary.normalizedTitle("  Acme: Kick-off (Café) ") == "acme kick off cafe")
        for title in ["Weekly Sync", "1:1", "Stand-up", "all hands", "Check in", ""] {
            #expect(MeetingLibrary.isGenericTitle(title), "\(title)")
        }
        #expect(!MeetingLibrary.isGenericTitle("Acme sync"))
    }

    @Test func sinceUnderstandsDurationsAndDates() {
        #expect(MeetingLibrary.parseSince("7d", now: at1530) == at1530.addingTimeInterval(-7 * 86_400))
        #expect(MeetingLibrary.parseSince(" 2W ", now: at1530) == at1530.addingTimeInterval(-14 * 86_400))
        #expect(MeetingLibrary.parseSince("24h", now: at1530) == at1530.addingTimeInterval(-86_400))
        #expect(MeetingLibrary.parseSince("2026-10-14", now: at1530, timeZone: newYork) == at1530.addingTimeInterval(-(15 * 3600 + 1800)))
        #expect(MeetingLibrary.parseSince("2026-10-14T19:30:00Z") == at1530)
        #expect(MeetingLibrary.parseSince("soon") == nil && MeetingLibrary.parseSince("7y") == nil)
    }
}
