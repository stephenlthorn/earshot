import Foundation
import Testing
@testable import EarshotKit

/// The real-model checks (c) to (i), shared by ClaudeLiveTests (the user's Claude Code) and LocalLiveTests (a local
/// model server). Each makes real calls through `client` with `model` and records one verdict line. Only the gated
/// suites call them; unit tests never call a model.
enum LiveScenarios {
    // MARK: Notes from a fixed transcript

    /// (c) The action item names Ashley, the proposal and Friday.
    static func notesFindAshleysProposalByFriday(client: any ClaudeClient, model: String) async throws {
        let transcript = try ClaudeFixtures.text("ashley-proposal.txt")
        let notes = try await ClaudeNotesWriter(client: client, model: model, effort: "low")
            .write(LiveClaude.notesRequest(transcript))
        let item = notes.actionItems.first { item in
            let text = LiveClaude.lower(item.task, item.context, item.due)
            return text.contains("proposal") && text.contains("friday") && text.contains("ashley")
        }
        verdict("c", "notes: Ashley, the proposal and Friday", item != nil,
                "items=\(LiveClaude.json(notes.actionItems.map { [$0.task, $0.owner, $0.due ?? "null"] }))")
    }

    /// (d) Two external attendees and nobody identified in the transcript: no item is attributed to either of them.
    static func notesNeverGuessWhichExternalAttendeeSpoke(client: any ClaudeClient, model: String) async throws {
        let context = NotesContext(attendees: [ContextAttendee(name: "Stephen Thorn", side: .me),
                                               ContextAttendee(name: "Priya Raman", side: .external),
                                               ContextAttendee(name: "Tom Okafor", side: .external)],
                                   profile: .external)
        let notes = try await ClaudeNotesWriter(client: client, model: model, effort: "low")
            .write(LiveClaude.notesRequest(try ClaudeFixtures.text("two-externals.txt"), context: context))
        let guessed = notes.actionItems.filter { item in
            let text = LiveClaude.lower(item.task, item.owner, item.context)
            return ["priya", "raman", "tom ", "okafor"].contains { text.contains($0) } || item.owner == "Tom"
        }
        let ok = guessed.isEmpty && notes.actionItems.count >= 2
        verdict("d", "notes: nothing attributed to an unidentified external attendee", ok,
                "owners=\(LiveClaude.json(notes.actionItems.map(\.owner))), attributed to Priya or Tom: \(guessed.count)")
    }

    /// (e) The notes reword a to-do started during the call and still link it through `live_ref`.
    static func notesLinkARewordedStartedItemThroughLiveRef(client: any ClaudeClient, model: String) async throws {
        let started = NotesContext.StartedItem(id: "L2", task: "Pull together a competitor price comparison sheet")
        let context = NotesContext(started: [NotesContext.StartedItem(id: "L1", task: "Reserve offsite space"), started])
        let notes = try await ClaudeNotesWriter(client: client, model: model, effort: "low")
            .write(LiveClaude.notesRequest(try ClaudeFixtures.text("live-ref.txt"), context: context))
        let linked = notes.actionItems.filter { $0.liveRef == "L2" }
        let item = linked.first
        let ok = linked.count == 1 && item.map { $0.task != started.task && LiveClaude.lower($0.task).contains("pric") } == true
        verdict("e", "notes: live_ref links reworded live item L2", ok,
                "live wording=\"\(started.task)\"; notes=\(LiveClaude.json(notes.actionItems.map { [$0.task, $0.liveRef ?? "null"] }))")
    }

    // MARK: Live to-dos

    /// (f) A scripted meeting fed in three stages: two to-dos, then the proposal's deadline changes by ref, then a
    /// new to-do.
    static func liveExtractionAcrossStagesUpdatesByRef(client inner: any ClaudeClient, model: String) async throws {
        let stages = try ClaudeFixtures.liveStages()
        let finals = Locked<[Segment]>([])
        let clock = Locked<Double>(0)
        let latest = Locked<[LiveItem]>([])
        let client = RecordingClient(inner)
        let extractor = LiveExtractor(
            client: client, model: model, effort: "low", interval: .seconds(90),
            finals: { finals.get }, finalize: {}, now: { clock.get },
            context: { LivePrompt.Meeting(title: "Proposal and onboarding", userName: "Stephen", attendees: ["Ashley Park"]) },
            onItems: { items in latest.update { $0 = items } }, onStatus: { _ in }, sleep: { _ in })
        var results: [LiveExtractor.PassResult] = []
        var snapshots: [[LiveItem]] = []
        for stage in stages {
            finals.update { $0 += stage }
            clock.update { $0 = stage.last?.end ?? 0 }
            results.append(await extractor.passNow())
            snapshots.append(latest.get)
        }
        let isProposal = { (task: String) in task.lowercased().contains("proposal") }
        let first = snapshots.first?.first { isProposal($0.task) }
        let final = snapshots.last ?? []
        let proposals = final.filter { isProposal($0.task) }
        let stage2 = client.replies.count > 1
            ? (try? JSONDecoder().decode(LivePrompt.Response.self, from: client.replies[1]))?.items ?? [] : []
        let byRef = first.map { item in stage2.contains { $0.ref == item.id && isProposal($0.task) } } ?? false
        let updated = first.flatMap { item in final.first { $0.id == item.id } }
        let ok = results == [.extracted, .extracted, .extracted]
            && snapshots.first?.contains { $0.task.lowercased().contains("checklist") } == true
            && byRef && proposals.count == 1 && LiveClaude.lower(updated?.due).contains("thursday")
            && final.contains { $0.task.lowercased().contains("venue") && $0.firstSeen > 150 }
        verdict("f", "live to-dos fed in stages, updated by ref", ok,
                "passes=\(results); stage 2 reply=\(LiveClaude.json(stage2.map { [$0.ref, $0.task, $0.due ?? "null"] })); "
                + "final=\(LiveClaude.json(final.map { [$0.id, $0.task, $0.due ?? "null"] }))")
    }

    // MARK: Brief, ask and fix

    /// (g) The brief from fixture history (the v1 Acme kickoff): the open loops come from that meeting.
    static func briefFromFixtureHistory(client: any ClaudeClient, model: String) async throws {
        let store = try V1Fixtures.store()
        let record = MeetingRecord.load(try V1Fixtures.session(store, "Acme kickoff"), from: store)
        let now = Date()
        let event = CalendarEventInfo(id: "claude-test", title: "Acme pilot check-in", start: now, end: now + 1800,
                                      attendees: [Attendee(name: "Dana Smith", email: "dana@acme.example"),
                                                  Attendee(name: "Stephen", email: "stephen@example.com", isMe: true)],
                                      agenda: "How the first week of the pilot went.")
        let brief = try await BriefWriter(client: client, model: model)
            .write(event: event, title: nil, history: [record], userName: "Stephen", now: now)
        let label = BriefFallback.source(record)
        let loops = brief.openLoops
        let ok = !brief.headline.isEmpty && loops.contains { LiveClaude.lower($0.task).contains("scope") }
            && loops.allSatisfy { $0.from == label } && brief.sources == [record.id]
        verdict("g", "brief from fixture history", ok,
                "headline=\"\(brief.headline)\"; loops=\(LiveClaude.json(loops.map { [$0.owner, $0.task, $0.from] })); label=\"\(label)\"")
    }

    /// (h) Ask answers from the transcript and quotes the time as [mm:ss].
    static func askAnswersWithATime(client: any ClaudeClient, model: String) async throws {
        let lines = try ClaudeFixtures.transcript("ashley-proposal.txt")
        let asked = try #require(lines.first { $0.speaker == "Ashley" && $0.text.contains("revised proposal") })
        let answer = try await MeetingQA(client: client, model: model)
            .ask(question: "When did Ashley ask for the revised proposal, and by when does she want it?", notes: nil,
                 transcript: lines)
        let time = "[\(NotesRenderer.clock(asked.start))]"
        let ok = answer.contains(time) && answer.lowercased().contains("friday")
        verdict("h", "ask answers with a [mm:ss] time", ok, "expected \(time) and Friday; answer=\"\(answer)\"")
    }

    /// (i) Fix applies the user's instruction and keeps everything else.
    static func fixAppliesTheInstruction(client: any ClaudeClient, model: String) async throws {
        let notes = MeetingNotes(
            title: "Proposal review with Ashley", summary: "Ashley wants the revised proposal by Friday for her board.",
            attendees: ["Stephen", "Ashley", "Dana"], keyPoints: ["The pricing needs a three-year option"],
            actionItems: [ActionItem(task: "Send Ashley the revised proposal", owner: "Stephen", due: "Friday", doer: .me,
                                     context: "Add the three-year option."),
                          ActionItem(task: "Book the venue for the launch workshop", owner: "Stephen", doer: .me)])
        let revised = try await NotesFixer(client: client, model: model, effort: "low")
            .fix(instruction: "Dana is booking the venue, not me. Fix the owner.", notes: notes,
                 transcript: try ClaudeFixtures.transcript("ashley-proposal.txt"))
        let venue = revised.actionItems.first { $0.task.lowercased().contains("venue") }
        let proposal = revised.actionItems.first { $0.task.lowercased().contains("proposal") }
        let diff = NotesDiff.compare(notes, revised)
        let ok = venue?.owner.contains("Dana") == true && proposal?.owner == "Stephen" && proposal?.due == "Friday"
            && revised.title == notes.title && revised.actionItems.count == 2
        verdict("i", "fix applies an instruction", ok,
                "items=\(LiveClaude.json(revised.actionItems.map { [$0.task, $0.owner, $0.due ?? "null"] })); "
                + "changed=\(diff.changed.count) added=\(diff.added.count) removed=\(diff.removed.count) title changed=\(diff.titleChanged)")
    }
}
