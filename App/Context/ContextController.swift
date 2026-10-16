import EarshotKit
import Foundation
import Observation
import os

/// The calendar (spec 5): while "Use my calendar" is on, it reads the event happening now at most every 60 s while
/// the menu is idle, when the menu opens and at recording start. A new event preselects its profile's mode and names
/// the meeting when Title is left blank; once the event is over, a mode the user left alone goes back to the default.
/// At recording start it saves the event and profile and writes the brief in the background, so the start never waits
/// for the calendar or Claude. Decisions are in EarshotKit (`CurrentEventTracker`, `RecordingStart`, `BriefJob`).
@MainActor @Observable
final class ContextController {
    private(set) var tracker = CurrentEventTracker()
    /// The brief for the recording in progress, once written. The live panel shows it.
    private(set) var brief: MeetingBrief?

    /// "Now: <title> · <profile>" for the menu. An event that ended since the last read isn't shown.
    var nowLine: String? { tracker.menuLine(now: Date()) }
    /// The event's title, shown in the empty Title field.
    var titlePlaceholder: String? { tracker.titlePlaceholder(now: Date()) }
    /// The event happening now, if the calendar is on: the last one read, while it still overlaps now.
    var event: CalendarEventInfo? {
        model?.settings.useCalendar == true ? tracker.current(now: Date()) : nil
    }

    @ObservationIgnored private weak var model: AppModel?
    @ObservationIgnored private let source = EventKitCalendarSource()
    @ObservationIgnored private var poll: Task<Void, Never>?
    @ObservationIgnored private var reading = false
    /// A forced read (the menu opened, access was granted) arrived during a read: one more runs after it.
    @ObservationIgnored private var pendingForce = false
    /// The calendar read and brief for the recording in progress. Cancelled at Stop.
    @ObservationIgnored private var startJob: Task<Void, Never>?
    /// The recording the brief being written belongs to.
    @ObservationIgnored private var briefSessionID: String?
    @ObservationIgnored private let log = Logger(subsystem: "com.stephenthorn.earshot", category: "calendar")

    func attach(_ model: AppModel) {
        self.model = model
        apply()
    }

    /// Follows "Use my calendar": polling while it is on; nothing kept while it is off.
    func apply() {
        guard let model, !sampleOnly else { return }
        guard model.settings.useCalendar else {
            poll?.cancel()
            poll = nil
            // No event is current any more: a mode still as it was preselected goes back to the default, now when idle,
            // or at the next idle point (`restoreWhenIdle`) during a recording or a start.
            let idle = !model.isRecording && !model.isStarting
            if let mode = tracker.calendarTurnedOff(currentMode: model.mode, settings: model.settings, canRestore: idle) {
                model.mode = mode
            }
            return
        }
        guard poll == nil else { return }
        poll = Task { [weak self] in
            while !Task.isCancelled {
                await self?.read(force: false)
                try? await Task.sleep(for: .seconds(CurrentEvent.pollInterval))
            }
        }
    }

    // v2: screenshots. A sample event as if just read, for the menu's "Now:" line. From then on the controller is
    // sample-only: it never reads the calendar or polls, even if something attaches it to a model.
    @ObservationIgnored private var sampleOnly = false

    func showSample(_ event: CalendarEventInfo, settings: EarshotSettings, now: Date) {
        sampleOnly = true
        poll?.cancel()
        poll = nil
        _ = tracker.observe(event, settings: settings, now: now, canPreselect: false)
    }

    /// The menu opened: read now. With the calendar off, a restore left over from a recording or a start runs.
    func menuOpened() {
        if let model, !model.isRecording, !model.isStarting { restoreWhenIdle() }
        Task { await read(force: true) }
    }

    /// With the calendar off, a mode preselected before it was turned off and still left alone goes back to the
    /// default (`CurrentEventTracker.calendarTurnedOff`). With it on, the next idle read does this.
    private func restoreWhenIdle() {
        guard let model, !model.settings.useCalendar, !sampleOnly else { return }
        if let mode = tracker.restoreDefault(currentMode: model.mode, settings: model.settings) {
            model.mode = mode
        }
    }

    /// The current authorization, without asking.
    func authorization() async -> CalendarAuthorization {
        await source.authorization()
    }

    /// Asks for full access to events (once; macOS remembers the answer), then reads.
    func requestAccess() async -> CalendarAuthorization {
        let answer = await source.requestAccess()
        if let problem = await source.lastAccessError() {
            log.error("Calendar access request failed: \(problem, privacy: .public)")
        }
        await read(force: true)
        return answer
    }

    /// The event a recording starts with: the last one read (the menu read it as it opened, or the poll did), only
    /// while it is still current.
    var eventForStart: CalendarEventInfo? { event }

    private func read(force: Bool) async {
        guard let model, model.settings.useCalendar, !sampleOnly else { return }
        guard !reading else {
            pendingForce = pendingForce || force
            return
        }
        let idle = !model.isRecording && !model.isStarting
        guard force || tracker.shouldPoll(now: Date(), idle: idle) else { return }
        reading = true
        await readOnce(model)
        // A read that began before access was granted found nothing; the forced one waiting runs now.
        while pendingForce {
            pendingForce = false
            await readOnce(model)
        }
        reading = false
    }

    private func readOnce(_ model: AppModel) async {
        let event = await CurrentEvent.fetch(from: source, now: Date())
        guard model.settings.useCalendar else { return }  // turned off while reading
        let canPreselect = !model.isRecording && !model.isStarting
        // A new event preselects its mode; once no event is current, a mode the user left alone goes back to the
        // default (`CurrentEventTracker`).
        if let mode = tracker.observe(event, settings: model.settings, now: Date(), canPreselect: canPreselect,
                                      currentMode: model.mode) {
            model.mode = mode
        }
    }

    // MARK: Recording

    /// After capture started: reads the calendar again and saves a newer event with its profile (or drops one that
    /// has ended), then writes the brief when it should be written. All of it runs off the main actor, a failure is
    /// only logged, and Stop cancels it, so nothing is written for a meeting that has stopped.
    func recordingStarted(_ session: Session, store: SessionStore, settings: EarshotSettings, secrets: KeychainStore,
                          index: LibraryIndex) {
        brief = nil
        briefSessionID = session.id
        startJob?.cancel()
        startJob = nil
        guard settings.useCalendar else { return }
        let source = source, log = log
        startJob = Task.detached { [weak self] in
            let canRead = await source.authorization().canRead
            let now = Date()
            let fresh = canRead ? await CurrentEvent.fetch(from: source, now: now) : nil
            if !Task.isCancelled, let found = RecordingStart.refreshed(session, fresh: fresh, canRead: canRead, now: now,
                                                                       settings: settings) {
                do {
                    let saved = try store.update(session.id) { found.apply(to: &$0) }
                    if saved.calendarEvent == found.event {
                        await self?.eventChanged(sessionID: session.id, end: found.event?.end, profile: found.profile)
                    }
                } catch {
                    log.error("Couldn't save the calendar event: \(error.localizedDescription, privacy: .public)")
                }
            }
            guard !Task.isCancelled else { return }
            let job = BriefJob(store: store, library: MeetingLibrary(index: index, store: store),
                               settings: settings, makeClient: { try settings.claudeClient(secrets: secrets) })
            let outcome = await job.run(sessionID: session.id)
            switch outcome {
            case let .written(brief): await self?.show(brief, for: session.id)
            case .skipped: break
            case let .failed(reason): log.error("The brief failed: \(reason, privacy: .public)")
            }
        }
    }

    func recordingStopped() {
        restoreWhenIdle()  // the recording is over: the next idle point
        brief = nil
        briefSessionID = nil
        startJob?.cancel()
        startJob = nil
    }

    private func eventChanged(sessionID: String, end: Date?, profile: MeetingProfile) {
        model?.calls.eventChanged(sessionID: sessionID, end: end)
        model?.liveController.profileChanged(sessionID: sessionID, profile: profile)  // the brief card follows it
    }

    private func show(_ brief: MeetingBrief, for sessionID: String) {
        guard briefSessionID == sessionID else { return }
        self.brief = brief
    }
}
