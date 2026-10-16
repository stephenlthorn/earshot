import AppKit
import EarshotKit
import Foundation
import Observation
import os

/// Noticing calls (spec 7): while "Notice calls" is on, a MicActivityMonitor watches which apps use the microphone.
/// A call is asked about with a notification (Record or Not now), or in the menu with a badge on the menu bar icon
/// when notifications aren't allowed, or recorded at once when "Start automatically" allows it. Recordings Earshot started stop, or ask
/// to, when the call ends. Every decision is in EarshotKit (`CallQuestions`, `CallResponse`,
/// `CallNoticePolicy`, `AutoStopPolicy`).
@MainActor @Observable
final class CallController {
    /// The questions waiting and which recording Earshot may stop (EarshotKit `CallQuestions`).
    private(set) var questions = CallQuestions()

    /// The question waiting in the menu, with the menu bar badge, because notifications don't reach the user.
    var prompt: CallPrompt? { questions.prompt }
    /// The call the current recording follows. The screen reader captures its windows.
    var activeCall: CallEvent.Call? { questions.activeCall }
    var showsBadge: Bool { questions.showsBadge }

    @ObservationIgnored private weak var model: AppModel?
    @ObservationIgnored private var monitor: MicActivityMonitor?
    @ObservationIgnored private var consumer: Task<Void, Never>?
    /// The last message to the monitor. Each waits for the one before, so a short recording's start and stop arrive
    /// in order.
    @ObservationIgnored private var lastMessage: Task<Void, Never>?
    @ObservationIgnored private var expiry: Task<Void, Never>?
    @ObservationIgnored private let log = Logger(subsystem: "com.stephenthorn.earshot", category: "calls")

    func attach(_ model: AppModel) {
        self.model = model
        apply()
    }

    /// Follows "Notice calls": watching while it is on, nothing while it is off.
    func apply() {
        guard let model else { return }
        if model.settings.noticeCalls { startWatching() } else { stopWatching() }
    }

    // MARK: Recording

    func recordingStarted(_ session: Session, call: CallEvent.Call?, settings: EarshotSettings) {
        expiry?.cancel()
        let started = questions.recordingStarted(session: session, call: call)
        EarshotNotifications.remove(ids: started.removeIDs)
        tellRecording(stopWhenCallEnds: settings.autoStopCalls)
    }

    func recordingStopped() {
        EarshotNotifications.remove(ids: questions.recordingStopped())
        tell { await $0.recordingStopped() }
    }

    /// The calendar read at start found another event for `sessionID`: auto-stop follows its end.
    func eventChanged(sessionID: String, end: Date?) {
        guard let model, let state = questions.eventChanged(sessionID: sessionID, end: end) else { return }
        tell(state, stopWhenCallEnds: model.settings.autoStopCalls)
    }

    // MARK: Answers

    /// Record or Not now, Stop or Keep recording, from a notification or the menu.
    func answer(promptID: String, yes: Bool) async {
        guard let model else { return }
        switch questions.answer(id: promptID, yes: yes, now: Date(), isRecording: model.isRecording) {
        case let .startRecording(call): await model.startRecording(trigger: .auto, call: call)
        case let .stop(sessionID): stop(sessionID: sessionID)
        case let .keepRecording(sessionID):
            guard CallQuestions.canStop(sessionID: sessionID, current: model.currentSessionID) else { return }
            tell { await $0.keepRecording() }
        case .none: break
        }
    }

    /// Stops the recording `sessionID`, only while it is the one running.
    func stop(sessionID: String?) {
        guard let model, CallQuestions.canStop(sessionID: sessionID, current: model.currentSessionID) else { return }
        model.stopRecording()
    }

    // MARK: Watching

    private func startWatching() {
        guard let model, monitor == nil else { return }
        let monitor = MicActivityMonitor(runningApps: { await MainActor.run { CallController.runningApps() } })
        self.monitor = monitor
        consumer = Task { [weak self] in
            for await event in monitor.events {
                await self?.handle(event)
            }
        }
        // Turned on during a recording: the monitor hears about it before its first check, so the call already
        // running isn't taken for a new one, and a recording Earshot started can still stop when the call ends.
        if model.isRecording { tellRecording(stopWhenCallEnds: model.settings.autoStopCalls) }
        tell { await $0.start() }
    }

    private func tellRecording(stopWhenCallEnds: Bool) {
        guard let state = questions.monitorState else { return }
        tell(state, stopWhenCallEnds: stopWhenCallEnds)
    }

    private func tell(_ state: CallQuestions.MonitorState, stopWhenCallEnds: Bool) {
        tell { await $0.recordingStarted(call: state.call, startedByEarshot: state.startedByEarshot,
                                         eventEnd: state.eventEnd, stopWhenCallEnds: stopWhenCallEnds) }
    }

    private func tell(_ message: @escaping @Sendable (MicActivityMonitor) async -> Void) {
        guard let monitor else { return }
        let previous = lastMessage
        lastMessage = Task {
            await previous?.value
            await message(monitor)
        }
    }

    private func stopWatching() {
        monitor?.finish()
        monitor = nil
        consumer?.cancel()
        consumer = nil
        EarshotNotifications.remove(ids: questions.watchingStopped())
    }

    private func handle(_ event: CallEvent) async {
        guard let model else { return }
        let reaches = await EarshotNotifications.authorized()
        switch event {
        case let .started(call):
            // Pressing Record by hand can race the monitor hearing about it.
            guard !model.isRecording, !model.isStarting else { return }
            let response = CallResponse.decide(call, settings: model.settings, event: model.context.event,
                                               notificationsAuthorized: reaches)
            log.info("Call noticed: \(call.appName, privacy: .public), \(String(describing: response), privacy: .public)")
            switch response {
            case .ignore: break
            case .autoRecord: await autoRecord(call, model: model)
            case .askByNotification, .askInApp:
                ask(CallPrompt(kind: .record, call: call, sessionID: nil, createdAt: Date()), byNotification: reaches,
                    model: model)
            }
        case let .askToStop(call):
            guard let id = questions.autoStopSession(current: model.currentSessionID) else { return }
            ask(CallPrompt(kind: .stop, call: call, sessionID: id, createdAt: Date()), byNotification: reaches,
                model: model)
        case .stop:
            guard let id = questions.autoStopSession(current: model.currentSessionID) else { return }
            log.info("The call ended; stopping the recording.")
            stop(sessionID: id)
        }
    }

    private func autoRecord(_ call: CallEvent.Call, model: AppModel) async {
        await model.startRecording(trigger: .auto, call: call)
        guard let id = questions.autoStopSession(current: model.currentSessionID), !model.e2e else { return }
        EarshotNotifications.post(id: NotificationRoute.ID.recording(session: id), title: CallTexts.recording(call.appName),
                                  category: .callRecording, userInfo: [NotificationRoute.Key.session: id])
    }

    private func ask(_ question: CallPrompt, byNotification: Bool, model: AppModel) {
        guard let id = questions.ask(question, byNotification: byNotification && !model.e2e) else {
            expireLater(question)
            return
        }
        var info = [NotificationRoute.Key.prompt: question.id]
        if let session = question.sessionID { info[NotificationRoute.Key.session] = session }
        EarshotNotifications.post(id: id, title: question.text,
                                  category: question.kind == .record ? .callNotice : .callEnded, userInfo: info)
    }

    /// Takes the menu question down once it goes stale.
    private func expireLater(_ question: CallPrompt) {
        expiry?.cancel()
        expiry = Task { [weak self] in
            try? await Task.sleep(for: .seconds(CallPrompt.lifetime))
            guard !Task.isCancelled else { return }
            self?.questions.expire(promptID: question.id)
        }
    }

    /// Running apps' bundle ids and names, for call app names and the Safari rule. Regular apps only, as
    /// `MeetingApps.match` asks.
    static func runningApps() -> [String: String] {
        Dictionary(NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }
            .compactMap { app in app.bundleIdentifier.map { ($0, app.localizedName ?? $0) } },
                   uniquingKeysWith: { first, _ in first })
    }
}
