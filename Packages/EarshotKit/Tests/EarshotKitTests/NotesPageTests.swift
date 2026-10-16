import Foundation
import Testing
@testable import EarshotKit

struct NotesPageTests {
    private static func session(flags: [Flag] = [], runs: [String: String] = [:], profile: MeetingProfile? = nil,
                                mode: Mode = .notesAndDo) -> Session {
        var session = Session(id: "20261014-153000", folderName: "2026-10-14 1530 Acme kickoff", title: "Acme kickoff",
                              mode: mode, startedAt: at1530, endedAt: at1530.addingTimeInterval(2400), recording: false,
                              tracks: [], stages: [:], sent: [], warnings: [])
        session.flags = flags
        session.routineRuns = runs
        session.profile = profile
        return session
    }

    private static let transcript = [
        Segment(track: .me, start: 1, end: 4, text: "Dana, I'll send the scope by Friday."),
        Segment(track: .them, start: 62, end: 66, text: "Great. Look at this slide with the pricing."),
        Segment(track: .me, start: 62.4, end: 63, text: "Got it."),
        Segment(track: .them, start: 754, end: 760, text: "The budget is approved."),
    ]

    private static func input(notes: MeetingNotes = sampleNotes, session: Session = session(),
                              transcript: [Segment] = transcript, brief: MeetingBrief? = nil, live: [LiveItem] = [],
                              screen: [ScreenMoment] = [], statuses: [String]? = nil) -> NotesPageInput {
        NotesPageInput(notes: notes, session: session, transcript: transcript, names: [.me: "Stephen"], brief: brief,
                       liveItems: live, screenMoments: screen,
                       statuses: statuses ?? ItemStatus.compute(notes: notes, items: nil, sent: [], live: live),
                       timeZone: newYork)
    }

    /// Every href in the page.
    private static func links(_ html: String) -> [String] {
        let regex = try! NSRegularExpression(pattern: #"href="([^"]*)""#)
        return regex.matches(in: html, range: NSRange(html.startIndex..., in: html)).map {
            String(html[Range($0.range(at: 1), in: html)!])
        }
    }

    /// Byte search. `String.contains` compares whole grapheme clusters, so it would miss a "<" joined to the
    /// character before it, which is exactly what a browser still parses as a tag.
    private static func rawContains(_ text: String, _ needle: String) -> Bool {
        let hay = Array(text.utf8), pin = Array(needle.utf8)
        guard !pin.isEmpty, pin.count <= hay.count else { return false }
        return (0...(hay.count - pin.count)).contains { hay[$0..<($0 + pin.count)].elementsEqual(pin) }
    }

    @Test func everyTextIsEscaped() {
        let hostile = "<script>alert(1)</script> & \"quoted\" 'single' <img src=x onerror=alert(2)>"
        var notes = sampleNotes
        notes.title = hostile
        notes.summary = hostile
        notes.decisions = [hostile]
        notes.keyPoints = [hostile]
        notes.openQuestions = [hostile]
        notes.stillOpen = [hostile]
        notes.attendees = [hostile]
        notes.flaggedMoments = [FlaggedMoment(seconds: 62, note: hostile)]
        notes.actionItems = [ActionItem(task: hostile, owner: hostile, due: hostile, doer: .ai, context: hostile)]
        let brief = MeetingBrief(eventID: nil, model: "m", createdAt: at1530, headline: hostile, points: [hostile],
                                 openLoops: [], sources: [])
        let html = NotesPageRenderer.html(Self.input(
            notes: notes, transcript: [Segment(track: .them, start: 5, end: 6, text: hostile)], brief: brief,
            screen: [ScreenMoment(offset: 10, text: hostile)], statuses: [hostile]))
        #expect(!html.contains("<script"))
        #expect(!html.contains("<img"))
        #expect(!html.contains("onerror=alert(2)>"))
        #expect(html.contains("&lt;script&gt;alert(1)&lt;/script&gt; &amp; &quot;quoted&quot; &#39;single&#39;"))
        #expect(html.contains("<title>&lt;script&gt;"))
    }

    @Test func escapeCoversTheFiveCharacters() {
        #expect(NotesPageRenderer.escape(#"a<b>c&d"e'f"#) == "a&lt;b&gt;c&amp;d&quot;e&#39;f")
    }

    /// U+0600 is a Prepend character, so it joins the next character into one grapheme cluster ("\u{0600}<").
    @Test func escapeWorksPerScalarNotPerGraphemeCluster() {
        let escaped = NotesPageRenderer.escape("\u{0600}<b>\u{0600}\"x\u{0600}&\u{0600}'")
        for raw in ["<", ">", "\"", "'"] { #expect(!Self.rawContains(escaped, raw), "\(raw)") }
        #expect(escaped.unicodeScalars.filter { $0 == "&" }.count == 5)
        #expect(escaped == "\u{0600}&lt;b&gt;\u{0600}&quot;x\u{0600}&amp;\u{0600}&#39;")
    }

    @Test func joinedCharactersCannotSmuggleMarkupIntoThePage() {
        let hostile = "\u{0600}<a href=https://e.test>x"
        var notes = sampleNotes
        notes.attendees = []
        notes.summary = hostile
        var session = Self.session()
        session.calendarEvent = CalendarEventInfo(id: "e1", title: hostile, start: at1530, end: at1530,
                                                  attendees: [Attendee(name: hostile)])
        let html = NotesPageRenderer.html(Self.input(notes: notes, session: session,
                                                     transcript: [Segment(track: .them, start: 5, end: 6, text: hostile)],
                                                     screen: [ScreenMoment(offset: 10, text: hostile)]))
        #expect(!Self.rawContains(html, "<a href=https://e.test") && !Self.rawContains(html, "e.test>"))
        #expect(html.contains("With \u{0600}&lt;a href=https://e.test&gt;x"))
    }

    @Test func thePageHasNoScriptsNoRemoteResourcesAndBothThemes() {
        let html = NotesPageRenderer.html(Self.input())
        let lower = html.lowercased()
        for banned in ["<script", "javascript:", "<iframe", "<object", "<embed", "<link", "@import", "url(", "src=",
                       "http://", "on" + "click"] {
            #expect(!lower.contains(banned), "\(banned)")
        }
        #expect(html.hasPrefix("<!doctype html>"))
        #expect(html.contains("prefers-color-scheme: dark"))
        #expect(html.contains("@media print"))
        #expect(html.contains("Content-Security-Policy"))
        #expect(html.contains("default-src 'none'"))
        #expect(!html.contains("\u{2014}"))
    }

    @Test func theHeaderShowsTitleDateLengthAttendeesProfileAndMode() {
        let html = NotesPageRenderer.html(Self.input(session: Self.session(profile: .external)))
        #expect(html.contains("<h1>Acme kickoff</h1>"))
        #expect(html.contains("Wed 14 Oct 2026, 15:30"))
        #expect(html.contains("40 min"))
        #expect(html.contains("Stephen, Dana"))
        #expect(html.contains("External"))
        #expect(html.contains("Notes + Do"))
        let none = NotesPageRenderer.html(Self.input(session: Self.session(profile: .noEvent, mode: .notes)))
        #expect(!none.contains("External") && !none.contains("Internal") && none.contains(">Notes<"))
    }

    @Test func sectionsAppearOnlyWhenTheyHaveContent() {
        var notes = sampleNotes
        notes.stillOpen = ["Dana: send the logs (from Acme intro)"]
        notes.flaggedMoments = [FlaggedMoment(seconds: 754, note: "Budget approved.")]
        let brief = MeetingBrief(eventID: "e1", model: "m", createdAt: at1530, headline: "Pilot scope is the open item",
                                 points: ["Dana owes logs"], openLoops: [], sources: [])
        let full = NotesPageRenderer.html(Self.input(notes: notes, brief: brief,
                                                     screen: [ScreenMoment(offset: 63, text: "Pricing: $40k")]))
        for heading in ["Summary", "Before the call", "Still open from before", "Decisions", "Action items",
                        "Flagged moments", "Key points", "Open questions", "Timeline", "Full transcript"] {
            #expect(full.contains(">\(heading)<"), "\(heading)")
        }
        let bare = NotesPageRenderer.html(Self.input(notes: MeetingNotes.noSpeech, transcript: [], statuses: []))
        #expect(bare.contains(">Summary<"))
        for heading in ["Before the call", "Still open from before", "Decisions", "Action items", "Flagged moments",
                        "Key points", "Open questions", "Timeline", "Full transcript"] {
            #expect(!bare.contains(">\(heading)<"), "\(heading)")
        }
    }

    @Test func actionItemsShowOwnerTaskDueTheAIBadgeAndStatus() {
        let html = NotesPageRenderer.html(Self.input(statuses: ["Sent to Webhook", ItemStatus.notSent]))
        #expect(html.contains("Draft the pilot scope email to Dana"))
        #expect(html.contains("Friday"))
        #expect(html.components(separatedBy: "class=\"badge ai\"").count == 2)
        #expect(html.contains("Sent to Webhook") && html.contains(">Not sent<"))
        let missing = NotesPageRenderer.html(Self.input(statuses: []))
        #expect(missing.contains("Call the venue"))
    }

    @Test func transcriptLinesAreAnchoredBySecondAndRepeatsStayUnique() {
        let html = NotesPageRenderer.html(Self.input())
        #expect(html.contains("id=\"t-1\"") && html.contains("id=\"t-62\"") && html.contains("id=\"t-754\""))
        #expect(html.contains("id=\"t-62-2\""))
        #expect(html.contains("<details"))
        #expect(html.contains("Stephen") && html.contains("Them"))
    }

    @Test func flaggedMomentsShowMinutesAndSecondsAndLinkToTheLine() {
        var notes = sampleNotes
        notes.flaggedMoments = [FlaggedMoment(seconds: 760, note: "Budget approved."),
                                FlaggedMoment(seconds: 1e30, note: "Far away.")]
        let html = NotesPageRenderer.html(Self.input(notes: notes, session: Self.session(flags: [Flag(offset: 755, source: .hotkey)])))
        #expect(html.contains("href=\"#t-754\""))
        #expect(html.contains("12:40"))
        #expect(html.contains("Budget approved."))
        #expect(html.contains("5999:59"))
    }

    @Test func theTimelineHasMinuteMarkersTurnsFlagsAndScreenMoments() {
        let html = NotesPageRenderer.html(Self.input(session: Self.session(flags: [Flag(offset: 755, source: .voice)]),
                                                     screen: [ScreenMoment(offset: 63, text: "Pricing: $40k")]))
        #expect(html.contains(">00:00<") && html.contains(">01:00<") && html.contains(">12:00<"))
        #expect(!html.contains(">02:00<"))
        #expect(html.contains("Pricing: $40k"))
        #expect(html.contains(">Flagged<"))
    }

    @Test func theOnlyLinksAreHttpsRunsRelativeFilesAndAnchors() {
        let runs = ["m1": "https://claude.ai/code/session_01", "m2": "javascript:alert(1)", "m3": "http://plain.test",
                    "m4": "file:///etc/passwd", "m5": "//evil.test/x", "m6": "https://"]
        var notes = sampleNotes
        notes.actionItems[0].liveRef = "L1"
        let live = [
            LiveItem(id: "L1", task: "Draft the pilot scope email to Dana", owner: "Stephen", aiDoable: true,
                     firstSeen: 10, updated: 20, status: .startedInCloud, link: "https://claude.ai/code/session_02"),
            LiveItem(id: "L2", task: "Call the venue", owner: "Stephen", aiDoable: false, firstSeen: 10, updated: 20,
                     status: .running, link: "data:text/html,hi"),
        ]
        let screen = [ScreenMoment(offset: 63, text: "Slide one", image: "0063.png"),
                      ScreenMoment(offset: 90, text: "Slide two", image: "../../secret.png"),
                      ScreenMoment(offset: 120, text: "Slide three", image: "/Users/x/a.png"),
                      ScreenMoment(offset: 150, text: "Slide four", image: "https://evil.test/a.png")]
        let html = NotesPageRenderer.html(Self.input(notes: notes, session: Self.session(runs: runs), live: live,
                                                     screen: screen))
        let links = Self.links(html)
        #expect(links.contains("https://claude.ai/code/session_01"))
        #expect(links.contains("https://claude.ai/code/session_02"))
        #expect(links.contains("screen/0063.png"))
        #expect(links.contains("notes.md") && links.contains("transcript.md"))
        for link in links {
            let allowed = link.hasPrefix("#t-") || link.hasPrefix("https://claude.ai/")
                || ["notes.md", "transcript.md", "screen/0063.png"].contains(link)
            #expect(allowed, "\(link)")
        }
        #expect(!html.contains("evil.test") && !html.contains("secret.png") && !html.contains("data:text"))
    }

    @Test func linkRulesAcceptOnlyHttpsWithAHostAndPlainRelativePaths() {
        #expect(NotesPageRenderer.httpsLink("https://claude.ai/code/x?y=1") == "https://claude.ai/code/x?y=1")
        for bad in ["http://a.test", "javascript:alert(1)", "HTTPS://", "//a.test", "https://a.test/\"onmouseover",
                    "https://a b.test", "ftp://a.test"] {
            #expect(NotesPageRenderer.httpsLink(bad) == nil, "\(bad)")
        }
        #expect(NotesPageRenderer.relativeLink("screen/00 63.png") == "screen/00%2063.png")
        for bad in ["../x.png", "screen/../../x", "/abs.png", "a:b.png", "screen\\x.png", "", "x?y", "x#y", "~/x"] {
            #expect(NotesPageRenderer.relativeLink(bad) == nil, "\(bad)")
        }
    }

    @Test func screenshotsLinkIntoTheScreenFolderByFileNameOnly() {
        let names = ["0063.png", "nested/0090.png", "..", ".", "../x.png", "a/../b.png", "", "x\\y.png", "0120 b.png"]
        let screen = names.enumerated().map { ScreenMoment(offset: Double(60 + $0.offset), text: "Slide", image: $0.element) }
        let links = Self.links(NotesPageRenderer.html(Self.input(screen: screen)))
        let shots = links.filter { !$0.hasPrefix("#") && $0 != "notes.md" && $0 != "transcript.md" }
        #expect(shots == ["screen/0063.png", "screen/0120%20b.png"])
        #expect(!links.contains("0063.png"))
    }

    /// The transcript starts open, so `#t-` links from flagged moments and the timeline land in every browser,
    /// including ones that don't open a closed `<details>` on fragment navigation (Safari before 26.2).
    @Test func theTranscriptStartsOpenSoTimeLinksLandEverywhere() {
        let html = NotesPageRenderer.html(Self.input())
        #expect(html.contains("<details open>"))
        #expect(!html.contains("<details>"))
    }

    @Test func noTranscriptMeansNoTranscriptLink() {
        let html = NotesPageRenderer.html(Self.input(transcript: []))
        #expect(Self.links(html).contains("notes.md"))
        #expect(!Self.links(html).contains("transcript.md"))
    }

    @Test func everyV1MeetingWithNotesRendersAPage() throws {
        let store = try V1Fixtures.store()
        for title in ["Acme kickoff", "Globex pricing review", "Brain dump onboarding ideas", "Initech onboarding"] {
            let session = try V1Fixtures.session(store, title)
            let notes = try store.read(MeetingNotes.self, session, MeetingFile.notes)
            let segments = try store.read([Segment].self, session, MeetingFile.transcript)
            let items = try store.readIfPresent([ActionItem].self, session, MeetingFile.items)
            let statuses = ItemStatus.compute(notes: notes, items: items, sent: session.sent, live: [])
            let html = NotesPageRenderer.html(NotesPageInput(notes: notes, session: session, transcript: segments,
                                                             statuses: statuses, timeZone: newYork))
            #expect(html.contains("<h1>\(NotesPageRenderer.escape(notes.title))</h1>"), "\(title)")
            #expect(!html.lowercased().contains("<script"))
            if title == "Globex pricing review" { #expect(html.contains("Sent to Webhook")) }
        }
    }
}
