import CoreGraphics
import Foundation
import Testing
@testable import EarshotKit

// A sample in flight when screen reading is switched off or narrowed is dropped once the capture or the read
// returns, with its screenshot. The app stops the sampler (cancels its task) on those switches, so the tests cancel
// the sampling task from inside the capture or the read. Fixtures are shared with ScreenTests.swift.

private let noSecureInput = ScreenFixtures.noSecureInput
private func slide(_ n: Int) -> String { ScreenFixtures.slide(n) }

/// Returns `image`, running `during` first, as a stop that arrives while the system captures.
private struct HookedCapturer: ScreenCapturing {
    var image: CGImage = ScreenFixtures.leftDark
    var during: @Sendable () -> Void = {}

    func capture(appBundlePrefix: String?, wholeDisplay: Bool, maxWidth: Int) async throws -> CGImage? {
        during()
        return image
    }

    func hasPermission() -> Bool { true }
}

/// Returns `text`, running `during` first, as a stop that arrives while Vision reads; counts its calls.
private final class HookedRecognizer: TextRecognizing, @unchecked Sendable {
    let text: String
    let during: @Sendable () -> Void
    let calls = Locked(0)

    init(_ text: String, during: @escaping @Sendable () -> Void = {}) {
        self.text = text
        self.during = during
    }

    func recognize(_ image: CGImage) async throws -> String {
        calls.update { $0 += 1 }
        during()
        return text
    }
}

/// Cancels the task that is running, as the app does when a screen switch goes off.
private let stop: @Sendable () -> Void = { withUnsafeCurrentTask { $0?.cancel() } }

private func sampler(_ folder: URL, capturer: HookedCapturer = HookedCapturer(), recognizer: HookedRecognizer,
                     options: ScreenSampler.Options = .init(keepImages: true)) -> ScreenSampler {
    ScreenSampler(folder: folder, capturer: capturer, recognizer: recognizer, secureInput: noSecureInput,
                  appBundlePrefix: { "us.zoom.xos" }, now: { 30 }, sleep: { _ in }, options: options)
}

struct ScreenSamplerSwitchTests {
    @Test func aStopDuringTheCaptureDropsTheFrameUnread() async throws {
        // A capture that ignores the cancel still returns its frame; it is never read or kept.
        let folder = tempDir()
        let recognizer = HookedRecognizer(slide(1))
        let s = sampler(folder, capturer: HookedCapturer(during: stop), recognizer: recognizer)
        let outcome = await Task { await s.sampleOnce() }.value
        #expect(outcome == .skipped(.cancelled))
        #expect(recognizer.calls.get == 0)
        #expect(await s.moments().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: folder.appending(path: MeetingFile.screenFolder).path))
    }

    @Test func aStopDuringTheReadDropsTheMomentAndItsImage() async throws {
        let folder = tempDir()
        let s = sampler(folder, recognizer: HookedRecognizer(slide(1), during: stop))
        let outcome = await Task { await s.sampleOnce() }.value
        #expect(outcome == .skipped(.cancelled))
        #expect(await s.moments().isEmpty)
        try await s.save()
        #expect(try JSONFiles.read(ScreenFile.self, from: folder.appending(path: MeetingFile.screen)).moments.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: folder.appending(path: MeetingFile.screenFolder).path))
    }

    @Test func withoutAStopTheMomentAndItsImageAreKept() async throws {
        let folder = tempDir()
        let s = sampler(folder, recognizer: HookedRecognizer(slide(1)))
        guard case .kept(let moment) = await Task(operation: { await s.sampleOnce() }).value else {
            Issue.record("not kept")
            return
        }
        #expect(moment.text == slide(1) && moment.image != nil)
        #expect(FileManager.default.fileExists(atPath: folder.appending(path: MeetingFile.screenFolder).path))
    }
}
