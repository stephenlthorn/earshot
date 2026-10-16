import Foundation

/// Watches which apps use the microphone and turns that into `CallEvent`s, using `CallNoticePolicy` and
/// `AutoStopPolicy`. It checks on every change from the source and polls every 3 seconds as a fallback.
/// The app tells it when a recording starts and stops.
public actor MicActivityMonitor {
    public static let pollInterval = Duration.seconds(3)

    /// One consumer. Ends after `finish()`.
    public nonisolated let events: AsyncStream<CallEvent>
    private nonisolated let continuation: AsyncStream<CallEvent>.Continuation

    private let source: any AudioProcessSource
    private let now: @Sendable () -> Date
    private let sleep: @Sendable (Duration) async throws -> Void
    private let runningApps: @Sendable () async -> [String: String]

    private var noticePolicy: CallNoticePolicy
    private var recording = false
    private var autoStop: AutoStopPolicy?
    private var lastDecision = AutoStopPolicy.Decision.keepRecording
    private var tasks: [Task<Void, Never>] = []

    /// - Parameters:
    ///   - runningApps: running apps' bundle ids and names (from NSWorkspace), for display names and the Safari rule.
    public init(source: any AudioProcessSource = CoreAudioProcessSource(),
                ownPID: Int32 = ProcessInfo.processInfo.processIdentifier,
                now: @escaping @Sendable () -> Date = { Date() },
                sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
                runningApps: @escaping @Sendable () async -> [String: String] = { [:] }) {
        self.source = source
        self.now = now
        self.sleep = sleep
        self.runningApps = runningApps
        self.noticePolicy = CallNoticePolicy(ownPID: ownPID)
        (events, continuation) = AsyncStream.makeStream(of: CallEvent.self)
        // Finishing the events, or the consumer going away, also stops listening and polling.
        continuation.onTermination = { [weak self] _ in
            Task { await self?.stop() }
        }
    }

    deinit {
        tasks.forEach { $0.cancel() }
    }

    /// Starts listening and polling. Calling it again while running does nothing. A call already using the
    /// microphone counts as new on each start; the quiet period still applies.
    public func start() {
        guard tasks.isEmpty else { return }
        noticePolicy.forgetPreviousSnapshot()
        let source = source, sleep = sleep, interval = Self.pollInterval
        tasks = [
            Task { [weak self] in
                await self?.check()
                while !Task.isCancelled {
                    do { try await sleep(interval) } catch { return }
                    guard let self else { return }
                    await self.check()
                }
            },
            Task { [weak self] in
                for await _ in source.changes() {
                    guard let self else { return }
                    await self.check()
                }
            },
        ]
    }

    /// Stops listening and polling. The event stream stays open, so `start()` can resume.
    public func stop() {
        tasks.forEach { $0.cancel() }
        tasks = []
    }

    /// Ends the event stream for good.
    public nonisolated func finish() {
        continuation.finish()
    }

    /// A recording started. Pass the call and `startedByEarshot: true` when Earshot started it (automatically or
    /// from its own notice) so it can stop when the call ends; recordings started by hand are never stopped.
    public func recordingStarted(call: CallEvent.Call?, startedByEarshot: Bool, eventEnd: Date?, stopWhenCallEnds: Bool) {
        recording = true
        lastDecision = .keepRecording
        autoStop = call.map {
            AutoStopPolicy(call: $0, startedByEarshot: startedByEarshot, stopWhenCallEnds: stopWhenCallEnds,
                           eventEnd: eventEnd, startedAt: now())
        }
    }

    /// The user answered Keep recording: the recording isn't stopped or asked about again until the call app's
    /// input runs again, or the call ends.
    public func keepRecording() {
        guard var stopper = autoStop else { return }
        stopper.keepRecording(now: now())
        autoStop = stopper
        lastDecision = .keepRecording
    }

    public func recordingStopped() {
        recording = false
        autoStop = nil
        lastDecision = .keepRecording
    }

    /// Reads the process list once and emits what the policies decide. `start()` calls this on every change and
    /// every poll. It does nothing in a cancelled task, so nothing is read after `stop()`.
    public func check() async {
        guard !Task.isCancelled else { return }
        let apps = await runningApps()
        guard !Task.isCancelled else { return }
        let snapshot = source.processes()
        let time = now()
        if var stopper = autoStop {
            let decision = stopper.observe(snapshot, now: time)
            autoStop = stopper
            emit(decision, for: stopper.call)
        }
        if let call = noticePolicy.notice(snapshot, recording: recording, runningApps: apps, now: time) {
            continuation.yield(.started(call))
        }
    }

    /// Asks once per quiet spell, and stops once. After a stop, it stays quiet until the next recording.
    private func emit(_ decision: AutoStopPolicy.Decision, for call: CallEvent.Call) {
        defer { lastDecision = decision }
        guard decision != lastDecision else { return }
        switch decision {
        case .keepRecording: break
        case .ask: continuation.yield(.askToStop(call))
        case .stop:
            continuation.yield(.stop(call))
            autoStop = nil
        }
    }
}
