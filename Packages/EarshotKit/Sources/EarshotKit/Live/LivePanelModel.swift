import Foundation

/// One live to-do as the panel draws it (spec 4.4 and 4.5): its words, the state line and the buttons it offers.
public struct LiveRow: Equatable, Sendable, Identifiable {
    public enum Tone: Equatable, Sendable {
        case plain, working, good, bad, muted
    }

    public enum Action: Equatable, Sendable {
        case start
        /// No live target works; the value says why, for the button's help text.
        case setUp(String)
        case cancel
        /// Open what a finished Claude Code or command run left behind.
        case open
        /// The routine's run page (always https).
        case openRun(String)
        case dismiss
    }

    public var id: String
    public var task: String
    public var owner: String
    public var due: String?
    public var aiDoable: Bool
    /// "Running", "Failed: timed out" and so on; nil for a suggestion.
    public var state: String?
    public var tone: Tone
    public var actions: [Action]

    public init(id: String, task: String, owner: String, due: String? = nil, aiDoable: Bool, state: String? = nil,
                tone: Tone = .plain, actions: [Action] = []) {
        self.id = id
        self.task = task
        self.owner = owner
        self.due = due
        self.aiDoable = aiDoable
        self.state = state
        self.tone = tone
        self.actions = actions
    }
}

/// Turns live.json's items into the panel's rows.
public enum LiveRows {
    public static let setUpLabel = LiveStartPolicy.setUpTarget
    public static let allowStartLabel = "Allow Start in Settings"

    /// The words on the button shown in place of Start: a routine that is set up but not allowed says what to turn
    /// on; anything else says to set up a target. `reason` is the `.unavailable` reason.
    public static func setUpButton(for reason: String) -> String {
        reason == LiveStartPolicy.routineNotAllowed ? allowStartLabel : setUpLabel
    }

    /// - Parameters:
    ///   - start: the live target's decision, or nil when Start isn't offered (the meeting isn't Notes + Do).
    ///   - pressedAt: when Start was pressed, per item, for the "Starting… Cancel" window.
    /// Dismissed items are hidden; the rest keep the order they were found in.
    public static func rows(_ items: [LiveItem], start: LiveStartPolicy.Decision?, pressedAt: [String: Date],
                            now: Date, window: Duration = LiveStartPolicy.cancelWindow) -> [LiveRow] {
        let seconds = Double(window.components.seconds) + Double(window.components.attoseconds) / 1e18
        return items.filter { $0.status != .dismissed }
            .sorted { ($0.firstSeen, number($0.id)) < ($1.firstSeen, number($1.id)) }
            .map { item in
                let inWindow = pressedAt[item.id].map { now.timeIntervalSince($0) < seconds } ?? false
                let (state, tone, actions) = describe(item, start: start, inWindow: inWindow)
                return LiveRow(id: item.id, task: item.task, owner: item.owner, due: item.due,
                               aiDoable: item.aiDoable, state: state, tone: tone, actions: actions)
            }
    }

    private static func describe(_ item: LiveItem, start: LiveStartPolicy.Decision?, inWindow: Bool)
        -> (String?, LiveRow.Tone, [LiveRow.Action]) {
        switch item.status {
        case .suggested: (nil, .plain, startActions(start, for: item) + [.dismiss])
        case .queued: (inWindow ? starting(item.target) : "Queued", .working, [.cancel])
        case .sending: ("Sending\u{2026}", .working, [])
        case .running: ("Running", .working, [])
        case .done: ("Done", .good, [.open])
        case .sent: ("Sent", .good, [])
        case .startedInCloud: ("Started in the cloud", .good, runLink(item.link).map { [.openRun($0)] } ?? [])
        case .failed:
            (item.detail.map { $0.isEmpty ? "Failed" : "Failed: \($0)" } ?? "Failed", .bad,
             startActions(start, for: item) + [.dismiss])
        case .interrupted: ("Interrupted", .muted, [])
        case .dismissed: (nil, .muted, [])
        }
    }

    /// The cancel window's state line. It names the target, because Start may use another one while the chosen
    /// target is off (`LiveTargetChoice`).
    public static func starting(_ target: String?) -> String {
        guard let target, !target.isEmpty else { return "Starting\u{2026}" }
        return "Starting with \(ItemStatus.targetLabel(target))\u{2026}"
    }

    /// Start is offered only on to-dos the model marked AI-doable (spec 4); a failed one keeps Start, for a retry.
    public static func offersStart(_ item: LiveItem) -> Bool {
        item.aiDoable
    }

    private static func startActions(_ start: LiveStartPolicy.Decision?, for item: LiveItem) -> [LiveRow.Action] {
        guard offersStart(item) else { return [] }
        return switch start {
        case nil: []
        case .oneClick?, .confirmSheet?: [.start]
        case let .unavailable(reason)?: [.setUp(reason)]
        }
    }

    private static func runLink(_ link: String?) -> String? {
        guard let link, let url = URL(string: link), url.scheme == "https", url.host() != nil else { return nil }
        return link
    }

    private static func number(_ id: String) -> Int {
        Int(id.drop { !$0.isNumber }) ?? Int.max
    }
}

/// Fixed panel and Settings wording.
public enum LivePanelText {
    public static let flagCombo = "\u{2303}\u{2325}\u{2318}F"
    public static let sharingCombo = "\u{2303}\u{2325}\u{2318}H"
    public static let hidingNote = "Earshot tries to hide this panel from screen sharing."
    /// The panel's problem line when live.json can't be written.
    public static let couldNotSave = "Couldn't save the live to-dos"

    /// The quit warning's text. A meeting's Do run waits for Retry; a live to-do that is cut off is marked
    /// Interrupted and never sent again on its own (spec 4.4).
    /// - Parameters:
    ///   - meeting: the targets still working on meetings' Do items.
    ///   - live: the targets still working on live to-dos.
    ///   - liveItems: how many live to-dos they are working on.
    public static func quitWarning(meeting: [String], live: [String], liveItems: Int) -> String {
        let join = { (labels: [String]) in ListFormatter.localizedString(byJoining: labels) }
        let verb = { (labels: [String]) in labels.count == 1 ? "is" : "are" }
        let todo = liveItems > 1 ? "live to-dos" : "a live to-do"
        let marked = liveItems > 1 ? "those live to-dos are marked Interrupted" : "the live to-do is marked Interrupted"
        if live.isEmpty {
            return "\(join(meeting)) \(verb(meeting)) still working on this meeting's items. Quitting stops "
                + "\(meeting.count == 1 ? "it" : "them"), and the meeting waits for you to press Retry."
        }
        if meeting.isEmpty {
            return "\(join(live)) \(verb(live)) still working on \(todo). Quitting stops "
                + "\(live.count == 1 ? "it" : "them"), and \(marked)."
        }
        return "\(join(meeting)) \(verb(meeting)) still working on this meeting's items, and \(join(live)) on \(todo). "
            + "Quitting stops them. The meeting waits for you to press Retry, and \(marked)."
    }

    /// "Flagged at 12:31", on the meeting clock.
    public static func flagged(at offset: Double) -> String {
        "Flagged at \(NotesRenderer.clock(offset))"
    }

    /// For Settings (spec 16): "Earshot couldn't register ⌃⌥⌘F".
    public static func couldNotRegister(_ combo: String) -> String {
        "Earshot couldn't register \(combo)"
    }
}

/// What the Start sheet shows: exactly what the target will get (spec 4.4).
public enum LiveStartSheet {
    public static func title(for target: any DoTarget) -> String {
        "Send to \(target.label)?"
    }

    /// Claude Code gets the prompt text; a command gets the payload JSON on standard input; anything else is shown
    /// as the JSON it is sent.
    public static func text(_ payload: DoPayload, target: any DoTarget) -> String {
        let json = (try? payload.encoded()).map { String(decoding: $0, as: UTF8.self) } ?? ""
        switch target {
        case let claude as ClaudeCodeTarget:
            return DoPrompt.text(payload, userName: claude.userName)
        case let command as CommandTarget:
            return "Earshot runs this command:\n\(command.command)\n\nIt gets this JSON on standard input:\n\(json)"
        default:
            return json
        }
    }
}

/// What the live pass knows about the meeting besides the transcript (spec 4.3).
public enum LiveContext {
    /// - Parameter session: the latest copy of session.json, so flags saved during the call are included.
    public static func meeting(session: Session, settings: EarshotSettings, lessons: [Lesson]) -> LivePrompt.Meeting {
        let event = session.calendarEvent
        let title = CurrentEvent.meetingTitle(typed: session.title, event: event) ?? ""
        let attendees = (event?.others ?? []).map(\.displayName).filter { !$0.isEmpty }
        return LivePrompt.Meeting(title: title, userName: settings.userName, attendees: attendees, flags: session.flags,
                                  lessons: settings.learnFromEdits ? lessons : [],
                                  style: ProfileRules.style(session: session, settings: settings))
    }
}

/// Saving flags (spec 8 and 14.3).
public enum LiveFlags {
    /// Saves a flag through `SessionStore.update` when `FlagRules.shouldAdd` allows it, keeping the flags in time
    /// order. Returns the flag saved, or nil for a repeat within 10 s or past the cap.
    @discardableResult
    public static func add(at offset: Double, source: FlagSource, store: SessionStore, id: String) throws -> Flag? {
        var added: Flag?
        try store.update(id) { session in
            guard FlagRules.shouldAdd(at: offset, existing: session.flags) else { return }
            let flag = Flag(offset: offset, source: source)
            let index = session.flags.firstIndex { $0.offset > offset } ?? session.flags.count
            session.flags.insert(flag, at: index)
            added = flag
        }
        return added
    }

    /// Saves what the recorder owns at Stop: the tracks, the warnings, `recording` and `endedAt`. Everything else in
    /// session.json is kept as it is on disk, so flags and any other field saved during the recording (the calendar
    /// event, the profile) are never overwritten by the recorder's older copy (spec 14.3).
    public static func save(_ session: Session, keepingFlagsIn store: SessionStore) throws {
        try store.update(session.id) { saved in
            saved.tracks = session.tracks
            saved.warnings = session.warnings
            saved.recording = session.recording
            saved.endedAt = session.endedAt
        }
    }
}
