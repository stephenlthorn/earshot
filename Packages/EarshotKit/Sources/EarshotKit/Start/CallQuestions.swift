import Foundation

/// The call questions waiting for an answer, and which recording Earshot may stop on its own (spec 7.2). The App's
/// CallController only connects this to notifications, the menu and the MicActivityMonitor.
///
/// A recording started by hand is never stopped automatically: only one started for a call (`startedBy == .auto`
/// with a call) is, and only while it is the recording running.
public struct CallQuestions: Equatable, Sendable {
    /// What an answer asks the App to do.
    public enum Action: Equatable, Sendable {
        case startRecording(CallEvent.Call)
        case stop(sessionID: String)
        /// Keep recording: the monitor stops asking and won't give up on this recording (`MicActivityMonitor.keepRecording`).
        case keepRecording(sessionID: String)
        case none
    }

    /// What a recording start means for call detection.
    public struct Started: Equatable, Sendable {
        /// True when Earshot may stop this recording when the call ends.
        public var byEarshot: Bool
        /// Notifications to take down: no question applies once a recording runs.
        public var removeIDs: [String]
    }

    /// What the MicActivityMonitor is told about the running recording.
    public struct MonitorState: Equatable, Sendable {
        public var call: CallEvent.Call?
        public var startedByEarshot: Bool
        public var eventEnd: Date?

        public init(call: CallEvent.Call?, startedByEarshot: Bool, eventEnd: Date?) {
            self.call = call
            self.startedByEarshot = startedByEarshot
            self.eventEnd = eventEnd
        }
    }

    /// Questions sent as notifications, by prompt id, so a button press finds its call.
    public private(set) var asked: [String: CallPrompt] = [:]
    /// The question shown in the menu, with the menu bar badge, because notifications don't reach the user.
    public private(set) var prompt: CallPrompt?
    /// The call the running recording follows. The screen reader captures its windows.
    public private(set) var activeCall: CallEvent.Call?
    /// The recording running, if any.
    public private(set) var sessionID: String?
    /// The recording Earshot started for a call. Only it is ever stopped automatically.
    public private(set) var autoSessionID: String?
    /// The end of the running recording's calendar event.
    public private(set) var eventEnd: Date?

    public init() {}

    /// True while a question waits in the menu: the menu bar icon shows a badge.
    public var showsBadge: Bool { prompt != nil }

    // MARK: Recording

    /// A recording started. Every question is cleared, since none of them applies any more.
    public mutating func recordingStarted(session: Session, call: CallEvent.Call?) -> Started {
        let byEarshot = session.startedBy == .auto && call != nil
        let removeIDs = asked.values.map { NotificationRoute.ID.prompt($0.id) }
        asked = [:]
        prompt = nil
        activeCall = call
        sessionID = session.id
        autoSessionID = byEarshot ? session.id : nil
        eventEnd = session.calendarEvent?.end
        return Started(byEarshot: byEarshot, removeIDs: removeIDs)
    }

    /// The recording stopped. Returns the notifications that no longer apply: its Stop questions, its "Recording your
    /// call" notice and its consent reminder. A Record question stays.
    public mutating func recordingStopped() -> [String] {
        let stale = asked.values.filter { $0.kind == .stop }
        var removeIDs = stale.map { NotificationRoute.ID.prompt($0.id) }
        if let sessionID {
            removeIDs += [NotificationRoute.ID.recording(session: sessionID), NotificationRoute.ID.consent(session: sessionID)]
        }
        stale.forEach { asked[$0.id] = nil }
        if prompt?.kind == .stop { prompt = nil }
        activeCall = nil
        sessionID = nil
        autoSessionID = nil
        eventEnd = nil
        return removeIDs
    }

    /// The monitor's view of the running recording, or nil with none.
    public var monitorState: MonitorState? {
        guard sessionID != nil else { return nil }
        let byEarshot = autoSessionID != nil
        return MonitorState(call: byEarshot ? activeCall : nil, startedByEarshot: byEarshot, eventEnd: eventEnd)
    }

    /// The calendar read at start found another event for `sessionID`. Returns what to tell the monitor when that is
    /// the running recording and Earshot may stop it; otherwise nil (nothing to stop, so nothing to tell).
    public mutating func eventChanged(sessionID: String, end: Date?) -> MonitorState? {
        guard self.sessionID == sessionID else { return nil }
        eventEnd = end
        return autoSessionID == sessionID ? monitorState : nil
    }

    /// The recording a call's end may stop or ask about: Earshot's own, while it is `current`.
    public func autoStopSession(current: String?) -> String? {
        guard let autoSessionID, autoSessionID == current else { return nil }
        return autoSessionID
    }

    /// Stop acts only on the recording it names, while that recording runs.
    public static func canStop(sessionID: String?, current: String?) -> Bool {
        guard let sessionID else { return false }
        return sessionID == current
    }

    // MARK: Questions

    /// Keeps `question` until it is answered. Returns the notification id to post it under, or nil when it is shown
    /// in the menu instead.
    public mutating func ask(_ question: CallPrompt, byNotification: Bool) -> String? {
        guard byNotification else {
            prompt = question
            return nil
        }
        asked[question.id] = question
        return NotificationRoute.ID.prompt(question.id)
    }

    /// The menu question `promptID` went stale. A newer one stays.
    public mutating func expire(promptID: String) {
        if prompt?.id == promptID { prompt = nil }
    }

    /// Record or Stop (`yes`), Not now or Keep recording. The question is forgotten either way. Record starts the
    /// call only while the question is current and nothing records; Stop names its recording, which the App stops
    /// only if `canStop` says so. Keep recording names it too, so only that recording is kept going.
    public mutating func answer(id: String, yes: Bool, now: Date, isRecording: Bool) -> Action {
        let found = asked.removeValue(forKey: id) ?? (prompt?.id == id ? prompt : nil)
        if prompt?.id == id { prompt = nil }
        guard let found else { return .none }
        guard yes else {
            guard found.kind == .stop, let session = found.sessionID, session == sessionID else { return .none }
            return .keepRecording(sessionID: session)
        }
        switch found.kind {
        case .record:
            // A notification left in Notification Center can be pressed long after the call ended.
            guard found.isCurrent(now: now), !isRecording else { return .none }
            return .startRecording(found.call)
        case .stop:
            return found.sessionID.map { .stop(sessionID: $0) } ?? .none
        }
    }

    /// "Notice calls" was turned off: the Record questions go. Returns their notification ids.
    public mutating func watchingStopped() -> [String] {
        let dropped = asked.values.filter { $0.kind == .record }
        dropped.forEach { asked[$0.id] = nil }
        if prompt?.kind == .record { prompt = nil }
        return dropped.map { NotificationRoute.ID.prompt($0.id) }
    }
}
