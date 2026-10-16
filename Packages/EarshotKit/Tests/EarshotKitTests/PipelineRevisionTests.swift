import Foundation
import Testing
@testable import EarshotKit

/// The pipeline's page, revisions, extra sends and saved choices, beyond the main run (spec 6, 8, 10, 14.4).
struct PipelineRevisionTests {
    static let loops = [OpenLoop(owner: "Dana", task: "Send the pricing sheet", from: "Acme pricing, 7 Oct")]

    /// The action item table row for `task` on the page.
    func row(_ page: String, _ task: String) -> String {
        guard let start = page.range(of: "<span class=\"task\">\(task)</span>") else { return "" }
        let rest = page[start.upperBound...]
        return String(rest[..<(rest.range(of: "</tr>")?.lowerBound ?? rest.endIndex)])
    }

    /// A meeting whose notes are written (`notes`), ready for its dispatch stage.
    func notesDone(_ w: V2World, notes: MeetingNotes = sampleNotes) throws -> Session {
        let s = try w.meeting()
        try Pipeline.json(meetingSegments.values.flatMap { $0 }).write(to: w.store.file(s, MeetingFile.transcript))
        try w.store.write(notes, s, MeetingFile.notes)
        try Data("# Notes\n".utf8).write(to: w.store.file(s, MeetingFile.notesMarkdown))
        return try w.store.update(s.id) {
            $0.stages[.transcribe] = StageState(status: .done)
            $0.stages[.notes] = StageState(status: .done)
        }
    }

    // MARK: The page

    @Test func thePageCarriesTheBriefTheLiveItemsAndTheScreen() async throws {
        let w = V2World()
        var linked = sampleNotes
        linked.actionItems[0].liveRef = "L1"
        w.writer.notes.update { $0 = linked }
        let s = try w.meeting(mode: .notes)
        try w.store.write(MeetingBrief(eventID: "e1", model: "m", createdAt: at1530, headline: "Pricing is the open question",
                                       points: ["Dana owes the pricing sheet"], openLoops: Self.loops), s, MeetingFile.brief)
        try w.store.write(LiveFile(items: [LiveItem(id: "L1", task: "Draft the pilot scope email", owner: "Stephen",
                                                    aiDoable: true, firstSeen: 2, status: .done)]), s, MeetingFile.live)
        try w.store.write(ScreenFile(moments: [ScreenMoment(offset: 5, text: "Q4 price per seat")]), s, MeetingFile.screen)
        await w.pipeline().run(sessionID: s.id)
        let page = try w.page(w.fresh(s))
        #expect(page.contains("Pricing is the open question") && page.contains("Dana owes the pricing sheet"))
        #expect(row(page, "Draft the pilot scope email to Dana").contains(ItemStatus.startedDuringCall))
        #expect(page.contains("Q4 price per seat"))
        let entry = try #require(w.index?.entry(id: s.id))
        #expect(entry.record.live.map(\.id) == ["L1"])
        #expect(entry.record.brief?.openLoops == Self.loops)
        #expect(entry.record.statuses.first == ItemStatus.startedDuringCall)
    }

    // MARK: Started items and warnings

    @Test func itemsLeftOutBecauseTheyWereStartedAreNamedInAWarning() async throws {
        var w = V2World()
        let target = FakeTarget("webhook")
        w.targets = [target]
        var linked = sampleNotes
        linked.actionItems[0].liveRef = "L1"
        let s = try notesDone(w, notes: linked)
        try w.store.write(LiveFile(items: [LiveItem(id: "L1", task: "Scope email", owner: "Stephen", aiDoable: true,
                                                    firstSeen: 2, status: .sent)]), s, MeetingFile.live)
        await w.pipeline(confirm: { _, notes in notes.actionItems }).run(sessionID: s.id)
        #expect(target.sent.get.first?.items.map(\.task) == ["Call the venue"])
        #expect(try w.fresh(s).warnings.contains(Pipeline.leftOutWarning(1)))
        #expect(Pipeline.leftOutWarning(2) == "2 items were left out because they were started during the call.")
    }

    @Test func sendExtraNeverSendsAnItemStartedDuringTheCall() async throws {
        var w = V2World()
        let target = FakeTarget("webhook")
        w.targets = [target]
        var notes = sampleNotes
        notes.actionItems.append(ActionItem(task: "Book the room", owner: "Stephen", doer: .me, liveRef: "L2"))
        w.writer.notes.update { $0 = notes }
        let s = try w.meeting()
        try w.store.write(LiveFile(items: [LiveItem(id: "L2", task: "Book the room", owner: "Stephen", aiDoable: false,
                                                    firstSeen: 2, status: .sent)]), s, MeetingFile.live)
        let pipeline = w.pipeline()
        await pipeline.run(sessionID: s.id)
        let results = try await pipeline.sendExtra(sessionID: s.id, items: [notes.actionItems[2], notes.actionItems[1]])
        #expect(results.keys.sorted() == ["webhook"])
        #expect(target.sent.get.last?.items.map(\.task) == ["Call the venue"])
        #expect(try w.items(w.fresh(s)).map(\.task) == ["Draft the pilot scope email to Dana", "Call the venue"])
        #expect(try w.fresh(s).warnings.contains(Pipeline.leftOutWarning(1)))
    }

    // MARK: Revisions that fail part-way

    @Test func aRevisionThatCantBeWrittenIsAWarningAndTheSendGoesAhead() async throws {
        var w = V2World()
        let target = FakeTarget("webhook")
        w.targets = [target]
        let s = try notesDone(w)
        // notes.md can't be replaced, so the revision fails after notes.json is written.
        try FileManager.default.removeItem(at: w.store.file(s, MeetingFile.notesMarkdown))
        try FileManager.default.createDirectory(at: w.store.file(s, MeetingFile.notesMarkdown), withIntermediateDirectories: true)
        await w.pipeline(confirm: { _, notes in
            var item = notes.actionItems[0]
            item.task = "Draft the pilot scope email to Dana and Lee"
            item.source = "n1"
            return [item]
        }).run(sessionID: s.id)
        let done = try w.fresh(s)
        #expect(done.stages[.dispatch]?.status == .done)
        #expect(done.warnings.contains { $0.hasPrefix("The edited items were sent, but the notes may not show the edits") })
        let payload = try #require(target.sent.get.first)
        #expect(payload.items.map(\.task) == ["Draft the pilot scope email to Dana and Lee"])
        // The payload carries the notes as they are on disk, not an older copy.
        #expect(payload.notes == (try w.notes(done)))
    }

    @Test func aRevisionWhoseCountCantBeSavedChangesNoNotes() async throws {
        let w = V2World()
        let (pipeline, done) = try await w.finished()
        let lock = w.store.file(done, MeetingFile.lock)
        try? FileManager.default.removeItem(at: lock)
        try FileManager.default.createDirectory(at: lock, withIntermediateDirectories: true)
        var fixed = sampleNotes
        fixed.summary = "A three-week pilot."
        await #expect(throws: (any Error).self) {
            try await pipeline.saveRevision(sessionID: done.id, notes: fixed, lesson: nil)
        }
        #expect(try w.notes(done) == sampleNotes)
        #expect(try !String(contentsOf: w.store.file(done, MeetingFile.notesMarkdown), encoding: .utf8)
            .contains("A three-week pilot."))
    }

    @Test func aLessonThatCantBeSavedIsAWarningNotAFailedSave() async throws {
        let w = V2World()
        let (pipeline, done) = try await w.finished()
        try FileManager.default.createDirectory(at: w.lessons.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"version":2,"lessons":[]}"#.utf8).write(to: w.lessons.url)
        let lesson = LessonDiff.instruction("Shorter", style: .general, title: "Acme kickoff", date: at1530)
        try await pipeline.saveRevision(sessionID: done.id, notes: sampleNotes, lesson: lesson)
        let now = try w.fresh(done)
        #expect(now.notesRevision == 1)
        #expect(now.warnings.contains { $0.hasPrefix("The notes were saved, but Earshot couldn't save what it learned") })
    }

    @Test func saveRevisionAndSendExtraThrowWhileAnotherProcessHoldsTheMeeting() async throws {
        let w = V2World()
        let (pipeline, done) = try await w.finished()
        try w.store.markBusy(done)
        await #expect(throws: PipelineError.meetingBusy) {
            try await pipeline.saveRevision(sessionID: done.id, notes: sampleNotes, lesson: nil)
        }
        await #expect(throws: PipelineError.meetingBusy) {
            _ = try await pipeline.sendExtra(sessionID: done.id, items: sampleNotes.actionItems)
        }
        w.store.clearBusy(done)
        try await pipeline.saveRevision(sessionID: done.id, notes: sampleNotes, lesson: nil)
        #expect(try w.fresh(done).notesRevision == 1)
    }

    // MARK: Statuses after a send or a Fix

    @Test func aFailedTargetStillLeavesTheIndexShowingTheOtherSend() async throws {
        var w = V2World()
        w.targets = [FakeTarget("webhook"), FakeTarget("command", ok: false)]
        let (_, done) = try await w.finished()
        #expect(done.stages[.dispatch]?.status == .failed)
        #expect(w.index?.entry(id: done.id)?.record.statuses.first == "Sent to Webhook")
    }

    @Test func itemsSentAfterASkippedSendShowAsSent() async throws {
        let w = V2World()
        let (pipeline, done) = try await w.finished(confirm: { _, _ in nil })
        #expect(done.isFinished && done.sent.isEmpty)
        _ = try await pipeline.sendExtra(sessionID: done.id, items: [sampleNotes.actionItems[1]])
        let now = try w.fresh(done)
        #expect(now.sent == ["webhook"])
        #expect(w.index?.entry(id: done.id)?.record.statuses == [ItemStatus.notSent, "Sent to Webhook"])
        #expect(row(try w.page(now), "Call the venue").contains("Sent to Webhook"))
    }

    @Test func sendExtraWaitsForTheFirstSendToFinish() async throws {
        var w = V2World()
        let target = FakeTarget("webhook", ok: false)
        w.targets = [target]
        let (pipeline, done) = try await w.finished()
        #expect(done.stages[.dispatch]?.status == .failed)
        let saved = try Data(contentsOf: w.store.file(done, MeetingFile.items))
        await #expect(throws: PipelineError.sendNotFinished) {
            _ = try await pipeline.sendExtra(sessionID: done.id, items: [sampleNotes.actionItems[1]])
        }
        #expect(target.sent.get.count == 1)
        #expect(try Data(contentsOf: w.store.file(done, MeetingFile.items)) == saved)
    }

    @Test func aFixThatAddsAndRemovesItemsKeepsEachItemsStatus() async throws {
        let w = V2World()
        let (pipeline, done) = try await w.finished(confirm: { _, notes in [notes.actionItems[0]] })
        #expect(try w.items(done).map(\.source) == ["n1"])
        var fixed = sampleNotes
        // A new item goes first, the sent one is reworded slightly, and "Call the venue" is removed.
        fixed.actionItems = [ActionItem(task: "Summarise the pilot risks", owner: "Stephen", doer: .ai),
                             ActionItem(task: "Draft the pilot scope email to Dana today", owner: "Stephen", doer: .ai)]
        try await pipeline.saveRevision(sessionID: done.id, notes: fixed, lesson: nil)
        let now = try w.fresh(done)
        #expect(try w.items(now).map(\.source) == ["n2"])
        #expect(w.index?.entry(id: done.id)?.record.statuses == [ItemStatus.notSent, "Sent to Webhook"])
        let page = try w.page(now)
        #expect(row(page, "Summarise the pilot risks").contains(ItemStatus.notSent))
        #expect(row(page, "Draft the pilot scope email to Dana today").contains("Sent to Webhook"))
    }

    @Test func anEntryThatMatchesNoItemAfterAFixLosesItsSource() {
        let entries = [ActionItem(task: "Call the venue", owner: "Stephen", doer: .me, source: "n2"),
                       ActionItem(task: "Book the room", owner: "Stephen", doer: .me, source: "L3")]
        var fixed = sampleNotes
        fixed.actionItems = [ActionItem(task: "Write the risks memo", owner: "Stephen", doer: .ai)]
        let retagged = Pipeline.retagged(entries, old: sampleNotes, new: fixed)
        #expect(retagged.map(\.source) == [nil, "L3"])
    }

    // MARK: Matching confirmed items to the notes

    @Test func anEditedItemNeverTakesTheSlotOfAnUnchangedOne() {
        var notes = sampleNotes
        notes.actionItems = [ActionItem(task: "Send Dana the pricing sheet", owner: "Stephen", doer: .me),
                             ActionItem(task: "Send Dana the pricing sheet today", owner: "Stephen", doer: .me)]
        // The first one was edited so that it now looks more like the second, which comes back unchanged.
        let confirmed = [ActionItem(task: "Send Dana the pricing sheet by today", owner: "Stephen", doer: .me),
                         notes.actionItems[1]]
        let tagged = Pipeline.withSources(confirmed, notes: notes)
        #expect(tagged.map(\.source) == ["n1", "n2"])
        #expect(Pipeline.revised(notes, with: tagged)?.actionItems.map(\.task)
            == ["Send Dana the pricing sheet by today", "Send Dana the pricing sheet today"])
    }

    // MARK: Extra sends to some targets

    /// A finished meeting sent to webhook and command, then a Fix that adds one item, which is returned.
    func fixedWithAnExtraItem(_ w: V2World) async throws -> (Pipeline, Session, ActionItem) {
        let (pipeline, done) = try await w.finished()
        var fixed = sampleNotes
        fixed.actionItems.append(ActionItem(task: "Summarise the pilot risks", owner: "Stephen", doer: .ai))
        try await pipeline.saveRevision(sessionID: done.id, notes: fixed, lesson: nil)
        return (pipeline, done, fixed.actionItems[2])
    }

    @Test func sendExtraSendsOnlyToTheTargetsItIsGiven() async throws {
        var w = V2World()
        let webhook = FakeTarget("webhook"), command = FakeTarget("command")
        w.targets = [webhook, command]
        let (pipeline, done, extra) = try await fixedWithAnExtraItem(w)
        let results = try await pipeline.sendExtra(sessionID: done.id, items: [extra], targets: ["command"])
        #expect(results.keys.sorted() == ["command"])
        #expect(webhook.sent.get.count == 1)
        #expect(command.sent.get.count == 2)
        #expect(command.sent.get.last?.items.map(\.task) == ["Summarise the pilot risks"])
        #expect(command.sent.get.last?.session.id == Pipeline.extraPayloadID(sessionID: done.id, revision: 1, items: [extra]))
    }

    @Test func aRetryAfterAPartialFailureGoesOnlyToTheTargetThatFailed() async throws {
        var w = V2World()
        let webhook = FakeTarget("webhook"), command = FakeTarget("command")
        w.targets = [webhook, command]
        let (pipeline, done, extra) = try await fixedWithAnExtraItem(w)
        command.ok.update { $0 = false }
        let plan = AskRules.extraSends([extra], targets: ["webhook", "command"], delivered: [:])
        #expect(plan.count == 1)
        let first = try await pipeline.sendExtra(sessionID: done.id, items: plan[0].items, targets: plan[0].targets)
        #expect(first["webhook"]?.ok == true && first["command"]?.ok == false)
        let delivered = AskRules.delivered([:], after: plan[0], results: first)
        let retry = AskRules.extraSends([extra], targets: ["webhook", "command"], delivered: delivered)
        #expect(retry == [AskRules.ExtraSend(items: [extra], targets: ["command"])])
        command.ok.update { $0 = true }
        let second = try await pipeline.sendExtra(sessionID: done.id, items: retry[0].items, targets: retry[0].targets)
        #expect(second.keys.sorted() == ["command"] && second["command"]?.ok == true)
        // The webhook took the extra item once, with the first send.
        #expect(webhook.sent.get.count == 2)
        #expect(command.sent.get.count == 3)
        #expect(try w.items(w.fresh(done)).map(\.task).filter { $0 == extra.task }.count == 1)
        #expect(try w.fresh(done).sent.sorted() == ["command", "webhook"])
    }

    /// A receiver keeps done-state per payload id and item position, so a send with other items needs another id,
    /// and a retry of the same items needs the same one.
    @Test func eachSetOfItemsGetsItsOwnPayloadIDAndARetryKeepsIt() async throws {
        var w = V2World()
        let routine = LinkTarget(link: V2World.link)
        w.targets = [routine]
        let (pipeline, done) = try await w.finished()
        var fixed = sampleNotes
        fixed.actionItems += [ActionItem(task: "Summarise the pilot risks", owner: "Stephen", doer: .ai),
                              ActionItem(task: "Book the pilot kickoff room", owner: "Stephen", doer: .ai)]
        try await pipeline.saveRevision(sessionID: done.id, notes: fixed, lesson: nil)
        let risks = fixed.actionItems[2], room = fixed.actionItems[3]
        _ = try await pipeline.sendExtra(sessionID: done.id, items: [risks])
        _ = try await pipeline.sendExtra(sessionID: done.id, items: [risks])
        _ = try await pipeline.sendExtra(sessionID: done.id, items: [risks, room])
        let ids = routine.sent.get.map(\.session.id)
        #expect(ids.count == 4)
        #expect(ids[1] == ids[2], "an identical retry keeps its id")
        #expect(ids[1] != ids[3], "another set of items gets another id")
        #expect(ids[1] == Pipeline.extraPayloadID(sessionID: done.id, revision: 1, items: [risks]))
        #expect(ids[3] == Pipeline.extraPayloadID(sessionID: done.id, revision: 1, items: [risks, room]))
        #expect(ids.dropFirst().allSatisfy { $0.hasPrefix("\(done.id)-r1-") })
        // The routine runs and the items are recorded under the id that carried them.
        let now = try w.fresh(done)
        #expect(now.routineRuns[ids[1]] == V2World.link && now.routineRuns[ids[3]] == V2World.link)
        #expect(try w.items(now).compactMap(\.payload).contains(ids[3]))
    }

    @Test func sendExtraWithNoTargetLeftSendsNothing() async throws {
        var w = V2World()
        let webhook = FakeTarget("webhook")
        w.targets = [webhook]
        let (pipeline, done, extra) = try await fixedWithAnExtraItem(w)
        #expect(try await pipeline.sendExtra(sessionID: done.id, items: [extra], targets: []).isEmpty)
        // A target that is switched off now is never sent to, even when asked for.
        #expect(try await pipeline.sendExtra(sessionID: done.id, items: [extra], targets: ["routine"]).isEmpty)
        #expect(webhook.sent.get.count == 1)
        #expect(try w.items(w.fresh(done)).map(\.task) == ActionItem.defaultSelection(sampleNotes.actionItems).map(\.task))
    }

    /// Finding 10: the targets took the items, then recording them failed. The results still come back, so the Ask
    /// window knows who has the items, and the failure is a warning on the meeting.
    @Test func sendExtraReturnsItsResultsWhenRecordingThemFails() async throws {
        var w = V2World()
        let breaks = BreaksItemsTarget()
        w.targets = [breaks]
        let (pipeline, done, extra) = try await fixedWithAnExtraItem(w)
        breaks.breaks.update { $0 = true }
        let results = try await pipeline.sendExtra(sessionID: done.id, items: [extra])
        #expect(results["webhook"]?.ok == true)
        let fresh = try w.fresh(done)
        #expect(fresh.warnings.contains { $0.hasPrefix(Pipeline.notRecordedWarning) })
        #expect(fresh.sent == ["webhook"])
    }

    // MARK: Choices saved by the command line

    @Test func aPersonsChoiceIsKeptForEveryLaterRetry() async throws {
        var w = V2World()
        let webhook = FakeTarget("webhook", ok: false), command = FakeTarget("command", ok: false)
        w.targets = [webhook, command]
        let s = try w.meeting()
        try w.store.update(s.id) { $0.startedBy = .cli }
        let asked = Locked(0)
        let pipeline = w.pipeline(confirm: { _, notes in
            asked.update { $0 += 1 }
            return asked.get == 1 ? ActionItem.defaultSelection(notes.actionItems) : [notes.actionItems[1]]
        })
        // `earshot process` runs it, holding the meeting, and the AI's pick fails to send.
        try w.store.markBusy(s)
        await pipeline.run(sessionID: s.id)
        w.store.clearBusy(s)
        // In the app, Retry asks the person, because the saved choice was the AI's.
        webhook.ok.update { $0 = true }
        await pipeline.retry(sessionID: s.id)
        #expect(asked.get == 2)
        #expect(webhook.sent.get.last?.items.map(\.task) == ["Call the venue"])
        // A later Retry sends what the person chose to the rest, without asking again.
        command.ok.update { $0 = true }
        await pipeline.retry(sessionID: s.id)
        #expect(asked.get == 2)
        #expect(command.sent.get.last?.items.map(\.task) == ["Call the venue"])
        #expect(try w.fresh(s).isFinished)
    }

    // MARK: The command line's lessons file

    @Test func theCommandLineFindsLessonsWhereTheAppKeepsThem() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        #expect(LessonsStore.defaultURL(home: home).standardizedFileURL == LessonsStore.defaultURL.standardizedFileURL)
        #expect(LessonsStore.defaultURL(home: URL(filePath: "/tmp/h")).path
            == "/tmp/h/Library/Application Support/Earshot/lessons.json")
    }
}

/// A target that takes the payload. Once `breaks` is on, it then puts a folder where items.json was, so recording
/// the sent items fails.
final class BreaksItemsTarget: DoTarget, @unchecked Sendable {
    let id = "webhook"
    let label = "Webhook"
    let breaks = Locked(false)
    func send(_ payload: DoPayload, json: Data, folder: URL) async -> DispatchResult {
        if breaks.get {
            let items = folder.appending(path: MeetingFile.items)
            try? FileManager.default.removeItem(at: items)
            try? FileManager.default.createDirectory(at: items, withIntermediateDirectories: true)
        }
        return DispatchResult(ok: true, detail: "200")
    }
}
