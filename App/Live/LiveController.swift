import AppKit
import EarshotKit
import Observation
import os

/// The live assistant, flags and the panel during a recording (spec 4, 7.4 and 8). It runs on the main actor and
/// only wires things up: the live work itself runs in `LiveSession`, off the main actor, and every decision is in
/// EarshotKit.
@MainActor @Observable
final class LiveController {
    typealias Layout = LivePanelState.Layout

    struct Consent {
        var line: String
        var shownAt: Date
        var startedBy: StartTrigger
    }

    // What the panel shows.
    var items: [LiveItem] = []
    var status: LiveStatus?
    var tickerMe = ""
    var tickerThem = ""
    var flagNote: String?
    var brief: MeetingBrief?
    /// Collapsed for External meetings, following a profile saved after the start until the user clicks (spec 4.5).
    var briefCard = BriefCardExpansion()
    var layout = Layout.full
    var consent: Consent?
    /// Nil when this meeting offers no Start: it isn't Notes + Do, or the live assistant is off.
    var startDecision: LiveStartPolicy.Decision?
    var pressedAt: [String: Date] = [:]
    var sheet: StartSheetRequest?
    /// The live assistant is running for this recording.
    var liveOn = false
    /// The provider this recording's live client was made for, so the panel names it even if Settings changes.
    private(set) var liveProvider = NotesProvider.claudeCode
    /// The live assistant was switched off during this recording: its passes and transcribers stopped, and the
    /// to-dos it found stay in the panel until the recording stops.
    var liveSwitchedOff = false
    var transcriptionProblem: String?
    /// Set while live.json can't be written, or after a Dismiss that couldn't be saved.
    var saveProblem: String?
    var elapsed: TimeInterval = 0
    var now = Date()
    /// Hotkeys the system refused, as Settings shows them ("Earshot couldn't register ⌃⌥⌘F").
    var hotkeyProblems: [String] = []

    /// For Settings: the flag hotkey is on but couldn't be registered.
    var flagHotkeyProblem: String? { hotkeyProblem(.flag) }
    /// For Settings: the panel is on but its Sharing hotkey couldn't be registered.
    var sharingHotkeyProblem: String? { hotkeyProblem(.sharing) }

    private func hotkeyProblem(_ key: Hotkeys.Key) -> String? {
        let text = LivePanelText.couldNotRegister(key.combo)
        return hotkeyProblems.contains(text) ? text : nil
    }

    @ObservationIgnored weak var model: AppModel?
    @ObservationIgnored private(set) var live: LiveSession?
    @ObservationIgnored private var mode = Mode.notes
    @ObservationIgnored var hovered: String?
    @ObservationIgnored private var finishing: [String: LiveSession] = [:]
    @ObservationIgnored private var eventsTask: Task<Void, Never>?
    @ObservationIgnored private var clock: Timer?
    @ObservationIgnored private var flagNoteUntil = Date.distantPast
    @ObservationIgnored private var nextBriefCheck = Date.distantPast
    /// Until when brief.json is looked for; nil when this meeting gets no brief.
    @ObservationIgnored private var briefCheckUntil: Date?
    /// Capture is running and `begin()` has saved the meeting, so a flag can't be overwritten by the start save.
    @ObservationIgnored private(set) var began = false
    @ObservationIgnored private let hotkeys = Hotkeys()
    @ObservationIgnored private lazy var panel = LivePanel(controller: self)

    static let flagNoteSeconds: TimeInterval = 4
    static let briefCheckSeconds: TimeInterval = 2
    /// How long a brief is waited for after the recording starts.
    static let briefWaitSeconds: TimeInterval = 600
    static let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Earshot", category: "live")
    /// How long quitting waits for live sends that are already going.
    static let quitLimit: Duration = .seconds(5)

    init(model: AppModel) {
        self.model = model
    }

    // MARK: Launch and settings

    /// At launch, before any recording: live to-dos a crash or quit left sending become interrupted. A failure is
    /// logged; live to-dos that couldn't be read are named once in the banner.
    func recover(in store: SessionStore) {
        do {
            try LiveStore.recover(in: store)
        } catch {
            Self.log.error("Live to-do recovery failed: \(error.localizedDescription, privacy: .public)")
            if case LiveStore.Failure.partlyUnreadable = error, let model {
                model.banner = [model.banner, error.localizedDescription].compactMap { $0 }.joined(separator: "\n")
            }
        }
    }

    func registerHotkeys() {
        guard let settings = model?.settings else { return }
        hotkeys.unregisterAll()
        var problems: [String] = []
        if settings.flagHotkey, !hotkeys.register(.flag, action: { [weak self] in self?.flag(.hotkey) }) {
            problems.append(LivePanelText.couldNotRegister(Hotkeys.Key.flag.combo))
        }
        if settings.showLivePanel, !hotkeys.register(.sharing, action: { [weak self] in self?.toggleSharing() }) {
            problems.append(LivePanelText.couldNotRegister(Hotkeys.Key.sharing.combo))
        }
        hotkeyProblems = problems
    }

    func settingsChanged(from old: EarshotSettings) {
        guard let settings = model?.settings else { return }
        if old.flagHotkey != settings.flagHotkey || old.showLivePanel != settings.showLivePanel { registerHotkeys() }
        if old.hidePanelFromCapture != settings.hidePanelFromCapture { panel.hideFromCapture(settings.hidePanelFromCapture) }
        if let live, liveOn, RecordingSwitches.stopsLiveAssistant(from: old, to: settings) { switchOff(live) }
        if live != nil { startDecision = decision(settings) }
    }

    /// The live assistant was switched off during the recording (spec 4.1): its passes and live transcribers stop at
    /// once and live.json is saved. The panel, flags and Start runs already queued carry on. It stays off until the
    /// next recording, even if it is switched back on.
    private func switchOff(_ live: LiveSession) {
        liveOn = false
        liveSwitchedOff = true
        status = nil
        tickerMe = ""
        tickerThem = ""
        transcriptionProblem = nil
        sheet = nil  // nothing new is sent from a sheet that was open
        Task { await live.stop() }
        Self.log.info("The live assistant was switched off during the recording; its passes and transcribers stopped.")
    }

    // MARK: Recording

    /// Before capture starts, so the live feed is in place for the first buffer.
    func prepare(capture: CaptureSession, session: Session, store: SessionStore, mode: Mode) {
        guard let model else { return }
        let settings = model.settings
        let liveOn = settings.liveAssistant && mode != .record
        let client = liveOn ? try? settings.claudeClient(secrets: model.keychain) : nil
        let lessons = liveOn && settings.learnFromEdits ? LessonsStore(url: model.dataLocations.lessons).all() : []
        live = Self.makeSession(capture: capture, session: session, store: store, settings: settings, liveOn: liveOn,
                                client: client, lessons: lessons)
        self.mode = mode
        self.liveOn = liveOn
        liveProvider = settings.provider
        liveSwitchedOff = false
    }

    /// Capture failed to start, so nothing was started either.
    func discard() {
        live = nil
        liveOn = false
        liveSwitchedOff = false
        began = false
    }

    /// Capture is running: start the live work, the consent reminder and the panel.
    func begin() {
        guard let live, let model else { return }
        let settings = model.settings
        let session = live.latestSession()
        reset()
        began = true
        briefCard = BriefCardExpansion(profile: session.profile)
        // v2: gated on the settings, not on the session: the calendar read at start can save the event (and then
        // brief.json) a few seconds after this runs.
        briefCheckUntil = settings.briefEnabled && settings.useCalendar
            ? Date().addingTimeInterval(Self.briefWaitSeconds) : nil
        startDecision = decision(settings)
        let shown = settings.showLivePanel
        switch ConsentPolicy.delivery(settings: settings, panelShown: shown) {
        case .banner?: consent = Consent(line: ConsentPolicy.line(settings: settings), shownAt: Date(),
                                         startedBy: session.startedBy)
        case .notification?: break  // v2: B3's recordingDidStart posts it, with the Copy consent line action
        case nil: break
        }
        eventsTask = Task { [weak self] in
            for await event in live.events { self?.apply(event) }
        }
        Task { await live.start() }
        startClock()
        if shown { panel.show(hidingFromCapture: settings.hidePanelFromCapture) }
        model.livePanelVisible = shown
    }

    /// The recording stopped. Never blocks Stop: the transcribers finish and live.json is saved in the background,
    /// within `LiveSession.defaultStopLimit`, and Start runs already going carry on. Live to-dos still queued go
    /// back to suggested (spec 4.4), so the notes after the call offer them and they never go out twice; the
    /// returned task finishes once they have, and the meeting's pipeline waits for it.
    @discardableResult
    func end() -> Task<Void, Never>? {
        guard let live else { return nil }
        live.hold()  // at once, so nothing queued starts between Stop and the take-back
        self.live = nil
        began = false
        briefCheckUntil = nil
        eventsTask?.cancel()
        eventsTask = nil
        clock?.invalidate()
        clock = nil
        panel.hide()
        model?.livePanelVisible = false
        reset()
        liveOn = false
        liveSwitchedOff = false
        let id = live.sessionID
        finishing[id] = live
        let takenBack = Task { await live.takeBackQueued() }
        Task { [weak self] in
            await takenBack.value
            await live.stop()
            await live.waitUntilIdle()
            await live.close()
            self?.finishing[id] = nil
        }
        return takenBack
    }

    private func reset() {
        items = []
        status = nil
        tickerMe = ""
        tickerThem = ""
        flagNote = nil
        brief = nil
        layout = .full
        consent = nil
        pressedAt = [:]
        sheet = nil
        hovered = nil
        transcriptionProblem = nil
        saveProblem = nil
        elapsed = 0
        startDecision = nil
        // Not liveSwitchedOff: a switch-off between prepare() and begin() must still show in the panel.
    }

    // MARK: Quitting

    /// Live Start runs that would be cut off by quitting and are never sent again on their own (Claude Code, a
    /// command), as labels for the quit warning.
    func busyTargetLabels() -> [String] {
        guard let model else { return [] }
        let sessions = [live].compactMap { $0 } + Array(finishing.values)
        let ids = Set(sessions.flatMap { $0.busyTargetIDs() })
        guard !ids.isEmpty else { return [] }
        let known = Dictionary(model.settings.targets(secrets: model.keychain).map { ($0.id, $0) },
                               uniquingKeysWith: { first, _ in first })
        return ids.sorted().compactMap { known[$0]?.repeatsSafely == true ? nil : known[$0]?.label ?? $0 }
    }

    /// How many live to-dos the busy targets are working on, for the quit warning's words.
    func busyItemCount() -> Int {
        ([live].compactMap { $0 } + Array(finishing.values))
            .flatMap { $0.store.items }.filter { [.sending, .running].contains($0.status) }.count
    }

    /// True while a live Start is queued, being sent or running, or a stopped recording's live work is still
    /// finishing (the transcribers' last words and the live.json save).
    var hasLiveWork: Bool {
        !finishing.isEmpty || ([live].compactMap { $0 }).contains { $0.hasPendingWork() }
    }

    /// Before quitting stops the programs Earshot started: no live job starts from now on, so a run that is stopped
    /// can't pull the next queued to-do out. `finishBeforeQuit()` then takes those back.
    func holdQueues() {
        for session in [live].compactMap({ $0 }) + Array(finishing.values) { session.hold() }
    }

    /// Called after the user chose to quit and the recording was stopped: takes back what hasn't gone out, then
    /// waits a few seconds for the stop's save and for sends already going, so live.json records how they ended.
    func finishBeforeQuit() async {
        let sessions = Array(finishing.values)
        for session in sessions { await session.cancelQueued() }
        await LiveSession.within(Self.quitLimit) {
            for session in sessions {
                await session.stop()
                await session.waitUntilIdle()
            }
        }
    }

    // MARK: Events and the clock

    private func apply(_ event: LiveEvent) {
        switch event {
        case let .items(items):
            self.items = items
            // A press is forgotten once its item has moved past queued (an older list may still say suggested).
            pressedAt = pressedAt.filter { id, _ in
                [.queued, .suggested].contains(items.first { $0.id == id }?.status ?? .queued)
            }
        case let .status(status):
            if liveOn { self.status = status }
        case let .ticker(me, them):
            guard liveOn else { return }
            tickerMe = me
            tickerThem = them
        case let .flagged(flag):
            flagNote = LivePanelText.flagged(at: flag.offset)
            flagNoteUntil = Date().addingTimeInterval(Self.flagNoteSeconds)
        case let .transcriptionFailed(reason):
            guard liveOn else { return }
            transcriptionProblem = "Live transcription couldn't start: \(reason)"
        }
    }

    private func startClock() {
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        clock = timer
        tick()
    }

    private func tick() {
        let now = Date()
        self.now = now
        elapsed = model?.elapsed ?? 0
        if flagNote != nil, now >= flagNoteUntil { flagNote = nil }
        if let consent, !ConsentPolicy.bannerVisible(startedBy: consent.startedBy, shownAt: consent.shownAt, now: now,
                                                      dismissed: false) {
            self.consent = nil
        }
        if let live { saveProblem = live.store.lastError == nil ? nil : LivePanelText.couldNotSave }
        checkBrief(now)
    }

    /// brief.json is looked for every few seconds, off the main actor, only when this meeting gets a brief (briefs
    /// are on and it has a calendar event), and only for the first minutes of the recording.
    private func checkBrief(_ now: Date) {
        guard brief == nil, let until = briefCheckUntil, let live else { return }
        guard now < until else {
            briefCheckUntil = nil
            return
        }
        guard now >= nextBriefCheck else { return }
        nextBriefCheck = now.addingTimeInterval(Self.briefCheckSeconds)
        Task { [weak self] in
            let (found, profile) = await Task.detached { (live.readBrief(), live.latestSession().profile) }.value
            guard let self, let found, self.live === live else { return }
            // The brief is written after the calendar read saves the profile, so the profile is known by now.
            briefCard.profileKnown(profile)
            self.brief = found
        }
    }

    /// The calendar read at the start saved an event and profile for `sessionID` (ContextController).
    func profileChanged(sessionID: String, profile: MeetingProfile?) {
        guard let live, live.sessionID == sessionID else { return }
        briefCard.profileKnown(profile)
    }

    // MARK: Helpers

    /// Nil unless the live assistant runs for this Notes + Do recording. The target follows `LiveTargetChoice`: a
    /// chosen target that is off gives way to the first working one.
    func decision(_ settings: EarshotSettings) -> LiveStartPolicy.Decision? {
        guard let model, liveOn, settings.liveAssistant, mode == .notesAndDo else { return nil }
        return LiveStartPolicy.decision(settings: settings, targets: settings.targets(secrets: model.keychain))
    }

    /// Built outside the main actor: the transcribers' clock and the capture feed are called from other threads
    /// (spec 17).
    nonisolated private static func makeSession(capture: CaptureSession, session: Session, store: SessionStore,
                                                settings: EarshotSettings, liveOn: Bool, client: (any ClaudeClient)?,
                                                lessons: [Lesson]) -> LiveSession {
        let locale = Locale(identifier: settings.localeIdentifier)
        let transcribers: [any LiveTranscribing] = liveOn ? [Track.me, .them].map { track in
            LiveTranscriber(track: track, locale: locale, firstHostTime: { capture.firstHostTime })
        } : []
        if !transcribers.isEmpty { capture.liveFeed = LiveSession.feed(for: transcribers) }
        return LiveSession(store: store, session: session, transcribers: transcribers, client: client,
                           settings: settings, lessons: lessons, offset: { capture.currentOffset() })
    }
}
