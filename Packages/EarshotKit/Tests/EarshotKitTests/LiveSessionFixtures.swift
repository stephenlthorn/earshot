import AVFoundation
import Foundation
import Testing
@testable import EarshotKit

/// A gate that holds whoever waits on it until it is opened, and ignores cancellation, so a test can keep work
/// stuck past a time limit.
final class StuckGate: @unchecked Sendable {
    private let state = Locked<(open: Bool, waiters: [CheckedContinuation<Void, Never>])>((false, []))
    let entered = Locked(0)

    func wait() async {
        entered.update { $0 += 1 }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            var resume = false
            state.update { if $0.open { resume = true } else { $0.waiters.append(continuation) } }
            if resume { continuation.resume() }
        }
    }

    func open() {
        var waiting: [CheckedContinuation<Void, Never>] = []
        state.update {
            $0.open = true
            waiting = $0.waiters
            $0.waiters = []
        }
        for continuation in waiting { continuation.resume() }
    }
}

/// A transcriber the test speaks through.
final class SpokenTranscriber: LiveTranscribing, @unchecked Sendable {
    let track: Track
    let updates: AsyncStream<LiveUpdate>
    private let output: AsyncStream<LiveUpdate>.Continuation
    let appended = Locked<[UInt64]>([])
    let started = Locked(0)
    let finalized = Locked(0)
    let finished = Locked(0)
    let failStart: Bool
    /// When set, `finish()` waits on it, whatever the cancellation.
    let finishGate: StuckGate?

    init(_ track: Track, failStart: Bool = false, finishGate: StuckGate? = nil) {
        self.track = track
        self.failStart = failStart
        self.finishGate = finishGate
        (updates, output) = AsyncStream.makeStream(of: LiveUpdate.self)
    }

    func start() async throws {
        started.update { $0 += 1 }
        if failStart { throw LiveTranscriberError.noAudioFormat }
    }

    func append(_ buffer: AVAudioPCMBuffer, hostTime: UInt64) { appended.update { $0.append(hostTime) } }
    func finalizeNow() async { finalized.update { $0 += 1 } }

    func finish() async {
        finished.update { $0 += 1 }
        await finishGate?.wait()
        output.finish()
    }

    func say(_ text: String, _ start: Double, _ end: Double, final: Bool = true) {
        output.yield(LiveUpdate(segment: Segment(track: track, start: start, end: end, text: text), isFinal: final))
    }
}

final class ScriptedClaude: ClaudeClient, @unchecked Sendable {
    let requests = Locked<[ClaudeRequest]>([])
    private let reply: String

    init(_ reply: String = #"{"items":[]}"#) { self.reply = reply }

    func structured(_ request: ClaudeRequest) async throws -> Data {
        requests.update { $0.append(request) }
        return Data(reply.utf8)
    }
}

struct KeptTarget: DoTarget {
    var id = "webhook"
    let label = "Webhook"
    let sent = Locked<[DoPayload]>([])
    /// When set, each send waits on it.
    var gate: StuckGate?
    var result = DispatchResult(ok: true, detail: "accepted")

    func send(_ payload: DoPayload, json: Data, folder: URL) async -> DispatchResult {
        sent.update { $0.append(payload) }
        await gate?.wait()
        return result
    }
}

/// Everything one live session reported.
final class Events: @unchecked Sendable {
    let all = Locked<[LiveEvent]>([])
    let ended = Locked(false)
    private var task: Task<Void, Never>?

    init(_ stream: AsyncStream<LiveEvent>) {
        let all = all, ended = ended
        task = Task {
            for await event in stream { all.update { $0.append(event) } }
            ended.update { $0 = true }
        }
    }

    var items: [LiveItem]? {
        all.get.reversed().lazy.compactMap { if case let .items(items) = $0 { items } else { nil } }.first
    }

    var flags: [Flag] { all.get.compactMap { if case let .flagged(flag) = $0 { flag } else { nil } } }
}

let liveOneItem = #"{"items":[{"ref":"","task":"Send Dana the pilot scope","owner":"Stephen","due":null,"#
    + #""ai_doable":true,"why":"Dana asked for it in writing"}]}"#
let liveLongLine = String(repeating: "We need the pilot scope in writing by Friday please. ", count: 4)

struct LiveHarness {
    let store = SessionStore(root: tempDir())
    let session: Session
    let me = SpokenTranscriber(.me)
    let them = SpokenTranscriber(.them)

    init(mode: Mode = .notesAndDo) throws {
        session = try store.create(mode: mode, title: "Kickoff", now: at1530)
    }

    func live(client: (any ClaudeClient)? = ScriptedClaude(), transcribers: [any LiveTranscribing]? = nil,
              settings: EarshotSettings = EarshotSettings(), interval: Duration = .seconds(3600),
              stopLimit: Duration = .seconds(4), cancelWindow: Duration = .zero,
              lanes: TargetLanes = TargetLanes()) -> LiveSession {
        var settings = settings
        settings.liveInterval = Int(interval.components.seconds)
        return LiveSession(store: store, session: session, transcribers: transcribers ?? [me, them], client: client,
                           settings: settings, offset: { 30 }, stopLimit: stopLimit, cancelWindow: cancelWindow,
                           lanes: lanes)
    }

    /// The live.json on disk now, wherever the meeting's folder is.
    func liveFile() throws -> LiveFile {
        let current = try #require(store.find(session.id))
        return try store.read(LiveFile.self, current, MeetingFile.live)
    }
}
