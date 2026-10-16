import Foundation
import Testing
@testable import EarshotKit

/// One run at a time per target across meetings and the pipeline (spec 3.2), and what Stop does to queued live
/// to-dos (spec 4.4).
struct TargetLanesTests {
    private static func twoItems() -> [LiveItem] {
        (1...2).map { LiveItem(id: "L\($0)", task: "Task \($0)", owner: "Stephen", aiDoable: true, firstSeen: 0) }
    }

    @Test(.timeLimit(.minutes(1))) func aLaneIsHeldUntilItIsGivenBack() async throws {
        let lanes = TargetLanes()
        #expect(lanes.tryAcquire("claude-code"))
        #expect(!lanes.tryAcquire("claude-code") && lanes.isBusy("claude-code"))
        #expect(lanes.tryAcquire("webhook"), "other targets have their own lane")
        let waiting = Task { try await lanes.acquire("claude-code") }
        try await Task.sleep(for: .milliseconds(20))
        lanes.release("claude-code")
        try await waiting.value
        #expect(lanes.isBusy("claude-code"), "the waiter took it")
        lanes.release("claude-code")
        #expect(!lanes.isBusy("claude-code"))
        await lanes.released("claude-code")  // free: returns at once
    }

    @Test(.timeLimit(.minutes(1))) func aCancelledWaitHoldsNothing() async throws {
        let lanes = TargetLanes()
        #expect(lanes.tryAcquire("claude-code"))
        let waiting = Task { try await lanes.acquire("claude-code") }
        try await Task.sleep(for: .milliseconds(20))
        waiting.cancel()
        await #expect(throws: CancellationError.self) { try await waiting.value }
        lanes.release("claude-code")
        #expect(!lanes.isBusy("claude-code"))
    }

    @Test(.timeLimit(.minutes(1))) func anotherMeetingsStartWaitsForTheRunStillGoing() async throws {
        let lanes = TargetLanes()
        let first = try LiveHarness(), second = try LiveHarness()
        let a = first.live(transcribers: [], lanes: lanes), b = second.live(transcribers: [], lanes: lanes)
        a.store.replaceItems(Self.twoItems())
        b.store.replaceItems(Self.twoItems())
        let gate = StuckGate()
        let target = KeptTarget(id: "claude-code", gate: gate)
        let rowA = try #require(a.store.items.first), rowB = try #require(b.store.items.first)
        #expect(await a.start(rowA, payload: await a.payload(for: rowA, at: at1530), target: target, confirmed: true))
        await pollUntil { gate.entered.get == 1 }
        #expect(await b.start(rowB, payload: await b.payload(for: rowB, at: at1530), target: target, confirmed: true))
        try await Task.sleep(for: .milliseconds(30))
        #expect(gate.entered.get == 1, "meeting B's run waits for meeting A's")
        #expect(b.store.items.first?.status == .queued)
        gate.open()
        await a.waitUntilIdle()
        await b.waitUntilIdle()
        #expect(target.sent.get.count == 2)
        #expect(b.store.items.first?.status == .done)
        #expect(!lanes.isBusy("claude-code"))
        await a.stop()
        await b.stop()
    }

    @Test(.timeLimit(.minutes(1))) func aStartWaitingForAnotherMeetingCanStillBeCancelled() async throws {
        let lanes = TargetLanes()
        let other = try LiveHarness()
        let b = other.live(transcribers: [], lanes: lanes)
        b.store.replaceItems(Self.twoItems())
        #expect(lanes.tryAcquire("claude-code"))  // meeting A's run
        let target = KeptTarget(id: "claude-code")
        let row = try #require(b.store.items.first)
        #expect(await b.start(row, payload: await b.payload(for: row, at: at1530), target: target, confirmed: true))
        #expect(await b.cancel(row.id))
        await b.waitUntilIdle()  // returns although A's run is still going
        #expect(b.store.items.first?.status == .suggested && target.sent.get.isEmpty)
        lanes.release("claude-code")
        await b.stop()
    }

    @Test(.timeLimit(.minutes(1))) func theMeetingsSendWaitsForALiveRunOnTheSameTarget() async throws {
        var world = V2World()
        let lanes = TargetLanes()
        world.lanes = lanes
        let webhook = FakeTarget("webhook")
        world.targets = [webhook]
        let w = world
        let s = try w.meeting()
        #expect(lanes.tryAcquire("webhook"))  // a live Start still running
        let pipeline = w.pipeline()
        let run = Task { await pipeline.run(sessionID: s.id) }
        await pollUntil { (try? w.fresh(s))?.stages[.dispatch]?.status == .running }
        try await Task.sleep(for: .milliseconds(30))
        #expect(webhook.sent.get.isEmpty)
        lanes.release("webhook")
        await run.value
        #expect(webhook.sent.get.count == 1)
        #expect(try w.fresh(s).isFinished && !lanes.isBusy("webhook"))
    }

    // MARK: Stop

    @Test(.timeLimit(.minutes(1))) func stopTakesBackWhatIsQueuedSoItIsNeverSentTwice() async throws {
        let h = try LiveHarness()
        let live = h.live(transcribers: [])
        live.store.replaceItems(Self.twoItems())
        let gate = StuckGate()
        let target = KeptTarget(id: "claude-code", gate: gate)
        for row in live.store.items {
            #expect(await live.start(row, payload: await live.payload(for: row, at: at1530), target: target,
                                     confirmed: true))
        }
        await pollUntil { gate.entered.get == 1 }
        #expect(live.store.items.map(\.status) == [.running, .queued])
        await live.takeBackQueued()
        #expect(try h.liveFile().items.map(\.status) == [.running, .suggested])
        // The post-call send now sees L2 as a plain suggestion, so the notes offer it and nothing links it away.
        #expect(try h.liveFile().items.filter(\.status.isStarted).map(\.id) == ["L1"])
        gate.open()
        await live.waitUntilIdle()
        #expect(target.sent.get.count == 1, "the run going finishes; the one taken back never goes out")
        #expect(try h.liveFile().items.map(\.status) == [.done, .suggested])
        await live.stop()
    }

    // MARK: The folder a live run was handed

    @Test(.timeLimit(.minutes(1))) func theNotesKeepTheFolderNameWhileALiveRunIsGoing() async throws {
        let w = V2World()
        let s = try w.meeting(title: nil)
        try w.store.write(LiveFile(items: [
            LiveItem(id: "L1", task: "Draft the scope", owner: "Stephen", aiDoable: true, firstSeen: 2, status: .running,
                     target: "claude-code"),
        ]), s, MeetingFile.live)
        await w.pipeline().run(sessionID: s.id)
        let after = try w.fresh(s)
        #expect(after.folderName == s.folderName, "the run's log and EARSHOT_SESSION_DIR still point here")
        #expect(after.title == sampleNotes.title)
        #expect(after.isFinished)
    }

    @Test(.timeLimit(.minutes(1))) func theNotesRenameTheFolderOnceLiveRunsHaveEnded() async throws {
        let w = V2World()
        let s = try w.meeting(title: nil)
        try w.store.write(LiveFile(items: [
            LiveItem(id: "L1", task: "Draft the scope", owner: "Stephen", aiDoable: true, firstSeen: 2, status: .done,
                     target: "claude-code"),
        ]), s, MeetingFile.live)
        await w.pipeline().run(sessionID: s.id)
        let after = try w.fresh(s)
        #expect(after.folderName != s.folderName && after.folderName.hasSuffix(sampleNotes.title))
        #expect(after.title == sampleNotes.title)
    }
}
