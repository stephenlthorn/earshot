import Foundation
import Testing
@testable import EarshotKit

private func item(_ number: Int, _ status: LiveItem.Status = .suggested, seen: Double? = nil, detail: String? = nil,
                  link: String? = nil, ai: Bool = true) -> LiveItem {
    LiveItem(id: "L\(number)", task: "Task \(number)", owner: "Dana", aiDoable: ai, why: "Dana asked",
             firstSeen: seen ?? Double(number), status: status, target: status == .suggested ? nil : "webhook",
             detail: detail, link: link)
}

struct LiveRowsTests {
    let now = Date(timeIntervalSince1970: 1_000)

    @Test func suggestedRowsOfferStartAndDismissInNotesAndDo() {
        let rows = LiveRows.rows([item(1)], start: .oneClick, pressedAt: [:], now: now)
        #expect(rows.count == 1)
        #expect(rows[0].state == nil)
        #expect(rows[0].actions == [.start, .dismiss])
        #expect(rows[0].task == "Task 1" && rows[0].owner == "Dana" && rows[0].aiDoable)
    }

    @Test func theSheetDecisionStillShowsStart() {
        #expect(LiveRows.rows([item(1)], start: .confirmSheet, pressedAt: [:], now: now)[0].actions == [.start, .dismiss])
    }

    @Test func withoutNotesAndDoThereIsNoStartOnlyDismiss() {
        #expect(LiveRows.rows([item(1)], start: nil, pressedAt: [:], now: now)[0].actions == [.dismiss])
    }

    @Test func withoutAWorkingTargetStartBecomesSetUp() {
        let rows = LiveRows.rows([item(1)], start: .unavailable(LiveStartPolicy.routineNotAllowed), pressedAt: [:],
                                 now: now)
        #expect(rows[0].actions == [.setUp(LiveStartPolicy.routineNotAllowed), .dismiss])
        #expect(LiveRows.setUpLabel == "Set up a Do target")
        #expect(LiveRows.setUpButton(for: LiveStartPolicy.routineNotAllowed) == "Allow Start in Settings")
        #expect(LiveRows.setUpButton(for: LiveStartPolicy.setUpTarget) == "Set up a Do target")
    }

    @Test func aQueuedRowSaysStartingDuringTheWindowThenQueued() {
        let pressed = ["L1": now.addingTimeInterval(-1)]
        let starting = LiveRows.rows([item(1, .queued)], start: .oneClick, pressedAt: pressed, now: now)[0]
        #expect(starting.state == "Starting with Webhook\u{2026}")
        #expect(starting.actions == [.cancel])
        let later = LiveRows.rows([item(1, .queued)], start: .oneClick, pressedAt: pressed,
                                  now: now.addingTimeInterval(3))[0]
        #expect(later.state == "Queued")
        #expect(later.actions == [.cancel])
        let unknown = LiveRows.rows([item(1, .queued)], start: .oneClick, pressedAt: [:], now: now)[0]
        #expect(unknown.state == "Queued")
    }

    @Test func theStartingLineNamesTheTargetItGoesTo() {
        // Start may fall back to another target while the chosen one is off, so the window says which one runs.
        #expect(LiveRows.starting("claude-code") == "Starting with Claude Code\u{2026}")
        #expect(LiveRows.starting("routine") == "Starting with Claude Code routine\u{2026}")
        #expect(LiveRows.starting("command") == "Starting with Command\u{2026}")
        #expect(LiveRows.starting(nil) == "Starting\u{2026}" && LiveRows.starting("") == "Starting\u{2026}")
        var queued = item(1, .queued)
        queued.target = "claude-code"
        let row = LiveRows.rows([queued], start: .oneClick, pressedAt: ["L1": now], now: now)[0]
        #expect(row.state == "Starting with Claude Code\u{2026}" && row.actions == [.cancel])
    }

    @Test func eachStateHasItsWordsAndActions() {
        let items = [item(1, .sending), item(2, .running), item(3, .done), item(4, .sent),
                     item(5, .startedInCloud, link: "https://claude.ai/code/run1"), item(6, .failed, detail: "timed out"),
                     item(7, .interrupted), item(8, .startedInCloud)]
        let rows = LiveRows.rows(items, start: .oneClick, pressedAt: [:], now: now)
        #expect(rows.map(\.state) == ["Sending\u{2026}", "Running", "Done", "Sent", "Started in the cloud",
                                      "Failed: timed out", "Interrupted", "Started in the cloud"])
        #expect(rows.map(\.actions) == [[], [], [.open], [], [.openRun("https://claude.ai/code/run1")],
                                        [.start, .dismiss], [], []])
        #expect(rows.map(\.tone) == [.working, .working, .good, .good, .good, .bad, .muted, .good])
    }

    @Test func aFailedRowWithoutAReasonSaysFailed() {
        #expect(LiveRows.rows([item(1, .failed)], start: nil, pressedAt: [:], now: now)[0].state == "Failed")
        #expect(LiveRows.rows([item(1, .failed)], start: nil, pressedAt: [:], now: now)[0].actions == [.dismiss])
    }

    @Test func aRunLinkMustBeHTTPS() {
        let rows = LiveRows.rows([item(1, .startedInCloud, link: "file:///etc/passwd")], start: .oneClick,
                                 pressedAt: [:], now: now)
        #expect(rows[0].actions == [])
    }

    @Test func dismissedRowsAreHiddenAndTheRestStayInTheOrderFound() {
        let items = [item(3, seen: 40), item(1, seen: 10), item(2, .dismissed, seen: 20), item(10, seen: 40)]
        let rows = LiveRows.rows(items, start: nil, pressedAt: [:], now: now)
        #expect(rows.map(\.id) == ["L1", "L3", "L10"])
    }

    @Test func rowTextHasNoDashes() {
        let all = LiveItem.Status.allCases.map { item(1, $0, detail: "x") }
        for row in LiveRows.rows(all, start: .oneClick, pressedAt: [:], now: now) {
            #expect(!(row.state ?? "").contains("\u{2014}"))
        }
    }
}

struct LivePanelTextTests {
    @Test func flagFeedbackUsesMinutesAndSeconds() {
        #expect(LivePanelText.flagged(at: 751) == "Flagged at 12:31")
        #expect(LivePanelText.flagged(at: 4_510.6) == "Flagged at 75:10")
    }

    @Test func aHotkeyThatCantBeRegisteredIsNamed() {
        #expect(LivePanelText.couldNotRegister(LivePanelText.flagCombo) == "Earshot couldn't register \u{2303}\u{2325}\u{2318}F")
        #expect(LivePanelText.sharingCombo == "\u{2303}\u{2325}\u{2318}H")
    }

    @Test func theSharingNoteSaysItOnlyTries() {
        #expect(LivePanelText.hidingNote.contains("tries to hide"))
    }

    @Test func aFailedSaveIsSaidPlainly() {
        #expect(LivePanelText.couldNotSave == "Couldn't save the live to-dos")
    }

    @Test func theQuitWarningKeepsTheRetryWordsForMeetingItemsOnly() {
        #expect(LivePanelText.quitWarning(meeting: ["Claude Code"], live: [], liveItems: 0)
            == "Claude Code is still working on this meeting's items. Quitting stops it, and the meeting waits for you "
            + "to press Retry.")
        #expect(LivePanelText.quitWarning(meeting: ["Claude Code", "My script"], live: [], liveItems: 0)
            == "Claude Code and My script are still working on this meeting's items. Quitting stops them, and the "
            + "meeting waits for you to press Retry.")
    }

    @Test func theQuitWarningSaysLiveToDosAreMarkedInterruptedNotRetried() {
        #expect(LivePanelText.quitWarning(meeting: [], live: ["Claude Code"], liveItems: 1)
            == "Claude Code is still working on a live to-do. Quitting stops it, and the live to-do is marked "
            + "Interrupted.")
        #expect(LivePanelText.quitWarning(meeting: [], live: ["Claude Code", "My script"], liveItems: 2)
            == "Claude Code and My script are still working on live to-dos. Quitting stops them, and those live "
            + "to-dos are marked Interrupted.")
        let both = LivePanelText.quitWarning(meeting: ["My script"], live: ["Claude Code"], liveItems: 1)
        #expect(both == "My script is still working on this meeting's items, and Claude Code on a live to-do. "
            + "Quitting stops them. The meeting waits for you to press Retry, and the live to-do is marked Interrupted.")
        #expect(!both.contains("\u{2014}") && !both.contains("\u{2013}"))
    }
}

struct LiveContextTests {
    private func session(title: String?, profile: MeetingProfile? = nil, event: CalendarEventInfo? = nil) -> Session {
        var session = Session(id: "m1", folderName: "m1", title: title, mode: .notesAndDo, startedAt: at1530,
                              endedAt: nil, recording: true, tracks: [], stages: [:], sent: [], warnings: [])
        session.profile = profile
        session.calendarEvent = event
        session.flags = [Flag(offset: 12, source: .hotkey)]
        return session
    }

    private let event = CalendarEventInfo(
        id: "e1", title: "Acme pricing call", start: at1530, end: at1530.addingTimeInterval(1800),
        attendees: [Attendee(name: "Stephen", email: "s@me.com", isMe: true), Attendee(name: "Dana", email: "d@acme.com"),
                    Attendee(name: "bob@acme.com", email: "bob@acme.com")])

    private let lesson = Lesson(date: at1530, style: .general, kind: .instruction, instruction: "Owners by first name",
                                meetingTitle: "Old")

    @Test func theMeetingCarriesTitleNamesFlagsAndLessons() {
        var settings = EarshotSettings()
        settings.userName = "Stephen"
        let meeting = LiveContext.meeting(session: session(title: "Kickoff", event: event), settings: settings,
                                          lessons: [lesson])
        #expect(meeting.title == "Kickoff")
        #expect(meeting.userName == "Stephen")
        #expect(meeting.attendees == ["Dana", "acme.com"])
        #expect(meeting.flags == [Flag(offset: 12, source: .hotkey)])
        #expect(meeting.lessons == [lesson])
        #expect(meeting.style == settings.style)
    }

    @Test func anUntitledMeetingUsesTheEventTitle() {
        let meeting = LiveContext.meeting(session: session(title: nil, event: event), settings: EarshotSettings(),
                                          lessons: [])
        #expect(meeting.title == "Acme pricing call")
        #expect(LiveContext.meeting(session: session(title: "  "), settings: EarshotSettings(), lessons: []).title == "")
    }

    @Test func anEventTitleReachesTheLivePassCleaned() {
        var raw = event
        raw.title = "Intro call with dana.smith@acme.com"
        #expect(LiveContext.meeting(session: session(title: nil, event: raw), settings: EarshotSettings(),
                                    lessons: []).title == "Intro call with [address at acme.com]")
        raw.title = "Zoom https://zoom.us/j/8123456789?pwd=Xy12 passcode 4411"
        let meeting = LiveContext.meeting(session: session(title: nil, event: raw), settings: EarshotSettings(), lessons: [])
        #expect(meeting.title == "")
        raw.title = "Pricing https://zoom.us/j/8123456789?pwd=Xy12"
        let prompt = LivePrompt.user(LivePrompt.Input(
            meeting: LiveContext.meeting(session: session(title: nil, event: raw), settings: EarshotSettings(), lessons: []),
            known: [], earlier: [], new: []))
        #expect(prompt.contains("Pricing [link]") && !prompt.contains("pwd=") && !prompt.contains("zoom.us/j"))
    }

    @Test func lessonsAreLeftOutWhenLearningIsOff() {
        var settings = EarshotSettings()
        settings.learnFromEdits = false
        #expect(LiveContext.meeting(session: session(title: "x"), settings: settings, lessons: [lesson]).lessons.isEmpty)
    }

    @Test func theProfileChoosesTheStyle() {
        let meeting = LiveContext.meeting(session: session(title: nil, profile: .external, event: event),
                                          settings: EarshotSettings(), lessons: [])
        #expect(meeting.style == .salesCall)
    }
}

struct LiveStartSheetTests {
    private func payload() -> DoPayload {
        let session = Session(id: "m1", folderName: "m1", title: "Kickoff", mode: .notesAndDo, startedAt: at1530,
                              endedAt: nil, recording: true, tracks: [], stages: [:], sent: [], warnings: [])
        return LiveDispatch.payload(for: item(3), session: session, folder: URL(fileURLWithPath: "/tmp/m1"),
                                    event: nil, at: at1530)
    }

    @Test func claudeCodeShowsTheExactPromptItGets() {
        let target = ClaudeCodeTarget(claudePath: "/bin/claude", workingFolder: URL(fileURLWithPath: "/tmp"),
                                      permissionMode: "acceptEdits", userName: "Stephen")
        let payload = payload()
        #expect(LiveStartSheet.text(payload, target: target) == DoPrompt.text(payload, userName: "Stephen"))
        #expect(LiveStartSheet.title(for: target) == "Send to Claude Code?")
    }

    @Test func aCommandShowsTheCommandAndTheJSON() throws {
        let payload = payload()
        let text = LiveStartSheet.text(payload, target: CommandTarget(command: "./do-it.sh"))
        #expect(text.contains("./do-it.sh"))
        #expect(text.contains(String(decoding: try payload.encoded(), as: UTF8.self)))
        #expect(!text.contains("\u{2014}"))
    }
}

struct LiveFlagsTests {
    @Test func aFlagIsSavedInTimeOrderAndARepeatIsNot() throws {
        let store = SessionStore(root: tempDir())
        let session = try store.create(mode: .notes, title: "Flags", now: at1530)
        #expect(try LiveFlags.add(at: 40, source: .hotkey, store: store, id: session.id) == Flag(offset: 40, source: .hotkey))
        #expect(try LiveFlags.add(at: 45, source: .panel, store: store, id: session.id) == nil)
        #expect(try LiveFlags.add(at: 12, source: .voice, store: store, id: session.id) == Flag(offset: 12, source: .voice))
        #expect(store.find(session.id)?.flags == [Flag(offset: 12, source: .voice), Flag(offset: 40, source: .hotkey)])
    }

    @Test func aMissingMeetingThrows() {
        let store = SessionStore(root: tempDir())
        #expect(throws: SessionStoreError.self) { try LiveFlags.add(at: 1, source: .panel, store: store, id: "nope") }
    }

    @Test func stopSavesOnlyWhatTheRecorderOwns() throws {
        let store = SessionStore(root: tempDir())
        var session = try store.create(mode: .notes, title: "Flags", now: at1530)
        try LiveFlags.add(at: 40, source: .hotkey, store: store, id: session.id)
        try store.update(session.id) { $0.profile = .external }  // written by someone else during the recording
        session.recording = false
        session.warnings = ["Call audio was silent."]
        session.tracks = [TrackFile(track: .me, file: "mic.caf", offset: 0.25)]
        session.endedAt = at1530.addingTimeInterval(600)
        session.title = "A stale title"
        try LiveFlags.save(session, keepingFlagsIn: store)
        let saved = try #require(store.find(session.id))
        #expect(saved.flags == [Flag(offset: 40, source: .hotkey)])
        #expect(saved.profile == .external)
        #expect(saved.title == "Flags")
        #expect(!saved.recording)
        #expect(saved.warnings == ["Call audio was silent."])
        #expect(saved.tracks == [TrackFile(track: .me, file: "mic.caf", offset: 0.25)])
        #expect(saved.endedAt == at1530.addingTimeInterval(600))
    }
}
