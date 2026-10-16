import Foundation

/// The panel's status line for the live assistant (spec 4.5).
public enum LiveStatus: Equatable, Sendable {
    case listening
    case reading
    /// The pass failed; it is tried again at the next check. The value is the error, for the log.
    case failed(String)
    /// No more passes this meeting. The value is the reason, for example "Claude usage limit".
    case paused(String)

    /// The line the panel shows.
    public var line: String {
        switch self {
        case .listening: "Listening"
        case .reading: "Reading the last two minutes\u{2026}"
        case .failed: "Couldn't reach Claude; trying at the next check"
        case let .paused(reason): "Paused: \(reason)"
        }
    }

    /// The line for the provider that writes the live to-dos: a failed pass on a local model names the local model.
    public func line(provider: NotesProvider) -> String {
        if case .failed = self, provider == .local { return "Couldn't reach the local model; trying at the next check" }
        return line
    }
}

/// Finds to-dos in the live transcript every `interval` (spec 4.3). A pass runs only when there are at least
/// `minimumCharacters` of new final text, no pass is running, and a structured-call slot is free. The slot comes
/// from the client: `ClaudeCodeClient` asks `ClaudeGate` with `skipIfBusy: true` for the live role and throws
/// `ClaudeBusy` when every slot is taken, so the pass is skipped (not queued) and its text waits for the next one.
/// After a usage-limit or not-signed-in error, or a setup problem that won't fix itself during the call (`setupPause`),
/// the assistant pauses for the rest of the meeting (spec 3.2).
public actor LiveExtractor {
    public static let modelUnavailable = "the live model isn't available, pick another in Settings, Live"
    public static let claudeTooOld = "Claude Code is too old, update it"
    public static let keyProblem = "check the API key in Settings, Claude"
    public static let claudeNotFound = "Claude Code wasn't found, check Settings, Claude"

    /// The pause reason for an error no later check can fix, or nil for one that may pass (a network blip, a
    /// timeout, an answer in the wrong shape). A local model problem never pauses: the user may start the server
    /// mid-call, and each later pass tries again.
    public static func setupPause(_ error: NotesError) -> String? {
        switch error {
        case .modelUnavailable: modelUnavailable
        case .claudeTooOld: claudeTooOld
        case .badKey, .missingKey: keyProblem
        case .claudeNotFound: claudeNotFound
        case .local: nil
        default: nil
        }
    }

    /// What one call of `passNow()` did.
    public enum PassResult: Equatable, Sendable {
        case extracted
        case notEnoughText
        case alreadyRunning
        case busy
        case failed(String)
        case paused(String)
        case cancelled
    }

    public static let defaultMinimumCharacters = 150
    public static let defaultContextSeconds = 60.0
    /// At most this much new text goes into one pass, the most recent. After failed passes the unread text keeps
    /// growing; what doesn't fit becomes earlier context, so one prompt never holds a long outage.
    public static let defaultMaxNewCharacters = 8_000

    private let client: any ClaudeClient
    private let model: String
    private let effort: String
    private let interval: Duration
    private let minimumCharacters: Int
    private let contextSeconds: Double
    private let maxNewCharacters: Int
    private let finals: @Sendable () async -> [Segment]
    private let finalize: @Sendable () async -> Void
    private let now: @Sendable () -> Double
    private let context: @Sendable () async -> LivePrompt.Meeting
    private let onItems: @Sendable ([LiveItem]) async -> Void
    private let onStatus: @Sendable (LiveStatus) async -> Void
    private let sleep: @Sendable (Duration) async throws -> Void

    private var items: [LiveItem] = []
    private var frozen: Set<String> = []
    /// The highest `L` number this meeting has seen. It never goes down, so a number is never given out twice.
    private var issued = 0
    /// How many of `finals()` earlier passes have read. The final list only grows.
    private var consumed = 0
    private var inFlight = false
    private var pausedReason: String?

    /// - Parameters:
    ///   - maxNewCharacters: the most new text one pass sends; see `defaultMaxNewCharacters`.
    ///   - finals: every final live segment so far, in the order they arrived (the list only grows).
    ///   - finalize: makes recent speech final on both tracks; called before each pass.
    ///   - now: the meeting clock, in seconds (spec 14.1).
    ///   - context: the title, attendee names, flags and lessons.
    ///   - onItems: the whole list after a pass changed it.
    public init(client: any ClaudeClient, model: String, effort: String, interval: Duration,
                minimumCharacters: Int = LiveExtractor.defaultMinimumCharacters,
                contextSeconds: Double = LiveExtractor.defaultContextSeconds,
                maxNewCharacters: Int = LiveExtractor.defaultMaxNewCharacters,
                finals: @escaping @Sendable () async -> [Segment],
                finalize: @escaping @Sendable () async -> Void,
                now: @escaping @Sendable () -> Double,
                context: @escaping @Sendable () async -> LivePrompt.Meeting,
                onItems: @escaping @Sendable ([LiveItem]) async -> Void,
                onStatus: @escaping @Sendable (LiveStatus) async -> Void,
                sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) {
        self.client = client
        self.model = model
        self.effort = effort
        self.interval = interval
        self.minimumCharacters = minimumCharacters
        self.contextSeconds = contextSeconds
        self.maxNewCharacters = maxNewCharacters
        self.finals = finals
        self.finalize = finalize
        self.now = now
        self.context = context
        self.onItems = onItems
        self.onStatus = onStatus
        self.sleep = sleep
    }

    /// Checks every `interval` until the task is cancelled or the assistant pauses.
    public func run() async {
        guard pausedReason == nil else { return }
        await onStatus(.listening)
        while pausedReason == nil, !Task.isCancelled {
            do {
                try await sleep(interval)
            } catch {
                return
            }
            if case .cancelled = await passNow() { return }
        }
    }

    /// The latest list from the controller, with the statuses it set (Start, Dismiss). The list may be older than
    /// this extractor's (the App read the store before the last pass reached it), so it is merged by id:
    /// - an item missing from `items` is kept;
    /// - a known item takes the incoming status, target, detail and link;
    /// - its words come from whichever copy was updated later;
    /// - an item the extractor doesn't have is added.
    public func update(_ items: [LiveItem]) {
        let incoming = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let known = Set(self.items.map(\.id))
        self.items = self.items.map { mine in
            guard let theirs = incoming[mine.id] else { return mine }
            guard mine.updated > theirs.updated else { return theirs }
            var kept = mine
            kept.status = theirs.status
            kept.target = theirs.target
            kept.detail = theirs.detail
            kept.link = theirs.link
            return kept
        } + items.filter { !known.contains($0.id) }
        issued = max(issued, LiveMerge.highestNumber(self.items))
    }

    /// Items whose row the pointer is over. A pass never changes them.
    public func setFrozen(_ ids: Set<String>) {
        frozen = ids
    }

    /// One pass now, if the conditions hold.
    @discardableResult
    public func passNow() async -> PassResult {
        if let pausedReason { return .paused(pausedReason) }
        guard !inFlight else { return .alreadyRunning }
        inFlight = true
        defer { inFlight = false }

        await finalize()
        let all = await finals()
        let start = min(consumed, all.count)
        let unread = all[start...]
        guard unread.reduce(0, { $0 + Self.length($1) }) >= minimumCharacters else { return .notEnoughText }

        let cut = newStart(in: all, from: start)
        let input = await makeInput(earlier: Array(all[..<cut]), new: Array(all[cut...]))
        await onStatus(.reading)
        do {
            let response = try await client.decode(LivePrompt.Response.self,
                                                   LivePrompt.request(input, model: model, effort: effort))
            consumed = all.count
            items = LiveMerge.merge(response.items, into: items, at: now(), frozen: frozen, issued: issued)
            issued = max(issued, LiveMerge.highestNumber(items))
            await onItems(items)
            await onStatus(.listening)
            return .extracted
        } catch {
            return await handle(error)
        }
    }

    private static func length(_ segment: Segment) -> Int {
        segment.text.trimmingCharacters(in: .whitespacesAndNewlines).count
    }

    /// Where this pass's new text starts: the most recent unread segments that fit in `maxNewCharacters`, and always
    /// at least the last one.
    private func newStart(in all: [Segment], from start: Int) -> Int {
        var cut = all.count
        var total = 0
        while cut > start {
            total += Self.length(all[cut - 1])
            if total > maxNewCharacters, cut < all.count { break }
            cut -= 1
        }
        return cut
    }

    private func makeInput(earlier: [Segment], new: [Segment]) async -> LivePrompt.Input {
        let windowStart = (new.map(\.start).min() ?? now()) - contextSeconds
        var meeting = await context()
        meeting.flags = meeting.flags.filter { $0.offset >= windowStart }
        return LivePrompt.Input(meeting: meeting, known: items, earlier: earlier.filter { $0.end >= windowStart },
                                new: new)
    }

    private func handle(_ error: any Error) async -> PassResult {
        switch error {
        case is ClaudeBusy:
            await onStatus(.listening)
            return .busy
        case is CancellationError:
            return .cancelled
        case NotesError.usageLimit:
            return await pause("Claude usage limit")
        case NotesError.notSignedIn:
            return await pause("Claude Code is not signed in")
        case let error as NotesError where Self.setupPause(error) != nil:
            return await pause(Self.setupPause(error) ?? "")
        default:
            let detail = error.localizedDescription
            await onStatus(.failed(detail))
            return .failed(detail)
        }
    }

    private func pause(_ reason: String) async -> PassResult {
        pausedReason = reason
        await onStatus(.paused(reason))
        return .paused(reason)
    }
}
