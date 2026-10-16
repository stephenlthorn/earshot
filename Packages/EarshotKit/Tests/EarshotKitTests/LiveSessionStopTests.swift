import Foundation
import Testing
@testable import EarshotKit

/// Stop, quitting and a meeting folder renamed while live Start runs are still going.
struct LiveSessionStopTests {
    private static func twoItems() -> [LiveItem] {
        (1...2).map { LiveItem(id: "L\($0)", task: "Task \($0)", owner: "Stephen", aiDoable: true, firstSeen: 0) }
    }

    @Test(.timeLimit(.minutes(1))) func stopNeverWaitsLongerThanItsLimitAndStillSaves() async throws {
        let h = try LiveHarness()
        let gate = StuckGate()
        let stuck = SpokenTranscriber(.me, finishGate: gate)
        let live = h.live(transcribers: [stuck, h.them], stopLimit: .milliseconds(200))
        await live.start()
        h.them.say("Something worth keeping.", 0, 2)
        await pollUntil { live.store.segments.count == 1 }
        // Within LiveStore.segmentInterval of the first, so it waits in memory for the next write.
        h.them.say("And this, said just before Stop.", 2, 4)
        await pollUntil { live.store.segments.count == 2 }
        #expect(try h.liveFile().segments.count == 1)
        let took = await ContinuousClock().measure { await live.stop() }
        #expect(took < .seconds(2))
        #expect(try h.liveFile().segments.map(\.text) == ["Something worth keeping.", "And this, said just before Stop."])
        gate.open()
    }

    @Test(.timeLimit(.minutes(1))) func aSecondStopReturnsOnlyOnceTheFirstHasSaved() async throws {
        let h = try LiveHarness()
        let gate = StuckGate()
        let stuck = SpokenTranscriber(.me, finishGate: gate)
        let live = h.live(transcribers: [stuck, h.them], stopLimit: .milliseconds(300))
        await live.start()
        h.them.say("Something worth keeping.", 0, 2)
        await pollUntil { live.store.segments.count == 1 }
        h.them.say("And this, said just before Stop.", 2, 4)
        await pollUntil { live.store.segments.count == 2 }
        let first = Task { await live.stop() }
        await pollUntil { stuck.finished.get == 1 }
        await live.stop()
        #expect(try h.liveFile().segments.count == 2)
        await first.value
        gate.open()
    }

    @Test(.timeLimit(.minutes(1))) func aStopBeforeStartLeavesNothingRunning() async throws {
        let h = try LiveHarness()
        let live = h.live(interval: .seconds(1))
        await live.stop()
        await live.start()
        #expect(await !live.isRunning)
        #expect(h.me.started.get == 0 && h.them.started.get == 0)
    }

    @Test(.timeLimit(.minutes(1))) func theBusyTargetsAreThoseSendingOrRunning() async throws {
        let h = try LiveHarness()
        let live = h.live(transcribers: [])
        live.store.replaceItems(Self.twoItems())
        try live.store.setStatus("L1", .running, target: "claude-code")
        #expect(live.busyTargetIDs() == ["claude-code"])
        #expect(live.hasPendingWork())
        try live.store.setStatus("L1", .done, target: "claude-code")
        #expect(live.busyTargetIDs().isEmpty)
        #expect(!live.hasPendingWork())
        await live.stop()
    }

    @Test(.timeLimit(.minutes(1))) func quittingTakesBackWhatIsStillQueuedAndNeverSendsIt() async throws {
        let h = try LiveHarness()
        let live = h.live(transcribers: [], cancelWindow: .seconds(60))
        let events = Events(live.events)
        live.store.replaceItems(Self.twoItems())
        let row = try #require(live.store.items.first)
        let target = KeptTarget()
        let payload = await live.payload(for: row, at: at1530)
        #expect(await live.start(row, payload: payload, target: target, confirmed: false))
        #expect(try h.liveFile().items.first?.status == .queued)
        #expect(live.hasPendingWork())
        await live.cancelQueued()
        #expect(try h.liveFile().items.first?.status == .suggested)
        await live.waitUntilIdle()
        #expect(target.sent.get.isEmpty)
        #expect(!live.hasPendingWork())
        await live.stop()
        await live.close()
        await pollUntil { events.ended.get }
        #expect(events.ended.get)
    }

    @Test(.timeLimit(.minutes(1))) func onceHeldTheQueueStartsNothingNewSoQuittingCanTakeItBack() async throws {
        let h = try LiveHarness()
        let live = h.live(transcribers: [])
        live.store.replaceItems(Self.twoItems())
        let gate = StuckGate()
        let target = KeptTarget(id: "claude-code", gate: gate)
        for row in live.store.items {
            let payload = await live.payload(for: row, at: at1530)
            #expect(await live.start(row, payload: payload, target: target, confirmed: true))
        }
        await pollUntil { gate.entered.get == 1 }
        #expect(live.store.items.map(\.status) == [.running, .queued])
        live.hold()
        gate.open()
        await live.waitUntilIdle()
        #expect(target.sent.get.count == 1)
        #expect(live.store.items.map(\.status) == [.done, .queued])
        await live.cancelQueued()
        #expect(try h.liveFile().items.map(\.status) == [.done, .suggested])
        await live.stop()
    }

    /// A Start pressed just before Stop whose send lands after it (the sheet's confirm, or a press still reading its
    /// payload) is refused: it stays suggested, so the notes offer it once and nothing sends it again later.
    @Test(.timeLimit(.minutes(1))) func aStartThatLandsAfterStopIsLeftToTheNotes() async throws {
        let h = try LiveHarness()
        let live = h.live(transcribers: [])
        live.store.replaceItems(Self.twoItems())
        let target = KeptTarget(id: "claude-code", gate: StuckGate())
        let row = try #require(live.store.items.first)
        let payload = await live.payload(for: row, at: at1530)
        await live.takeBackQueued()
        #expect(!(await live.start(row, payload: payload, target: target, confirmed: true)))
        #expect(!(await live.start(row, payload: payload, target: target, confirmed: false)))
        await live.waitUntilIdle()
        #expect(target.sent.get.isEmpty)
        #expect(live.store.items.map(\.status) == [.suggested, .suggested])
        #expect(!live.hasPendingWork())
        await live.stop()
    }

    @Test(.timeLimit(.minutes(1))) func aRunThatOutlastsARenameFinishesInTheRenamedFolder() async throws {
        let h = try LiveHarness()
        let live = h.live(transcribers: [])
        live.store.replaceItems(Self.twoItems())
        let gate = StuckGate()
        let target = KeptTarget(id: "claude-code", gate: gate)
        let row = try #require(live.store.items.first)
        let payload = await live.payload(for: row, at: at1530)
        #expect(await live.start(row, payload: payload, target: target, confirmed: true))
        await pollUntil { gate.entered.get == 1 }
        #expect(live.busyTargetIDs() == ["claude-code"])
        let renamed = try h.store.retitle(h.session, to: "Acme kickoff")
        #expect(renamed.folderName != h.session.folderName)
        gate.open()
        await live.waitUntilIdle()
        #expect(try h.store.read(LiveFile.self, renamed, MeetingFile.live).items.first?.status == .done)
        #expect(live.busyTargetIDs().isEmpty)
        #expect(!live.hasPendingWork())
        #expect(live.store.folder == h.store.folder(renamed))
        #expect(!FileManager.default.fileExists(atPath: h.store.folder(h.session).path))
        await live.stop()
    }

    // MARK: The live assistant switched off during the recording (spec 4.1)

    /// The App stops the live session mid-recording when the live assistant is switched off. The panel, flags,
    /// Dismiss and Start runs already queued keep working until the recording stops.
    @Test(.timeLimit(.minutes(1))) func aMidRecordingStopKeepsFlagsDismissAndQueuedRuns() async throws {
        let h = try LiveHarness()
        let live = h.live()
        let events = Events(live.events)
        await live.start()
        live.store.replaceItems((1...3).map {
            LiveItem(id: "L\($0)", task: "Task \($0)", owner: "Stephen", aiDoable: true, firstSeen: 0)
        })
        let gate = StuckGate()
        let target = KeptTarget(gate: gate)
        for row in live.store.items.prefix(2) {
            let payload = await live.payload(for: row, at: at1530)
            #expect(await live.start(row, payload: payload, target: target, confirmed: true))
        }
        await pollUntil { gate.entered.get == 1 }
        #expect(live.store.items.first { $0.id == "L2" }?.status == .queued)

        await live.stop()
        #expect(h.me.finished.get == 1 && h.them.finished.get == 1)

        // A pressed flag is still saved and shown.
        #expect(await live.flag(.panel) == Flag(offset: 30, source: .panel))
        #expect(h.store.find(h.session.id)?.flags == [Flag(offset: 30, source: .panel)])
        await pollUntil { events.flags.count == 1 }
        #expect(events.flags == [Flag(offset: 30, source: .panel)])

        // Dismiss is still written at once and reaches the panel.
        try await live.dismiss("L3")
        #expect(try h.liveFile().items.first { $0.id == "L3" }?.status == .dismissed)
        await pollUntil { events.items?.first { $0.id == "L3" }?.status == .dismissed }
        #expect(events.items?.first { $0.id == "L3" }?.status == .dismissed)

        // The run going and the one queued behind it finish, and their statuses reach live.json and the panel.
        gate.open()
        await live.waitUntilIdle()
        #expect(target.sent.get.map { $0.items.first?.task } == ["Task 1", "Task 2"])
        #expect(try h.liveFile().items.map(\.status) == [.sent, .sent, .dismissed])
        await pollUntil { events.items?.map(\.status) == [.sent, .sent, .dismissed] }
        #expect(events.items?.map(\.status) == [.sent, .sent, .dismissed])

        // Stop at the end of the recording waits on the same stop and closes cleanly.
        await live.stop()
        await live.close()
        await pollUntil { events.ended.get }
        #expect(events.ended.get)
    }

    /// After a mid-recording stop, speech is no longer transcribed and nothing new goes to Claude.
    @Test(.timeLimit(.minutes(1))) func afterAMidRecordingStopNothingIsTranscribedOrSent() async throws {
        let h = try LiveHarness()
        let client = ScriptedClaude(liveOneItem)
        let live = h.live(client: client)
        await live.start()
        h.them.say(liveLongLine, 0, 20)
        await pollUntil { live.store.segments.count == 1 }
        #expect(await live.passNow() == .extracted)

        await live.stop()
        h.them.say(liveLongLine, 30, 50)
        h.me.say(liveLongLine, 50, 70)
        #expect(await live.passNow() == .notEnoughText)
        #expect(client.requests.get.count == 1)
        #expect(live.store.segments.count == 1)
        #expect(live.store.items.map(\.id) == ["L1"])
    }

    /// The timed passes end at a mid-recording stop.
    @Test(.timeLimit(.minutes(1))) func aMidRecordingStopEndsTheTimedPasses() async throws {
        let h = try LiveHarness()
        let waits = Locked(0)
        var settings = EarshotSettings()
        settings.liveInterval = 7
        let live = LiveSession(store: h.store, session: h.session, transcribers: [h.me, h.them],
                               client: ScriptedClaude(), settings: settings, offset: { 30 }, cancelWindow: .zero,
                               lanes: TargetLanes(), sleep: { duration in
                                   if duration == .seconds(7) { waits.update { $0 += 1 } }
                                   try await Task.sleep(for: .milliseconds(5))
                               })
        await live.start()
        await pollUntil { waits.get >= 3 }
        #expect(waits.get >= 3)
        await live.stop()
        let atStop = waits.get
        try await Task.sleep(for: .milliseconds(150))
        #expect(waits.get <= atStop + 1)
    }
}
