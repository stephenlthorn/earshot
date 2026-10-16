// Packages/EarshotKit/Sources/EarshotKit/Audio/CaptureSession.swift
import AVFoundation
import Foundation

/// Copies each buffer off the audio thread and writes it on a serial queue, so file IO never stalls audio.
/// A padding writer (the mic) also fills a gap in the host times, such as a mic restart, with silence, so the
/// file's timeline stays on wall-clock time (spec 14.1).
final class TrackWriter: @unchecked Sendable {  // `nextStart` is only touched on `queue`
    /// Gaps up to this long are timing jitter, not lost audio. The live timeline uses the same rule (spec 14.1).
    static let padThreshold = CaptureSession.gapThreshold
    /// The longest gap filled with silence: 2 hours of 16 kHz mono is about 230 MB.
    static let maxPad: Double = 2 * 3_600

    private let sink: any AudioSinking
    private let queue: DispatchQueue
    private let lock = NSLock()
    private var failures = 0
    let padsGaps: Bool
    private let padLimit: Double
    /// Where the next buffer should start, in host seconds, if no audio was lost.
    private var nextStart: Double?

    /// Buffers dropped or not written, plus a failed close.
    var errors: Int { lock.withLock { failures } }

    convenience init(url: URL, padsGaps: Bool = false) throws {
        self.init(sink: try AudioFileSink(url: url, sampleRate: 16_000), padsGaps: padsGaps)
    }

    init(sink: any AudioSinking, padsGaps: Bool = false, maxPad: Double = TrackWriter.maxPad) {
        self.sink = sink
        self.padsGaps = padsGaps
        padLimit = maxPad
        queue = DispatchQueue(label: "earshot.write.\(sink.url.lastPathComponent)", qos: .userInitiated)
    }

    /// `hostTime` is when the buffer's first frame was captured; a padding writer needs it to see gaps.
    func write(_ buffer: AVAudioPCMBuffer, hostTime: UInt64? = nil) {
        guard buffer.frameLength > 0 else { return }
        guard let copy = buffer.deepCopy() else {
            recordFailure()
            return
        }
        nonisolated(unsafe) let pending = copy
        queue.async { [self] in
            if padsGaps, let hostTime { padGap(before: pending, at: AVAudioTime.seconds(forHostTime: hostTime)) }
            do { try sink.append(pending) } catch { recordFailure() }
        }
    }

    /// Runs on `queue`. Writes silence, in the arriving buffer's format, for the time since the last buffer ended.
    private func padGap(before buffer: AVAudioPCMBuffer, at start: Double) {
        defer { nextStart = start + Double(buffer.frameLength) / buffer.format.sampleRate }
        guard let expected = nextStart else { return }
        let gap = min(start - expected, padLimit)
        guard gap > Self.padThreshold else { return }
        var remaining = AVAudioFrameCount((gap * buffer.format.sampleRate).rounded())
        let chunk = AVAudioFrameCount(buffer.format.sampleRate)  // one second at a time
        while remaining > 0 {
            let frames = min(remaining, chunk)
            guard let silence = Self.silence(buffer.format, frames: frames) else {
                recordFailure()
                return
            }
            do { try sink.append(silence) } catch { recordFailure() }
            remaining -= frames
        }
    }

    static func silence(_ format: AVAudioFormat, frames: AVAudioFrameCount) -> AVAudioPCMBuffer? {
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return nil }
        buffer.frameLength = frames
        for plane in UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList) {
            if let data = plane.mData { memset(data, 0, Int(plane.mDataByteSize)) }
        }
        return buffer
    }

    func finish() {
        queue.sync {
            do { try sink.finish() } catch { recordFailure() }
        }
    }

    /// Closes the file and deletes it, for a track that never started recording. Best effort: there is nothing to report.
    func abandon() {
        queue.sync { try? sink.finish() }
        try? FileManager.default.removeItem(at: sink.url)
    }

    private func recordFailure() {
        lock.withLock { failures += 1 }
    }
}

/// Records the mic to mic.caf and the call audio to system.caf, with live levels and a silence check.
public final class CaptureSession: @unchecked Sendable {
    public struct Levels: Equatable, Sendable {
        public var me: Float = 0
        public var them: Float = 0
        public init() {}
    }

    struct TrackStats {
        var firstHost: UInt64?
        var peak: Float = 0
        var level: Float = 0
    }

    static let silenceThreshold: Float = 0.0001
    public static let silentCall = "The call audio was silent. If the call had sound, allow Earshot in System Settings > Privacy & Security > Screen & System Audio Recording."
    public static let silentMic = "Your microphone track was silent. If you spoke, allow Earshot in System Settings > Privacy & Security > Microphone."

    private let lock = NSLock()
    private var stats: [Track: TrackStats] = [.me: TrackStats(), .them: TrackStats()]
    private var writers: [Track: TrackWriter] = [:]
    /// Tracks that couldn't start and settings that couldn't be applied, known once `start` returns. The panel
    /// shows them straight away; `stop()` also puts them in its warnings for session.json.
    public private(set) var startWarnings: [String] = []
    private let mic = MicRecorder()
    private let tap = SystemAudioTap()
    private(set) var relays: [Track: LiveRelay] = [:]

    /// A stretch of missing host time longer than this is lost audio: the mic file gets silence for it and the
    /// live timeline jumps over it, so the two timelines agree (spec 14.1).
    public static let gapThreshold = 0.5

    /// Gets every captured buffer for live transcription: a deep copy, its track and its host time, on a serial
    /// queue per track, never on the audio thread. Set it before `start`. It is never called after `stop()` returns.
    public var liveFeed: (@Sendable (Track, AVAudioPCMBuffer, UInt64) -> Void)?

    public init() {}

    public func start(in folder: URL, echoCancellation: Bool = false) throws {
        var problems: [String] = []
        var notes: [String] = []
        do {
            try startTrack(.me, in: folder) { writer in
                let handler = Self.makeHandler(self, .me, writer, live: liveRelay(for: .me))
                if let note = try mic.start(echoCancellation: echoCancellation, handler: handler) { notes.append(note) }
            }
        } catch {
            problems.append(Self.problem("Microphone", error))
        }
        do {
            try startTrack(.them, in: folder) { writer in
                try tap.start(handler: Self.makeHandler(self, .them, writer, live: liveRelay(for: .them)))
            }
        } catch {
            problems.append(Self.problem("Call audio", error))
        }
        guard !writers.isEmpty else { throw CaptureError.nothingStarted(problems.joined(separator: "; ")) }
        startWarnings = problems.map(Self.startWarning) + notes
    }

    /// Each track's file, and whether a gap in it is filled with silence: only the mic restarts mid-call.
    /// Capture records only `.me` and `.them`; `.speaker` is an imported file's track.
    static func trackConfig(_ track: Track) -> (file: String, padsGaps: Bool) {
        switch track {
        case .me: ("mic.caf", true)
        case .them: ("system.caf", false)
        case .speaker: ("speaker.caf", false)
        }
    }

    /// The relay that hands this track's buffers to `liveFeed`, kept so `stop()` can drain it; nil without a feed.
    func liveRelay(for track: Track) -> LiveRelay? {
        guard let liveFeed else { return nil }
        let relay = LiveRelay(track: track, feed: liveFeed)
        relays[track] = relay
        return relay
    }

    /// Waits until every buffer already handed to the live feed has reached it, then lets the relays go.
    func drainLive() {
        relays.values.forEach { $0.drain() }
        relays = [:]
    }

    /// Opens the track's file and runs `begin`. If either fails, the header-only file is removed so a Mac without
    /// a microphone doesn't get an empty mic.caf in every meeting.
    func startTrack(_ track: Track, in folder: URL, begin: (TrackWriter) throws -> Void) throws {
        let config = Self.trackConfig(track)
        let url = folder.appending(path: config.file)
        var writer: TrackWriter?
        do {
            let made = try TrackWriter(url: url, padsGaps: config.padsGaps)
            writer = made
            try begin(made)
            writers[track] = made
        } catch {
            if let writer { writer.abandon() } else { try? FileManager.default.removeItem(at: url) }
            throw error
        }
    }

    /// "Microphone: No microphone is available": the error's text without its final full stop.
    static func problem(_ source: String, _ error: any Error) -> String {
        var detail = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        while detail.hasSuffix(".") { detail.removeLast() }
        return "\(source): \(detail)"
    }

    static func startWarning(_ problem: String) -> String { "\(problem). Recording continued without it." }

    /// The host time of the earliest track's first buffer: time zero for every offset in the meeting (spec 14.1).
    public var firstHostTime: UInt64? {
        lock.withLock { stats.values.compactMap(\.firstHost).min() }
    }

    /// Seconds from the first buffer to `hostTime`, never below zero; nil until a buffer has arrived.
    public func offset(forHostTime hostTime: UInt64) -> Double? {
        guard let first = firstHostTime else { return nil }
        return max(0, AVAudioTime.seconds(forHostTime: hostTime) - AVAudioTime.seconds(forHostTime: first))
    }

    /// The offset of this moment, from `mach_absolute_time()`; flags and screen captures use it, never a `Date`.
    public func currentOffset() -> Double? {
        offset(forHostTime: mach_absolute_time())
    }

    public var levels: Levels {
        lock.withLock {
            var levels = Levels()
            levels.me = stats[.me]?.level ?? 0
            levels.them = stats[.them]?.level ?? 0
            return levels
        }
    }

    /// Stops both tracks. Returns them with their offsets, plus warnings for session.json. When it returns, every
    /// captured buffer has reached `liveFeed`.
    public func stop() -> (tracks: [TrackFile], warnings: [String]) {
        mic.stop()
        tap.stop()
        drainLive()
        writers.values.forEach { $0.finish() }
        let snapshot = lock.withLock { stats }
        let earliest = snapshot.values.compactMap(\.firstHost).min()
        var tracks: [TrackFile] = []
        var warnings = startWarnings + mic.warnings
        for track in [Track.me, .them] {
            guard let writer = writers[track] else { continue }
            let file = Self.trackConfig(track).file
            let stat = snapshot[track] ?? TrackStats()
            var offset = 0.0
            if let first = stat.firstHost, let earliest {
                offset = AVAudioTime.seconds(forHostTime: first) - AVAudioTime.seconds(forHostTime: earliest)
            }
            tracks.append(TrackFile(track: track, file: file, offset: offset))
            if stat.peak < Self.silenceThreshold { warnings.append(track == .me ? Self.silentMic : Self.silentCall) }
            if writer.errors > 0 { warnings.append("Some \(track == .me ? "microphone" : "call") audio couldn't be saved.") }
        }
        writers = [:]
        return (tracks, warnings)
    }

    /// Runs on the audio thread for every buffer. The clock starts (in `observe`) before the live feed sees a buffer.
    static func makeHandler(_ session: CaptureSession, _ track: Track, _ writer: TrackWriter,
                            live: LiveRelay? = nil) -> @Sendable (AVAudioPCMBuffer, UInt64) -> Void {
        { [weak session] buffer, hostTime in
            let level = measure(buffer)
            writer.write(buffer, hostTime: hostTime)
            session?.observe(track, level: level, hostTime: hostTime)
            live?.send(buffer, hostTime: hostTime)
        }
    }

    /// Hands each buffer to the live feed as a deep copy on its own serial queue, so a slow consumer never
    /// holds up the audio thread.
    final class LiveRelay: @unchecked Sendable {  // immutable; `feed` only ever runs on `queue`
        private let track: Track
        private let feed: @Sendable (Track, AVAudioPCMBuffer, UInt64) -> Void
        private let queue: DispatchQueue

        init(track: Track, feed: @escaping @Sendable (Track, AVAudioPCMBuffer, UInt64) -> Void) {
            self.track = track
            self.feed = feed
            queue = DispatchQueue(label: "earshot.live.\(track.rawValue)", qos: .userInitiated)
        }

        func send(_ buffer: AVAudioPCMBuffer, hostTime: UInt64) {
            guard buffer.frameLength > 0, let copy = buffer.deepCopy() else { return }
            nonisolated(unsafe) let pending = copy  // handed over: nothing else holds it
            queue.async { [track, feed] in feed(track, pending, hostTime) }
        }

        /// Waits until every buffer sent so far has reached the feed.
        func drain() { queue.sync {} }
    }

    func observe(_ track: Track, level: (rms: Float, peak: Float), hostTime: UInt64) {
        lock.withLock {
            guard var stat = stats[track] else { return }  // a local copy: reading and writing `stats` in one statement overlaps
            if stat.firstHost == nil { stat.firstHost = hostTime }
            stat.peak = max(stat.peak, level.peak)
            stat.level = level.rms
            stats[track] = stat
        }
    }

    /// RMS and peak over every sample of every channel: a planar mic buffer can carry the voice on any channel.
    static func measure(_ buffer: AVAudioPCMBuffer) -> (rms: Float, peak: Float) {
        let channels = Int(buffer.format.channelCount)
        guard let data = buffer.floatChannelData, buffer.frameLength > 0, channels > 0 else { return (0, 0) }
        let frames = Int(buffer.frameLength)
        // Interleaved: one plane holding every channel. Planar: one plane per channel.
        let planes = buffer.format.isInterleaved ? 1 : channels
        let samplesPerPlane = buffer.format.isInterleaved ? frames * channels : frames
        var sum: Float = 0, peak: Float = 0
        for plane in 0..<planes {
            let samples = data[plane]
            for index in 0..<samplesPerPlane {
                let value = samples[index]
                sum += value * value
                peak = max(peak, abs(value))
            }
        }
        return ((sum / Float(planes * samplesPerPlane)).squareRoot(), peak)
    }
}

/// macOS has no API to check the system-audio permission, and a denied tap just records silence (verified).
/// So: tap for a moment while another process plays a sound, and see whether we heard it.
public enum SystemAudioCheck {
    public static func run() async -> Bool {
        let heard = Locked(Float(0))
        let tap = SystemAudioTap()
        do {
            try tap.start { buffer, _ in
                let peak = CaptureSession.measure(buffer).peak
                heard.update { $0 = max($0, peak) }
            }
        } catch {
            return false
        }
        // afplay is a separate process, so the tap (which excludes Earshot) can hear it.
        _ = try? await ProcessRunner().run("/usr/bin/afplay", ["/System/Library/Sounds/Glass.aiff"], stdin: nil,
                                           directory: nil, environment: [:], timeout: .seconds(5))
        try? await Task.sleep(for: .milliseconds(300))
        tap.stop()
        return heard.get > 0.001
    }
}
