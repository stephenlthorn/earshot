// Packages/EarshotKit/Sources/EarshotKit/Audio/AudioFileSink.swift
import AVFoundation
import Foundation

enum AudioFileSinkError: Error {
    case badFormat
    case converterUnavailable
    case allocationFailed
}

/// What a `TrackWriter` needs from its sink, so a test can hand it one that fails.
protocol AudioSinking: AnyObject, Sendable {
    var url: URL { get }
    func append(_ input: AVAudioPCMBuffer) throws
    func finish() throws
}

/// Converts incoming PCM (any rate, channels or interleaving) to 16-bit mono at `sampleRate` and appends it to a CAF.
/// Not realtime-safe: call it from a writer queue, never from an audio callback.
final class AudioFileSink: @unchecked Sendable {  // confined to its TrackWriter's serial queue
    let url: URL
    let outputFormat: AVAudioFormat
    private let file: AVAudioFile
    private var converter: AVAudioConverter?
    private var converterInputFormat: AVAudioFormat?

    init(url: URL, sampleRate: Double, channels: AVAudioChannelCount = 1) throws {
        guard let processing = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate,
                                             channels: channels, interleaved: false) else {
            throw AudioFileSinkError.badFormat
        }
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: channels,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        // settings = the format on disk; commonFormat/interleaved = the processing format write(from:) expects.
        file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        self.url = url
        outputFormat = processing
    }

    func append(_ input: AVAudioPCMBuffer) throws {
        guard input.frameLength > 0 else { return }
        if input.format == outputFormat {
            try file.write(from: input)
            return
        }
        let converter = try converterFor(input.format)
        let ratio = outputFormat.sampleRate / input.format.sampleRate
        let capacity = AVAudioFrameCount((Double(input.frameLength) * ratio).rounded(.up)) + 32
        guard let out = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else {
            throw AudioFileSinkError.allocationFailed
        }
        nonisolated(unsafe) let pending = input  // the input block is @Sendable; the buffer is not
        nonisolated(unsafe) var consumed = false
        var error: NSError?
        let status = converter.convert(to: out, error: &error) { _, outStatus in
            if consumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            outStatus.pointee = .haveData
            return pending
        }
        if status == .error, let error { throw error }
        if out.frameLength > 0 { try file.write(from: out) }
    }

    /// Drains the converter's filter delay (a few frames were lost without this, verified) and closes the file.
    func finish() throws {
        defer { file.close() }
        guard let converter, let out = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: 1024) else { return }
        var error: NSError?
        _ = converter.convert(to: out, error: &error) { _, outStatus in
            outStatus.pointee = .endOfStream
            return nil
        }
        if let error { throw error }
        if out.frameLength > 0 { try file.write(from: out) }
        converter.reset()
    }

    private func converterFor(_ format: AVAudioFormat) throws -> AVAudioConverter {
        if let converter, converterInputFormat == format { return converter }
        guard let made = AVAudioConverter(from: format, to: outputFormat) else { throw AudioFileSinkError.converterUnavailable }
        made.downmix = format.channelCount > outputFormat.channelCount  // mix left and right instead of dropping right
        converter = made
        converterInputFormat = format
        return made
    }
}

extension AudioFileSink: AudioSinking {}
