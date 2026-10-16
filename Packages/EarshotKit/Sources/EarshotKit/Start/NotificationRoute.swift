import Foundation

/// Earshot's notification categories and buttons, and what a press means (spec 7.2, 7.4). The App registers the
/// categories and turns each response into a `Command` here, so the rules are tested without UserNotifications.
public enum NotificationRoute {
    public enum Category: String, CaseIterable, Sendable {
        /// "<App> is using your microphone. Record this call?"
        case callNotice = "earshot.call.notice"
        /// "Recording your <App> call"
        case callRecording = "earshot.call.recording"
        /// "The call seems to have ended. Stop recording?"
        case callEnded = "earshot.call.ended"
        /// "Recording. Let everyone know."
        case consent = "earshot.consent"

        public var actions: [Action] {
            switch self {
            case .callNotice: [.record, .notNow]
            case .callRecording: [.stop]
            case .callEnded: [.stop, .keepRecording]
            case .consent: [.copyLine]
            }
        }
    }

    public enum Action: String, CaseIterable, Sendable {
        case record = "earshot.record"
        case notNow = "earshot.not-now"
        case stop = "earshot.stop"
        case keepRecording = "earshot.keep-recording"
        case copyLine = "earshot.copy-line"

        public var title: String {
            switch self {
            case .record: "Record"
            case .notNow: "Not now"
            case .stop: "Stop"
            case .keepRecording: "Keep recording"
            case .copyLine: "Copy consent line"
            }
        }
    }

    /// userInfo keys. Values are strings.
    public enum Key {
        /// The `CallPrompt` id a Record, Not now or Keep recording press answers.
        public static let prompt = "prompt"
        /// The recording a Stop press is for.
        public static let session = "session"
        /// A file or folder to open when the notification is clicked.
        public static let path = "path"
    }

    /// Notification ids, so the App can take a notification down once it no longer applies.
    public enum ID {
        /// A call question (Record this call, or Stop recording).
        public static func prompt(_ id: String) -> String { "earshot.call.prompt.\(id)" }
        /// "Recording your <App> call".
        public static func recording(session: String) -> String { "earshot.call.recording.\(session)" }
        /// "Recording. Let everyone know."
        public static func consent(session: String) -> String { "earshot.consent.\(session)" }
    }

    /// True when a notification reaches the user (spec 7.2): notifications are allowed and show a banner or alert.
    /// Provisional ones are delivered quietly to Notification Center, so they don't count.
    public static func reachesUser(allowed: Bool, provisional: Bool, alertsShown: Bool) -> Bool {
        allowed && !provisional && alertsShown
    }

    public enum Command: Equatable, Sendable {
        case record(prompt: String)
        case dismiss(prompt: String)
        case stop(session: String)
        case copyConsentLine
        case open(path: String)
        case none
    }

    /// What a press means. A click on the notification itself opens its path, or copies the consent line; it never
    /// records or stops. A button whose id is missing does nothing, so an old notification can't act on a new call.
    public static func command(category: String, action: String, userInfo: [String: String]) -> Command {
        let prompt = userInfo[Key.prompt], session = userInfo[Key.session]
        switch (Category(rawValue: category), Action(rawValue: action)) {
        case (.callNotice?, .record?): return prompt.map { .record(prompt: $0) } ?? .none
        case (.callNotice?, .notNow?), (.callEnded?, .keepRecording?): return prompt.map { .dismiss(prompt: $0) } ?? .none
        case (.callRecording?, .stop?), (.callEnded?, .stop?): return session.map { .stop(session: $0) } ?? .none
        case (.consent?, _): return .copyConsentLine
        case (_, nil): return userInfo[Key.path].map { .open(path: $0) } ?? .none
        default: return .none
        }
    }
}
