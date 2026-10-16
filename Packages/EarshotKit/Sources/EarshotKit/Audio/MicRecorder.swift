// Packages/EarshotKit/Sources/EarshotKit/Audio/MicRecorder.swift
import AVFoundation
import Foundation

public enum CaptureError: Error, LocalizedError {
    case noMicrophone
    case nothingStarted(String)

    public var errorDescription: String? {
        switch self {
        case .noMicrophone: "No microphone is available."
        case let .nothingStarted(detail): "Recording couldn't start: \(detail)"
        }
    }
}

/// The default input device through AVAudioEngine. Buffers go to `handler` on the engine's thread.
/// When the input device changes mid-recording, the engine stops itself and posts a configuration change; the
/// recorder then puts its tap back for the new device's format and starts the engine again, into the same handler
/// (the file sink converts whatever format arrives).
final class MicRecorder: @unchecked Sendable {  // started and stopped from one place; restarts run on `queue`
    typealias Handler = @Sendable (AVAudioPCMBuffer, UInt64) -> Void
    static let echoCancellationFailed = "Echo cancellation couldn't be turned on; recording without it."
    private let engine = AVAudioEngine()
    /// Runs restarts and `stop()` one at a time. `handler`, `running`, `broken` and `startedAt` are only touched on it.
    private let queue = DispatchQueue(label: "earshot.mic", qos: .userInitiated)
    private var handler: Handler?
    private var running = false
    private var broken = false
    private var startedAt = Date()
    private var observer: (any NSObjectProtocol)?
    private let found = Locked<[String]>([])

    /// Problems while recording, such as a device change the mic couldn't follow, for session.json.
    var warnings: [String] { found.get }

    /// Returns a warning if echo cancellation was asked for and couldn't be turned on; the recording goes ahead without it.
    func start(echoCancellation: Bool, handler: @escaping Handler) throws -> String? {
        let input = engine.inputNode
        var warning: String?
        if echoCancellation {
            do { try input.setVoiceProcessingEnabled(true) } catch { warning = Self.echoCancellationFailed }
        }
        try Self.installTap(on: input, handler: handler)
        engine.prepare()
        try engine.start()
        queue.sync {
            self.handler = handler
            running = true
            startedAt = Date()
        }
        observer = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine,
                                                          queue: nil, using: Self.makeConfigurationBlock(self))
        return warning
    }

    func stop() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        queue.sync {
            running = false
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
    }

    /// The input device changed. Never restart the engine inside the notification itself: it is posted on the
    /// engine's own queue, so the work moves to ours.
    private func configurationChanged() {
        queue.async { [self] in
            guard running, let handler else { return }
            let engine = engine
            let outcome = Self.restart(elapsed: Date().timeIntervalSince(startedAt), wasBroken: broken, reinstall: {
                engine.inputNode.removeTap(onBus: 0)
                try Self.installTap(on: engine.inputNode, handler: handler)
            }, start: {
                engine.prepare()
                try engine.start()
            })
            broken = outcome.broken
            if let warning = outcome.warning { found.update { $0.append(warning) } }
        }
    }

    /// Puts the tap back and starts the engine. A failure is reported once, when the mic stops working; a later
    /// device change tries again, and the mic track picks up if that works.
    static func restart(elapsed: TimeInterval, wasBroken: Bool, reinstall: () throws -> Void,
                        start: () throws -> Void) -> (broken: Bool, warning: String?) {
        do {
            try reinstall()
            try start()
            return (false, nil)
        } catch {
            return (true, wasBroken ? nil : restartFailed(at: elapsed))
        }
    }

    static func restartFailed(at elapsed: TimeInterval) -> String {
        "Your microphone changed during the recording and couldn't be restarted; the mic track stops at "
            + "\(TranscriptRenderer.timestamp(elapsed))."
    }

    private static func installTap(on input: AVAudioInputNode, handler: @escaping Handler) throws {
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw CaptureError.noMicrophone }
        input.installTap(onBus: 0, bufferSize: 4096, format: format, block: makeTapBlock(handler))
    }

    /// The tap's host time, or now if it doesn't carry one. A 0 would make the other track's offset
    /// "seconds since boot" and wreck the merge.
    static func hostTime(of when: AVAudioTime) -> UInt64 {
        when.isHostTimeValid ? when.hostTime : mach_absolute_time()
    }

    /// Nonisolated and static so the block never inherits @MainActor isolation (that traps at runtime, verified).
    private static func makeTapBlock(_ handler: @escaping Handler) -> AVAudioNodeTapBlock {
        { buffer, when in handler(buffer, hostTime(of: when)) }
    }

    /// Nonisolated and static for the same reason: the notification arrives on one of the engine's threads.
    private static func makeConfigurationBlock(_ recorder: MicRecorder) -> @Sendable (Notification) -> Void {
        { [weak recorder] _ in recorder?.configurationChanged() }
    }
}
