import AppKit
import AVFoundation
import EarshotKit
import Foundation

/// v2 start path (B3): the calendar context, call detection, screen reading and the recording reminder, wired around
/// `startRecording` and `stopRecording`. Decisions live in EarshotKit; this only connects them to the system.
extension AppModel {
    /// At launch (not in e2e runs): the calendar poll and call detection, each only while its setting is on.
    func startWatchers() {
        context.attach(self)
        calls.attach(self)
    }

    /// Settings changed: the calendar poll and call detection follow their switches, and screen reading switched
    /// off stops a recording's sampler at once (spec 9).
    func watchersFollowSettings(from old: EarshotSettings) {
        context.apply()
        calls.apply()
        screen.settingsChanged(from: old, to: settings)
    }

    /// What the new recording starts with: the typed title or the event's, the event, its profile and the trigger.
    func recordingStart(mode: Mode, typedTitle: String, trigger: StartTrigger) -> RecordingStart {
        RecordingStart(mode: mode, typedTitle: typedTitle, trigger: trigger, event: context.eventForStart,
                       settings: settings)
    }

    /// Capture is running for `session`. Nothing here can stop or delay the recording. `call` is the call it was
    /// started for; without one, the screen reader follows whichever call app is using the microphone.
    func recordingDidStart(_ session: Session, store: SessionStore, call: CallEvent.Call?, capture: CaptureSession) {
        context.recordingStarted(session, store: store, settings: settings, secrets: keychain,
                                 index: LibraryIndex(url: dataLocations.index))
        calls.recordingStarted(session, call: call, settings: settings)
        screen.start(folder: store.folder(session), call: call, settings: settings, clock: Self.meetingClock(capture))
        remindConsent(session)
    }

    /// The recording is stopping. The returned task finishes once screen.json is saved, so the notes see it.
    func recordingWillStop() -> Task<Void, Never> {
        context.recordingStopped()
        calls.recordingStopped()
        return screen.stop()
    }

    /// The reminder goes in a notification when the live panel is hidden; the panel shows its own banner (spec 7.4).
    /// The live panel sets `livePanelVisible` before `recordingDidStart` runs.
    private func remindConsent(_ session: Session) {
        guard !e2e, ConsentPolicy.delivery(settings: settings, panelShown: livePanelVisible) == .notification else { return }
        EarshotNotifications.post(id: NotificationRoute.ID.consent(session: session.id), title: CallTexts.consentTitle,
                                  body: ConsentPolicy.line(settings: settings), category: .consent)
    }

    /// Seconds on the meeting clock for screen moments (spec 14.1): from the earliest track's first buffer, on the host
    /// clock (never a Date). Nil until the first buffer arrives.
    static func meetingClock(_ capture: CaptureSession) -> @Sendable () -> Double? {
        { capture.currentOffset() }
    }

    // MARK: Notifications and prompts

    /// A notification button or click, routed by `NotificationRouter`.
    func perform(_ command: NotificationRoute.Command) async {
        switch command {
        case let .record(prompt): await calls.answer(promptID: prompt, yes: true)
        case let .dismiss(prompt): await calls.answer(promptID: prompt, yes: false)
        case let .stop(session): calls.stop(sessionID: session)
        case .copyConsentLine: copyConsentLine()
        case let .open(path): NSWorkspace.shared.open(URL(fileURLWithPath: path))
        case .none: break
        }
    }

    /// Answers the call question shown in the menu: Record or Stop (`yes`), Not now or Keep recording.
    func answerCallPrompt(_ prompt: CallPrompt, yes: Bool) {
        Task { await calls.answer(promptID: prompt.id, yes: yes) }
    }

    /// Puts the consent line (spec 7.4) on the clipboard.
    func copyConsentLine() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(ConsentPolicy.line(settings: settings), forType: .string)
    }

    // MARK: Permissions, for Settings and onboarding

    /// Asks for Screen Recording. True when it is already allowed; otherwise macOS shows its prompt (the first time
    /// only), and Earshot has to relaunch after the grant. The ask is remembered, so onboarding can tell "denied before".
    @discardableResult
    func requestScreenAccess() -> Bool {
        let allowed = ScreenController.requestAccess()
        if !allowed { UserDefaults.standard.set(true, forKey: Self.screenAccessAskedKey) }
        return allowed
    }

    var hasScreenAccess: Bool { ScreenController.hasAccess }

    /// Asks for full access to calendar events, then reads the current event.
    func requestCalendarAccess() async -> CalendarAuthorization { await context.requestAccess() }

    func calendarAuthorization() async -> CalendarAuthorization { await context.authorization() }

    /// Whether "Start automatically" can be switched on: notifications are allowed or the panel is on (spec 7.2).
    func canTurnOnAutoRecord() async -> Bool {
        CallNoticePolicy.canTurnOnAutoRecord(notificationsAuthorized: await EarshotNotifications.authorized(),
                                             panelOn: settings.showLivePanel)
    }
}
