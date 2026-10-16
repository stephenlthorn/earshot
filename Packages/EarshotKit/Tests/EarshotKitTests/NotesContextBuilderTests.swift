import Foundation
import Testing
@testable import EarshotKit

struct NotesContextBuilderTests {
    /// An external meeting: the user, someone at acme.com and a colleague at northwind.com, with a dial-in agenda.
    static let event = CalendarEventInfo(
        id: "e1", title: "Acme follow-up", start: at1530, end: at1530.addingTimeInterval(3600),
        attendees: [Attendee(name: "Stephen Thorn", email: "stephen@northwind.com", isMe: true),
                    Attendee(name: "Dana Lee", email: "dana@acme.com"),
                    Attendee(name: "Lee Park", email: "lee@northwind.com")],
        agenda: "Pricing follow-up\nJoin: https://zoom.us/j/123\nPasscode: 999")

    static let session: Session = {
        var s = Session(id: "2026-10-14-1530-abcd", folderName: "x", title: "Acme follow-up", mode: .notes,
                        startedAt: at1530, endedAt: at1530.addingTimeInterval(600), recording: false, tracks: [],
                        stages: [:], sent: [], warnings: [])
        s.calendarEvent = Self.event
        s.profile = .external
        return s
    }()

    static let history: [MeetingRecord] = {
        var past = session
        past.id = "past"
        past.title = "Acme pricing"
        past.startedAt = at1530.addingTimeInterval(-7 * 86_400)
        return [MeetingRecord(session: past, folder: URL(filePath: "/tmp/past"),
                              notes: MeetingNotes(title: "Acme pricing", summary: "s", actionItems: [
                                  ActionItem(task: "Send the pricing sheet", owner: "Dana Lee", doer: .someoneElse)]))]
    }()

    @Test func aV1MeetingGetsAnEmptyContext() {
        let v1 = Session(id: "a", folderName: "a", title: nil, mode: .notes, startedAt: at1530, endedAt: nil,
                         recording: false, tracks: [], stages: [:], sent: [], warnings: [])
        let context = NotesContextBuilder.build(.init(session: v1, transcript: meetingSegments[.me]!, history: Self.history))
        #expect(context == .empty)
    }

    @Test func attendeesProfileAndAgendaComeFromTheEvent() {
        let context = NotesContextBuilder.build(.init(session: Self.session, myDomains: "northwind.com"))
        #expect(context.attendees.map(\.side) == [.me, .external, .internal])
        #expect(context.profile == .external)
        #expect(context.agenda == AgendaSanitizer.clean(Self.event.agenda))
        #expect(!context.agenda.contains("999") && !context.agenda.contains("zoom"))
        var dialIn = Self.session
        dialIn.calendarEvent?.agenda = "https://zoom.us/j/1\nPasscode: 2"
        #expect(NotesContextBuilder.build(.init(session: dialIn)).agenda == "")
    }

    @Test func aCompleteBriefGivesTheLoopsAndOtherwiseRelatedMeetingsDo() {
        let loops = [OpenLoop(owner: "Dana", task: "Brief loop", from: "Brief")]
        let brief = MeetingBrief(eventID: "e1", model: "m", createdAt: at1530, headline: "h", openLoops: loops)
        let fromBrief = NotesContextBuilder.build(.init(session: Self.session, brief: brief, history: Self.history))
        #expect(fromBrief.openLoops == loops)
        let fallback = NotesContextBuilder.build(.init(session: Self.session, history: Self.history, timeZone: newYork))
        #expect(fallback.openLoops == [OpenLoop(owner: "Dana Lee", task: "Send the pricing sheet", from: "Acme pricing, 7 Oct")])
        var noEvent = Self.session
        noEvent.calendarEvent = nil
        #expect(NotesContextBuilder.build(.init(session: noEvent, history: Self.history)).openLoops.isEmpty)
    }

    @Test func aBriefCountsOnlyWhenItDecodesCompletely() throws {
        let brief = MeetingBrief(eventID: "e1", model: "m", createdAt: at1530, headline: "h",
                                 openLoops: [OpenLoop(owner: "Dana", task: "t", from: "f")])
        let good = try JSONFiles.encoder().encode(brief)
        #expect(NotesContextBuilder.completeBrief(from: good) == brief)
        let noLoops = Data(#"{"version":1,"model":"m","createdAt":"2026-10-14T19:30:00Z","headline":"h"}"#.utf8)
        #expect(NotesContextBuilder.completeBrief(from: noLoops)?.openLoops == [])
        let lostLoop = Data(#"{"createdAt":"2026-10-14T19:30:00Z","headline":"h","openLoops":[{"owner":"x"},{"owner":"a","task":"b","from":"c"}]}"#.utf8)
        #expect(NotesContextBuilder.completeBrief(from: lostLoop) == nil)
        #expect(NotesContextBuilder.completeBrief(from: Data(#"{"headline":"h"}"#.utf8)) == nil)
        #expect(NotesContextBuilder.completeBrief(from: Data("garbage".utf8)) == nil)
    }

    @Test func lessonsAreUsedOnlyWhenLearningFromEditsAndAtMostEight() {
        let lessons = (0..<12).map { n in
            Lesson(date: at1530.addingTimeInterval(Double(n)), style: n.isMultiple(of: 2) ? .salesCall : .general,
                   kind: .instruction, instruction: "L\(n)", meetingTitle: "m")
        }
        let on = NotesContextBuilder.build(.init(session: Self.session, lessons: lessons, style: .salesCall))
        #expect(on.lessons.map(\.instruction) == ["L10", "L8", "L6", "L4", "L2", "L0", "L11", "L9"])
        let off = NotesContextBuilder.build(.init(session: Self.session, lessons: lessons, learnFromEdits: false))
        #expect(off.lessons.isEmpty)
    }

    @Test func eachFlagGetsThirtySecondsOfTranscriptEitherSide() {
        var s = Self.session
        s.flags = [Flag(offset: 200, source: .voice), Flag(offset: 60, source: .hotkey), Flag(offset: 500, source: .panel)]
        let transcript = [Segment(track: .me, start: 10, end: 29, text: "Too early."),
                          Segment(track: .them, start: 25, end: 31, text: "Just inside."),
                          Segment(track: .me, start: 50, end: 55, text: "This number here."),
                          Segment(track: .them, start: 90, end: 95, text: "Edge."),
                          Segment(track: .me, start: 91, end: 99, text: "Too late."),
                          Segment(track: .me, start: 190, end: 195, text: "Second flag.")]
        let flags = NotesContextBuilder.build(.init(session: s, transcript: transcript, names: [.me: "Stephen"])).flags
        #expect(flags.map(\.offset) == [60, 200, 500])
        #expect(flags[0].text == "[00:00:25] Them: Just inside.\n[00:00:50] Stephen: This number here.\n[00:01:30] Them: Edge.")
        #expect(flags[1].text == "[00:03:10] Stephen: Second flag.")
        #expect(flags[2].text == NotesContextBuilder.quietFlag)
    }

    @Test func screenTextComesFromTheScreenSelection() {
        var s = Self.session
        s.flags = [Flag(offset: 100, source: .hotkey)]
        let moments = [ScreenMoment(offset: 20, text: "Agenda slide"), ScreenMoment(offset: 110, text: "Price 1200")]
        let context = NotesContextBuilder.build(.init(session: s, screen: moments))
        #expect(context.screen == ScreenSelection.excerpts(moments: moments, flags: s.flags, segments: []))
        #expect(context.screen.map(\.offset) == [20, 110])
    }

    @Test func onlyLiveToDosThatWentOutAreListedAsStarted() {
        let live = LiveItem.Status.allCases.enumerated().map { n, status in
            LiveItem(id: "L\(n + 1)", task: "\(status)", owner: "Stephen", aiDoable: true, firstSeen: 0, status: status)
        }
        let context = NotesContextBuilder.build(.init(session: Self.session, live: live))
        #expect(context.started.map(\.task) == ["sending", "running", "done", "sent", "startedInCloud", "interrupted"])
    }
}
