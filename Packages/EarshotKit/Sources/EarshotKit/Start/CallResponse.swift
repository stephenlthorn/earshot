import Foundation

/// What Earshot does about a call it noticed (spec 7.2).
public enum CallResponse: Equatable, Sendable {
    /// "Notice calls" is off.
    case ignore
    /// Start recording now and say so ("Recording your <App> call", with Stop).
    case autoRecord
    /// Ask with a notification: Record or Not now.
    case askByNotification
    /// Notifications aren't allowed: ask in the menu, with a badge on the menu bar icon.
    case askInApp

    public static func decide(_ call: CallEvent.Call, settings: EarshotSettings, event: CalendarEventInfo?,
                              notificationsAuthorized: Bool) -> CallResponse {
        guard settings.noticeCalls else { return .ignore }
        let videoLink = event.map(VideoLinks.contains) ?? false
        if CallNoticePolicy.shouldAutoRecord(call, autoRecordOn: settings.autoRecordCalls, eventHasVideoLink: videoLink,
                                             notificationsAuthorized: notificationsAuthorized,
                                             panelOn: settings.showLivePanel) {
            return .autoRecord
        }
        return notificationsAuthorized ? .askByNotification : .askInApp
    }
}

/// The words of call notices and the recording reminder. Plain and short, with no dashes.
public enum CallTexts {
    public static func ask(_ app: String) -> String { "\(app) is using your microphone. Record this call?" }
    public static func recording(_ app: String) -> String { "Recording your \(app) call" }
    public static let askToStop = "The call seems to have ended. Stop recording?"
    public static let consentTitle = "Recording. Let everyone know."
}

/// A question about a call waiting for the user: Record this call, or Stop recording. It is shown as a notification,
/// or in the menu (with a badge on the menu bar icon) when notifications aren't allowed. Its id ties a button press
/// to this question, so a stale notification never acts on a newer call or recording.
public struct CallPrompt: Equatable, Sendable, Identifiable {
    public enum Kind: Equatable, Sendable { case record, stop }

    /// A question older than this is stale: the call has most likely moved on.
    public static let lifetime: TimeInterval = CallNoticePolicy.quietPeriod

    public var id: String
    public var kind: Kind
    public var call: CallEvent.Call
    /// The recording a Stop question is about.
    public var sessionID: String?
    public var createdAt: Date

    public init(id: String = UUID().uuidString, kind: Kind, call: CallEvent.Call, sessionID: String?, createdAt: Date) {
        self.id = id
        self.kind = kind
        self.call = call
        self.sessionID = sessionID
        self.createdAt = createdAt
    }

    public var text: String {
        switch kind {
        case .record: CallTexts.ask(call.appName)
        case .stop: CallTexts.askToStop
        }
    }

    public func isCurrent(now: Date) -> Bool {
        now.timeIntervalSince(createdAt) < Self.lifetime
    }
}

/// The call app using the microphone right now, for a recording started by hand: the screen reader follows it.
public enum CallMatch {
    /// A call app (other than Earshot) with input running on a real microphone. Dedicated call apps win, then the
    /// lowest pid, so the answer is stable.
    public static func activeCall(_ snapshot: [AudioProcessInfo], runningApps: [String: String],
                                  ownPID: Int32) -> CallEvent.Call? {
        snapshot.filter { $0.pid != ownPID && $0.runningInput && $0.usesRealMicrophone }
            .compactMap { info -> CallEvent.Call? in
                guard let bundleID = info.bundleID, let name = MeetingApps.match(bundleID, runningApps: runningApps) else {
                    return nil
                }
                return CallEvent.Call(pid: info.pid, bundleID: bundleID, appName: name,
                                      isDedicated: MeetingApps.isDedicatedCallApp(bundleID))
            }
            .min { $0.isDedicated != $1.isDedicated ? $0.isDedicated : $0.pid < $1.pid }
    }
}

/// When the screen is read and what it follows (spec 9).
public enum ScreenReading {
    /// Only with "Read my screen during calls" on and Screen Recording allowed.
    public static func shouldRun(settings: EarshotSettings, hasPermission: Bool) -> Bool {
        settings.readScreen && hasPermission
    }

    /// The bundle prefix whose windows the capturer takes: the call app's matched prefix (Safari for its WebKit
    /// helpers, the browser for its helpers), or nil without a call app, so nothing is captured.
    public static func appPrefix(for call: CallEvent.Call?) -> String? {
        call.map { MeetingApps.appKey(for: $0.bundleID) ?? $0.bundleID }
    }

    public static func options(settings: EarshotSettings) -> ScreenSampler.Options {
        ScreenSampler.Options(wholeDisplay: settings.screenWholeDisplay, keepImages: settings.keepScreenshots)
    }
}
