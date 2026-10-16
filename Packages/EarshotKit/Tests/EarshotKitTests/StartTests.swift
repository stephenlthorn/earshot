import Foundation
import Testing
@testable import EarshotKit

/// The recording start path: what starts it, the calendar context it records and the brief (spec 2, 5, 7.3).
/// Every suite is nested here, so `--filter StartTests` runs them all and no name clashes with other files.
struct StartTests {
    static let me = Attendee(name: "Stephen Thorn", email: "stephen@thorn.example", isMe: true)

    static func event(_ id: String = "evt-1", title: String = "Acme pricing", people: [Attendee] = [
        Attendee(name: "Dana Smith", email: "dana@acme.com"),
    ], agenda: String = "", url: String? = nil) -> CalendarEventInfo {
        CalendarEventInfo(id: id, title: title, start: at1530, end: at1530.addingTimeInterval(1800),
                          attendees: [me] + people, agenda: agenda, url: url)
    }

    static func settings(calendar: Bool = true, _ change: (inout EarshotSettings) -> Void = { _ in }) -> EarshotSettings {
        var settings = EarshotSettings()
        settings.useCalendar = calendar
        settings.myDomains = "thorn.example"
        change(&settings)
        return settings
    }
}

extension StartTests {
    @Suite struct RecordingStartTests {
        @Test func aClaudeProblemIsShownButNeverStopsTheRecording() {
            let check = RecordingStart.check(setupProblem: "Claude Code not found", disk: .ok)
            #expect(check.blocker == nil)
            #expect(check.notices == ["Claude Code not found"])
        }

        @Test func onlyAFullDiskStopsTheStart() {
            #expect(RecordingStart.check(setupProblem: nil, disk: .critical).blocker == RecordingStart.diskFull)
            #expect(RecordingStart.check(setupProblem: "x", disk: .critical).blocker == RecordingStart.diskFull)
            let low = RecordingStart.check(setupProblem: "Claude Code not found", disk: .low)
            #expect(low.blocker == nil)
            #expect(low.notices == ["Claude Code not found", RecordingStart.diskLow])
            #expect(RecordingStart.check(setupProblem: nil, disk: nil) == RecordingStart.Check(blocker: nil, notices: []))
        }

        @Test func theEventNamesTheMeetingWhenTitleIsBlankAndGivesItsProfile() {
            let start = RecordingStart(mode: .notes, typedTitle: "  ", trigger: .manual, event: StartTests.event(),
                                       settings: StartTests.settings())
            #expect(start.title == "Acme pricing")
            #expect(start.calendarEvent?.id == "evt-1")
            #expect(start.profile == .external)
            #expect(start.startedBy == .manual)
            #expect(start.mode == .notes)
        }

        @Test func anEventTitleIsCleanedBeforeItBecomesTheSessionTitle() throws {
            let event = StartTests.event(title: "Intro call with dana.smith@acme.com https://zoom.us/j/81?pwd=Xy12")
            let start = RecordingStart(mode: .notesAndDo, typedTitle: "", trigger: .manual, event: event,
                                       settings: StartTests.settings())
            #expect(start.title == "Intro call with [address at acme.com] [link]")
            // The session title is what every Do payload, Claude Code prompt and routine text carries.
            let (payload, _) = try samplePayload(title: start.title)
            for text in [String(decoding: try payload.encoded(), as: UTF8.self),
                         DoPrompt.text(payload, userName: "Stephen"),
                         DoPrompt.text(payload, userName: "Stephen", location: .cloud)] {
                #expect(!text.contains("dana.smith@") && !text.contains("pwd=") && !text.contains("zoom.us/j"))
            }
            let passcode = StartTests.event(title: "Zoom https://zoom.us/j/81?pwd=Xy12 passcode 4411")
            #expect(RecordingStart(mode: .notes, typedTitle: "", trigger: .manual, event: passcode,
                                   settings: StartTests.settings()).title == nil)
        }

        @Test func aTypedTitleWins() {
            let start = RecordingStart(mode: .notes, typedTitle: "Pricing with Dana", trigger: .auto,
                                       event: StartTests.event(), settings: StartTests.settings())
            #expect(start.title == "Pricing with Dana")
            #expect(start.startedBy == .auto)
        }

        @Test func withTheCalendarOffNoEventOrProfileIsKept() {
            let start = RecordingStart(mode: .record, typedTitle: "", trigger: .manual, event: StartTests.event(),
                                       settings: StartTests.settings(calendar: false))
            #expect(start.calendarEvent == nil)
            #expect(start.profile == nil)
            #expect(start.title == nil)
        }

        @Test func withTheCalendarOnButNoEventTheProfileIsNone() {
            let start = RecordingStart(mode: .notes, typedTitle: "", trigger: .manual, event: nil,
                                       settings: StartTests.settings())
            #expect(start.profile == MeetingProfile.noEvent)
            #expect(start.calendarEvent == nil)
        }

        @Test func applyWritesTheEventProfileAndTriggerIntoTheSession() throws {
            let store = SessionStore(root: tempDir(), timeZone: newYork)
            var session = try store.create(mode: .notes, title: "Acme pricing", now: at1530)
            let internalEvent = StartTests.event(people: [Attendee(name: "Ana", email: "ana@thorn.example")])
            RecordingStart(mode: .notes, typedTitle: "", trigger: .auto, event: internalEvent,
                           settings: StartTests.settings()).apply(to: &session)
            #expect(session.calendarEvent == internalEvent)
            #expect(session.profile == .internal)
            #expect(session.startedBy == .auto)
        }

        @Test func aFreshReadReplacesAMissingOrDifferentEventOnly() {
            var session = StartTests.session("s", startedBy: .manual)
            let settings = StartTests.settings()
            let found = RecordingStart.refreshed(session, fresh: StartTests.event(), canRead: true, now: at1530,
                                                 settings: settings)
            #expect(found?.event?.id == "evt-1")
            #expect(found?.profile == .external)
            session.calendarEvent = StartTests.event()
            #expect(RecordingStart.refreshed(session, fresh: StartTests.event(), canRead: true, now: at1530,
                                             settings: settings) == nil)
            #expect(RecordingStart.refreshed(session, fresh: nil, canRead: true, now: at1530, settings: settings) == nil)
            let other = StartTests.event("evt-2", title: "Globex intro")
            #expect(RecordingStart.refreshed(session, fresh: other, canRead: true, now: at1530,
                                             settings: settings)?.event?.id == "evt-2")
            #expect(RecordingStart.refreshed(session, fresh: other, canRead: true, now: at1530,
                                             settings: StartTests.settings(calendar: false)) == nil)
        }

        @Test func anEventThatEndedIsDroppedWhenTheFreshReadIsEmpty() {
            var session = StartTests.session("s", startedBy: .manual, event: StartTests.event())
            session.title = "Acme pricing"
            let settings = StartTests.settings()
            let afterEnd = StartTests.event().end.addingTimeInterval(30)
            let cleared = RecordingStart.refreshed(session, fresh: nil, canRead: true, now: afterEnd, settings: settings)
            #expect(cleared == RecordingStart.Refresh(event: nil, profile: .noEvent))
            // Without access an empty read says nothing about the event, so it is kept.
            #expect(RecordingStart.refreshed(session, fresh: nil, canRead: false, now: afterEnd, settings: settings) == nil)
            // A title the event gave goes with it; a typed one stays.
            var saved = session
            cleared?.apply(to: &saved)
            #expect(saved.calendarEvent == nil)
            #expect(saved.profile == .noEvent)
            #expect(saved.title == nil)
            var typed = session
            typed.title = "Pricing with Dana"
            cleared?.apply(to: &typed)
            #expect(typed.title == "Pricing with Dana")
        }

        @Test func aNewerEventNamesAMeetingWhoseTitleWasBlankOrCameFromTheOldEvent() {
            let next = StartTests.event("evt-2", title: "Globex intro")
            let refresh = RecordingStart.Refresh(event: next, profile: .external)
            var blank = StartTests.session("s", startedBy: .manual)
            refresh.apply(to: &blank)
            #expect(blank.title == "Globex intro")
            #expect(blank.calendarEvent == next)
            var fromOld = StartTests.session("s", startedBy: .manual, event: StartTests.event())
            fromOld.title = "Acme pricing"
            refresh.apply(to: &fromOld)
            #expect(fromOld.title == "Globex intro")
            var typed = StartTests.session("s", startedBy: .manual, event: StartTests.event())
            typed.title = "My notes"
            refresh.apply(to: &typed)
            #expect(typed.title == "My notes")
        }

        @Test func aStoppedRecordingIsNeverChanged() {
            var stopped = StartTests.session("s", startedBy: .manual)
            stopped.recording = false
            RecordingStart.Refresh(event: StartTests.event(), profile: .external).apply(to: &stopped)
            #expect(stopped.calendarEvent == nil)
            #expect(stopped.title == nil)
        }
    }

    @Suite struct CurrentEventTrackerTests {
        @Test func aNewEventPreselectsItsProfilesModeOnce() {
            var tracker = CurrentEventTracker()
            let settings = StartTests.settings { $0.webhookOn = true }
            #expect(tracker.observe(StartTests.event(), settings: settings, now: at1530, canPreselect: true) == .notesAndDo)
            #expect(tracker.profile == .external)
            // The user may change the mode; the same event never changes it back.
            #expect(tracker.observe(StartTests.event(), settings: settings, now: at1530, canPreselect: true) == nil)
            #expect(tracker.observe(nil, settings: settings, now: at1530, canPreselect: true) == nil)
            #expect(tracker.observe(StartTests.event(), settings: settings, now: at1530, canPreselect: true) == nil)
            let internalEvent = StartTests.event("evt-2", people: [Attendee(name: "Ana", email: "ana@thorn.example")])
            #expect(tracker.observe(internalEvent, settings: settings, now: at1530, canPreselect: true) == .notes)
        }

        @Test func duringARecordingTheModeWaitsForTheNextRead() {
            var tracker = CurrentEventTracker()
            let settings = StartTests.settings()
            #expect(tracker.observe(StartTests.event(), settings: settings, now: at1530, canPreselect: false) == nil)
            #expect(tracker.menuLine(now: at1530) == "Now: Acme pricing · External")
            #expect(tracker.observe(StartTests.event(), settings: settings, now: at1530, canPreselect: true) == .notes)
        }

        @Test func theMenuLineAndPlaceholderFollowTheEvent() {
            var tracker = CurrentEventTracker()
            #expect(tracker.menuLine(now: at1530) == nil)
            #expect(tracker.titlePlaceholder(now: at1530) == nil)
            _ = tracker.observe(StartTests.event(title: " Acme pricing "), settings: StartTests.settings(), now: at1530,
                                canPreselect: true)
            #expect(tracker.menuLine(now: at1530) == "Now: Acme pricing · External")
            #expect(tracker.titlePlaceholder(now: at1530) == "Acme pricing")
            _ = tracker.observe(StartTests.event("solo", title: "Focus", people: []), settings: StartTests.settings(),
                                now: at1530, canPreselect: true)
            #expect(tracker.menuLine(now: at1530) == "Now: Focus")
            #expect(tracker.profile == .noEvent)
            _ = tracker.observe(nil, settings: StartTests.settings(), now: at1530, canPreselect: true)
            #expect(tracker.menuLine(now: at1530) == nil)
            #expect(tracker.titlePlaceholder(now: at1530) == nil)
        }

        @Test func anEventThatEndedSinceTheLastReadIsNotCurrent() {
            var tracker = CurrentEventTracker()
            let event = StartTests.event()
            _ = tracker.observe(event, settings: StartTests.settings(), now: event.end.addingTimeInterval(-15),
                                canPreselect: true)
            #expect(tracker.current(now: event.end.addingTimeInterval(-1)) == event)
            let after = event.end.addingTimeInterval(30)
            #expect(tracker.current(now: after) == nil)
            #expect(tracker.menuLine(now: after) == nil)
            #expect(tracker.titlePlaceholder(now: after) == nil)
            // An event starting within the lead time already counts.
            #expect(tracker.current(now: event.start.addingTimeInterval(-CurrentEvent.leadTime + 1)) == event)
            #expect(tracker.current(now: event.start.addingTimeInterval(-CurrentEvent.leadTime - 1)) == nil)
        }

        @Test func pollsAtMostEverySixtySecondsAndOnlyWhileIdle() {
            var tracker = CurrentEventTracker()
            #expect(tracker.shouldPoll(now: at1530, idle: true))
            #expect(!tracker.shouldPoll(now: at1530, idle: false))
            _ = tracker.observe(nil, settings: StartTests.settings(), now: at1530, canPreselect: true)
            #expect(!tracker.shouldPoll(now: at1530.addingTimeInterval(59), idle: true))
            #expect(tracker.shouldPoll(now: at1530.addingTimeInterval(60), idle: true))
            #expect(!tracker.shouldPoll(now: at1530.addingTimeInterval(600), idle: false))
        }

        @Test func resetForgetsEverything() {
            var tracker = CurrentEventTracker()
            _ = tracker.observe(StartTests.event(), settings: StartTests.settings(), now: at1530, canPreselect: true)
            tracker.reset()
            #expect(tracker == CurrentEventTracker())
            #expect(tracker.observe(StartTests.event(), settings: StartTests.settings(), now: at1530,
                                    canPreselect: true) == .notes)
        }
    }
}
