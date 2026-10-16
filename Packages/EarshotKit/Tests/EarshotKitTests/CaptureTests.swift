// Packages/EarshotKit/Tests/EarshotKitTests/CaptureTests.swift
import AVFoundation
import Foundation
import Testing
@testable import EarshotKit

/// 48 kHz stereo Float32 interleaved: what the process tap delivers (verified).
func tapLikeBuffer(frames: AVAudioFrameCount, amplitude: Float) -> AVAudioPCMBuffer {
    let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 2, interleaved: true)!
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
    buffer.frameLength = frames
    let samples = buffer.floatChannelData![0]
    for frame in 0..<Int(frames) {
        let value = amplitude * sin(Float(frame) * 2 * .pi * 440 / 48_000)
        samples[frame * 2] = value
        samples[frame * 2 + 1] = value
    }
    return buffer
}

/// A sink that can be told to fail, for the writer's error counting.
final class FakeSink: AudioSinking, @unchecked Sendable {
    struct Broken: Error {}
    let url = URL(fileURLWithPath: "fake.caf")
    let appended = Locked(0)
    private let failAppends: Bool
    private let failFinish: Bool

    init(failAppends: Bool = false, failFinish: Bool = false) {
        self.failAppends = failAppends
        self.failFinish = failFinish
    }

    func append(_ input: AVAudioPCMBuffer) throws {
        if failAppends { throw Broken() }
        appended.update { $0 += 1 }
    }

    func finish() throws {
        if failFinish { throw Broken() }
    }
}

struct CaptureTests {
    @Test func sinkTurnsTapAudioInto16kMonoOfTheSameLength() throws {
        let url = tempDir().appending(path: "system.caf")
        let sink = try AudioFileSink(url: url, sampleRate: 16_000)
        for _ in 0..<94 { try sink.append(tapLikeBuffer(frames: 512, amplitude: 0.5)) }  // 94 x 512 frames = 1.0027 s
        try sink.finish()
        let file = try AVAudioFile(forReading: url)
        #expect(file.fileFormat.sampleRate == 16_000 && file.fileFormat.channelCount == 1)
        let seconds = Double(file.length) / 16_000
        let expected = Double(94 * 512) / 48_000  // split up: one #expect expression was too slow to type-check
        #expect(abs(seconds - expected) < 0.01)
    }

    @Test func measuresLevelsOfInterleavedAndPlanarBuffers() {
        let loud = CaptureSession.measure(tapLikeBuffer(frames: 4800, amplitude: 0.5))
        #expect(abs(loud.peak - 0.5) < 0.01 && abs(loud.rms - 0.3536) < 0.01)
        let silent = CaptureSession.measure(tapLikeBuffer(frames: 4800, amplitude: 0))
        #expect(silent.peak == 0 && silent.rms == 0)
        let planar = AVAudioPCMBuffer(pcmFormat: AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!, frameCapacity: 160)!
        planar.frameLength = 160
        for i in 0..<160 { planar.floatChannelData![0][i] = i == 10 ? -0.8 : 0 }
        #expect(CaptureSession.measure(planar).peak == 0.8)
    }

    @Test func silenceWarningsPointToTheRightSetting() {
        #expect(CaptureSession.silentCall.contains("Screen & System Audio Recording"))
        #expect(CaptureSession.silentMic.contains("Microphone"))
    }

    @Test func measuresEveryChannelOfAPlanarBuffer() {
        // The mic's input node is planar, often with 2+ channels; the voice may be on any of them.
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4800)!
        buffer.frameLength = 4800
        for frame in 0..<4800 {
            buffer.floatChannelData![0][frame] = 0
            buffer.floatChannelData![1][frame] = 0.5 * sin(Float(frame) * 2 * .pi * 440 / 48_000)
        }
        let level = CaptureSession.measure(buffer)
        #expect(abs(level.peak - 0.5) < 0.01)
        #expect(abs(level.rms - 0.25) < 0.01)  // 0.3536 on one channel, 0 on the other, over all samples
    }

    @Test func aFailedCloseCountsAsLostAudio() {
        let writer = TrackWriter(sink: FakeSink(failFinish: true))
        writer.write(tapLikeBuffer(frames: 512, amplitude: 0.5))
        writer.finish()
        #expect(writer.errors == 1)
    }

    @Test func aFailedWriteCountsAsLostAudio() {
        let writer = TrackWriter(sink: FakeSink(failAppends: true))
        for _ in 0..<3 { writer.write(tapLikeBuffer(frames: 512, amplitude: 0.5)) }
        writer.finish()
        #expect(writer.errors == 3)
    }

    @Test func aHealthyWriterCountsNoErrorsAndSkipsEmptyBuffers() {
        let sink = FakeSink()
        let writer = TrackWriter(sink: sink)
        for _ in 0..<3 { writer.write(tapLikeBuffer(frames: 512, amplitude: 0.5)) }
        writer.write(tapLikeBuffer(frames: 0, amplitude: 0))
        writer.finish()
        #expect(writer.errors == 0)
        #expect(sink.appended.get == 3)
    }

    @Test func startWarningsEndWithOneFullStop() {
        let problem = CaptureSession.problem("Microphone", CaptureError.noMicrophone)
        #expect(problem == "Microphone: No microphone is available")
        #expect(CaptureSession.startWarning(problem) == "Microphone: No microphone is available. Recording continued without it.")
        let quiet = CaptureSession.problem("Call audio", CoreAudioError(status: -50, call: "AudioDeviceStart"))
        #expect(!quiet.hasSuffix("."))
    }

    @Test func aTrackThatFailsToStartLeavesNoFileBehind() throws {
        let folder = tempDir()
        let file = folder.appending(path: "mic.caf")
        let session = CaptureSession()
        let existedWhileStarting = Locked(false)
        #expect(throws: CaptureError.self) {
            try session.startTrack(.me, in: folder) { _ in
                existedWhileStarting.update { $0 = FileManager.default.fileExists(atPath: file.path) }
                throw CaptureError.noMicrophone
            }
        }
        #expect(existedWhileStarting.get)  // the writer had created the file, so the removal is what's being tested
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }

    @Test func aMicThatComesBackAfterADeviceChangeLeavesNoWarning() {
        let started = Locked(0)
        let outcome = MicRecorder.restart(elapsed: 751, wasBroken: false, reinstall: {}, start: { started.update { $0 += 1 } })
        #expect(outcome.broken == false && outcome.warning == nil)
        #expect(started.get == 1)
    }

    @Test func aMicThatCantRestartSaysWhenItsTrackStops() {
        let outcome = MicRecorder.restart(elapsed: 751, wasBroken: false, reinstall: {}, start: { throw CaptureError.noMicrophone })
        #expect(outcome.broken)
        #expect(outcome.warning == "Your microphone changed during the recording and couldn't be restarted; the mic track stops at 00:12:31.")
        // No tap for the new device (none there): the engine isn't started at all.
        let started = Locked(0)
        let noTap = MicRecorder.restart(elapsed: 5, wasBroken: false, reinstall: { throw CaptureError.noMicrophone },
                                        start: { started.update { $0 += 1 } })
        #expect(noTap.broken && noTap.warning?.hasSuffix("stops at 00:00:05.") == true && started.get == 0)
    }

    @Test func aMicThatStaysBrokenIsReportedOnceAndOneThatRecoversIsReportedAgainIfItBreaks() {
        let fail: () throws -> Void = { throw CaptureError.noMicrophone }
        let again = MicRecorder.restart(elapsed: 900, wasBroken: true, reinstall: {}, start: fail)
        #expect(again.broken && again.warning == nil)
        let back = MicRecorder.restart(elapsed: 960, wasBroken: true, reinstall: {}, start: {})
        #expect(!back.broken && back.warning == nil)
    }

    @Test func hostTimeFallsBackToNowWhenTheStampHasNone() {
        let before = mach_absolute_time()
        #expect(MicRecorder.hostTime(of: AVAudioTime(sampleTime: 0, atRate: 48_000)) >= before)
        #expect(MicRecorder.hostTime(of: AVAudioTime(hostTime: 12_345)) == 12_345)
        var stamp = AudioTimeStamp()
        stamp.mHostTime = 777
        #expect(SystemAudioTap.hostTime(of: stamp) >= before)  // flag not set: 777 is not to be believed
        stamp.mFlags = .hostTimeValid
        #expect(SystemAudioTap.hostTime(of: stamp) == 777)
    }
}
