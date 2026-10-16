import Foundation
import Testing
@testable import EarshotKit

private let runLink = "https://claude.ai/code/session_01RUN"

/// After the call, an item sent to the routine target whose run link was recorded is "Started in the cloud", and
/// the notes page links the run (spec 12 and 14.4).
struct CloudRunStatusTests {
    let notes = MeetingNotes(title: "T", summary: "S", actionItems: [
        ActionItem(task: "Draft the pilot scope email", owner: "Stephen", doer: .ai, liveRef: "L1"),
        ActionItem(task: "Book the venue for the review", owner: "Stephen", doer: .me),
    ])
    let sentFirst = [ActionItem(task: "Draft the pilot scope email", owner: "Stephen", doer: .ai, source: "n1")]

    @Test func anItemSentToTheRoutineWithARunIsStartedInTheCloud() {
        #expect(ItemStatus.startedInCloud == "Started in the cloud")
        #expect(ItemStatus.compute(notes: notes, items: sentFirst, sent: ["routine"], live: [], cloudRuns: [runLink, nil])
            == [ItemStatus.startedInCloud, ItemStatus.notSent])
        #expect(ItemStatus.compute(notes: notes, items: sentFirst, sent: ["webhook", "routine"], live: [], cloudRuns: [runLink])
            == [ItemStatus.startedInCloud, ItemStatus.notSent])
    }

    @Test func withoutARunOrTheRoutineItIsJustSent() {
        #expect(ItemStatus.compute(notes: notes, items: sentFirst, sent: ["routine"], live: [], cloudRuns: [nil, nil])
            == ["Sent to Claude Code routine", ItemStatus.notSent])
        #expect(ItemStatus.compute(notes: notes, items: sentFirst, sent: ["routine"], live: [])
            == ["Sent to Claude Code routine", ItemStatus.notSent])
        #expect(ItemStatus.compute(notes: notes, items: nil, sent: ["routine"], live: [], cloudRuns: [runLink, runLink])
            == [ItemStatus.notSentYet, ItemStatus.notSentYet])
    }

    @Test func startedDuringTheCallStillComesFirst() {
        let live = [LiveItem(id: "L1", task: "x", owner: "Stephen", aiDoable: true, firstSeen: 0, status: .done)]
        #expect(ItemStatus.compute(notes: notes, items: sentFirst, sent: ["routine"], live: live, cloudRuns: [runLink, nil])
            == [ItemStatus.startedDuringCall, ItemStatus.notSent])
    }

    /// The meeting's own send is keyed by its id; a later extra send by "<id>-r<n>". The meeting's own run comes
    /// first, then the newest extra one.
    @Test func theRunIsTheMeetingsOwnPayloadsThenTheNewestExtraOne() {
        var session = Session(id: "20261014-153000", folderName: "f", title: nil, mode: .notesAndDo, startedAt: at1530,
                              endedAt: nil, recording: false, tracks: [], stages: [:], sent: ["routine"], warnings: [])
        #expect(ItemStatus.routineRun(for: session) == nil)
        session.routineRuns = ["20261014-153000-r1": "https://claude.ai/code/r1", "20261014-153000-r10": "https://claude.ai/code/r10",
                               "20261014-153000-r9": "https://claude.ai/code/r9", "other-r50": "https://claude.ai/code/x"]
        #expect(ItemStatus.routineRun(for: session) == "https://claude.ai/code/r10")
        session.routineRuns["20261014-153000"] = runLink
        #expect(ItemStatus.routineRun(for: session) == runLink)
        session.routineRuns = ["20261014-153000": "  "]
        #expect(ItemStatus.routineRun(for: session) == nil)
    }

    /// Extra sends now end in a hash of their items ("<id>-r<n>-<hash>"); the newest revision still wins, and
    /// older "<id>-r<n>" keys still count.
    @Test func theNewestExtraRunIsFoundWithItsItemHash() {
        var session = Session(id: "20261014-153000", folderName: "f", title: nil, mode: .notesAndDo, startedAt: at1530,
                              endedAt: nil, recording: false, tracks: [], stages: [:], sent: ["routine"], warnings: [])
        session.routineRuns = ["20261014-153000-r2-0a1b2c3d": "https://claude.ai/code/r2", "20261014-153000-r1": "https://claude.ai/code/r1",
                               "20261014-153000-r10-ffff0000": "https://claude.ai/code/r10", "20261014-153000-rx-1": "https://claude.ai/code/x"]
        #expect(ItemStatus.routineRun(for: session) == "https://claude.ai/code/r10")
        session.routineRuns["20261014-153000-r10-ffff0000"] = nil
        #expect(ItemStatus.routineRun(for: session) == "https://claude.ai/code/r2")
    }

    private func page(link: String) -> String {
        var session = Session(id: "20261014-153000", folderName: "f", title: "Acme kickoff", mode: .notesAndDo,
                              startedAt: at1530, endedAt: at1530.addingTimeInterval(2400), recording: false, tracks: [],
                              stages: [:], sent: ["routine"], warnings: [])
        session.routineRuns = [session.id: link]
        let runs = ItemStatus.cloudRuns(notes: notes, items: sentFirst, session: session)
        let statuses = ItemStatus.compute(notes: notes, items: sentFirst, sent: session.sent, live: [], cloudRuns: runs)
        return NotesPageRenderer.html(NotesPageInput(notes: notes, session: session, statuses: statuses,
                                                     cloudRuns: runs, timeZone: newYork))
    }

    @Test func theNotesPageShowsTheStatusWithAnOpenRunLink() {
        let html = page(link: runLink)
        #expect(html.contains("<span class=\"status started\">Started in the cloud</span><a class=\"run\" href=\"\(runLink)\">Open run</a>"))
        #expect(html.components(separatedBy: ">Open run<").count == 2, "only the item sent to the routine")
    }

    @Test func aRunLinkThatIsNotHttpsIsNeverALink() {
        for link in ["http://claude.ai/code/x", "javascript:alert(1)", "https://claude.ai/a\"onclick=x"] {
            let html = page(link: link)
            #expect(html.contains(">Started in the cloud</span>"), "\(link)")
            #expect(!html.contains(">Open run<"), "\(link)")
            #expect(!html.contains("javascript:") && !html.contains("http://claude.ai"), "\(link)")
        }
    }

    /// Each item's run is the run of the payload that carried it: `routineRuns[<payload>]`. Entries written before
    /// the payload was recorded fall back to the meeting's run when the routine took the meeting's items.
    @Test func eachItemsRunIsItsOwnPayloads() {
        var session = Session(id: "20261014-153000", folderName: "f", title: nil, mode: .notesAndDo, startedAt: at1530,
                              endedAt: nil, recording: false, tracks: [], stages: [:], sent: ["webhook", "routine"],
                              warnings: [])
        session.routineRuns = ["20261014-153000-r1": "https://claude.ai/code/r1"]
        let three = MeetingNotes(title: "T", summary: "S", actionItems: notes.actionItems
            + [ActionItem(task: "Summarise the pilot risks", owner: "Stephen", doer: .ai)])
        let items = [ActionItem(task: "Draft the pilot scope email", owner: "Stephen", doer: .ai, source: "n1",
                                payload: session.id),
                     ActionItem(task: "Summarise the pilot risks", owner: "Stephen", doer: .ai, source: "n3",
                                payload: "20261014-153000-r1")]
        #expect(ItemStatus.cloudRuns(notes: three, items: items, session: session) == [nil, nil, "https://claude.ai/code/r1"])
        session.routineRuns[session.id] = runLink
        #expect(ItemStatus.cloudRuns(notes: three, items: items, session: session) == [runLink, nil, "https://claude.ai/code/r1"])
        // A blank run is no run.
        session.routineRuns["20261014-153000-r1"] = " "
        #expect(ItemStatus.cloudRuns(notes: three, items: items, session: session) == [runLink, nil, nil])
        // An older items.json, with no payload: the meeting's run, when the routine took the items.
        let legacy = items.map { item -> ActionItem in var item = item; item.payload = nil; return item }
        #expect(ItemStatus.cloudRuns(notes: three, items: legacy, session: session) == [runLink, nil, runLink])
        session.sent = ["webhook"]
        #expect(ItemStatus.cloudRuns(notes: three, items: legacy, session: session) == [nil, nil, nil])
        #expect(ItemStatus.cloudRuns(notes: three, items: nil, session: session) == [nil, nil, nil])
    }

    @Test func thePayloadFieldIsOptionalAndWrittenOnlyWhenSet() throws {
        let old = #"[{"task":"Call","owner":"Me","due":null,"doer":"me","context":"","live_ref":null,"source":"n1"}]"#
        let decoded = try JSONDecoder().decode([ActionItem].self, from: Data(old.utf8))
        #expect(decoded.first?.payload == nil && decoded.first?.source == "n1")
        let odd = #"[{"task":"Call","owner":"Me","doer":"me","payload":7}]"#
        #expect(try JSONDecoder().decode([ActionItem].self, from: Data(odd.utf8)).first?.payload == nil)
        #expect(!String(decoding: try JSONEncoder().encode(decoded), as: UTF8.self).contains("payload"))
        var tagged = decoded[0]
        tagged.payload = "m-r2"
        let round = try JSONDecoder().decode(ActionItem.self, from: JSONEncoder().encode(tagged))
        #expect(round.payload == "m-r2")
    }

    @Test func receiversNeverSeeThePayloadField() throws {
        let tagged = ActionItem(task: "Call", owner: "Me", doer: .me, source: "n1", payload: "m")
        let session = Session(id: "m", folderName: "f", title: "T", mode: .notesAndDo, startedAt: at1530, endedAt: nil,
                              recording: false, tracks: [], stages: [:], sent: [], warnings: [])
        let payload = DoPayload(session: session, folder: tempDir(), notes: sampleNotes, notesMarkdown: "",
                                transcriptPath: "/t.md", items: [tagged])
        #expect(payload.items.map(\.payload) == [nil])
        #expect(!String(decoding: try payload.encoded(), as: UTF8.self).contains("\"payload\""))
    }

    // MARK: Reminders and MCP

    @Test func itemsStartedInTheCloudAreNotOpen() {
        #expect(ItemStatus.isHandled(ItemStatus.startedInCloud))
        #expect(ItemStatus.isHandled(ItemStatus.startedDuringCall))
        #expect(ItemStatus.isHandled("Sent to Webhook"))
        #expect(!ItemStatus.isHandled(ItemStatus.notSent) && !ItemStatus.isHandled(ItemStatus.notSentYet))
        #expect(!Reminders.isOpen(ItemStatus.startedInCloud))
    }

    /// A meeting whose own send went to the routine and started a run: the user's item is neither a reminder nor
    /// an open item over MCP.
    private func cloudMeeting(_ h: LibraryHarness) throws -> Session {
        let item = ActionItem(task: "Send the revised pricing sheet", owner: "Stephen", doer: .me)
        let s = try h.meeting("Acme pricing", daysAgo: 1, notes: LibraryHarness.notes("Acme pricing", items: [item]),
                              items: [ActionItem(task: item.task, owner: "Stephen", doer: .me, source: "n1")],
                              sent: ["routine"], index: false)
        let saved = try h.store.update(s.id) { $0.routineRuns[$0.id] = runLink }
        try h.index.write(MeetingRecord.load(saved, from: h.store), transcript: [], names: [:], userName: "Stephen")
        return saved
    }

    @Test func remindersLeaveOutItemsStartedInTheCloud() throws {
        let h = LibraryHarness()
        let s = try cloudMeeting(h)
        #expect(h.index.entry(id: s.id)?.record.statuses == [ItemStatus.startedInCloud])
        try h.index.writeReminders(userName: "Stephen", now: at1530)
        #expect(try #require(h.index.reminders()).items.isEmpty)
    }

    @Test func meetingPrepListsNoItemStartedInTheCloudAsOpen() throws {
        let h = LibraryHarness()
        _ = try cloudMeeting(h)
        var server = MCPServer(library: h.library, userName: "Stephen", version: "0.2.0", app: "Terminal",
                               timeZone: newYork, now: { at1530 })
        let meta: [String: Any] = [
            "io.modelcontextprotocol/protocolVersion": "2026-07-28",
            "io.modelcontextprotocol/clientInfo": ["name": "claude-code", "version": "2.1.296"],
            "io.modelcontextprotocol/clientCapabilities": [String: Any](),
        ]
        let request: [String: Any] = ["jsonrpc": "2.0", "id": 1, "method": "tools/call",
                                      "params": ["name": "meeting_prep", "arguments": ["title": "Acme pricing"], "_meta": meta]]
        let line = String(decoding: try JSONSerialization.data(withJSONObject: request), as: UTF8.self)
        let answer = server.handle(line)
        let raw = try #require(answer)
        let reply = try #require(try JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any])
        let result = try #require(reply["result"] as? [String: Any], "\(raw)")
        let facts = (result["structuredContent"] as? [String: Any])?[MCPServer.contentTag.rawValue] as? [String: Any]
        let meetings = try #require(facts?["meetings"] as? [[String: Any]])
        #expect(meetings.count == 1)
        #expect((meetings.first?["open_items"] as? [[String: Any]])?.isEmpty == true)
    }
}

/// End to end through the pipeline: items.json records which payload carried each item, so each item shows its own
/// run.
struct CloudRunPayloadTests {
    let extra = ActionItem(task: "Summarise the pilot risks", owner: "Stephen", doer: .ai)

    /// The payload id of the Fix item's send.
    private func extraID(_ session: Session) -> String {
        Pipeline.extraPayloadID(sessionID: session.id, revision: 1, items: [extra])
    }

    /// A finished meeting sent by `first`, then a Fix item (n3) sent by `then` from a second app run on the same
    /// folders.
    private func sendTwice(first: [any DoTarget], then: [any DoTarget]) async throws -> (V2World, Session) {
        var w = V2World()
        w.targets = first
        let (pipeline, done) = try await w.finished()
        var fixed = sampleNotes
        fixed.actionItems.append(extra)
        try await pipeline.saveRevision(sessionID: done.id, notes: fixed, lesson: nil)
        var later = w
        later.targets = then
        _ = try await later.pipeline().sendExtra(sessionID: done.id, items: [fixed.actionItems[2]])
        return (w, try w.fresh(done))
    }

    @Test func aWebhookSendThenARoutineSendShowsOnlyTheRoutinesItemInTheCloud() async throws {
        let r1 = "https://claude.ai/code/session_01R1"
        let (w, now) = try await sendTwice(first: [FakeTarget("webhook")], then: [LinkTarget(link: r1)])
        #expect(now.sent == ["webhook", "routine"])
        #expect(now.routineRuns == [extraID(now): r1])
        #expect(try w.items(now).map(\.payload) == [now.id, extraID(now)])
        // "Sent to" names the meeting's targets; only n3 went to the routine, so only n3 started in the cloud.
        #expect(w.index?.entry(id: now.id)?.record.statuses
            == ["Sent to Webhook, Claude Code routine", ItemStatus.notSent, ItemStatus.startedInCloud])
        let page = try w.page(now)
        #expect(page.components(separatedBy: ">Open run<").count == 2)
        #expect(page.contains(">Started in the cloud</span><a class=\"run\" href=\"\(r1)\">Open run</a>"))
    }

    @Test func twoRoutineSendsLinkEachItemToItsOwnRun() async throws {
        let own = "https://claude.ai/code/session_01OWN", r1 = "https://claude.ai/code/session_01R1"
        let (w, now) = try await sendTwice(first: [LinkTarget(link: own)], then: [LinkTarget(link: r1)])
        #expect(now.routineRuns == [now.id: own, extraID(now): r1])
        #expect(w.index?.entry(id: now.id)?.record.statuses
            == [ItemStatus.startedInCloud, ItemStatus.notSent, ItemStatus.startedInCloud])
        // Each table row alone, cut at its end, so the footer's run links are not part of the last row.
        let rows = try w.page(now).components(separatedBy: "<tr>").map { $0.components(separatedBy: "</tr>")[0] }
            .filter { $0.contains("Open run") }
        #expect(rows.count == 2)
        #expect(rows.first?.contains("Draft the pilot scope email") == true && rows.first?.contains(own) == true)
        #expect(rows.last?.contains("Summarise the pilot risks") == true && rows.last?.contains(r1) == true)
        #expect(rows.allSatisfy { !($0.contains(own) && $0.contains(r1)) })
    }
}
