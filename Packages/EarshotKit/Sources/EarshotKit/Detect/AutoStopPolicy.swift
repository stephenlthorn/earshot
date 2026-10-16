import Foundation

/// When a recording Earshot started should stop (spec 7.2). Pure logic over process snapshots and the time passed
/// in. Recordings started by hand are never stopped.
public struct AutoStopPolicy: Sendable {
    public enum Decision: Equatable, Sendable { case keepRecording, ask, stop }

    /// Seconds without input before the call may have ended.
    public static let idleAfter: TimeInterval = 45
    /// Seconds without input after which a call that may still be going is stopped anyway.
    public static let giveUpAfter: TimeInterval = 5 * 60

    public let call: CallEvent.Call
    public let startedByEarshot: Bool
    public var stopWhenCallEnds: Bool
    public var eventEnd: Date?
    /// The last time any process of the call app had input running. Starts at the recording start.
    public private(set) var lastInputAt: Date
    /// The user answered Keep recording: no more asking and no give-up stop until input runs again. A call that
    /// has ended (the app gone, its output idle, the event over) still counts.
    public private(set) var kept = false

    public init(call: CallEvent.Call, startedByEarshot: Bool, stopWhenCallEnds: Bool, eventEnd: Date?, startedAt: Date) {
        self.call = call
        self.startedByEarshot = startedByEarshot
        self.stopWhenCallEnds = stopWhenCallEnds
        self.eventEnd = eventEnd
        self.lastInputAt = startedAt
    }

    /// Feeds one snapshot. Every process with the call's bundle id counts, so a helper that restarts with a new
    /// pid is still the same call.
    public mutating func observe(_ snapshot: [AudioProcessInfo], now: Date) -> Decision {
        let mine = snapshot.filter { $0.bundleID == call.bundleID }
        if mine.contains(where: \.runningInput) {
            lastInputAt = max(lastInputAt, now)
            kept = false
        }
        return Self.decide(inputIdleFor: now.timeIntervalSince(lastInputAt), processGone: mine.isEmpty,
                           outputIdle: !mine.contains(where: \.runningOutput),
                           eventEnded: eventEnd.map { $0 <= now } ?? false,
                           startedByEarshot: startedByEarshot, stopWhenCallEnds: stopWhenCallEnds, kept: kept)
    }

    /// The user answered Keep recording to "Stop recording?": the quiet spell starts again at `now`, and nothing is
    /// asked or given up on until input runs again.
    public mutating func keepRecording(now: Date) {
        lastInputAt = max(lastInputAt, now)
        kept = true
    }

    /// The call has ended when input has been idle for 45 s and the app is gone, its output is idle or the event
    /// has ended. Then it stops, or asks when "Stop when the call ends" is off. Input idle without any of those
    /// asks, and stops after 5 minutes whatever that setting says (spec 7.2), unless the user answered Keep
    /// recording (`kept`): then it keeps recording.
    public static func decide(inputIdleFor idle: TimeInterval, processGone: Bool, outputIdle: Bool, eventEnded: Bool,
                              startedByEarshot: Bool, stopWhenCallEnds: Bool, kept: Bool = false) -> Decision {
        guard startedByEarshot, idle >= idleAfter else { return .keepRecording }
        let ended = processGone || outputIdle || eventEnded
        if ended { return stopWhenCallEnds ? .stop : .ask }
        if kept { return .keepRecording }
        return idle >= giveUpAfter ? .stop : .ask
    }
}
