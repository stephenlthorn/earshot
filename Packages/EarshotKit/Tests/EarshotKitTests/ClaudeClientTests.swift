import Foundation
import Testing
@testable import EarshotKit

/// Holds a gate slot until `open()` is called.
final class Latch: @unchecked Sendable {
    private let opened = Locked(false)
    let entered = Locked(0)

    func open() { opened.update { $0 = true } }

    func hold() async {
        entered.update { $0 += 1 }
        while !opened.get { try? await Task.sleep(for: .milliseconds(2)) }
    }
}

func pollUntil(_ condition: @Sendable () async -> Bool) async {
    for _ in 0..<2_000 where !(await condition()) { try? await Task.sleep(for: .milliseconds(2)) }
}

struct ClaudeGateTests {
    @Test func aFreedSlotGoesToTheHighestPriorityWaiter() async throws {
        let gate = ClaudeGate(limit: 1)
        let latch = Latch()
        let order = Locked<[ClaudeRole]>([])
        let holder = Task { try await gate.run(.live, skipIfBusy: false) { await latch.hold() } }
        await pollUntil { latch.entered.get == 1 }
        var waiters: [Task<ClaudeRole?, any Error>] = []
        for role in [ClaudeRole.live, .brief, .ask, .brief, .fix, .notes] {
            waiters.append(Task { try await gate.run(role, skipIfBusy: false) { order.update { $0.append(role) }; return role } })
            let count = waiters.count
            await pollUntil { await gate.queued == count }
        }
        latch.open()
        _ = try await holder.value
        for waiter in waiters { _ = try await waiter.value }
        #expect(order.get == [.notes, .fix, .ask, .brief, .brief, .live])
    }

    @Test func skipIfBusyReturnsNilAtOnceWhenEverySlotIsTaken() async throws {
        let gate = ClaudeGate(limit: 2)
        let latch = Latch()
        let holders = (0..<2).map { _ in Task { try await gate.run(.notes, skipIfBusy: false) { await latch.hold() } } }
        await pollUntil { latch.entered.get == 2 }
        let ran = Locked(false)
        let skipped: Void? = try await gate.run(.live, skipIfBusy: true) { ran.update { $0 = true } }
        #expect(skipped == nil && !ran.get)
        #expect(await gate.queued == 0)
        latch.open()
        for holder in holders { _ = try await holder.value }
        // With a slot free it runs.
        #expect(try await gate.run(.live, skipIfBusy: true) { 7 } == 7)
    }

    @Test func atMostTheLimitRunAtOnce() async throws {
        let gate = ClaudeGate(limit: 2)
        let running = Locked(0), peak = Locked(0)
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<8 {
                group.addTask {
                    _ = try await gate.run(.ask, skipIfBusy: false) {
                        running.update { $0 += 1 }
                        peak.update { $0 = max($0, running.get) }
                        try? await Task.sleep(for: .milliseconds(20))
                        running.update { $0 -= 1 }
                    }
                }
            }
            try await group.waitForAll()
        }
        #expect(peak.get == 2)
    }

    @Test func aCancelledWaiterNeverRunsAndFreesItsPlace() async throws {
        let gate = ClaudeGate(limit: 1)
        let latch = Latch()
        let holder = Task { try await gate.run(.notes, skipIfBusy: false) { await latch.hold() } }
        await pollUntil { latch.entered.get == 1 }
        let ran = Locked(false)
        let waiter = Task { try await gate.run(.fix, skipIfBusy: false) { ran.update { $0 = true } } }
        await pollUntil { await gate.queued == 1 }
        waiter.cancel()
        await #expect(throws: CancellationError.self) { try await waiter.value }
        #expect(await gate.queued == 0)
        latch.open()
        _ = try await holder.value
        #expect(!ran.get)
        #expect(try await gate.run(.notes, skipIfBusy: true) { 1 } == 1)
    }

    @Test func anErrorInTheBodyStillFreesTheSlot() async throws {
        let gate = ClaudeGate(limit: 1)
        await #expect(throws: NotesError.refused) { try await gate.run(.notes, skipIfBusy: false) { throw NotesError.refused } }
        #expect(try await gate.run(.live, skipIfBusy: true) { 1 } == 1)
    }

    @Test func aLivePassIsSkippedWhenClaudeIsBusy() async throws {
        let gate = ClaudeGate(limit: 1)
        let latch = Latch()
        let holder = Task { try await gate.run(.notes, skipIfBusy: false) { await latch.hold() } }
        await pollUntil { latch.entered.get == 1 }
        let runner = FakeRunner(claudeOutput(claudeJSON()))
        let client = ClaudeCodeClient(claudePath: "/bin/claude", runner: runner, gate: gate, slots: nil)
        var live = notesRequest()
        live.role = .live
        await #expect(throws: ClaudeBusy()) { try await client.structured(live) }
        #expect(runner.calls.isEmpty)
        latch.open()
        _ = try await holder.value
    }
}

struct ClaudeClientTests {
    struct Canned: ClaudeClient {
        let json: String
        func structured(_ request: ClaudeRequest) async throws -> Data { Data(json.utf8) }
    }

    struct Answer: Decodable, Equatable { let ok: Bool }

    @Test func decodeReadsTheObjectOrSaysItIsTheWrongShape() async throws {
        let request = ClaudeRequest(role: .ask, system: "", user: "", schema: "{}", model: "m", effort: "low")
        #expect(try await Canned(json: #"{"ok":true}"#).decode(Answer.self, request) == Answer(ok: true))
        await #expect(throws: NotesError.badOutput("it did not match the expected format")) {
            try await Canned(json: #"{"fine":1}"#).decode(Answer.self, request)
        }
    }

    @Test func requestDefaults() {
        let request = ClaudeRequest(role: .live, system: "s", user: "u", schema: "{}", model: "m", effort: "low")
        #expect(request.maxTokens == 16_000 && request.timeout == .seconds(600))
    }

    @Test func theNotesWriterAsksInTheNotesRole() {
        let request = notesRequest(model: "claude-opus-5-5", effort: "high")
        #expect(request.role == .notes && request.model == "claude-opus-5-5" && request.effort == "high")
        #expect(request.maxTokens == 20_000 && request.schema == NotesSchema.json)
        #expect(request.system == NotesPrompt.system(sampleRequest) && request.user == NotesPrompt.user(sampleRequest))
    }

    @Test func theNewErrorsSayWhatToDoWithoutDashes() {
        let errors: [NotesError] = [.notSignedIn("x"), .usageLimit("x"), .claudeTooOld("x"), .modelUnavailable("claude-opus-5-5")]
        #expect(errors.map(\.errorDescription) == [
            "Claude Code is not signed in: run `claude` in Terminal and log in.",
            "Your Claude usage limit is reached. Press Retry later.",
            "Claude Code is too old; update it.",
            "Your plan can't use claude-opus-5-5; pick another in Settings.",
        ])
        #expect(errors.allSatisfy { !($0.errorDescription ?? "").contains("\u{2014}") })
    }

    /// Every role throws these, so they don't say "notes": a failed brief or ask reads right too. Every provider
    /// throws them too, so they name the model, not Claude: a local model's notes read right.
    @Test func answerErrorsFitEveryRole() {
        let errors: [NotesError] = [.badOutput("no JSON"), .refused, .truncated]
        #expect(errors.map(\.errorDescription) == [
            "The model's answer came back in the wrong shape: no JSON",
            "The model declined to answer.",
            "The model's answer was cut off before it was finished.",
        ])
    }
}
