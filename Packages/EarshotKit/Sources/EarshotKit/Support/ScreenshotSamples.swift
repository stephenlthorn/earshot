import Foundation

/// The made-up call the README screenshots show (`Earshot --render-screenshots`, spec 19): Ashley, the Earshot user
/// at Northwind, talks to Dana at Acme. No real people and no private data; addresses use reserved `.example`
/// domains. The app draws its real views with these values, and the notes page comes from `NotesPageRenderer`.
public enum ScreenshotSamples {
    public static let userName = "Ashley"
    public static let meetingTitle = "Acme pilot review"
    public static let proposalTask = "Send Acme the revised proposal by Friday"
    /// The model the sample brief names.
    public static let model = "claude-sonnet-5-5"
    /// The sample's clock, Thu 15 Oct 2026 at 15:20 in New York, so a re-render draws the same dates. The menu still
    /// uses the real time, because its views read the system clock; it shows no dates.
    public static let now = Date(timeIntervalSince1970: 1_792_092_000)
    public static let timeZone = TimeZone(identifier: "America/New_York") ?? TimeZone(secondsFromGMT: -4 * 3600)!

    // MARK: Calendar and settings

    /// The event happening now: started five minutes ago, with Dana from Acme, so its profile is External.
    public static func event(now: Date) -> CalendarEventInfo {
        CalendarEventInfo(id: "sample-acme-pilot", title: meetingTitle, start: now.addingTimeInterval(-300),
                          end: now.addingTimeInterval(1_500),
                          attendees: [Attendee(name: "Ashley Park", email: "ashley@northwind.example", isMe: true),
                                      Attendee(name: "Dana Reyes", email: "dana@acme.example")],
                          agenda: "Walk through the pilot proposal and pricing.")
    }

    /// Settings as a user who turned the v2 features on would have them. Never saved.
    public static func settings(saveFolder: String, workFolder: String) -> EarshotSettings {
        var settings = EarshotSettings()
        settings.saveFolder = saveFolder
        settings.defaultMode = .notesAndDo
        settings.userName = userName
        settings.claudePath = "/opt/homebrew/bin/claude"
        settings.claudeCodeTargetOn = true
        settings.claudeCodeFolder = workFolder
        settings.permissionMode = "restricted"
        settings.liveAssistant = true
        settings.useCalendar = true
        settings.myDomains = "northwind.example"
        settings.onboardedVersion = WelcomeSheet.currentVersion
        return settings
    }

    /// The same settings with notes written by a local model through Ollama, for the "settings-local" shot.
    public static func localSettings(saveFolder: String, workFolder: String) -> EarshotSettings {
        var settings = settings(saveFolder: saveFolder, workFolder: workFolder)
        settings.provider = .local
        settings.localURL = "http://localhost:11434/v1"
        settings.localModel = "qwen3:8b"
        return settings
    }

    /// The status Settings shows for `localSettings`. Made up here: the renderer never contacts a server.
    public static let localStatus = LocalModelStatus(state: .ready, address: "http://localhost:11434/v1",
                                                     model: "qwen3:8b", models: ["gemma3:12b", "gpt-oss:20b", "qwen3:8b"],
                                                     problem: nil)

    // MARK: The live panel

    public static let brief = MeetingBrief(
        eventID: "sample-acme-pilot", model: model, createdAt: Date(timeIntervalSince1970: 1_792_000_000),
        headline: "Second call with Acme: the pilot proposal",
        points: ["Dana's team tracks every job in spreadsheets today", "Last time Dana asked about pricing for 20 seats"],
        openLoops: [OpenLoop(owner: userName, task: "Share the case study", from: "Acme intro call, 5 Oct")])

    static let proposal = LiveItem(id: "L1", task: proposalTask, owner: userName, aiDoable: true,
                                   why: "Dana asked for it in writing", firstSeen: 400)
    /// The open loop from the brief, raised again in the call: the to-do left offering Start.
    static let caseStudy = LiveItem(id: "L2", task: "Share the depot case study with Dana", owner: userName,
                                    aiDoable: true, why: "Dana asked for it again", firstSeen: 520)
    static let pricing = LiveItem(id: "L3", task: "Compare our pricing tiers with Acme's current tool", owner: userName,
                                  due: "Thursday", aiDoable: true, why: "Dana asked how we compare", firstSeen: 610)

    /// The finished panel: one Done, one still offering Start, one Running. Every one is the user's and AI-doable,
    /// because the panel offers Start only on AI-doable to-dos (spec 4).
    public static let liveItems = [with(proposal, .done), caseStudy, with(pricing, .running)]

    /// One picture of the panel for the animated GIF.
    public struct PanelFrame: Equatable, Sendable {
        public var elapsed: TimeInterval
        public var items: [LiveItem]
        /// Items whose Start was pressed a moment ago, so they read "Starting with Claude Code…" with Cancel.
        public var pressed: [String]
        public var status: LiveStatus
        public var tickerThem: String
        public var tickerMe: String

        /// The panel's rows, as the live target "Claude Code, restricted" draws them; a pressed Start reads
        /// "Starting with Claude Code…" with Cancel.
        public func rows(now: Date) -> [LiveRow] {
            let pressedAt = Dictionary(uniqueKeysWithValues: pressed.map { ($0, now) })
            return LiveRows.rows(items, start: .oneClick, pressedAt: pressedAt, now: now)
        }

        public var statusLine: String { status.line }
        public var isReading: Bool { status == .reading }
    }

    /// Twelve frames of the panel filling up: to-dos arrive one by one, and a Start turns into Running, then Done.
    public static let panelFrames: [PanelFrame] = [
        frame(372, [], .listening, "so the pilot would cover the two depots", "makes sense, that keeps it small"),
        frame(395, [], .reading, "and we'd want the numbers in writing", "sure, I can put that together"),
        frame(418, [proposal], .listening, "could you send that over by Friday", "yes, the revised proposal by Friday"),
        frame(426, [with(proposal, .queued)], .listening, "great, that works for us", "I'll get it started now",
              pressed: ["L1"]),
        frame(441, [with(proposal, .running)], .listening, "the budget question is with finance", "who should I talk to"),
        frame(530, [with(proposal, .running), caseStudy], .listening, "did you have that depot case study",
              "yes, I'll share it with you"),
        frame(562, [with(proposal, .done), caseStudy], .listening, "how do you compare on price", "good question"),
        frame(590, [with(proposal, .done), caseStudy], .reading, "we pay per seat with our current tool",
              "let me look at that"),
        frame(618, [with(proposal, .done), caseStudy, pricing], .listening, "a side by side would help",
              "I'll send one by Thursday"),
        frame(624, [with(proposal, .done), caseStudy, with(pricing, .queued)], .listening, "that would be great",
              "starting on it now", pressed: ["L3"]),
        frame(640, liveItems, .listening, "anything else from your side", "I think that covers it"),
        frame(655, liveItems, .listening, "thanks Ashley, talk Friday", "thanks Dana, speak soon"),
    ]

    static func frame(_ elapsed: TimeInterval, _ items: [LiveItem], _ status: LiveStatus, _ them: String,
                      _ me: String, pressed: [String] = []) -> PanelFrame {
        PanelFrame(elapsed: elapsed, items: items, pressed: pressed, status: status, tickerThem: them, tickerMe: me)
    }

    static func with(_ item: LiveItem, _ status: LiveItem.Status) -> LiveItem {
        var copy = item
        copy.status = status
        copy.target = status == .suggested ? nil : "claude-code"
        return copy
    }

    // MARK: Notes and the confirm window

    public static let notes = MeetingNotes(
        title: meetingTitle,
        summary: "Dana is ready to run a four-week pilot at two depots once the revised proposal arrives. Pricing is "
            + "the open question, and Acme's finance lead signs off on budget.",
        attendees: ["Ashley", "Dana"],
        keyPoints: ["Acme tracks every job in spreadsheets today", "The pilot covers two depots for four weeks",
                    "Acme pays per seat for its current tool"],
        decisions: ["Run the pilot at two depots", "Start the week after the proposal is signed"],
        actionItems: [
            ActionItem(task: "Send Acme the revised proposal", owner: userName, due: "Friday", doer: .ai,
                       context: "Dana asked for it in writing.", liveRef: "L1"),
            ActionItem(task: "Draft a summary of the pilot terms", owner: userName, due: nil, doer: .ai,
                       context: "Dana will share it with the depot managers."),
            ActionItem(task: "Compare our pricing tiers with Acme's current tool", owner: userName, due: "Thursday",
                       doer: .ai, context: "Dana asked how we compare."),
            ActionItem(task: "Book a call with Acme's finance lead", owner: "Dana", due: nil, doer: .someoneElse),
        ],
        openQuestions: ["Does the pilot price carry over to the full rollout?"],
        flaggedMoments: [FlaggedMoment(seconds: 431, note: "Dana: the proposal needs the depot numbers")],
        stillOpen: ["Ashley: share the case study (from Acme intro call, 5 Oct)"])

    /// What live.json held at the end of the call, as far as the confirm window cares: the proposal went out.
    public static let confirmLive = [with(proposal, .done)]

    /// The confirm window's checklist with the proposal locked ("Started during the call") and one row edited.
    public static func confirmDraft() -> ConfirmDraft {
        var draft = ConfirmDraft(notes: notes, live: confirmLive)
        if let index = draft.rows.firstIndex(where: { $0.original.task.hasPrefix("Draft a summary") }) {
            draft.rows[index].task = "Draft a one-page summary of the pilot terms for Dana"
            draft.rows[index].due = "Wednesday"
        }
        return draft
    }

    // MARK: The menu's recent meetings

    struct Recent {
        var title: String
        var mode: Mode
        var hoursAgo: Double
        var minutes: Double
        var sent: [String] = []
        var writingNotes = false
    }

    static let recent = [
        Recent(title: "Proposal prep with Dana", mode: .notes, hoursAgo: 0.6, minutes: 22, writingNotes: true),
        Recent(title: "Weekly team sync", mode: .notes, hoursAgo: 22, minutes: 31),
        Recent(title: "Acme intro call", mode: .notesAndDo, hoursAgo: 240, minutes: 38, sent: ["claude-code"]),
        Recent(title: "Pricing walkthrough", mode: .record, hoursAgo: 290, minutes: 17),
    ]

    /// Saves the menu's recent meetings in `store` (a scratch folder, never the user's). Returns them, and the id of
    /// the one still writing its notes.
    public static func writeRecentMeetings(to store: SessionStore, now: Date) throws
        -> (sessions: [Session], writingNotes: String?) {
        var sessions: [Session] = []
        var busy: String?
        for meeting in recent {
            let start = now.addingTimeInterval(-meeting.hoursAgo * 3600)
            var session = try store.create(mode: meeting.mode, title: meeting.title, now: start)
            session.recording = false
            session.endedAt = start.addingTimeInterval(meeting.minutes * 60).wholeSeconds
            for stage in meeting.mode.stages {
                let pending = meeting.writingNotes && stage != .transcribe
                session.stages[stage] = StageState(status: pending ? .pending : .done)
            }
            session.sent = meeting.sent
            try store.save(session)
            if meeting.writingNotes { busy = session.id }
            sessions.append(session)
        }
        return (sessions, busy)
    }

    // MARK: The notes page

    public static let transcript = [
        Segment(track: .them, start: 372, end: 380, text: "So the pilot would cover the two depots."),
        Segment(track: .me, start: 381, end: 385, text: "Makes sense, that keeps it small."),
        Segment(track: .them, start: 410, end: 418, text: "Could you send the revised proposal over by Friday?"),
        Segment(track: .me, start: 419, end: 424, text: "Yes, the revised proposal by Friday."),
        Segment(track: .them, start: 431, end: 440, text: "It needs the depot numbers, or finance will send it back."),
        Segment(track: .them, start: 562, end: 566, text: "How do you compare on price?"),
        Segment(track: .me, start: 600, end: 607, text: "I'll send a side by side by Thursday."),
    ]

    /// `notes.html` for the sample meeting, as the pipeline would write it.
    public static func notesPageHTML(now: Date = ScreenshotSamples.now,
                                     timeZone: TimeZone = ScreenshotSamples.timeZone) -> String {
        let start = now.addingTimeInterval(-2_700).wholeSeconds
        var session = Session(id: "sample-acme-pilot", folderName: meetingTitle, title: meetingTitle, mode: .notesAndDo,
                              startedAt: start, endedAt: start.addingTimeInterval(2_460), recording: false, tracks: [],
                              stages: [:], sent: ["claude-code"], warnings: [])
        session.profile = .external
        session.calendarEvent = event(now: now)
        session.flags = [Flag(offset: 431, source: .hotkey)]
        let items = Array(notes.actionItems.dropFirst().prefix(2))
        let statuses = ItemStatus.compute(notes: notes, items: items, sent: session.sent, live: confirmLive)
        let input = NotesPageInput(notes: notes, session: session, transcript: transcript,
                                   names: [.me: userName, .them: "Dana"], brief: brief, liveItems: confirmLive,
                                   statuses: statuses, timeZone: timeZone)
        return NotesPageRenderer.html(input)
    }

    /// The page with one color scheme pinned, so a headless browser draws it light or dark whatever its own setting.
    public static func pinColorScheme(_ html: String, dark: Bool) -> String {
        html.replacingOccurrences(of: "@media (prefers-color-scheme: dark){", with: dark ? "@media all{" : "@media not all{")
            .replacingOccurrences(of: #"<meta name="color-scheme" content="light dark">"#,
                                  with: #"<meta name="color-scheme" content="\#(dark ? "dark" : "light")">"#)
    }
}
