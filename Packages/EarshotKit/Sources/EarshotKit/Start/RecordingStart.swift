import Foundation

/// What a new recording starts with (spec 2, 5.2, 7.3): its title, the calendar event and profile, and who started it.
/// The App builds one when Record is pressed or a call starts it, and saves it into the new session.
public struct RecordingStart: Equatable, Sendable {
    public static let diskFull = "Less than 500 MB of disk space is free, so Earshot can't record."
    public static let diskLow = "Less than 2 GB of disk space is free."

    public var mode: Mode
    /// What the user typed, or the event's title when Title was left blank.
    public var title: String?
    public var startedBy: StartTrigger
    /// Kept only while "Use my calendar" is on.
    public var calendarEvent: CalendarEventInfo?
    /// Nil while "Use my calendar" is off; `.noEvent` when it is on and no event is current.
    public var profile: MeetingProfile?

    public init(mode: Mode, typedTitle: String, trigger: StartTrigger, event: CalendarEventInfo?,
                settings: EarshotSettings) {
        let event = settings.useCalendar ? event : nil
        self.mode = mode
        self.title = CurrentEvent.meetingTitle(typed: typedTitle, event: event)
        self.startedBy = trigger
        self.calendarEvent = event
        self.profile = settings.useCalendar ? Self.profile(event, settings: settings) : nil
    }

    /// Writes the event, the profile and the trigger into `session`.
    public func apply(to session: inout Session) {
        session.calendarEvent = calendarEvent
        session.profile = profile
        session.startedBy = startedBy
    }

    /// What stops a recording from starting and what only goes in the banner.
    public struct Check: Equatable, Sendable {
        public var blocker: String?
        public var notices: [String]

        public init(blocker: String?, notices: [String]) {
            self.blocker = blocker
            self.notices = notices
        }
    }

    /// Capture never waits for Claude (spec 2): a Claude setup problem is only a notice, and the notes stage fails
    /// into Retry later. Only a nearly full disk stops the start.
    public static func check(setupProblem: String?, disk: DiskSpace.Level?) -> Check {
        if disk == .critical { return Check(blocker: diskFull, notices: []) }
        var notices = setupProblem.map { [$0] } ?? []
        if disk == .low { notices.append(diskLow) }
        return Check(blocker: nil, notices: notices)
    }

    /// What the calendar read at recording start changes in the session.
    public struct Refresh: Equatable, Sendable {
        /// The event now current, or nil when the one the recording started with has ended.
        public var event: CalendarEventInfo?
        public var profile: MeetingProfile

        public init(event: CalendarEventInfo?, profile: MeetingProfile) {
            self.event = event
            self.profile = profile
        }

        /// Saves the event and profile into `session`. A title that was blank or came from the earlier event follows
        /// the new event (spec 5.2); a typed title stays. A recording that has stopped is never changed, so the notes
        /// stage always reads the same input.
        public func apply(to session: inout Session) {
            guard session.recording else { return }
            let current = session.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let fromEvent = current.isEmpty || current == CurrentEvent.meetingTitle(typed: nil, event: session.calendarEvent)
            session.calendarEvent = event
            session.profile = profile
            if fromEvent { session.title = CurrentEvent.meetingTitle(typed: nil, event: event) }
        }
    }

    /// The calendar read again once capture runs. Returns a change when it found an event the session doesn't hold,
    /// or when it found nothing (with access) and the session's event no longer overlaps `now`: the recording then
    /// has no event. Nil when nothing changes or with the calendar off.
    public static func refreshed(_ session: Session, fresh: CalendarEventInfo?, canRead: Bool, now: Date,
                                 settings: EarshotSettings) -> Refresh? {
        guard settings.useCalendar else { return nil }
        if let fresh {
            guard fresh != session.calendarEvent else { return nil }
            return Refresh(event: fresh, profile: profile(fresh, settings: settings))
        }
        guard canRead, let held = session.calendarEvent, CurrentEvent.pick([held], now: now) == nil else { return nil }
        return Refresh(event: nil, profile: .noEvent)
    }

    static func profile(_ event: CalendarEventInfo?, settings: EarshotSettings) -> MeetingProfile {
        ProfileRules.profile(event: event, myDomains: ProfileRules.myDomains(event: event, settings: settings))
    }
}

/// Whether the live panel's brief card is open (spec 4.5): collapsed when the meeting is External. The profile can be
/// saved a few seconds after the recording starts (the calendar is read again once capture runs), so the card follows
/// the profile until the user opens or closes it by hand.
public struct BriefCardExpansion: Equatable, Sendable {
    public private(set) var expanded: Bool
    /// The user opened or closed the card, so the profile no longer decides.
    public private(set) var setByHand = false

    /// `profile` is the session's at the start, or nil while it isn't known.
    public init(profile: MeetingProfile? = nil) {
        expanded = Self.opens(profile)
    }

    /// The session's profile became known or changed.
    public mutating func profileKnown(_ profile: MeetingProfile?) {
        guard !setByHand else { return }
        expanded = Self.opens(profile)
    }

    /// The user's click.
    public mutating func toggle() {
        expanded.toggle()
        setByHand = true
    }

    private static func opens(_ profile: MeetingProfile?) -> Bool { profile != .external }
}

/// The current calendar event as the menu shows it (spec 5.2, 5.3): read at most every 60 s while idle, it gives the
/// "Now:" line, the title placeholder, and the mode to preselect once per new event. Once that event is over, the
/// user's default mode comes back, unless the user changed the mode since it was preselected.
public struct CurrentEventTracker: Equatable, Sendable {
    public private(set) var event: CalendarEventInfo?
    public private(set) var profile: MeetingProfile = .noEvent
    public private(set) var lastRead: Date?
    /// The last event whose mode was preselected. A user's change sticks until a different event is current.
    public private(set) var preselectedID: String?
    /// The mode preselected for the last new event, until that event is over and the mode was restored or found
    /// changed by the user. Nil when the preselection changed nothing (the user had already chosen that mode), so a
    /// mode the user chose before the event stays after it.
    public private(set) var preselectedMode: Mode?

    public init() {}

    /// True when the menu is idle (not recording or starting) and the last read is at least `pollInterval` old.
    public func shouldPoll(now: Date, idle: Bool) -> Bool {
        guard idle else { return false }
        return lastRead.map { now.timeIntervalSince($0) >= CurrentEvent.pollInterval } ?? true
    }

    /// Records a read. Returns the mode to preselect when a new event became current, or the user's default mode
    /// when no event is current any more and `currentMode` is still the one preselected. While a recording runs
    /// (`canPreselect` false) nothing changes the mode: a new event counts as new again at the next read, and the
    /// default comes back at the next idle read. Without `currentMode` nothing is restored.
    public mutating func observe(_ event: CalendarEventInfo?, settings: EarshotSettings, now: Date,
                                 canPreselect: Bool, currentMode: Mode? = nil) -> Mode? {
        lastRead = now
        self.event = event
        profile = RecordingStart.profile(event, settings: settings)
        guard canPreselect else { return nil }
        guard let event else { return restoreDefault(currentMode: currentMode, settings: settings) }
        guard CurrentEvent.isNew(event, previousID: preselectedID) else { return nil }
        preselectedID = event.id
        let mode = ProfileRules.mode(profile: profile, settings: settings)
        // Remembered only when it changed the mode, or when the mode is still as the last event set it.
        let changes = currentMode == nil || currentMode != mode || preselectedMode == mode
        preselectedMode = changes ? mode : nil
        return mode
    }

    /// An idle point with no event current: the user's default mode when `currentMode` is still the one preselected
    /// (see `modeToRestore`). Either way the preselection is forgotten, so it restores at most once. Without
    /// `currentMode` nothing is restored.
    public mutating func restoreDefault(currentMode: Mode?, settings: EarshotSettings) -> Mode? {
        let restore = currentMode.flatMap { modeToRestore(currentMode: $0, settings: settings) }
        preselectedMode = nil
        return restore
    }

    /// "Use my calendar" was turned off: forgets the event. When idle (`canRestore`) it returns what
    /// `restoreDefault` returns. During a recording or a start the preselected mode is kept, and the App calls
    /// `restoreDefault` at the next idle point (the recording ended, or the menu opened).
    public mutating func calendarTurnedOff(currentMode: Mode, settings: EarshotSettings, canRestore: Bool) -> Mode? {
        let kept = preselectedMode
        self = CurrentEventTracker()
        preselectedMode = kept
        guard canRestore else { return nil }
        return restoreDefault(currentMode: currentMode, settings: settings)
    }

    /// The user's default mode, when `currentMode` is still the one preselected for an event and differs from it.
    /// Nil when nothing was preselected or the user has changed the mode since.
    public func modeToRestore(currentMode: Mode, settings: EarshotSettings) -> Mode? {
        guard let preselectedMode, currentMode == preselectedMode, settings.defaultMode != currentMode else {
            return nil
        }
        return settings.defaultMode
    }

    /// Forgets everything, the preselected mode too. Turning "Use my calendar" off uses `calendarTurnedOff`.
    public mutating func reset() {
        self = CurrentEventTracker()
    }

    /// The event read last, while it still overlaps `now` (counting the lead time). An event that ended since the
    /// last read is not current.
    public func current(now: Date) -> CalendarEventInfo? {
        event.flatMap { CurrentEvent.pick([$0], now: now) }
    }

    /// "Now: <title> · <profile>", or nil without a current event.
    public func menuLine(now: Date) -> String? {
        current(now: now).map { CurrentEvent.menuLine($0, profile: profile) }
    }

    /// The current event's title for the empty Title field, or nil.
    public func titlePlaceholder(now: Date) -> String? {
        CurrentEvent.meetingTitle(typed: nil, event: current(now: now))
    }
}
