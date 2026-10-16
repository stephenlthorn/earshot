import AVFoundation
import Foundation

public enum AudioError: Error, LocalizedError {
    case allocationFailed
    public var errorDescription: String? { "Couldn't allocate an audio buffer." }
}

/// CAF to AAC .m4a, about 15 MB per hour at 16 kHz mono.
public struct AudioCompressor: AudioCompressing {
    public init() {}

    public func compress(_ source: URL, to destination: URL) async throws {
        let input = try AVAudioFile(forReading: source)
        let format = input.processingFormat
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: format.channelCount,
            AVEncoderBitRateKey: 32_000,
        ]
        let output = try AVAudioFile(forWriting: destination, settings: settings, commonFormat: format.commonFormat,
                                     interleaved: format.isInterleaved)
        do {
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 65_536) else { throw AudioError.allocationFailed }
            while input.framePosition < input.length {
                try Task.checkCancellation()
                try input.read(into: buffer)
                if buffer.frameLength == 0 { break }
                try output.write(from: buffer)
            }
            output.close()
        } catch {
            // Never leave half a file that looks like a finished one.
            output.close()
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
    }

    public func duration(of file: URL) throws -> Double {
        let audio = try AVAudioFile(forReading: file)
        return Double(audio.length) / audio.fileFormat.sampleRate
    }
}
