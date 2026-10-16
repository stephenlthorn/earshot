import AVFoundation
import Foundation
import Testing
@testable import EarshotKit

let deviceTests = ProcessInfo.processInfo.environment["EARSHOT_DEVICE_TESTS"] == "1"

func say(_ text: String, to url: URL) async throws {
    let out = try await ProcessRunner().run("/usr/bin/say", ["-o", url.path, text], stdin: nil, directory: nil,
                                            environment: [:], timeout: .seconds(60))
    #expect(out.status == 0)
}

@Suite(.enabled(if: deviceTests, "needs EARSHOT_DEVICE_TESTS=1 and macOS 26 speech assets"))
struct DeviceAudioTests {
    @Test func transcribesAFileOnDevice() async throws {
        let audio = tempDir().appending(path: "said.aiff")
        try await say("Ashley needs to send the proposal by Friday. Sam will book the venue.", to: audio)
        let segments = try await AppleSpeechTranscriber().transcribe(audio, track: .them, locale: Locale(identifier: "en-US"))
        let text = segments.map(\.text).joined(separator: " ")
        #expect(text.contains("Ashley") && text.contains("Friday") && text.contains("venue"))
        #expect(segments.allSatisfy { $0.track == .them && $0.end > $0.start && $0.text == $0.text.trimmingCharacters(in: .whitespaces) })
    }

    @Test func compressesCafToAShorterM4AOfTheSameLength() async throws {
        let folder = tempDir()
        let said = folder.appending(path: "said.aiff"), caf = folder.appending(path: "said.caf"), m4a = folder.appending(path: "said.m4a")
        try await say("This is a compression test that runs for a few seconds.", to: said)
        let converted = try await ProcessRunner().run("/usr/bin/afconvert", ["-f", "caff", "-d", "LEI16@16000", "-c", "1", said.path, caf.path],
                                                      stdin: nil, directory: nil, environment: [:], timeout: .seconds(60))
        #expect(converted.status == 0)
        let compressor = AudioCompressor()
        try await compressor.compress(caf, to: m4a)
        #expect(abs(try compressor.duration(of: m4a) - compressor.duration(of: caf)) < 0.2)
        let size = { (url: URL) in try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0 }
        #expect(try size(m4a) < size(caf))
    }

    @Test(.timeLimit(.minutes(1))) func aMissingFileThrowsPromptly() async throws {
        let missing = tempDir().appending(path: "nowhere.caf")
        let clock = ContinuousClock()
        let started = clock.now
        await #expect(throws: (any Error).self) {
            _ = try await AppleSpeechTranscriber().transcribe(missing, track: .me, locale: Locale(identifier: "en-US"))
        }
        #expect(clock.now - started < .seconds(5))
    }

    @Test(.timeLimit(.minutes(1))) func aFileThatIsNotAudioThrowsInsteadOfHanging() async throws {
        let garbage = tempDir().appending(path: "garbage.caf")
        try Data((0..<2_048).map { _ in UInt8.random(in: 0...255) }).write(to: garbage)
        let clock = ContinuousClock()
        let started = clock.now
        await #expect(throws: (any Error).self) {
            _ = try await AppleSpeechTranscriber().transcribe(garbage, track: .me, locale: Locale(identifier: "en-US"))
        }
        #expect(clock.now - started < .seconds(5))
    }
}

/// A mono 16 kHz Int16 CAF holding a tone, written with AVAudioFile (the format the recorder produces).
func writeToneCaf(seconds: Int) throws -> URL {
    let url = tempDir().appending(path: "tone.caf")
    let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true)!
    let file = try AVAudioFile(forWriting: url, settings: format.settings, commonFormat: .pcmFormatInt16, interleaved: true)
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16_000)!
    buffer.frameLength = 16_000
    let samples = buffer.int16ChannelData![0]
    for second in 0..<seconds {
        for frame in 0..<16_000 { samples[frame] = Int16(8_000 * sin(Double(second * 16_000 + frame) * 0.05)) }
        try file.write(from: buffer)
    }
    file.close()
    return url
}

struct AudioCleanupTests {
    @Test func compressesAToneCaf() async throws {
        let caf = try writeToneCaf(seconds: 3)
        let m4a = caf.deletingLastPathComponent().appending(path: "tone.m4a")
        let compressor = AudioCompressor()
        try await compressor.compress(caf, to: m4a)
        #expect(abs(try compressor.duration(of: m4a) - compressor.duration(of: caf)) < 0.2)
    }

    @Test func aCancelledCompressionThrowsAndLeavesNoFile() async throws {
        let caf = try writeToneCaf(seconds: 5)
        let m4a = caf.deletingLastPathComponent().appending(path: "tone.m4a")
        let task = Task {
            try? await Task.sleep(for: .seconds(60))  // ends the moment the task is cancelled
            try await AudioCompressor().compress(caf, to: m4a)
        }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(!FileManager.default.fileExists(atPath: m4a.path))
    }

    @Test func aSourceThatFailsHalfWayLeavesNoPartialFile() async throws {
        let caf = try writeToneCaf(seconds: 20)
        let cut = caf.deletingLastPathComponent().appending(path: "cut.caf")
        let m4a = caf.deletingLastPathComponent().appending(path: "cut.m4a")
        // The header still promises 20 seconds, so reading fails after the first few chunks.
        try Data(contentsOf: caf).prefix(320_000).write(to: cut)
        await #expect(throws: (any Error).self) { try await AudioCompressor().compress(cut, to: m4a) }
        #expect(!FileManager.default.fileExists(atPath: m4a.path))
    }
}

struct TranscriberLifecycleTests {
    struct Boom: Error {}

    /// A listener that never hears anything, like iterating `transcriber.results` when nothing finishes it.
    static func listenForever(_ ended: Locked<Bool>) -> @Sendable () async throws -> [Segment] {
        {
            defer { ended.update { $0 = true } }
            try await Task.sleep(for: .seconds(10))  // long past any wait below, short enough that a regression fails instead of hanging
            return []
        }
    }

    static func waitUntil(_ condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition(), ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(10)) }
        return condition()
    }

    @Test func anAnalysisFailureStopsTheListenerAndTheAnalyzer() async throws {
        let ended = Locked(false), stopped = Locked(false)
        await #expect(throws: Boom.self) {
            _ = try await AppleSpeechTranscriber.collecting(Self.listenForever(ended), during: { throw Boom() },
                                                            stop: { stopped.update { $0 = true } })
        }
        #expect(stopped.get)
        #expect(await Self.waitUntil { ended.get })
    }

    @Test func cancellingTheCallerStopsTheListener() async throws {
        let ended = Locked(false)
        let task = Task {
            try await AppleSpeechTranscriber.collecting(Self.listenForever(ended), during: {}, stop: {})
        }
        task.cancel()
        await #expect(throws: CancellationError.self) { _ = try await task.value }
        #expect(await Self.waitUntil { ended.get })
    }

    @Test func returnsWhatWasHeardAndLeavesTheAnalyzerAlone() async throws {
        let stopped = Locked(false)
        let heard = [Segment(track: .me, start: 0, end: 1, text: "Hello")]
        let result = try await AppleSpeechTranscriber.collecting({ heard }, during: {}, stop: { stopped.update { $0 = true } })
        #expect(result == heard)
        #expect(!stopped.get)
    }
}
