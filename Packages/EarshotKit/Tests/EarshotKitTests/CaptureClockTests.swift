import AVFoundation
import Foundation
import Testing
@testable import EarshotKit

private func host(_ seconds: Double) -> UInt64 { AVAudioTime.hostTime(forSeconds: seconds) }

/// Remembers what reached the file: frame counts, and whether each buffer was all zeros.
private final class RecordingSink: AudioSinking, @unchecked Sendable {
    struct Entry: Equatable {
        var frames: AVAudioFrameCount
        var silent: Bool
        var sampleRate: Double
    }

    let url = URL(fileURLWithPath: "recording.caf")
    let entries = Locked<[Entry]>([])

    func append(_ input: AVAudioPCMBuffer) throws {
        let silent = CaptureSession.measure(input).peak == 0
        entries.update { $0.append(Entry(frames: input.frameLength, silent: silent, sampleRate: input.format.sampleRate)) }
    }

    func finish() throws {}

    var silentFrames: AVAudioFrameCount { entries.get.filter(\.silent).reduce(0) { $0 + $1.frames } }
}

struct CaptureClockTests {
    // MARK: The one clock

    @Test func theClockStartsAtTheEarliestTracksFirstBuffer() {
        let session = CaptureSession()
        #expect(session.firstHostTime == nil)
        #expect(session.offset(forHostTime: host(100)) == nil)
        #expect(session.currentOffset() == nil)
        session.observe(.them, level: (0, 0), hostTime: host(100.25))
        #expect(session.firstHostTime == host(100.25))
        session.observe(.me, level: (0, 0), hostTime: host(100))  // the mic's first buffer was captured earlier
        session.observe(.them, level: (0, 0), hostTime: host(99))  // a later buffer never moves the start
        #expect(session.firstHostTime == host(100))
    }

    @Test func offsetsAreSecondsSinceTheFirstBuffer() throws {
        let session = CaptureSession()
        session.observe(.me, level: (0, 0), hostTime: host(500))
        #expect(abs(try #require(session.offset(forHostTime: host(512.5))) - 12.5) < 0.001)
        #expect(session.offset(forHostTime: host(500)) == 0)
        #expect(session.offset(forHostTime: host(499)) == 0)  // never before the start
    }

    @Test func theCurrentOffsetComesFromTheHostClock() throws {
        let session = CaptureSession()
        let now = AVAudioTime.seconds(forHostTime: mach_absolute_time())
        session.observe(.me, level: (0, 0), hostTime: host(now - 3))
        let offset = try #require(session.currentOffset())
        #expect(offset >= 3 && offset < 4)
    }

    // MARK: The live feed

    @Test func theLiveFeedGetsACopyWithItsTrackAndHostTime() async throws {
        let session = CaptureSession()
        let received = Locked<[(Track, Float, UInt64, Bool)]>([])
        let relay = CaptureSession.LiveRelay(track: .them) { track, buffer, hostTime in
            received.update { $0.append((track, buffer.floatChannelData![0][0], hostTime, session.firstHostTime != nil)) }
        }
        let handler = CaptureSession.makeHandler(session, .them, TrackWriter(sink: RecordingSink()), live: relay)
        let buffer = tapLikeBuffer(frames: 512, amplitude: 0.5)
        buffer.floatChannelData![0][0] = 0.25
        handler(buffer, host(42))
        buffer.floatChannelData![0][0] = -1  // the audio thread reuses its buffer
        relay.drain()
        let got = try #require(received.get.first)
        #expect(received.get.count == 1)
        #expect(got.0 == .them && got.1 == 0.25 && got.2 == host(42))
        #expect(got.3)  // the clock has started by the time the feed sees its first buffer
    }

    @Test func aSlowLiveFeedNeverHoldsUpTheAudioThread() {
        let session = CaptureSession()
        let gate = DispatchSemaphore(value: 0)
        let calls = Locked(0)
        let relay = CaptureSession.LiveRelay(track: .me) { _, _, _ in
            gate.wait()
            calls.update { $0 += 1 }
        }
        let handler = CaptureSession.makeHandler(session, .me, TrackWriter(sink: RecordingSink()), live: relay)
        let clock = ContinuousClock()
        let started = clock.now
        for _ in 0..<5 { handler(tapLikeBuffer(frames: 512, amplitude: 0.1), host(1)) }
        #expect(clock.now - started < .milliseconds(500))
        #expect(calls.get == 0)
        for _ in 0..<5 { gate.signal() }
        relay.drain()
        #expect(calls.get == 5)
    }

    @Test func withoutALiveFeedTheHandlerStillWritesAndMeasures() {
        let session = CaptureSession()
        let sink = RecordingSink()
        let writer = TrackWriter(sink: sink)
        CaptureSession.makeHandler(session, .me, writer)(tapLikeBuffer(frames: 512, amplitude: 0.5), host(7))
        writer.finish()
        #expect(sink.entries.get.count == 1)
        #expect(session.firstHostTime == host(7) && session.levels.me > 0)
    }

    @Test func stopWaitsForTheLiveFeedToGetEveryBuffer() {
        let session = CaptureSession()
        let calls = Locked(0)
        session.liveFeed = { _, _, _ in
            Thread.sleep(forTimeInterval: 0.2)  // a slow consumer
            calls.update { $0 += 1 }
        }
        let relay = session.liveRelay(for: .me)
        let handler = CaptureSession.makeHandler(session, .me, TrackWriter(sink: RecordingSink()), live: relay)
        handler(tapLikeBuffer(frames: 512, amplitude: 0.1), host(1))  // captured just before stop
        #expect(calls.get == 0)
        session.drainLive()  // what stop() runs once the mic and the tap have stopped
        #expect(calls.get == 1)
        #expect(session.relays.isEmpty)
    }

    @Test func aLiveFeedGetsARelayForEachTrack() {
        let session = CaptureSession()
        #expect(session.liveRelay(for: .me) == nil)  // no feed, no relay
        session.liveFeed = { _, _, _ in }
        #expect(session.liveRelay(for: .me) != nil && session.liveRelay(for: .them) != nil)
        #expect(Set(session.relays.keys) == [.me, .them])
    }

    // MARK: Silence for a mic restart

    @Test func onlyTheMicTrackIsPaddedAndEachTrackHasItsFile() throws {
        let folder = tempDir()
        let session = CaptureSession()
        let opened = Locked<[Track: (pads: Bool, file: String)]>([:])
        for track in [Track.me, .them] {
            try session.startTrack(track, in: folder) { writer in
                opened.update { $0[track] = (writer.padsGaps, CaptureSession.trackConfig(track).file) }
            }
        }
        #expect(opened.get[.me]?.pads == true && opened.get[.them]?.pads == false)
        #expect(opened.get[.me]?.file == "mic.caf" && opened.get[.them]?.file == "system.caf")
        #expect(FileManager.default.fileExists(atPath: folder.appending(path: "mic.caf").path))
        #expect(FileManager.default.fileExists(atPath: folder.appending(path: "system.caf").path))
    }

    @Test func theFileAndTheLiveTimelineTreatAGapTheSameWay() async {
        #expect(TrackWriter.padThreshold == LiveTranscriber.jumpThreshold)
        #expect(LiveTranscriber.jumpThreshold == CaptureSession.gapThreshold)
        for (gap, lost) in [(0.4, false), (0.7, true)] {
            let sink = RecordingSink()
            let writer = TrackWriter(sink: sink, padsGaps: true)
            writer.write(tapLikeBuffer(frames: 4_800, amplitude: 0.5), hostTime: host(200))
            writer.write(tapLikeBuffer(frames: 4_800, amplitude: 0.5), hostTime: host(200.1 + gap))
            writer.finish()
            let padded = Double(sink.silentFrames) / 48_000

            let feeder = LiveTranscriber.Feeder(track: .me, base: { host(200) })
            feeder.ready(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!)
            feeder.push(tapLikeBuffer(frames: 4_800, amplitude: 0.5), hostTime: host(200))
            feeder.push(tapLikeBuffer(frames: 4_800, amplitude: 0.5), hostTime: host(200.1 + gap))
            await feeder.drain()
            feeder.end()
            var starts: [Int64] = []
            for await input in feeder.stream { starts.append(input.bufferStartTime?.value ?? -1) }
            let jumped = Double(starts[1] - 1_600) / 16_000

            #expect(lost ? abs(padded - gap) < 0.001 : padded == 0, "gap \(gap)")
            #expect(lost ? abs(jumped - gap) < 0.001 : jumped < 0.01, "gap \(gap)")  // no jump: follows on
        }
    }

    @Test func aRestartGapIsFilledWithSilenceOfTheSameLength() {
        let sink = RecordingSink()
        let writer = TrackWriter(sink: sink, padsGaps: true)
        writer.write(tapLikeBuffer(frames: 4_800, amplitude: 0.5), hostTime: host(200))
        writer.write(tapLikeBuffer(frames: 4_800, amplitude: 0.5), hostTime: host(200.1))
        writer.write(tapLikeBuffer(frames: 4_800, amplitude: 0.5), hostTime: host(203.2))  // 3 s with no buffers
        writer.write(tapLikeBuffer(frames: 4_800, amplitude: 0.5), hostTime: host(203.3))
        writer.finish()
        let entries = sink.entries.get
        #expect(entries.prefix(2).allSatisfy { !$0.silent })
        #expect(entries.last?.silent == false && entries[entries.count - 2].silent == false)
        #expect(abs(Int(sink.silentFrames) - 144_000) <= 2)  // 3.0 s at 48 kHz, in the new buffers' format
        #expect(entries.filter(\.silent).allSatisfy { $0.sampleRate == 48_000 })
        #expect(writer.errors == 0)
    }

    @Test func smallTimingJitterIsNotPadded() {
        let sink = RecordingSink()
        let writer = TrackWriter(sink: sink, padsGaps: true)
        writer.write(tapLikeBuffer(frames: 4_800, amplitude: 0.5), hostTime: host(200))
        writer.write(tapLikeBuffer(frames: 4_800, amplitude: 0.5), hostTime: host(200.12))
        writer.write(tapLikeBuffer(frames: 4_800, amplitude: 0.5), hostTime: host(200.21))  // overlaps: never padded
        writer.finish()
        #expect(sink.silentFrames == 0 && sink.entries.get.count == 3)
    }

    @Test func onlyAPaddingTrackIsPadded() {
        let sink = RecordingSink()
        let writer = TrackWriter(sink: sink)
        writer.write(tapLikeBuffer(frames: 4_800, amplitude: 0.5), hostTime: host(200))
        writer.write(tapLikeBuffer(frames: 4_800, amplitude: 0.5), hostTime: host(260))
        writer.finish()
        #expect(sink.silentFrames == 0)
    }

    @Test func aVeryLongGapIsPaddedOnlyUpToTheLimit() {
        let sink = RecordingSink()
        let writer = TrackWriter(sink: sink, padsGaps: true, maxPad: 2)
        writer.write(tapLikeBuffer(frames: 4_800, amplitude: 0.5), hostTime: host(200))
        writer.write(tapLikeBuffer(frames: 4_800, amplitude: 0.5), hostTime: host(5_000))
        writer.finish()
        #expect(sink.silentFrames == 96_000)
        #expect(TrackWriter.maxPad >= 3_600)
    }

    @Test func thePaddedMicFileMatchesWallClockTime() throws {
        let url = tempDir().appending(path: "mic.caf")
        let writer = TrackWriter(sink: try AudioFileSink(url: url, sampleRate: 16_000), padsGaps: true)
        for index in 0..<5 { writer.write(tapLikeBuffer(frames: 4_800, amplitude: 0.5), hostTime: host(300 + Double(index) / 10)) }
        // The new device runs at 44.1 kHz mono and comes back 2 s after the last buffer ended.
        let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
        for index in 0..<5 {
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4_410)!
            buffer.frameLength = 4_410
            for frame in 0..<4_410 { buffer.floatChannelData![0][frame] = 0.4 * sin(Float(frame) * 0.06) }
            writer.write(buffer, hostTime: host(302.5 + Double(index) / 10))
        }
        writer.finish()
        let seconds = Double(try AVAudioFile(forReading: url).length) / 16_000
        #expect(abs(seconds - 3.0) < 0.02)  // 0.5 s, then 2 s of silence, then 0.5 s
    }
}
