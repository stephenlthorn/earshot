import Foundation
import Testing
@testable import EarshotKit

func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
    try JSONFiles.decoder().decode(type, from: Data(json.utf8))
}

func jsonObject(_ value: some Encodable) throws -> [String: Any] {
    try #require(try JSONSerialization.jsonObject(with: JSONFiles.encoder().encode(value)) as? [String: Any])
}

/// A session.json as v1 wrote it.
let v1SessionJSON = """
{"id":"2026-10-14-1530-a3f9","folderName":"2026-10-14 1530 Acme","title":"Acme","mode":"notes",
 "startedAt":"2026-10-14T19:30:00Z","endedAt":"2026-10-14T20:10:00Z","recording":false,
 "tracks":[{"track":"me","file":"mic.m4a","offset":0},{"track":"them","file":"system.m4a","offset":0.25}],
 "stages":{"transcribe":{"status":"done","failures":0},"notes":{"status":"done","failures":0},
           "compress":{"status":"done","failures":0}},
 "sent":[],"inFlight":[],"warnings":[]}
"""

struct ModelTests {
    @Test func aV1SessionLoadsWithEmptyV2Fields() throws {
        let session = try decode(Session.self, v1SessionJSON)
        #expect(session.calendarEvent == nil && session.profile == nil && session.flags.isEmpty)
        #expect(session.startedBy == .manual && session.notesRevision == 0 && session.routineRuns.isEmpty)
        #expect(session.nextStage == nil)
    }

    @Test func aV1ImportFallsBackToStartedByImport() throws {
        let json = v1SessionJSON.replacingOccurrences(
            of: #"[{"track":"me","file":"mic.m4a","offset":0},{"track":"them","file":"system.m4a","offset":0.25}]"#,
            with: #"[{"track":"speaker","file":"import.m4a","offset":0}]"#)
        #expect(try decode(Session.self, json).startedBy == .importFile)
    }

    @Test func unknownValuesInNewFieldsNeverFailTheLoad() throws {
        let json = v1SessionJSON.replacingOccurrences(of: #""warnings":[]"#, with: """
            "warnings":[],"profile":"partner","startedBy":"robot","notesRevision":"two",
            "flags":[{"offset":12.5,"source":"telepathy"},{"source":"panel"},{"offset":30,"source":"voice"}],
            "calendarEvent":{"id":"E1","attendees":[{"name":"Dana","email":"dana@acme.com"},{"bogus":true}]},
            "routineRuns":{"m-live-1":"https://claude.ai/code/session_1"}
            """)
        let session = try decode(Session.self, json)
        #expect(session.profile == nil)
        #expect(session.startedBy == .manual)
        #expect(session.notesRevision == 0)
        #expect(session.flags == [Flag(offset: 12.5, source: .panel), Flag(offset: 30, source: .voice)])
        #expect(session.calendarEvent?.id == "E1")
        #expect(session.calendarEvent?.attendees.map(\.name) == ["Dana", ""])
        #expect(session.routineRuns["m-live-1"] == "https://claude.ai/code/session_1")
    }

    @Test func v2FieldsRoundTrip() throws {
        var session = try decode(Session.self, v1SessionJSON)
        session.calendarEvent = CalendarEventInfo(
            id: "E1", title: "Acme sync", start: at1530, end: at1530.addingTimeInterval(1800),
            attendees: [Attendee(name: "Stephen", email: "s@me.com", isMe: true), Attendee(name: "Dana", email: "dana@acme.com")],
            agenda: "Pricing", location: "Zoom", url: "https://zoom.us/j/1")
        session.profile = .external
        session.flags = [Flag(offset: 61, source: .hotkey)]
        session.startedBy = .auto
        session.notesRevision = 2
        session.routineRuns = ["x-r1": "https://claude.ai/code/1"]
        let data = try JSONFiles.encoder().encode(session)
        #expect(try JSONFiles.decoder().decode(Session.self, from: data) == session)
        let object = try jsonObject(session)
        #expect(object["profile"] as? String == "external" && object["startedBy"] as? String == "auto")
    }

    @Test func profileAndTriggerRawValues() {
        #expect(MeetingProfile.noEvent.rawValue == "none" && MeetingProfile.internal.rawValue == "internal")
        #expect(StartTrigger.importFile.rawValue == "import" && StartTrigger.cli.rawValue == "cli")
    }

    @Test func calendarEventsAreClippedAndAttendeesGiveDomains() {
        let many = (0..<80).map { Attendee(name: "P\($0)", email: "p\($0)@acme.com") }
        let event = CalendarEventInfo(id: "E", title: "T", start: at1530, end: at1530, attendees: many,
                                      agenda: String(repeating: "a", count: 3000))
        #expect(event.attendees.count == 50 && event.agenda.count == 1500)
        #expect(Attendee(name: "Dana", email: " Dana@ACME.com ").domain == "acme.com")
        #expect(Attendee(name: "Dana", email: "not-an-address").domain == nil)
        #expect(Attendee(name: "Dana").domain == nil)
    }

    @Test func actionItemsAlwaysWriteLiveRefAndOnlyWriteASetSource() throws {
        let plain = try jsonObject(ActionItem(task: "Call", owner: "Me", doer: .me))
        #expect(plain["live_ref"] is NSNull && plain["source"] == nil)
        let linked = try jsonObject(ActionItem(task: "Call", owner: "Me", doer: .me, liveRef: "L2", source: "n1"))
        #expect(linked["live_ref"] as? String == "L2" && linked["source"] as? String == "n1")
        let v1 = try decode(ActionItem.self, #"{"task":"Call","owner":"Me","due":null,"doer":"me","context":""}"#)
        #expect(v1.liveRef == nil && v1.source == nil)
    }

    @Test func v1NotesLoadAndNewListsRoundTrip() throws {
        let v1 = #"{"title":"T","summary":"S","attendees":[],"key_points":[],"decisions":[],"action_items":[],"open_questions":[]}"#
        let notes = try decode(MeetingNotes.self, v1)
        #expect(notes.flaggedMoments.isEmpty && notes.stillOpen.isEmpty)
        var full = sampleNotes
        full.flaggedMoments = [FlaggedMoment(seconds: 75, note: "Pricing number")]
        full.stillOpen = ["Dana: send the logs"]
        let object = try jsonObject(full)
        #expect(object["flagged_moments"] != nil && object["still_open"] != nil)
        #expect(try JSONDecoder().decode(MeetingNotes.self, from: JSONEncoder().encode(full)) == full)
    }

    @Test func liveFilesKeepGoodItemsAndTreatUnknownStatusesAsInterrupted() throws {
        let json = """
        {"version":1,"segments":[{"track":"me","start":1,"end":2,"text":"hi"}],"items":[
         {"id":"L1","task":"Draft scope","owner":"Me","aiDoable":true,"why":"asked","firstSeen":10,"updated":20,
          "status":"teleported","target":"webhook"},
         {"id":"L2","task":"Call","owner":"Me","aiDoable":false,"why":"","firstSeen":5,"updated":5,"status":"startedInCloud"},
         {"task":"no id"}]}
        """
        let file = try decode(LiveFile.self, json)
        #expect(file.items.map(\.id) == ["L1", "L2"])
        #expect(file.items[0].status == .interrupted && file.items[1].status == .startedInCloud)
        #expect(file.segments.count == 1)
        #expect(try JSONFiles.decoder().decode(LiveFile.self, from: JSONFiles.encoder().encode(file)) == file)
        #expect(LiveItem.Status.allCases.filter(\.isStarted) == [.sending, .running, .done, .sent, .startedInCloud, .interrupted])
    }

    @Test func lessonsDropUnknownKindsAndDefaultUnknownStyles() throws {
        let json = """
        {"version":1,"lessons":[
         {"id":"a","date":"2026-10-14T19:30:00Z","style":"sales_call","kind":"edited","before":{"task":"A","owner":"Me"},
          "after":{"task":"B","owner":"Me","due":"Friday"},"meetingTitle":"Acme"},
         {"id":"b","date":"2026-10-14T19:30:00Z","style":"poetry","kind":"not_sent","meetingTitle":"Acme"},
         {"id":"c","date":"2026-10-14T19:30:00Z","style":"general","kind":"mystery","meetingTitle":"Acme"}]}
        """
        let file = try decode(LessonsFile.self, json)
        #expect(file.lessons.map(\.id) == ["a", "b"])
        #expect(file.lessons[0].after?.due == "Friday" && file.lessons[1].style == .general)
        #expect(Lesson.Kind.notSent.rawValue == "not_sent" && Lesson.Kind.sentAnyway.rawValue == "sent_anyway")
        #expect(try JSONFiles.decoder().decode(LessonsFile.self, from: JSONFiles.encoder().encode(file)) == file)
    }

    @Test func briefScreenAndQAFilesRoundTripWithVersion() throws {
        let brief = MeetingBrief(eventID: "E1", model: "claude-sonnet-5-5", createdAt: at1530, headline: "Pricing follow-up",
                                 points: ["Seats went up"], openLoops: [OpenLoop(owner: "Dana", task: "Send logs", from: "Acme kickoff")],
                                 sources: ["2026-10-05-1000-aaaa"])
        let screen = ScreenFile(moments: [ScreenMoment(offset: 30, text: "Q3 revenue 1.2M")])
        let qa = QAFile(entries: [QAEntry(question: "Price?", answer: "[01:15] 40 dollars", askedAt: at1530, model: "m")])
        #expect(try JSONFiles.decoder().decode(MeetingBrief.self, from: JSONFiles.encoder().encode(brief)) == brief)
        #expect(try JSONFiles.decoder().decode(ScreenFile.self, from: JSONFiles.encoder().encode(screen)) == screen)
        #expect(try JSONFiles.decoder().decode(QAFile.self, from: JSONFiles.encoder().encode(qa)) == qa)
        #expect(try jsonObject(brief)["version"] as? Int == 1)
        #expect(try decode(ScreenFile.self, #"{"moments":[{"offset":1,"text":"x"},{"text":"no offset"}]}"#).moments.count == 1)
    }

    @Test func meetingFileNames() {
        #expect(MeetingFile.notesRevision(2) == "notes-r2.json")
        #expect(MeetingFile.doLog("webhook") == "do-webhook.log")
        #expect(MeetingFile.session == SessionStore.fileName)
        #expect([MeetingFile.live, MeetingFile.brief, MeetingFile.qa, MeetingFile.lock, MeetingFile.busy]
            == ["live.json", "brief.json", "qa.json", ".lock", ".busy"])
    }
}

struct ItemStatusTests {
    let notes = MeetingNotes(title: "T", summary: "S", actionItems: [
        ActionItem(task: "Draft the pilot scope email", owner: "Stephen", doer: .ai, liveRef: "L1"),
        ActionItem(task: "Book the venue for the review", owner: "Stephen", doer: .me),
        ActionItem(task: "Send the usage export", owner: "Mike", doer: .someoneElse),
    ])

    func live(_ id: String, _ task: String, _ status: LiveItem.Status) -> LiveItem {
        LiveItem(id: id, task: task, owner: "Stephen", aiDoable: true, firstSeen: 0, status: status)
    }

    @Test func liveRefToAStartedItemWins() {
        let statuses = ItemStatus.compute(notes: notes, items: nil, sent: [], live: [live("L1", "Something else", .done)])
        #expect(statuses == [ItemStatus.startedDuringCall, ItemStatus.notSentYet, ItemStatus.notSentYet])
    }

    @Test func similarityIsOnlyAFallbackWhenLiveRefIsNull() {
        let items = [
            live("L1", "Draft the pilot scope email", .suggested),
            live("L2", "Book the venue for review", .interrupted),
        ]
        // Item 1 names L1, which never started; the similar started L2 doesn't count for it.
        let statuses = ItemStatus.compute(notes: notes, items: nil, sent: [], live: items)
        #expect(statuses == [ItemStatus.notSentYet, ItemStatus.startedDuringCall, ItemStatus.notSentYet])
    }

    @Test func queuedFailedAndDismissedItemsAreNotStarted() {
        for status in [LiveItem.Status.queued, .failed, .dismissed, .suggested] {
            let statuses = ItemStatus.compute(notes: notes, items: nil, sent: [], live: [live("L1", "x", status)])
            #expect(statuses[0] == ItemStatus.notSentYet)
        }
    }

    @Test func sentNeedsAMatchingSourceAndASuccessfulTarget() {
        let items = [ActionItem(task: "Edited wording", owner: "Stephen", doer: .ai, source: "n1"),
                     ActionItem(task: "Book the venue for the review", owner: "Stephen", doer: .me, source: "n3")]
        #expect(ItemStatus.compute(notes: notes, items: items, sent: ["claude-code", "webhook"], live: [])
            == ["Sent to Claude Code, Webhook", ItemStatus.notSent, "Sent to Claude Code, Webhook"])
        #expect(ItemStatus.compute(notes: notes, items: items, sent: [], live: [])
            == [ItemStatus.notSent, ItemStatus.notSent, ItemStatus.notSent])
    }

    @Test func v1ItemsWithoutASourceMatchByTask() {
        let items = [ActionItem(task: "Book the venue for the review", owner: "Stephen", doer: .me)]
        #expect(ItemStatus.compute(notes: notes, items: items, sent: ["routine", "custom"], live: [])
            == [ItemStatus.notSent, "Sent to Claude Code routine, custom", ItemStatus.notSent])
    }

    @Test func sourceNumbersFromOne() {
        #expect(ItemStatus.source(forNotesIndex: 0) == "n1")
    }
}
