import Foundation
import Testing
@testable import EarshotKit

private let zoomID = "us.zoom.xos"
private let t0 = Date(timeIntervalSince1970: 1_792_006_200)

private func proc(_ pid: Int32, _ bundleID: String?, input: Bool = true, output: Bool = true) -> AudioProcessInfo {
    AudioProcessInfo(pid: pid, bundleID: bundleID, runningInput: input, runningOutput: output, usesRealMicrophone: input)
}

/// A scripted process list. `changes()` hands the test a continuation to fire a change by hand.
private final class FakeProcessSource: AudioProcessSource, @unchecked Sendable {
    let snapshot = Locked<[AudioProcessInfo]>([])
    let reads = Locked(0)
    let continuation = Locked<AsyncStream<Void>.Continuation?>(nil)
    let changesCalls = Locked(0)

    func processes() -> [AudioProcessInfo] {
        reads.update { $0 += 1 }
        return snapshot.get
    }

    func changes() -> AsyncStream<Void> {
        let (stream, continuation) = AsyncStream.makeStream(of: Void.self)
        changesCalls.update { $0 += 1 }
        self.continuation.update { $0 = continuation }
        return stream
    }
}

/// Time the test moves by hand.
private final class FakeClock: @unchecked Sendable {
    let time = Locked(t0)
    var now: Date { time.get }
    func advance(_ seconds: TimeInterval) { time.update { $0 += seconds } }
}

private func makeMonitor(_ source: FakeProcessSource, _ clock: FakeClock,
                         sleep: @escaping @Sendable (Duration) async throws -> Void = { _ in try await Task.sleep(for: .seconds(3_600)) })
    -> MicActivityMonitor {
    MicActivityMonitor(source: source, ownPID: 1, now: { clock.now }, sleep: sleep,
                       runningApps: { [zoomID: "zoom.us"] })
}

private func collect(_ monitor: MicActivityMonitor, count: Int) async -> [CallEvent] {
    var events: [CallEvent] = []
    for await event in monitor.events {
        events.append(event)
        if events.count == count { break }
    }
    return events
}

private let zoom = CallEvent.Call(pid: 100, bundleID: zoomID, appName: "zoom.us", isDedicated: true)

@Suite(.timeLimit(.minutes(1)))
struct DetectMonitorTests {
    @Test func reportsANewCallOnce() async {
        let source = FakeProcessSource(), clock = FakeClock()
        let monitor = makeMonitor(source, clock)
        await monitor.check()
        source.snapshot.update { $0 = [proc(100, zoomID)] }
        await monitor.check()
        clock.advance(3)
        await monitor.check()
        monitor.finish()
        #expect(await collect(monitor, count: 99) == [.started(zoom)])
    }

    @Test func staysQuietDuringAHandStartedRecordingAndNeverStopsIt() async {
        let source = FakeProcessSource(), clock = FakeClock()
        let monitor = makeMonitor(source, clock)
        await monitor.recordingStarted(call: nil, startedByEarshot: false, eventEnd: nil, stopWhenCallEnds: true)
        source.snapshot.update { $0 = [proc(100, zoomID)] }
        await monitor.check()
        source.snapshot.update { $0 = [] }
        for _ in 0..<200 {
            clock.advance(3)
            await monitor.check()
        }
        monitor.finish()
        #expect(await collect(monitor, count: 99) == [])
    }

    @Test func asksOnceThenStopsAfterFiveMinutes() async {
        let source = FakeProcessSource(), clock = FakeClock()
        let monitor = makeMonitor(source, clock)
        source.snapshot.update { $0 = [proc(100, zoomID)] }
        await monitor.check()
        await monitor.recordingStarted(call: zoom, startedByEarshot: true, eventEnd: nil, stopWhenCallEnds: true)
        source.snapshot.update { $0 = [proc(100, zoomID, input: false, output: true)] }
        for _ in 0..<120 {
            clock.advance(3)
            await monitor.check()
        }
        monitor.finish()
        #expect(await collect(monitor, count: 99) == [.started(zoom), .askToStop(zoom), .stop(zoom)])
    }

    @Test func keepRecordingStopsTheAskingAndTheGiveUpUntilTheMicComesBack() async {
        let source = FakeProcessSource(), clock = FakeClock()
        let monitor = makeMonitor(source, clock)
        await monitor.recordingStarted(call: zoom, startedByEarshot: true, eventEnd: nil, stopWhenCallEnds: true)
        let muted = [proc(100, zoomID, input: false, output: true)]
        source.snapshot.update { $0 = muted }
        clock.advance(45); await monitor.check()  // asks
        await monitor.keepRecording()
        for _ in 0..<200 {  // ten minutes of muted listening
            clock.advance(3)
            await monitor.check()
        }
        // Unmuting ends the answer; the next quiet spell asks again.
        source.snapshot.update { $0 = [proc(100, zoomID)] }
        clock.advance(3); await monitor.check()
        source.snapshot.update { $0 = muted }
        clock.advance(45); await monitor.check()
        monitor.finish()
        #expect(await collect(monitor, count: 99) == [.askToStop(zoom), .askToStop(zoom)])
    }

    @Test func afterKeepRecordingTheCallEndingStillStops() async {
        let source = FakeProcessSource(), clock = FakeClock()
        let monitor = makeMonitor(source, clock)
        await monitor.recordingStarted(call: zoom, startedByEarshot: true, eventEnd: nil, stopWhenCallEnds: true)
        source.snapshot.update { $0 = [proc(100, zoomID, input: false, output: true)] }
        clock.advance(45); await monitor.check()
        await monitor.keepRecording()
        clock.advance(60); await monitor.check()
        source.snapshot.update { $0 = [] }  // the app quit
        clock.advance(3); await monitor.check()
        monitor.finish()
        #expect(await collect(monitor, count: 99) == [.askToStop(zoom), .stop(zoom)])
    }

    @Test func stopsWhenTheCallAppQuits() async {
        let source = FakeProcessSource(), clock = FakeClock()
        let monitor = makeMonitor(source, clock)
        source.snapshot.update { $0 = [proc(100, zoomID)] }
        await monitor.recordingStarted(call: zoom, startedByEarshot: true, eventEnd: nil, stopWhenCallEnds: true)
        await monitor.check()
        source.snapshot.update { $0 = [] }
        clock.advance(30)
        await monitor.check()
        clock.advance(15)
        await monitor.check()
        clock.advance(3)
        await monitor.check()
        monitor.finish()
        #expect(await collect(monitor, count: 99) == [.stop(zoom)])
    }

    @Test func asksAgainAfterTheMicCameBackAndWentQuietAgain() async {
        let source = FakeProcessSource(), clock = FakeClock()
        let monitor = makeMonitor(source, clock)
        await monitor.recordingStarted(call: zoom, startedByEarshot: true, eventEnd: nil, stopWhenCallEnds: false)
        let quiet = [proc(100, zoomID, input: false, output: true)]
        source.snapshot.update { $0 = quiet }
        clock.advance(45); await monitor.check()
        clock.advance(3); await monitor.check()
        source.snapshot.update { $0 = [proc(100, zoomID)] }
        clock.advance(3); await monitor.check()
        source.snapshot.update { $0 = quiet }
        clock.advance(45); await monitor.check()
        monitor.finish()
        #expect(await collect(monitor, count: 99) == [.askToStop(zoom), .askToStop(zoom)])
    }

    @Test func noticesAgainAfterTheRecordingStoppedAndTheQuietPeriodPassed() async {
        let source = FakeProcessSource(), clock = FakeClock()
        let monitor = makeMonitor(source, clock)
        source.snapshot.update { $0 = [proc(100, zoomID)] }
        await monitor.check()
        await monitor.recordingStarted(call: zoom, startedByEarshot: true, eventEnd: nil, stopWhenCallEnds: true)
        await monitor.recordingStopped()
        source.snapshot.update { $0 = [] }
        clock.advance(601); await monitor.check()
        source.snapshot.update { $0 = [proc(100, zoomID)] }
        clock.advance(3); await monitor.check()
        monitor.finish()
        #expect(await collect(monitor, count: 99) == [.started(zoom), .started(zoom)])
    }

    @Test func pollsEveryThreeSecondsWithTheInjectedSleep() async {
        let source = FakeProcessSource(), clock = FakeClock()
        let slept = Locked<[Duration]>([])
        source.snapshot.update { $0 = [proc(100, zoomID)] }
        let monitor = makeMonitor(source, clock, sleep: { duration in
            let count = slept.get.count
            slept.update { $0.append(duration) }
            clock.advance(3)
            if count >= 4 { try await Task.sleep(for: .seconds(3_600)) }
        })
        await monitor.start()
        let events = await collect(monitor, count: 1)
        #expect(events == [.started(zoom)])
        while source.reads.get < 4 { await Task.yield() }
        await monitor.stop()
        #expect(slept.get.allSatisfy { $0 == .seconds(3) })
        #expect(MicActivityMonitor.pollInterval == .seconds(3))
    }

    @Test func aChangeFromTheSourceTriggersACheck() async throws {
        let source = FakeProcessSource(), clock = FakeClock()
        let monitor = makeMonitor(source, clock)
        await monitor.start()
        await monitor.start()
        while source.continuation.get == nil || source.reads.get < 1 { await Task.yield() }
        try await Task.sleep(for: .milliseconds(50))
        #expect(source.changesCalls.get == 1)
        #expect(source.reads.get == 1)
        source.snapshot.update { $0 = [proc(100, zoomID)] }
        source.continuation.get?.yield()
        #expect(await collect(monitor, count: 1) == [.started(zoom)])
        await monitor.stop()
    }

    @Test func stopEndsListeningAndPollingAndStartResumes() async throws {
        let source = FakeProcessSource(), clock = FakeClock()
        let monitor = makeMonitor(source, clock, sleep: { _ in try? await Task.sleep(for: .milliseconds(1)) })
        await monitor.start()
        while source.continuation.get == nil || source.reads.get < 3 { await Task.yield() }
        await monitor.stop()
        let reads = source.reads.get
        source.snapshot.update { $0 = [proc(100, zoomID)] }
        source.continuation.get?.yield()
        try await Task.sleep(for: .milliseconds(100))
        #expect(source.reads.get == reads)
        await monitor.start()
        #expect(await collect(monitor, count: 1) == [.started(zoom)])
        await monitor.stop()
        #expect(source.changesCalls.get == 2)
    }

    @Test func aCallHeldAcrossAStopAndStartIsNoticedAgainAfterTheQuietPeriod() async {
        let source = FakeProcessSource(), clock = FakeClock()
        let monitor = makeMonitor(source, clock)
        source.snapshot.update { $0 = [proc(100, zoomID)] }
        await monitor.start()
        #expect(await collect(monitor, count: 1) == [.started(zoom)])
        await monitor.stop()
        clock.advance(601)
        await monitor.start()
        #expect(await collect(monitor, count: 1) == [.started(zoom)])
        await monitor.stop()
    }

    @Test func finishingTheEventsStopsPolling() async throws {
        let source = FakeProcessSource(), clock = FakeClock()
        let monitor = makeMonitor(source, clock, sleep: { _ in try? await Task.sleep(for: .milliseconds(1)) })
        await monitor.start()
        while source.reads.get < 3 { await Task.yield() }
        monitor.finish()
        try await Task.sleep(for: .milliseconds(50))
        let reads = source.reads.get
        try await Task.sleep(for: .milliseconds(100))
        #expect(source.reads.get == reads)
    }

    @Test func withStopWhenTheCallEndsOffItOnlyAsks() async {
        let source = FakeProcessSource(), clock = FakeClock()
        let monitor = makeMonitor(source, clock)
        await monitor.recordingStarted(call: zoom, startedByEarshot: true, eventEnd: nil, stopWhenCallEnds: false)
        for _ in 0..<200 {
            clock.advance(3)
            await monitor.check()
        }
        monitor.finish()
        #expect(await collect(monitor, count: 99) == [.askToStop(zoom)])
    }

    /// Output keeps running, so only the calendar event can end the call.
    @Test(arguments: [
        (eventEnd: 10.0, stopOn: true, until: 44.0, expected: [CallEvent]()),
        (eventEnd: 10.0, stopOn: true, until: 45.0, expected: [.stop(zoom)]),
        (eventEnd: 30.0, stopOn: true, until: 45.0, expected: [.stop(zoom)]),
        (eventEnd: 30.0, stopOn: false, until: 45.0, expected: [.askToStop(zoom)]),
        (eventEnd: 3_600.0, stopOn: true, until: 45.0, expected: [.askToStop(zoom)]),
    ])
    func anEndedCalendarEventEndsTheCall(eventEnd: TimeInterval, stopOn: Bool, until: TimeInterval,
                                         expected: [CallEvent]) async {
        let source = FakeProcessSource(), clock = FakeClock()
        let monitor = makeMonitor(source, clock)
        source.snapshot.update { $0 = [proc(100, zoomID, input: false, output: true)] }
        await monitor.recordingStarted(call: zoom, startedByEarshot: true, eventEnd: t0 + eventEnd, stopWhenCallEnds: stopOn)
        while clock.now < t0 + until {
            clock.advance(min(3, (t0 + until).timeIntervalSince(clock.now)))
            await monitor.check()
        }
        monitor.finish()
        #expect(await collect(monitor, count: 99) == expected)
    }
}

@Suite(.enabled(if: deviceTests, "needs EARSHOT_DEVICE_TESTS=1 and audio output"))
struct DetectDeviceTests {
    private func startAfplay() throws -> Process {
        let player = Process()
        player.executableURL = URL(filePath: "/usr/bin/afplay")
        player.arguments = ["-v", "0.05", "-t", "5", "/System/Library/Sounds/Glass.aiff"]
        try player.run()
        return player
    }

    @Test(.timeLimit(.minutes(1))) func listsAfplayAsRunningOutputWhilePlaying() async throws {
        let player = try startAfplay()
        defer { player.terminate() }
        let source = CoreAudioProcessSource()
        var found: AudioProcessInfo?
        for _ in 0..<40 where found == nil {
            found = source.processes().first { $0.pid == player.processIdentifier && $0.runningOutput }
            if found == nil { try await Task.sleep(for: .milliseconds(100)) }
        }
        #expect(found != nil)
        #expect(found?.runningInput == false && found?.usesRealMicrophone == false)
        #expect(!source.processes().contains { $0.pid == getpid() && $0.runningInput })
    }

    @Test(.timeLimit(.minutes(1))) func reportsAChangeWhenAPlayerStarts() async throws {
        let stream = CoreAudioProcessSource().changes()
        let changed = Task { for await _ in stream { return true }; return false }
        try await Task.sleep(for: .milliseconds(300))
        let player = try startAfplay()
        defer { player.terminate() }
        let timeout = Task { try await Task.sleep(for: .seconds(5)); changed.cancel() }
        #expect(await changed.value)
        timeout.cancel()
    }
}
