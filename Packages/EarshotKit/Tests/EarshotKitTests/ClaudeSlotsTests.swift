import Foundation
import Testing
@testable import EarshotKit

/// Slots in a fresh folder that retry every 5 ms.
private func slots(_ folder: URL = tempDir(), skipTries: Int = 3) -> ClaudeSlots {
    ClaudeSlots(folder: folder, retry: .milliseconds(5), skipTries: skipTries)
}

/// Another process holding one slot file with `flock`, as the app, the CLI or the plugin hook would.
private final class OtherProcess: @unchecked Sendable {
    let process = Process()

    init(holding file: URL) throws {
        process.executableURL = URL(filePath: "/usr/bin/perl")
        process.arguments = ["-e", #"use Fcntl ":flock"; open(my $f, ">>", $ARGV[0]) or die; flock($f, LOCK_EX) or die; sleep 60"#,
                             file.path]
        try process.run()
    }

    /// Dies without cleaning up, as a crashed or killed holder would. Once it has exited, this does nothing, so a
    /// reused process id is never signalled.
    func kill() {
        guard process.isRunning else { return }
        Darwin.kill(process.processIdentifier, SIGKILL)
        process.waitUntilExit()
    }
}

/// True while another descriptor holds the slot file.
private func isHeld(_ file: URL) -> Bool {
    let descriptor = open(file.path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
    guard descriptor >= 0 else { return false }
    defer { close(descriptor) }
    guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else { return true }
    flock(descriptor, LOCK_UN)
    return false
}

struct ClaudeSlotsTests {
    @Test func theSlotFilesLiveInApplicationSupport() {
        let home = URL(filePath: "/Users/alex", directoryHint: .isDirectory)
        #expect(ClaudeSlots.defaultFolder(home: home).path == "/Users/alex/Library/Application Support/Earshot/Locks")
        #expect(ClaudeSlots.shared.folder == URL.applicationSupportDirectory.appending(path: "Earshot/Locks", directoryHint: .isDirectory))
        #expect(ClaudeSlots.shared.count == 2)
        let s = slots()
        #expect(s.slotFile(0).lastPathComponent == "structured-1.lock" && s.slotFile(1).lastPathComponent == "structured-2.lock")
    }

    @Test func twoHoldersTakeBothSlotsAndALiveCallSkips() async throws {
        let s = slots()
        let latch = Latch()
        let holders = (0..<2).map { _ in Task { try await s.run(skipIfBusy: false) { await latch.hold() } } }
        await pollUntil { latch.entered.get == 2 }
        #expect(latch.entered.get == 2, "two calls run at once")
        let ran = Locked(false)
        let skipped: Void? = try await s.run(skipIfBusy: true) { ran.update { $0 = true } }
        #expect(skipped == nil && !ran.get, "no third slot, so the live call skips")
        latch.open()
        for holder in holders { _ = try await holder.value }
        #expect(try await s.run(skipIfBusy: true) { 7 } == 7, "both slots are free again")
    }

    @Test func aCallThatMustRunWaitsForAFreeSlot() async throws {
        let s = slots()
        let latch = Latch()
        let holders = (0..<2).map { _ in Task { try await s.run(skipIfBusy: false) { await latch.hold() } } }
        await pollUntil { latch.entered.get == 2 }
        let ran = Locked(false)
        let waiter = Task { try await s.run(skipIfBusy: false) { ran.update { $0 = true }; return 1 } }
        try await Task.sleep(for: .milliseconds(50))
        #expect(!ran.get, "it waits while both slots are held")
        latch.open()
        #expect(try await waiter.value == 1 && ran.get)
        for holder in holders { _ = try await holder.value }
    }

    @Test func aSkippingCallRetriesBrieflyBeforeItSkips() async throws {
        let folder = tempDir()
        let tries = Locked(0)
        let s = ClaudeSlots(folder: folder, retry: .milliseconds(100), skipTries: 3, sleep: { _ in tries.update { $0 += 1 } })
        let latch = Latch()
        let holders = (0..<2).map { _ in Task { try await slots(folder).run(skipIfBusy: false) { await latch.hold() } } }
        await pollUntil { latch.entered.get == 2 }
        let skipped: Int? = try await s.run(skipIfBusy: true) { 1 }
        #expect(skipped == nil && tries.get == 2, "three tries, two short waits between them")
        latch.open()
        for holder in holders { _ = try await holder.value }
    }

    @Test func aWaitingCallCanBeCancelled() async throws {
        let s = slots()
        let latch = Latch()
        let holders = (0..<2).map { _ in Task { try await s.run(skipIfBusy: false) { await latch.hold() } } }
        await pollUntil { latch.entered.get == 2 }
        let ran = Locked(false)
        let waiter = Task { try await s.run(skipIfBusy: false) { ran.update { $0 = true } } }
        try await Task.sleep(for: .milliseconds(20))
        waiter.cancel()
        await #expect(throws: CancellationError.self) { try await waiter.value }
        #expect(!ran.get)
        latch.open()
        for holder in holders { _ = try await holder.value }
    }

    @Test func aSlotIsFreedWhenTheCallThrows() async throws {
        let s = slots(skipTries: 1)
        for _ in 0..<3 {
            await #expect(throws: NotesError.refused) { try await s.run(skipIfBusy: false) { throw NotesError.refused } }
        }
        #expect(!isHeld(s.slotFile(0)) && !isHeld(s.slotFile(1)))
        #expect(try await s.run(skipIfBusy: true) { 1 } == 1)
    }

    /// Two other processes hold both slots; a live call here skips. When one of them dies without letting go, the
    /// system drops its lock, so nothing waits forever.
    @Test func otherProcessesShareTheSlotsAndADeadHolderFreesItsSlot() async throws {
        let s = slots()
        try FileManager.default.createDirectory(at: s.folder, withIntermediateDirectories: true)
        let others = try (0..<2).map { try OtherProcess(holding: s.slotFile($0)) }
        defer { others.forEach { $0.kill() } }
        await pollUntil { isHeld(s.slotFile(0)) && isHeld(s.slotFile(1)) }
        #expect(isHeld(s.slotFile(0)) && isHeld(s.slotFile(1)))
        let skipped: Int? = try await s.run(skipIfBusy: true) { 1 }
        #expect(skipped == nil)
        others[0].kill()
        #expect(try await s.run(skipIfBusy: true) { 2 } == 2, "the dead holder's slot is free")
    }

    /// A folder that can't be made never blocks a call: there is just no cross-process limit then.
    @Test func aFolderThatCantBeMadeDoesNotBlockCalls() async throws {
        let file = tempDir().appending(path: "a-file")
        try Data().write(to: file)
        let s = slots(file.appending(path: "Locks"))
        #expect(try await s.run(skipIfBusy: true) { 3 } == 3)
        #expect(try await s.run(skipIfBusy: false) { 4 } == 4)
    }
}

/// The Claude Code client takes a cross-process slot as well as the in-process gate (spec 3.2).
struct ClaudeCodeClientSlotTests {
    @Test func aLiveCallSkipsWhenAnotherProcessHoldsBothSlots() async throws {
        let s = slots()
        try FileManager.default.createDirectory(at: s.folder, withIntermediateDirectories: true)
        let others = try (0..<2).map { try OtherProcess(holding: s.slotFile($0)) }
        defer { others.forEach { $0.kill() } }
        await pollUntil { isHeld(s.slotFile(0)) && isHeld(s.slotFile(1)) }
        let runner = FakeRunner(claudeOutput(claudeJSON()))
        let client = ClaudeCodeClient(claudePath: "/bin/claude", runner: runner, gate: ClaudeGate(), slots: s)
        var live = notesRequest()
        live.role = .live
        await #expect(throws: ClaudeBusy()) { try await client.structured(live) }
        #expect(runner.calls.isEmpty)
        // A notes call waits for a slot instead, and runs once one is free.
        let notes = Task { try await client.structured(notesRequest()) }
        try await Task.sleep(for: .milliseconds(30))
        #expect(runner.calls.isEmpty)
        others[1].kill()
        _ = try await notes.value
        #expect(runner.calls.count == 1)
    }

    @Test func theClientHoldsASlotWhileClaudeRuns() async throws {
        let s = slots()
        let seen = Locked<[Bool]>([])
        let runner = SlotCheckingRunner(files: [s.slotFile(0), s.slotFile(1)], seen: seen)
        let client = ClaudeCodeClient(claudePath: "/bin/claude", runner: runner, gate: ClaudeGate(), slots: s)
        _ = try await client.structured(notesRequest())
        #expect(seen.get == [true], "one slot file was locked while claude ran")
        #expect(!isHeld(s.slotFile(0)) && !isHeld(s.slotFile(1)), "and released afterwards")
    }

    @Test func theDefaultClientUsesTheSharedSlots() {
        #expect(ClaudeCodeClient(claudePath: "/bin/claude").slots?.folder == ClaudeSlots.shared.folder)
    }
}

/// Records whether any of `files` was locked while `claude` ran.
private struct SlotCheckingRunner: ProcessRunning {
    let files: [URL]
    let seen: Locked<[Bool]>

    func run(_ executable: String, _ arguments: [String], stdin: Data?, directory: URL?,
             environment: [String: String], inheritEnvironment: Bool, timeout: Duration) async throws -> ProcessOutput {
        let held = files.contains(where: isHeld)
        seen.update { $0.append(held) }
        return claudeOutput(claudeJSON())
    }
}
