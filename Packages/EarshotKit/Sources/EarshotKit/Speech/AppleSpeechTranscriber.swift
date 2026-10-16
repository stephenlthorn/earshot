import AVFoundation
import CoreMedia
import Foundation
import Speech

public enum SpeechSetupError: Error, Equatable, LocalizedError {
    case unsupportedLocale(String)
    public var errorDescription: String? {
        switch self {
        case let .unsupportedLocale(id): "On-device transcription doesn't support \(id). Pick another language in Settings."
        }
    }
}

/// On-device transcription with SpeechAnalyzer (macOS 26). Needs no permission prompt (verified 2026-10-14).
public struct AppleSpeechTranscriber: Transcribing {
    public init() {}

    /// Makes sure the speech model for `locale` is on this Mac, downloading it if needed.
    @discardableResult
    public static func prepare(locale: Locale, progress: @Sendable (Progress) -> Void = { _ in }) async throws -> Locale {
        guard let supported = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else {
            throw SpeechSetupError.unsupportedLocale(locale.identifier)
        }
        // AssetInventory.status can report .supported for an installed model, so always ask for a request:
        // nil means nothing to download.
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [module(supported)]) {
            progress(request.progress)
            try await request.downloadAndInstall()
        }
        return supported
    }

    static func module(_ locale: Locale) -> SpeechTranscriber {
        // One final result per sentence, with result.range giving its start and end.
        SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [], attributeOptions: [.audioTimeRange])
    }

    /// Runs `analysis` while `collect` gathers results in its own task. If `analysis` throws, or the caller is
    /// cancelled, the collector is cancelled (and `stop` runs on an analysis failure) before the error goes on,
    /// so nothing is left listening for results that will never finish.
    static func collecting<Collected: Sendable>(
        _ collect: @escaping @Sendable () async throws -> Collected,
        during analysis: () async throws -> Void,
        stop: () async -> Void
    ) async throws -> Collected {
        let collector = Task { try await collect() }
        do {
            try await analysis()
        } catch {
            collector.cancel()
            await stop()
            throw error
        }
        let collected = try await withTaskCancellationHandler { try await collector.value } onCancel: { collector.cancel() }
        try Task.checkCancellation()
        return collected
    }

    public func transcribe(_ file: URL, track: Track, locale: Locale) async throws -> [Segment] {
        let audio = try AVAudioFile(forReading: file)
        let transcriber = Self.module(try await Self.prepare(locale: locale))
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        // Start reading results before feeding audio.
        return try await Self.collecting({
            var segments: [Segment] = []
            for try await result in transcriber.results where result.isFinal {
                let text = String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { continue }
                segments.append(Segment(track: track, start: result.range.start.seconds, end: result.range.end.seconds, text: text))
            }
            return segments
        }, during: {
            if let last = try await analyzer.analyzeSequence(from: audio) {
                try await analyzer.finalizeAndFinish(through: last)
            } else {
                await analyzer.cancelAndFinishNow()
            }
        }, stop: { await analyzer.cancelAndFinishNow() })
    }
}
