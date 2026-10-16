import Foundation
import Testing
@testable import EarshotKit

/// The call questions and which recording may stop on its own (spec 7.2): a recording started by hand is never
/// stopped automatically, and an old or unknown question never acts.
extension StartTests {
    static func session(_ id: String, startedBy: StartTrigger, event: CalendarEventInfo? = nil) -> Session {
        var session = Session(id: id, folderName: id, title: nil, mode: .notes, startedAt: at1530, endedAt: nil,
                              recording: true, tracks: [], stages: [:], sent: [], warnings: [], startedBy: startedBy)
        session.calendarEvent = event
        return session
    }

    static func ask(_ kind: CallPrompt.Kind = .record, id: String = "p1", session: String? = nil,
                    at time: Date = at1530) -> CallPrompt {
        CallPrompt(id: id, kind: kind, call: zoom, sessionID: session, createdAt: time)
    }

    @Suite struct CallQuestionsTests {
        @Test func aRecordingStartedByHandIsNeverStoppable() {
            var questions = CallQuestions()
            let byHand = questions.recordingStarted(session: StartTests.session("s1", startedBy: .manual),
                                                    call: StartTests.zoom)
            #expect(!byHand.byEarshot)
            #expect(questions.autoStopSession(current: "s1") == nil)
            #expect(questions.monitorState == CallQuestions.MonitorState(call: nil, startedByEarshot: false, eventEnd: nil))
            _ = questions.recordingStopped()
            let noCall = questions.recordingStarted(session: StartTests.session("s2", startedBy: .auto), call: nil)
            #expect(!noCall.byEarshot)
            #expect(questions.autoStopSession(current: "s2") == nil)
        }

        @Test func aRecordingStartedForACallMayStopOnlyWhileItIsCurrent() {
            var questions = CallQuestions()
            let event = StartTests.event()
            let started = questions.recordingStarted(session: StartTests.session("s1", startedBy: .auto, event: event),
                                                     call: StartTests.zoom)
            #expect(started.byEarshot)
            #expect(questions.activeCall == StartTests.zoom)
            #expect(questions.autoStopSession(current: "s1") == "s1")
            #expect(questions.autoStopSession(current: "s2") == nil)
            #expect(questions.autoStopSession(current: nil) == nil)
            #expect(questions.monitorState == CallQuestions.MonitorState(call: StartTests.zoom, startedByEarshot: true,
                                                                         eventEnd: event.end))
            _ = questions.recordingStopped()
            #expect(questions.autoStopSession(current: "s1") == nil)
            #expect(questions.activeCall == nil)
            #expect(questions.monitorState == nil)
        }

        @Test func aStaleOrUnknownPromptDoesNothing() {
            var questions = CallQuestions()
            _ = questions.ask(StartTests.ask(id: "old", at: at1530), byNotification: true)
            let late = at1530.addingTimeInterval(CallPrompt.lifetime + 1)
            #expect(questions.answer(id: "old", yes: true, now: late, isRecording: false) == .none)
            #expect(questions.asked.isEmpty)
            #expect(questions.answer(id: "nope", yes: true, now: at1530, isRecording: false) == .none)
        }

        @Test func recordStartsTheCallOnlyWhenCurrentAndNothingIsRecording() {
            var questions = CallQuestions()
            #expect(questions.ask(StartTests.ask(id: "p1"), byNotification: true) == NotificationRoute.ID.prompt("p1"))
            #expect(questions.answer(id: "p1", yes: true, now: at1530, isRecording: true) == .none)
            #expect(questions.asked.isEmpty)
            #expect(questions.ask(StartTests.ask(id: "p2"), byNotification: false) == nil)
            #expect(questions.prompt?.id == "p2")
            #expect(questions.showsBadge)
            #expect(questions.answer(id: "p2", yes: true, now: at1530.addingTimeInterval(60), isRecording: false)
                == .startRecording(StartTests.zoom))
            #expect(questions.prompt == nil)
            #expect(!questions.showsBadge)
        }

        @Test func notNowOnlyForgetsTheQuestion() {
            var questions = CallQuestions()
            _ = questions.ask(StartTests.ask(id: "p1"), byNotification: false)
            #expect(questions.answer(id: "p1", yes: false, now: at1530, isRecording: false) == .none)
            #expect(questions.prompt == nil)
        }

        @Test func stopNamesItsRecordingAndOnlyThatOneStops() {
            var questions = CallQuestions()
            _ = questions.recordingStarted(session: StartTests.session("s1", startedBy: .auto), call: StartTests.zoom)
            _ = questions.ask(StartTests.ask(.stop, id: "q1", session: "s1"), byNotification: true)
            #expect(questions.answer(id: "q1", yes: true, now: at1530, isRecording: true) == .stop(sessionID: "s1"))
            #expect(CallQuestions.canStop(sessionID: "s1", current: "s1"))
            #expect(!CallQuestions.canStop(sessionID: "s1", current: "s2"))
            #expect(!CallQuestions.canStop(sessionID: "s1", current: nil))
            #expect(!CallQuestions.canStop(sessionID: nil, current: "s1"))
            _ = questions.ask(StartTests.ask(.stop, id: "q2", session: "s1"), byNotification: false)
            #expect(questions.answer(id: "q2", yes: false, now: at1530, isRecording: true) == .keepRecording(sessionID: "s1"))
            #expect(questions.prompt == nil)
        }

        @Test func keepRecordingOnlyKeepsTheRecordingItWasAskedAbout() {
            var questions = CallQuestions()
            _ = questions.recordingStarted(session: StartTests.session("s1", startedBy: .auto), call: StartTests.zoom)
            _ = questions.ask(StartTests.ask(.stop, id: "q1", session: "s0"), byNotification: true)
            #expect(questions.answer(id: "q1", yes: false, now: at1530, isRecording: true) == .none,
                    "a question about an older recording")
            #expect(questions.answer(id: "missing", yes: false, now: at1530, isRecording: true) == .none)
        }

        @Test func aStartClearsEveryQuestion() {
            var questions = CallQuestions()
            _ = questions.ask(StartTests.ask(id: "p1"), byNotification: true)
            _ = questions.ask(StartTests.ask(id: "p2"), byNotification: true)
            _ = questions.ask(StartTests.ask(id: "p3"), byNotification: false)
            let started = questions.recordingStarted(session: StartTests.session("s1", startedBy: .manual), call: nil)
            #expect(Set(started.removeIDs) == [NotificationRoute.ID.prompt("p1"), NotificationRoute.ID.prompt("p2")])
            #expect(questions.asked.isEmpty)
            #expect(questions.prompt == nil)
        }

        @Test func aStopRemovesOnlyTheStopQuestionsAndTheRecordingsNotices() {
            var questions = CallQuestions()
            _ = questions.recordingStarted(session: StartTests.session("s1", startedBy: .auto), call: StartTests.zoom)
            _ = questions.ask(StartTests.ask(.stop, id: "q1", session: "s1"), byNotification: true)
            _ = questions.ask(StartTests.ask(.record, id: "p1"), byNotification: true)
            let removed = questions.recordingStopped()
            #expect(Set(removed) == [NotificationRoute.ID.prompt("q1"), NotificationRoute.ID.recording(session: "s1"),
                                     NotificationRoute.ID.consent(session: "s1")])
            #expect(questions.asked.keys.sorted() == ["p1"])
            #expect(questions.recordingStopped().isEmpty)
        }

        @Test func aStopClearsAStopQuestionInTheMenuButKeepsARecordOne() {
            var questions = CallQuestions()
            _ = questions.recordingStarted(session: StartTests.session("s1", startedBy: .auto), call: StartTests.zoom)
            _ = questions.ask(StartTests.ask(.stop, id: "q1", session: "s1"), byNotification: false)
            _ = questions.recordingStopped()
            #expect(questions.prompt == nil)
            _ = questions.ask(StartTests.ask(.record, id: "p1"), byNotification: false)
            _ = questions.recordingStopped()
            #expect(questions.prompt?.id == "p1")
        }

        @Test func turningNoticeCallsOffDropsTheRecordQuestionsOnly() {
            var questions = CallQuestions()
            _ = questions.recordingStarted(session: StartTests.session("s1", startedBy: .auto), call: StartTests.zoom)
            _ = questions.ask(StartTests.ask(.stop, id: "q1", session: "s1"), byNotification: true)
            _ = questions.ask(StartTests.ask(.record, id: "p1"), byNotification: true)
            _ = questions.ask(StartTests.ask(.record, id: "p2"), byNotification: false)
            #expect(questions.watchingStopped() == [NotificationRoute.ID.prompt("p1")])
            #expect(questions.asked.keys.sorted() == ["q1"])
            #expect(questions.prompt == nil)
        }

        @Test func anExpiredMenuQuestionGoesAwayButANewerOneStays() {
            var questions = CallQuestions()
            _ = questions.ask(StartTests.ask(id: "p1"), byNotification: false)
            _ = questions.ask(StartTests.ask(id: "p2"), byNotification: false)
            questions.expire(promptID: "p1")
            #expect(questions.prompt?.id == "p2")
            questions.expire(promptID: "p2")
            #expect(questions.prompt == nil)
        }

        @Test func aNewEventEndReachesTheMonitorOnlyForEarshotsRunningRecording() {
            var questions = CallQuestions()
            let end = at1530.addingTimeInterval(3600)
            #expect(questions.eventChanged(sessionID: "s1", end: end) == nil)
            _ = questions.recordingStarted(session: StartTests.session("s1", startedBy: .auto), call: StartTests.zoom)
            #expect(questions.eventChanged(sessionID: "other", end: end) == nil)
            #expect(questions.eventChanged(sessionID: "s1", end: end)
                == CallQuestions.MonitorState(call: StartTests.zoom, startedByEarshot: true, eventEnd: end))
            #expect(questions.monitorState?.eventEnd == end)
            _ = questions.recordingStopped()
            _ = questions.recordingStarted(session: StartTests.session("s2", startedBy: .manual), call: nil)
            #expect(questions.eventChanged(sessionID: "s2", end: end) == nil)
            #expect(questions.monitorState?.eventEnd == end)
        }
    }
}
