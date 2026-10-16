import Foundation

/// Builds what the notes model gets besides the transcript (spec 5, 6, 8 and 9) from what is already on disk. Pure:
/// the pipeline reads the files, this decides. A v1 meeting (no event, flags, brief, screen or live to-dos, and no
/// lessons) gives `NotesContext.empty`, so its prompt is exactly v1's.
public enum NotesContextBuilder {
    /// Seconds of transcript taken either side of a flag (spec 8).
    public static let flagWindow = 30.0
    /// The excerpt a flag gets when nothing was said near it, so the model still covers the moment.
    public static let quietFlag = "(Nothing was said within 30 seconds of this flag.)"

    /// Everything the context is built from.
    public struct Input: Sendable {
        public var session: Session
        /// The merged transcript (transcript.json).
        public var transcript: [Segment]
        /// Speaker names by track, as in transcript.md.
        public var names: [Track: String]
        /// brief.json, only when it decoded completely (`completeBrief(from:)`).
        public var brief: MeetingBrief?
        /// Past meetings related to this one (`MeetingHistory.related`), used for open loops only when there is no
        /// complete brief and the meeting has a calendar event.
        public var history: [MeetingRecord]
        /// Every saved lesson; the context keeps the ones the prompt shows.
        public var lessons: [Lesson]
        public var learnFromEdits: Bool
        public var style: NotesStyle
        /// The company domains the user typed in Settings.
        public var myDomains: String
        /// screen.json's moments.
        public var screen: [ScreenMoment]
        /// live.json's to-dos.
        public var live: [LiveItem]
        public var timeZone: TimeZone

        public init(session: Session, transcript: [Segment] = [], names: [Track: String] = [:],
                    brief: MeetingBrief? = nil, history: [MeetingRecord] = [], lessons: [Lesson] = [],
                    learnFromEdits: Bool = true, style: NotesStyle = .general, myDomains: String = "",
                    screen: [ScreenMoment] = [], live: [LiveItem] = [], timeZone: TimeZone = .current) {
            self.session = session
            self.transcript = transcript
            self.names = names
            self.brief = brief
            self.history = history
            self.lessons = lessons
            self.learnFromEdits = learnFromEdits
            self.style = style
            self.myDomains = myDomains
            self.screen = screen
            self.live = live
            self.timeZone = timeZone
        }
    }

    public static func build(_ input: Input) -> NotesContext {
        let event = input.session.calendarEvent
        let domains = ProfileRules.myDomains(event: event, typed: input.myDomains)
        return NotesContext(
            attendees: ProfileRules.contextAttendees(event: event, myDomains: domains),
            profile: input.session.profile,
            agenda: agenda(event),
            openLoops: openLoops(input),
            lessons: input.learnFromEdits ? LessonsPrompt.pick(input.lessons, style: input.style,
                                                               limit: LessonsPrompt.notesLimit) : [],
            flags: flagExcerpts(input.session.flags, transcript: input.transcript, names: input.names),
            screen: ScreenSelection.excerpts(moments: input.screen, flags: input.session.flags,
                                             segments: input.transcript),
            started: started(input.live))
    }

    /// The event's notes, cleaned; "" when nothing but links and dial-in details is left.
    static func agenda(_ event: CalendarEventInfo?) -> String {
        guard let agenda = event?.agenda, AgendaSanitizer.hasContent(agenda) else { return "" }
        return AgendaSanitizer.clean(agenda)
    }

    /// The brief's loops when there is a complete brief; otherwise, for a meeting with a calendar event, each action
    /// item of the related meetings (spec 5.5), with no Claude call.
    static func openLoops(_ input: Input) -> [OpenLoop] {
        if let brief = input.brief { return brief.openLoops }
        guard input.session.calendarEvent != nil else { return [] }
        return BriefFallback.openLoops(from: input.history, timeZone: input.timeZone)
    }

    /// One excerpt per flag, in time order: the transcript lines that overlap 30 seconds either side of it.
    static func flagExcerpts(_ flags: [Flag], transcript: [Segment], names: [Track: String]) -> [Excerpt] {
        flags.filter { $0.offset.isFinite }.sorted { $0.offset < $1.offset }.prefix(Flag.maxCount).map { flag in
            let near = transcript.filter { $0.end >= flag.offset - flagWindow && $0.start <= flag.offset + flagWindow }
            let text = TranscriptRenderer.markdown(near, names: names).trimmingCharacters(in: .newlines)
            return Excerpt(offset: flag.offset, text: text.isEmpty ? quietFlag : text)
        }
    }

    /// The live to-dos that went out, or may have (sending, running, done, sent, started in the cloud, interrupted).
    static func started(_ live: [LiveItem]) -> [NotesContext.StartedItem] {
        live.filter(\.status.isStarted).map { NotesContext.StartedItem(id: $0.id, task: $0.task) }
    }

    /// brief.json's brief when it decodes completely: a file that doesn't decode, or whose open loops lost an entry
    /// to lenient decoding, is not used, so the notes fall back to the related meetings instead.
    public static func completeBrief(from data: Data) -> MeetingBrief? {
        guard let brief = try? JSONFiles.decoder().decode(MeetingBrief.self, from: data),
              let raw = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        let loops = raw["openLoops"].map { ($0 as? [Any])?.count ?? -1 } ?? 0
        return loops == brief.openLoops.count ? brief : nil
    }
}
