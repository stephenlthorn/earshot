import Foundation
import Testing
@testable import EarshotKit

/// The README screenshots' sample data (`Earshot --render-screenshots`).
struct ScreenshotSamplesTests {
    let now = at1530

    @Test func sampleTextHasNoDashesAndOnlyMadeUpPeople() throws {
        let encoder = JSONEncoder()
        let store = SessionStore(root: tempDir())
        let parts: [Data] = try [
            encoder.encode(ScreenshotSamples.notes),
            encoder.encode(ScreenshotSamples.brief),
            encoder.encode(ScreenshotSamples.liveItems),
            encoder.encode(ScreenshotSamples.panelFrames.flatMap(\.items)),
            encoder.encode(ScreenshotSamples.event(now: now)),
            encoder.encode(ScreenshotSamples.transcript),
            encoder.encode(ScreenshotSamples.writeRecentMeetings(to: store, now: now).sessions),
        ]
        let text = parts.map { String(decoding: $0, as: UTF8.self) }.joined()
            + ScreenshotSamples.panelFrames.map { $0.tickerMe + $0.tickerThem }.joined()
            + ScreenshotSamples.notesPageHTML(now: now)
        #expect(!text.contains("\u{2014}"))
        #expect(!text.contains("\u{2013}"))
        #expect(!text.contains("Stephen"))
        #expect(text.contains("Ashley") && text.contains("Dana") && text.contains("Acme"))
        #expect(text.contains(ScreenshotSamples.proposalTask))
        // Addresses are on reserved example domains only.
        let emails = ScreenshotSamples.event(now: now).attendees.compactMap(\.email)
        #expect(!emails.isEmpty)
        #expect(emails.allSatisfy { $0.hasSuffix(".example") })
    }

    @Test func theFinalPanelShowsStartRunningAndDone() {
        let rows = LiveRows.rows(ScreenshotSamples.liveItems, start: .oneClick, pressedAt: [:], now: now)
        #expect(rows.count == 3)
        #expect(rows.filter { $0.actions.contains(.start) }.count == 1)
        #expect(rows.filter { $0.state == "Running" }.count == 1)
        #expect(rows.filter { $0.state == "Done" }.count == 1)
        #expect(rows.first?.task == ScreenshotSamples.proposalTask)
        // The row left offering Start is one the AI can do, for the user: what Start is for (spec 4.4).
        let start = rows.first { $0.actions.contains(.start) }
        #expect(start?.aiDoable == true)
        #expect(start?.owner == ScreenshotSamples.userName)
    }

    @Test func noFrameOffersStartOnSomeoneElsesTask() {
        for frame in ScreenshotSamples.panelFrames {
            for row in frame.rows(now: now) where row.actions.contains(.start) {
                #expect(row.aiDoable && row.owner == ScreenshotSamples.userName, "\(row.task)")
            }
        }
    }

    @Test func aFrameDrawsItsRowsAndStatus() throws {
        let reading = try #require(ScreenshotSamples.panelFrames.first { $0.status == .reading })
        #expect(reading.isReading)
        #expect(reading.statusLine == LiveStatus.reading.line)
        let listening = try #require(ScreenshotSamples.panelFrames.last)
        #expect(!listening.isReading)
        #expect(listening.statusLine == LiveStatus.listening.line)
        #expect(listening.rows(now: now) == LiveRows.rows(listening.items, start: .oneClick, pressedAt: [:], now: now))
    }

    @Test func theSampleClockIsFixed() {
        // The committed notes page carries a date, so it comes from a fixed clock and time zone, not the machine's.
        #expect(ScreenshotSamples.notesPageHTML() == ScreenshotSamples.notesPageHTML(now: ScreenshotSamples.now,
                                                                                      timeZone: ScreenshotSamples.timeZone))
        #expect(ScreenshotSamples.timeZone.identifier == "America/New_York")
        #expect(ScreenshotSamples.notesPageHTML().contains("Thu 15 Oct 2026, 14:35"))
    }

    @Test func theGIFFramesFillUpOneByOne() {
        let frames = ScreenshotSamples.panelFrames
        #expect(frames.count == 12)
        #expect(frames.first?.items.isEmpty == true)
        #expect(frames.last?.items == ScreenshotSamples.liveItems)
        #expect(zip(frames, frames.dropFirst()).allSatisfy { $0.items.count <= $1.items.count })
        #expect(zip(frames, frames.dropFirst()).allSatisfy { $0.elapsed < $1.elapsed })
        // Items arrive one at a time.
        #expect(zip(frames, frames.dropFirst()).allSatisfy { $1.items.count - $0.items.count <= 1 })
        // The first to-do's Start turns into Starting, then Running, then Done.
        let first = frames.compactMap { frame in frame.items.first.map { ($0.status, frame.pressed.contains($0.id)) } }
        let path = first.map(\.0).reduce(into: [LiveItem.Status]()) { if $0.last != $1 { $0.append($1) } }
        #expect(path == [.suggested, .queued, .running, .done])
        #expect(first.contains { $0.0 == .queued && $0.1 })
        // The status line shows a pass reading at least once.
        #expect(frames.contains { $0.status == .reading })
    }

    @Test func aPressedStartReadsStartingInItsFrame() throws {
        let frame = try #require(ScreenshotSamples.panelFrames.first { !$0.pressed.isEmpty })
        let rows = frame.rows(now: now)
        #expect(rows.contains { $0.state == "Starting with Claude Code\u{2026}" && $0.actions == [.cancel] })
    }

    @Test func theConfirmDraftHasOneEditedRowAndOneStartedDuringTheCall() {
        let draft = ScreenshotSamples.confirmDraft()
        #expect(draft.rows.count >= 3)
        #expect(draft.rows.filter(\.startedDuringCall).count == 1)
        #expect(draft.rows.filter(\.isEdited).count == 1)
        #expect(draft.rows.first(where: \.startedDuringCall)?.original.liveRef == "L1")
        #expect(draft.canSend)
    }

    @Test func recentMeetingsAreSavedWithTheirStatuses() throws {
        let root = tempDir()
        let store = SessionStore(root: root)
        let written = try ScreenshotSamples.writeRecentMeetings(to: store, now: now)
        let all = store.all()
        #expect(all.count == written.sessions.count)
        #expect(all.count >= 3)
        #expect(all.allSatisfy { !$0.recording && $0.startedAt < now })
        let busy = try #require(written.writingNotes)
        #expect(all.first { $0.id == busy }?.nextStage == .notes)
        let others = all.filter { $0.id != busy }
        #expect(others.allSatisfy { $0.isFinished })
        #expect(all.contains { $0.mode == .notesAndDo && !$0.sent.isEmpty })
        // Running it again (a second render) adds meetings next to the first ones, never over them.
        let again = try ScreenshotSamples.writeRecentMeetings(to: store, now: now)
        #expect(store.all().count == written.sessions.count + again.sessions.count)
    }

    @Test func theEventIsCurrentExternalAndPicksNotesAndDo() {
        let settings = ScreenshotSamples.settings(saveFolder: "/tmp/x", workFolder: "/tmp")
        var tracker = CurrentEventTracker()
        let mode = tracker.observe(ScreenshotSamples.event(now: now), settings: settings, now: now, canPreselect: true)
        #expect(mode == .notesAndDo)
        #expect(tracker.menuLine(now: now) == "Now: \(ScreenshotSamples.meetingTitle) \u{00B7} External")
        #expect(settings.userName == ScreenshotSamples.userName)
        #expect(settings.liveAssistant && settings.useCalendar && settings.claudeCodeTargetOn)
        #expect(settings.permissionMode == "restricted")
    }

    @Test func theNotesPageShowsTheSampleMeeting() {
        let html = ScreenshotSamples.notesPageHTML(now: now)
        #expect(html.contains(ScreenshotSamples.meetingTitle))
        #expect(html.contains("Send Acme the revised proposal"))
        #expect(html.contains(ItemStatus.startedDuringCall))
        #expect(html.contains("prefers-color-scheme: dark"))
    }

    @Test func pinningTheColorSchemeKeepsOneLook() {
        let html = ScreenshotSamples.notesPageHTML(now: now)
        let light = ScreenshotSamples.pinColorScheme(html, dark: false)
        let dark = ScreenshotSamples.pinColorScheme(html, dark: true)
        #expect(!light.contains("prefers-color-scheme"))
        #expect(!dark.contains("prefers-color-scheme"))
        #expect(light.contains("@media not all{"))
        #expect(dark.contains("@media all{"))
        #expect(light.contains(#"<meta name="color-scheme" content="light">"#))
        #expect(dark.contains(#"<meta name="color-scheme" content="dark">"#))
        #expect(light.count < html.count + 20 && dark.count < html.count + 20)
    }

    /// The "settings-local" shot: the local provider with Ollama's address, and a ready status that no server sent.
    @Test func theLocalShotUsesOllamaAndAReadyStatus() {
        let settings = ScreenshotSamples.localSettings(saveFolder: "/tmp/m", workFolder: "/tmp/w")
        #expect(settings.provider == .local)
        #expect(settings.localURL == "http://localhost:11434/v1" && settings.localModel == "qwen3:8b")
        #expect(settings.saveFolder == "/tmp/m" && settings.userName == ScreenshotSamples.userName)
        let status = ScreenshotSamples.localStatus
        #expect(status.state == .ready && status.models == ["gemma3:12b", "gpt-oss:20b", "qwen3:8b"])
        #expect(status.address == settings.localURL && status.model == settings.localModel)
        #expect(status.summary == "Connected to localhost:11434. qwen3:8b is ready.")
    }
}
