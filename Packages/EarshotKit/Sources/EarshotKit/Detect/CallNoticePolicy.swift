import Foundation

/// What call detection tells the app.
public enum CallEvent: Equatable, Sendable {
    /// The call app noticed, by the process that started using the microphone.
    public struct Call: Equatable, Hashable, Sendable {
        public var pid: Int32
        public var bundleID: String
        /// What the user sees, such as "zoom.us" or "Google Chrome".
        public var appName: String
        public var isDedicated: Bool

        public init(pid: Int32, bundleID: String, appName: String, isDedicated: Bool) {
            self.pid = pid
            self.bundleID = bundleID
            self.appName = appName
            self.isDedicated = isDedicated
        }
    }

    /// A call app started using a real microphone: ask, or start recording when auto-record allows it.
    case started(Call)
    /// A recording Earshot started looks finished but might not be: "The call seems to have ended. Stop recording?"
    case askToStop(Call)
    /// A recording Earshot started has ended: stop it.
    case stop(Call)
}

/// When to notice a call (spec 7.1) and when auto-record may start one (spec 7.2). Pure logic over process
/// snapshots and the time passed in.
public struct CallNoticePolicy: Sendable {
    /// The same app is asked about at most once in this many seconds.
    public static let quietPeriod: TimeInterval = 10 * 60

    public let ownPID: Int32
    /// When each app was last asked about, keyed by `MeetingApps.appKey(for:)` so a changing display name
    /// never splits one app in two.
    public private(set) var lastAsked: [String: Date] = [:]
    /// The processes using a real microphone in the previous snapshot. Only a start counts.
    private var usingMic: Set<Int32> = []

    public init(ownPID: Int32 = ProcessInfo.processInfo.processIdentifier) {
        self.ownPID = ownPID
    }

    /// Forgets which processes were using a microphone, so a call already running counts as a start on the next
    /// snapshot. The quiet period is kept. The monitor calls this whenever it starts watching again.
    public mutating func forgetPreviousSnapshot() {
        usingMic = []
    }

    /// Feeds one snapshot. Returns the call to notice, if any, and starts its quiet period.
    /// A process counts when it is a call app, isn't Earshot, and has just started using a real microphone, while
    /// Earshot isn't recording and the app wasn't asked about in the last ten minutes. Dedicated apps win ties.
    public mutating func notice(_ snapshot: [AudioProcessInfo], recording: Bool, runningApps: [String: String],
                                now: Date) -> CallEvent.Call? {
        let onMic = snapshot.filter { $0.pid != ownPID && $0.runningInput && $0.usesRealMicrophone }
        let started = onMic.filter { !usingMic.contains($0.pid) }
        usingMic = Set(onMic.map(\.pid))
        guard !recording else { return nil }
        let calls = started.compactMap { info -> CallEvent.Call? in
            guard let bundleID = info.bundleID, let name = MeetingApps.match(bundleID, runningApps: runningApps) else {
                return nil
            }
            return CallEvent.Call(pid: info.pid, bundleID: bundleID, appName: name,
                                  isDedicated: MeetingApps.isDedicatedCallApp(bundleID))
        }
        let ready = calls.filter { call in
            lastAsked[Self.key(call)].map { now.timeIntervalSince($0) >= Self.quietPeriod } ?? true
        }
        guard let call = ready.sorted(by: Self.preferred).first else { return nil }
        lastAsked[Self.key(call)] = now
        return call
    }

    private static func key(_ call: CallEvent.Call) -> String {
        MeetingApps.appKey(for: call.bundleID) ?? call.bundleID
    }

    private static func preferred(_ a: CallEvent.Call, _ b: CallEvent.Call) -> Bool {
        a.isDedicated != b.isDedicated ? a.isDedicated : a.pid < b.pid
    }

    /// "Start automatically" can be switched on only while Earshot can reach the user.
    public static func canTurnOnAutoRecord(notificationsAuthorized: Bool, panelOn: Bool) -> Bool {
        notificationsAuthorized || panelOn
    }

    /// Whether a noticed call starts recording at once instead of asking: dedicated call apps, or a browser while
    /// the current calendar event has a video link, and only while the user can be told.
    public static func shouldAutoRecord(_ call: CallEvent.Call, autoRecordOn: Bool, eventHasVideoLink: Bool,
                                        notificationsAuthorized: Bool, panelOn: Bool) -> Bool {
        guard autoRecordOn, canTurnOnAutoRecord(notificationsAuthorized: notificationsAuthorized, panelOn: panelOn) else {
            return false
        }
        return call.isDedicated || eventHasVideoLink
    }
}
