import AVFoundation
import CoreMedia
import Foundation
import Speech

/// One live result: tentative (volatile) text for the ticker, or final text for the live transcript.
public struct LiveUpdate: Equatable, Sendable {
    public var segment: Segment
    public var isFinal: Bool

    public init(segment: Segment, isFinal: Bool) {
        self.segment = segment
        self.isFinal = isFinal
    }
}

public enum LiveTranscriberError: Error, LocalizedError {
    case noAudioFormat

    public var errorDescription: String? {
        switch self {
        case .noAudioFormat: "Live transcription couldn't find an audio format to use."
        }
    }
}

/// Streams one capture track into its own SpeechAnalyzer (spec 4.2). Feed it with `append` from the capture's
/// live feed; read `updates`. Times are seconds on the meeting clock (spec 14.1).
public actor LiveTranscriber {
    /// A gap in the host times longer than this moves the analyzer's timeline forward by the gap. The mic file is
    /// padded by the same rule, so the two timelines agree.
    public static let jumpThreshold = CaptureSession.gapThreshold
    /// `finalizeNow` forces the analyzer only once this many seconds of speech have gone without a final result.
    public static let forceAfter: Double = 12
    /// The longest `finish` waits for the analyzer's last results before it cancels the analyzer.
    static let stopLimit: Duration = .seconds(10)

    /// Audio the analyzer has heard and reported as volatile, but not yet made final.
    struct Pending: Equatable, Sendable {
        var start: Double
        var end: Double
    }

    public nonisolated let track: Track
    /// Volatile and final results, in the order the analyzer gives them. Ends after `finish()`.
    public nonisolated let updates: AsyncStream<LiveUpdate>
    private let output: AsyncStream<LiveUpdate>.Continuation
    private nonisolated let feeder: Feeder
    private let locale: Locale
    private var analyzer: SpeechAnalyzer?
    private var reader: Task<Void, Never>?
    private var starting: Task<Void, any Error>?
    private var finishing: Task<Void, Never>?
    private nonisolated let pending = Locked<Pending?>(nil)
    private var finished = false

    /// `firstHostTime` gives the capture's time zero (`CaptureSession.firstHostTime`). It is read once, when the
    /// first buffer is converted after the model has loaded, so it can be set up before capture starts. If it is
    /// still nil then, the first buffer appended is time zero.
    public init(track: Track, locale: Locale, firstHostTime: @escaping @Sendable () -> UInt64?) {
        self.track = track
        self.locale = locale
        (updates, output) = AsyncStream.makeStream(of: LiveUpdate.self, bufferingPolicy: .unbounded)
        feeder = Feeder(track: track, base: firstHostTime)
    }

    /// A time zero that is already known, or nil for "the first buffer appended".
    public init(track: Track, locale: Locale, firstHostTime: UInt64?) {
        self.init(track: track, locale: locale, firstHostTime: { firstHostTime })
    }

    /// Loads the speech model (downloading it if needed) and starts listening. Buffers appended before this
    /// returns are kept, up to `Feeder.maxPending` seconds. A second call waits for the first one.
    public func start() async throws {
        if let starting { return try await starting.value }
        guard analyzer == nil, !finished else { return }
        let task = Task { try await self.load() }
        starting = task
        do {
            try await task.value
        } catch {
            starting = nil  // a later call may try again
            throw error
        }
    }

    private func load() async throws {
        let supported = try await AppleSpeechTranscriber.prepare(locale: locale)
        let module = SpeechTranscriber(locale: supported, transcriptionOptions: [],
                                       reportingOptions: [.volatileResults, .fastResults], attributeOptions: [.audioTimeRange])
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [module]) else {
            throw LiveTranscriberError.noAudioFormat
        }
        let made = SpeechAnalyzer(modules: [module], options: .init(priority: .userInitiated, modelRetention: .lingering))
        try await made.prepareToAnalyze(in: format)
        guard !finished else { return }
        // Read results before any audio goes in.
        let listening = Task { [track, output, pending] in await Self.read(module, track: track, into: output, pending: pending) }
        do {
            try await made.start(inputSequence: feeder.stream)
        } catch {
            listening.cancel()
            await made.cancelAndFinishNow()
            throw error
        }
        guard !finished else {  // finish() ran while the analyzer was starting
            await made.cancelAndFinishNow()
            listening.cancel()
            return
        }
        analyzer = made
        reader = listening
        feeder.ready(format)
    }

    /// Takes a buffer from the capture's live feed. Never blocks: the conversion runs on a serial queue. The
    /// buffer is handed over and must not be touched afterwards.
    public nonisolated func append(_ buffer: AVAudioPCMBuffer, hostTime: UInt64) {
        feeder.push(buffer, hostTime: hostTime)
    }

    /// Before an extraction pass. Always converts every buffer appended so far and hands it to the analyzer. The
    /// analyzer makes a sentence final on its own at the speaker's pause, so normally that is all this does.
    /// Only when `forceAfter` seconds of speech have gone without a final (a long unbroken stretch) does it force
    /// everything heard so far to be final.
    ///
    /// Why not always force, as spec 4.2 first said: on macOS 26 `finalize(through:)` makes the whole volatile
    /// stretch final whatever time it is given (even its start), and a forced finalize mid-sentence loses or
    /// garbles about the next second of words (device probes, 2026-10-15). A failure leaves the text volatile.
    public func finalizeNow() async {
        guard let analyzer, !finished else { return }
        await feeder.drain()
        guard Self.shouldForce(pending.get) else { return }
        try? await analyzer.finalize(through: nil)
    }

    /// Ends the input, finalizes it, waits (up to `stopLimit`) for the last results and ends `updates`. A second
    /// call waits for the first one to finish.
    public func finish() async {
        if let finishing { return await finishing.value }
        finished = true
        let task = Task { await self.stop() }
        finishing = task
        await task.value
    }

    private func stop() async {
        feeder.end()
        await feeder.drain()
        if let analyzer {
            let ended = await Self.within(Self.stopLimit) { [reader] in
                do { try await analyzer.finalizeAndFinishThroughEndOfInput() } catch { return false }
                await reader?.value
                return true
            }
            if !ended {  // the analyzer failed or never ended its results
                await analyzer.cancelAndFinishNow()
                reader?.cancel()
            }
        }
        analyzer = nil
        reader = nil
        output.finish()
    }

    /// The stretch still volatile after `result`: a volatile result is the newest one; a final one clears the
    /// stretch it covers.
    static func pending(after current: Pending?, result: (start: Double, end: Double, isFinal: Bool)) -> Pending? {
        guard result.isFinal else { return Pending(start: result.start, end: result.end) }
        guard let current, current.start < result.end else { return current }
        return nil
    }

    /// True when `finalizeNow` should force the analyzer: the stretch without a final is at least `forceAfter` long.
    static func shouldForce(_ pending: Pending?) -> Bool {
        guard let pending else { return false }
        return pending.end - pending.start >= forceAfter
    }

    /// Runs `work` and returns what it returns, or false once `limit` has passed. The work is left running.
    static func within(_ limit: Duration, _ work: @escaping @Sendable () async -> Bool) async -> Bool {
        await withCheckedContinuation { (done: CheckedContinuation<Bool, Never>) in
            let resumed = Locked(false)
            let finish: @Sendable (Bool) -> Void = { value in
                var first = false
                resumed.update { first = !$0; $0 = true }
                if first { done.resume(returning: value) }
            }
            let timer = Task {
                try? await Task.sleep(for: limit)
                finish(false)
            }
            Task {
                finish(await work())
                timer.cancel()
            }
        }
    }

    private static func read(_ module: SpeechTranscriber, track: Track, into output: AsyncStream<LiveUpdate>.Continuation,
                             pending: Locked<Pending?>) async {
        do {
            for try await result in module.results {
                let start = result.range.start.seconds, end = result.range.end.seconds
                guard start.isFinite, end.isFinite else { continue }
                let text = cleaned(String(result.text.characters))
                pending.update { $0 = Self.pending(after: $0, result: (start, end, result.isFinal)) }
                output.yield(LiveUpdate(segment: Segment(track: track, start: start, end: end, text: text), isFinal: result.isFinal))
            }
        } catch {
            // The analyzer stopped (finish or cancel). The file transcription after the call is the source of truth.
        }
    }

    /// Result text without the stray leading punctuation the analyzer adds after a pause (". Sam will..."), and
    /// "" for a result that holds no words at all.
    static func cleaned(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.firstIndex(where: { $0.isLetter || $0.isNumber }) else { return "" }
        return String(trimmed[first...])
    }
}

extension LiveTranscriber {
    /// Converts buffers to the analyzer's format and gives each one a start time from the count of converted
    /// frames. Everything but `stream` is touched only on `queue`.
    final class Feeder: @unchecked Sendable {
        /// Seconds of audio kept while the analyzer is still loading; older audio is dropped.
        static let maxPending: Double = 30

        let stream: AsyncStream<AnalyzerInput>
        private let input: AsyncStream<AnalyzerInput>.Continuation
        private let queue: DispatchQueue
        private let clock: @Sendable () -> UInt64?
        private var base: Double?
        /// The host time of the first buffer pushed, kept even when that buffer is dropped from `pending`.
        private var firstPushed: UInt64?
        private var format: AVAudioFormat?
        private var converter: AVAudioConverter?
        private var converterInput: AVAudioFormat?
        private var framesOut: Int64 = 0
        private var yielded = false
        private var pending: [(buffer: AVAudioPCMBuffer, hostTime: UInt64)] = []
        private var ended = false

        /// `base` is read once, on the queue, when the first buffer is converted.
        init(track: Track, base: @escaping @Sendable () -> UInt64?) {
            (stream, input) = AsyncStream.makeStream(of: AnalyzerInput.self, bufferingPolicy: .unbounded)
            queue = DispatchQueue(label: "earshot.live.convert.\(track.rawValue)", qos: .userInitiated)
            clock = base
        }

        convenience init(track: Track, base: UInt64?) {
            self.init(track: track, base: { base })
        }

        func push(_ buffer: AVAudioPCMBuffer, hostTime: UInt64) {
            nonisolated(unsafe) let handed = buffer
            queue.async { [self] in take(handed, hostTime: hostTime) }
        }

        /// The analyzer is ready for audio in `format`; anything kept so far goes in now.
        func ready(_ format: AVAudioFormat) {
            queue.async { [self] in
                guard !ended else { return }
                self.format = format
                let kept = pending
                pending = []
                for entry in kept { convert(entry.buffer, hostTime: entry.hostTime) }
            }
        }

        /// Returns once every buffer pushed so far has been converted and handed to the analyzer.
        func drain() async {
            await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in queue.async { done.resume() } }
        }

        /// Ends the input. Later pushes are ignored.
        func end() {
            queue.async { [self] in
                ended = true
                pending = []
                input.finish()
            }
        }

        private func take(_ buffer: AVAudioPCMBuffer, hostTime: UInt64) {
            guard !ended, buffer.frameLength > 0 else { return }
            if firstPushed == nil { firstPushed = hostTime }
            guard format != nil else {
                pending.append((buffer, hostTime))
                var seconds = pending.reduce(0) { $0 + Double($1.buffer.frameLength) / $1.buffer.format.sampleRate }
                while seconds > Self.maxPending, let first = pending.first {
                    seconds -= Double(first.buffer.frameLength) / first.buffer.format.sampleRate
                    pending.removeFirst()
                }
                return
            }
            convert(buffer, hostTime: hostTime)
        }

        private func convert(_ buffer: AVAudioPCMBuffer, hostTime: UInt64) {
            guard let format, let converter = converter(for: buffer.format) else { return }
            let hostSeconds = AVAudioTime.seconds(forHostTime: hostTime)
            let zero = base ?? AVAudioTime.seconds(forHostTime: clock() ?? firstPushed ?? hostTime)
            base = zero
            let start = Self.startFrame(next: framesOut, wall: hostSeconds - zero, rate: format.sampleRate, first: !yielded)
            let ratio = format.sampleRate / buffer.format.sampleRate
            let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 16
            guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return }
            nonisolated(unsafe) let source = buffer  // the input block is @Sendable; the buffer is not
            nonisolated(unsafe) var consumed = false
            var error: NSError?
            let status = converter.convert(to: out, error: &error) { _, inputStatus in
                if consumed {
                    inputStatus.pointee = .noDataNow
                    return nil
                }
                consumed = true
                inputStatus.pointee = .haveData
                return source
            }
            guard status != .error, out.frameLength > 0 else { return }
            framesOut = start + Int64(out.frameLength)
            yielded = true
            input.yield(AnalyzerInput(buffer: out, bufferStartTime: CMTime(value: start, timescale: CMTimeScale(format.sampleRate))))
        }

        private func converter(for inputFormat: AVAudioFormat) -> AVAudioConverter? {
            if let converter, converterInput == inputFormat { return converter }
            guard let format, let made = AVAudioConverter(from: inputFormat, to: format) else { return nil }
            made.primeMethod = .none  // priming would shift the audio away from the start times given
            made.downmix = inputFormat.channelCount > format.channelCount
            converter = made
            converterInput = inputFormat
            return made
        }

        /// Where a buffer starts, in analyzer frames. The first buffer starts at its offset on the meeting clock.
        /// Later ones follow on, unless the host times say more than `jumpThreshold` seconds went missing (a mic
        /// restart, a dropped stretch): then the timeline jumps forward to match. It never goes back.
        static func startFrame(next: Int64, wall: Double, rate: Double, first: Bool) -> Int64 {
            let target = Int64((max(0, wall) * rate).rounded())
            if first { return max(next, target) }
            let behind = wall - Double(next) / rate
            return behind > LiveTranscriber.jumpThreshold ? max(next, target) : next
        }
    }
}
