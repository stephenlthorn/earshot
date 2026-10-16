import CoreGraphics
import Foundation
import Testing
@testable import EarshotKit

// The sampler's tests, split from ScreenTests.swift to keep each file under 800 lines. Fixtures are shared there.

private let leftDark = ScreenFixtures.leftDark
private let rightDark = ScreenFixtures.rightDark
private func slide(_ n: Int) -> String { ScreenFixtures.slide(n) }
private let noSecureInput = ScreenFixtures.noSecureInput

private final class FakeCapturer: ScreenCapturing, @unchecked Sendable {
    struct Call: Equatable { var app: String?; var wholeDisplay: Bool; var maxWidth: Int }
    private let state: Locked<(images: [CGImage?], calls: [Call])>
    let permission: Bool

    init(_ images: [CGImage?], permission: Bool = true) {
        state = Locked((images, []))
        self.permission = permission
    }

    var calls: [Call] { state.get.calls }

    func capture(appBundlePrefix: String?, wholeDisplay: Bool, maxWidth: Int) async throws -> CGImage? {
        var next: CGImage?
        state.update { value in
            value.calls.append(Call(app: appBundlePrefix, wholeDisplay: wholeDisplay, maxWidth: maxWidth))
            next = value.images.count > 1 ? value.images.removeFirst() : value.images.first ?? nil
        }
        return next
    }

    func hasPermission() -> Bool { permission }
}

private final class FakeRecognizer: TextRecognizing, @unchecked Sendable {
    private let state: Locked<(texts: [String], count: Int)>

    init(_ texts: [String]) { state = Locked((texts, 0)) }

    var count: Int { state.get.count }

    func recognize(_ image: CGImage) async throws -> String {
        var next = ""
        state.update { value in
            value.count += 1
            next = value.texts.count > 1 ? value.texts.removeFirst() : value.texts.first ?? ""
        }
        return next
    }
}

private func sampler(_ folder: URL, capturer: FakeCapturer, recognizer: FakeRecognizer,
                     secure: SecureInputCheck = noSecureInput, app: String? = "us.zoom.xos",
                     clock: Locked<Double> = Locked(10), sleeps: Locked<[Duration]> = Locked([]), maxSleeps: Int = 0,
                     options: ScreenSampler.Options = ScreenSampler.Options()) -> ScreenSampler {
    ScreenSampler(folder: folder, capturer: capturer, recognizer: recognizer, secureInput: secure,
                  appBundlePrefix: { app }, now: { clock.get },
                  sleep: { duration in
                      var count = 0
                      sleeps.update { $0.append(duration); count = $0.count }
                      clock.update { $0 += 15 }
                      if count > maxSleeps { throw CancellationError() }
                  },
                  options: options)
}

// MARK: - The sampler

struct ScreenSamplerTests {
    @Test func keepsAChangedFrameWithRedactedTextAtTheMeetingOffset() async throws {
        let capturer = FakeCapturer([leftDark])
        let recognizer = FakeRecognizer(["Revenue by region for 2027\npassword: hunter2\nCall 123456789012"])
        let s = sampler(tempDir(), capturer: capturer, recognizer: recognizer, clock: Locked(42.5))
        let outcome = await s.sampleOnce()
        let moments = await s.moments()
        #expect(moments == [ScreenMoment(offset: 42.5, text: "Revenue by region for 2027\nCall [number]")])
        #expect(outcome == .kept(moments[0]))
        #expect(capturer.calls == [.init(app: "us.zoom.xos", wholeDisplay: false, maxWidth: 1440)])
    }

    @Test func passesTheWholeDisplayChoiceToTheCapturer() async {
        let capturer = FakeCapturer([leftDark])
        let s = sampler(tempDir(), capturer: capturer, recognizer: FakeRecognizer([slide(1)]),
                        options: ScreenSampler.Options(wholeDisplay: true))
        _ = await s.sampleOnce()
        #expect(capturer.calls == [.init(app: "us.zoom.xos", wholeDisplay: true, maxWidth: 1440)])
    }

    @Test func anUnchangedFrameIsNotRead() async {
        let recognizer = FakeRecognizer([slide(1), slide(2)])
        let s = sampler(tempDir(), capturer: FakeCapturer([leftDark, leftDark]), recognizer: recognizer)
        _ = await s.sampleOnce()
        #expect(await s.sampleOnce() == .skipped(.unchanged))
        #expect(recognizer.count == 1)
        #expect(await s.moments().count == 1)
    }

    @Test func shortAndDuplicateTextIsDropped() async {
        let s = sampler(tempDir(), capturer: FakeCapturer([leftDark, rightDark, leftDark]),
                        recognizer: FakeRecognizer(["tiny", slide(1), slide(1)]))
        #expect(await s.sampleOnce() == .skipped(.tooLittleText))
        #expect(await s.sampleOnce() != .skipped(.tooLittleText))
        #expect(await s.sampleOnce() == .skipped(.duplicate))
        #expect(await s.moments().map(\.text) == [slide(1)])
    }

    @Test func stopsAtTheCap() async {
        let frames = (0..<130).map { $0 % 2 == 0 ? leftDark : rightDark }
        let capturer = FakeCapturer(frames)
        let s = sampler(tempDir(), capturer: capturer, recognizer: FakeRecognizer((0..<130).map(slide)))
        for _ in 0..<125 { _ = await s.sampleOnce() }
        #expect(await s.moments().count == 120)
        #expect(await s.sampleOnce() == .skipped(.full))
        #expect(capturer.calls.count == 120)
    }

    @Test func secureInputSkipsBeforeCapturing() async {
        let capturer = FakeCapturer([leftDark])
        let secure = SecureInputCheck(secureInputOn: { true }, frontmostBundleID: { "us.zoom.xos" })
        let s = sampler(tempDir(), capturer: capturer, recognizer: FakeRecognizer([slide(1)]), secure: secure)
        #expect(await s.sampleOnce() == .skipped(.secureInput))
        #expect(capturer.calls.isEmpty)
        #expect(await s.moments().isEmpty)
    }

    @Test func aFrontmostPasswordManagerSkips() async {
        let capturer = FakeCapturer([leftDark])
        let secure = SecureInputCheck(secureInputOn: { false }, frontmostBundleID: { "com.bitwarden.desktop" })
        let s = sampler(tempDir(), capturer: capturer, recognizer: FakeRecognizer([slide(1)]), secure: secure)
        #expect(await s.sampleOnce() == .skipped(.secureInput))
        #expect(capturer.calls.isEmpty)
    }

    @Test func noCallAppMeansNoCapture() async {
        let capturer = FakeCapturer([leftDark])
        let s = sampler(tempDir(), capturer: capturer, recognizer: FakeRecognizer([slide(1)]), app: nil,
                        options: ScreenSampler.Options(wholeDisplay: true))
        #expect(await s.sampleOnce() == .skipped(.noCallApp))
        #expect(capturer.calls.isEmpty)
    }

    @Test func noPermissionMeansNoCapture() async {
        let capturer = FakeCapturer([leftDark], permission: false)
        let s = sampler(tempDir(), capturer: capturer, recognizer: FakeRecognizer([slide(1)]))
        #expect(await s.sampleOnce() == .skipped(.noPermission))
        #expect(capturer.calls.isEmpty)
    }

    @Test func nothingOnScreenOrNoClockYetIsSkipped() async {
        let empty = sampler(tempDir(), capturer: FakeCapturer([nil]), recognizer: FakeRecognizer([slide(1)]))
        #expect(await empty.sampleOnce() == .skipped(.nothingToCapture))
        let early = ScreenSampler(folder: tempDir(), capturer: FakeCapturer([leftDark]), recognizer: FakeRecognizer([slide(1)]),
                                  secureInput: noSecureInput, appBundlePrefix: { "us.zoom.xos" }, now: { nil },
                                  sleep: { _ in })
        #expect(await early.sampleOnce() == .skipped(.notStarted))
    }

    @Test func failuresAreReportedNotThrown() async {
        struct Boom: Error {}
        final class Failing: ScreenCapturing, @unchecked Sendable {
            func capture(appBundlePrefix: String?, wholeDisplay: Bool, maxWidth: Int) async throws -> CGImage? { throw Boom() }
            func hasPermission() -> Bool { true }
        }
        let s = ScreenSampler(folder: tempDir(), capturer: Failing(), recognizer: FakeRecognizer([slide(1)]),
                              secureInput: noSecureInput, appBundlePrefix: { "us.zoom.xos" }, now: { 1 }, sleep: { _ in })
        guard case .failed = await s.sampleOnce() else { Issue.record("expected a failure"); return }
        #expect(await s.lastError?.hasPrefix("Earshot couldn't read the screen") == true)
    }

    @Test func saveWritesScreenJSONVersionOneWithoutImages() async throws {
        let folder = tempDir()
        let s = sampler(folder, capturer: FakeCapturer([leftDark, rightDark]), recognizer: FakeRecognizer([slide(1), slide(2)]))
        _ = await s.sampleOnce()
        _ = await s.sampleOnce()
        try await s.save()
        let raw = try JSONSerialization.jsonObject(with: Data(contentsOf: folder.appending(path: MeetingFile.screen))) as? [String: Any]
        #expect(raw?["version"] as? Int == 1)
        let file = try JSONFiles.read(ScreenFile.self, from: folder.appending(path: MeetingFile.screen))
        #expect(file.moments.map(\.text) == [slide(1), slide(2)])
        #expect(file.moments.allSatisfy { $0.image == nil })
        #expect(!FileManager.default.fileExists(atPath: folder.appending(path: MeetingFile.screenFolder).path))
    }

    @Test func keepScreenshotsWritesPNGsUnderTheScreenFolder() async throws {
        let folder = tempDir()
        let s = sampler(folder, capturer: FakeCapturer([leftDark, rightDark]), recognizer: FakeRecognizer([slide(1), slide(2)]),
                        options: ScreenSampler.Options(keepImages: true))
        _ = await s.sampleOnce()
        _ = await s.sampleOnce()
        try await s.save()
        let file = try JSONFiles.read(ScreenFile.self, from: folder.appending(path: MeetingFile.screen))
        #expect(file.moments.map(\.image) == ["001.png", "002.png"])
        for name in ["001.png", "002.png"] {
            let data = try Data(contentsOf: folder.appending(path: MeetingFile.screenFolder).appending(path: name))
            #expect(data.starts(with: [0x89, 0x50, 0x4E, 0x47]))
        }
    }

    @Test func runSamplesEveryFifteenSecondsAndSavesUntilCancelled() async throws {
        let folder = tempDir()
        let sleeps = Locked<[Duration]>([])
        let clock = Locked<Double>(0)
        let s = sampler(folder, capturer: FakeCapturer([leftDark, rightDark, leftDark]),
                        recognizer: FakeRecognizer([slide(1), slide(2), slide(3)]), clock: clock, sleeps: sleeps, maxSleeps: 2)
        await s.run()
        #expect(sleeps.get == [.seconds(15), .seconds(15), .seconds(15)])
        #expect(await s.moments().map(\.offset) == [0, 15, 30])
        let file = try JSONFiles.read(ScreenFile.self, from: folder.appending(path: MeetingFile.screen))
        #expect(file.moments.count == 3)
    }

    @Test func runStopsOnceFull() async {
        let frames = (0..<130).map { $0 % 2 == 0 ? leftDark : rightDark }
        let sleeps = Locked<[Duration]>([])
        let s = sampler(tempDir(), capturer: FakeCapturer(frames), recognizer: FakeRecognizer((0..<130).map(slide)),
                        sleeps: sleeps, maxSleeps: 1000)
        await s.run()
        #expect(await s.moments().count == 120)
        #expect(sleeps.get.count == 119)
    }

    // MARK: Fix round 1

    @Test func secureInputComingOnDuringTheCaptureSkipsTheFrame() async {
        let checks = Locked(0)
        let secure = SecureInputCheck(secureInputOn: { checks.update { $0 += 1 }; return checks.get >= 2 },
                                      frontmostBundleID: { "us.zoom.xos" })
        let capturer = FakeCapturer([leftDark])
        let recognizer = FakeRecognizer([slide(1)])
        let s = sampler(tempDir(), capturer: capturer, recognizer: recognizer, secure: secure)
        #expect(await s.sampleOnce() == .skipped(.secureInput))
        #expect(capturer.calls.count == 1)
        #expect(recognizer.count == 0)
        #expect(await s.moments().isEmpty)
    }

    @Test(.timeLimit(.minutes(1))) func runReturnsWhenItsTaskIsCancelled() async {
        let s = ScreenSampler(folder: tempDir(), capturer: FakeCapturer([leftDark]), recognizer: FakeRecognizer([slide(1)]),
                              secureInput: noSecureInput, appBundlePrefix: { "us.zoom.xos" }, now: { 1 },
                              sleep: { _ in await Task.yield() })
        let task = Task { await s.run() }
        while await s.moments().isEmpty { await Task.yield() }
        task.cancel()
        await task.value
        #expect(await s.moments().count == 1)
    }

    @Test func aSaveFailureIsLogged() async throws {
        let file = tempDir().appending(path: "not-a-folder")
        try Data("x".utf8).write(to: file)
        let s = sampler(file, capturer: FakeCapturer([leftDark]), recognizer: FakeRecognizer([slide(1)]))
        await s.run()
        #expect(await s.moments().count == 1)
        #expect(await s.lastError?.hasPrefix("Earshot couldn't save the screen text") == true)
    }

    @Test func runSavesAfterEachKeptMoment() async {
        let folder = tempDir()
        let savedAtFirstSleep = Locked<Int?>(nil)
        let s = ScreenSampler(folder: folder, capturer: FakeCapturer([leftDark, rightDark]),
                              recognizer: FakeRecognizer([slide(1), slide(2)]), secureInput: noSecureInput,
                              appBundlePrefix: { "us.zoom.xos" }, now: { 1 },
                              sleep: { _ in
                                  if savedAtFirstSleep.get != nil { throw CancellationError() }
                                  let file = try? JSONFiles.read(ScreenFile.self, from: folder.appending(path: MeetingFile.screen))
                                  savedAtFirstSleep.update { $0 = file?.moments.count ?? 0 }
                              })
        await s.run()
        #expect(savedAtFirstSleep.get == 1)
    }

    @Test func aSecondSamplerOnTheSameFolderKeepsTheEarlierMomentsAndScreenshots() async throws {
        let folder = tempDir()
        let options = ScreenSampler.Options(keepImages: true)
        let first = sampler(folder, capturer: FakeCapturer([leftDark, rightDark]),
                            recognizer: FakeRecognizer([slide(1), slide(2)]), options: options)
        _ = await first.sampleOnce()
        _ = await first.sampleOnce()
        try await first.save()
        let second = sampler(folder, capturer: FakeCapturer([leftDark, rightDark]),
                             recognizer: FakeRecognizer([slide(3), slide(4)]), clock: Locked(100), options: options)
        _ = await second.sampleOnce()
        _ = await second.sampleOnce()
        try await second.save()
        let file = try JSONFiles.read(ScreenFile.self, from: folder.appending(path: MeetingFile.screen))
        #expect(file.moments.map(\.text) == [slide(1), slide(2), slide(3), slide(4)])
        #expect(file.moments.map(\.image) == ["001.png", "002.png", "003.png", "004.png"])
        let names = try FileManager.default.contentsOfDirectory(atPath: folder.appending(path: MeetingFile.screenFolder).path)
        #expect(Set(names) == ["001.png", "002.png", "003.png", "004.png"])
    }

    @Test func aResumedSamplerCountsEarlierMomentsForTheCapAndDuplicates() async throws {
        let folder = tempDir()
        let url = folder.appending(path: MeetingFile.screen)
        try JSONFiles.write(ScreenFile(moments: [ScreenMoment(offset: 5, text: slide(1))]), to: url)
        let s = sampler(folder, capturer: FakeCapturer([leftDark]), recognizer: FakeRecognizer([slide(1)]))
        #expect(await s.sampleOnce() == .skipped(.duplicate))
        #expect(await s.moments().map(\.text) == [slide(1)])

        let full = (0..<ScreenFrameFilter.maxMoments).map { ScreenMoment(offset: Double($0), text: slide($0)) }
        try JSONFiles.write(ScreenFile(moments: full), to: url)
        let capturer = FakeCapturer([rightDark])
        let late = sampler(folder, capturer: capturer, recognizer: FakeRecognizer([slide(500)]))
        #expect(await late.sampleOnce() == .skipped(.full))
        #expect(capturer.calls.isEmpty)
    }

    @Test func aScreenshotNeverReplacesOneAlreadyInTheFolder() async throws {
        let folder = tempDir()
        let screens = folder.appending(path: MeetingFile.screenFolder)
        try FileManager.default.createDirectory(at: screens, withIntermediateDirectories: true)
        try Data("old".utf8).write(to: screens.appending(path: "007.png"))
        let s = sampler(folder, capturer: FakeCapturer([leftDark]), recognizer: FakeRecognizer([slide(1)]),
                        options: ScreenSampler.Options(keepImages: true))
        _ = await s.sampleOnce()
        #expect(await s.moments().map(\.image) == ["008.png"])
        #expect(try Data(contentsOf: screens.appending(path: "007.png")) == Data("old".utf8))
        #expect(ScreenSampler.nextImageNumber(after: []) == 1)
        #expect(ScreenSampler.nextImageNumber(after: ["002.png", "notes.txt", "010.PNG", "x.png"]) == 11)
    }

    @Test func aStopWhileCapturingIsNotAFailure() async {
        struct Stopping: ScreenCapturing {
            func capture(appBundlePrefix: String?, wholeDisplay: Bool, maxWidth: Int) async throws -> CGImage? {
                throw CancellationError()
            }
            func hasPermission() -> Bool { true }
        }
        let s = ScreenSampler(folder: tempDir(), capturer: Stopping(), recognizer: FakeRecognizer([slide(1)]),
                              secureInput: noSecureInput, appBundlePrefix: { "us.zoom.xos" }, now: { 1 }, sleep: { _ in })
        #expect(await s.sampleOnce() == .skipped(.cancelled))
        #expect(await s.lastError == nil)
    }
}
