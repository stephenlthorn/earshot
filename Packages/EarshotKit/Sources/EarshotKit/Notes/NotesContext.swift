import Foundation

/// A person on the meeting's calendar event, as the notes prompt sees them: a name, never an address.
public struct ContextAttendee: Codable, Equatable, Hashable, Sendable {
    public enum Side: String, Codable, Sendable {
        /// The user.
        case me
        /// Inside the user's domains.
        case `internal`
        /// Outside them.
        case external
    }

    public var name: String
    public var side: Side

    /// A name that is an address becomes its domain, so no full address reaches a prompt.
    public init(name: String, side: Side) {
        self.name = Attendee.safeName(name)
        self.side = side
    }

    /// The attendee's `displayName`, never their address.
    public init(_ attendee: Attendee, side: Side) {
        self.init(name: attendee.displayName, side: side)
    }
}

/// A slice of the meeting around one moment: the transcript around a flag, or the text read from the screen.
public struct Excerpt: Codable, Equatable, Hashable, Sendable {
    /// Seconds on the meeting clock.
    public var offset: Double
    public var text: String

    public init(offset: Double, text: String) {
        self.offset = offset
        self.text = text
    }
}

/// Everything besides the transcript that the notes model gets (spec 5, 6, 8 and 9). Empty for a v1-style meeting,
/// and then the prompt is exactly v1's.
public struct NotesContext: Equatable, Sendable {
    /// A live to-do that was started during the call, with its id ("L2").
    public struct StartedItem: Equatable, Hashable, Sendable {
        public var id: String
        public var task: String

        public init(id: String, task: String) {
            self.id = id
            self.task = task
        }
    }

    public var attendees: [ContextAttendee]
    public var profile: MeetingProfile?
    /// Already cleaned (links and dial-in lines removed).
    public var agenda: String
    public var openLoops: [OpenLoop]
    public var lessons: [Lesson]
    /// The transcript around each flag; `offset` is the flag's time.
    public var flags: [Excerpt]
    /// Screen text, already chosen and redacted.
    public var screen: [Excerpt]
    public var started: [StartedItem]

    public init(attendees: [ContextAttendee] = [], profile: MeetingProfile? = nil, agenda: String = "",
                openLoops: [OpenLoop] = [], lessons: [Lesson] = [], flags: [Excerpt] = [], screen: [Excerpt] = [],
                started: [StartedItem] = []) {
        self.attendees = attendees
        self.profile = profile
        self.agenda = agenda
        self.openLoops = openLoops
        self.lessons = lessons
        self.flags = flags
        self.screen = screen
        self.started = started
    }

    public static let empty = NotesContext()

    public var isEmpty: Bool { hasNoBlocks && (profile == nil || profile == .noEvent) }

    var hasNoBlocks: Bool {
        attendees.isEmpty && agenda.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && openLoops.isEmpty
            && lessons.isEmpty && flags.isEmpty && screen.isEmpty && started.isEmpty
    }
}

/// Lessons as examples for a prompt (spec 6): the same style first, newest first within each group.
public enum LessonsPrompt {
    public static let notesLimit = 8
    public static let liveLimit = 6

    /// The lessons inside `<lesson_examples>`, or "" when there are none.
    public static func render(_ lessons: [Lesson], style: NotesStyle?, limit: Int) -> String {
        let chosen = pick(lessons, style: style, limit: limit)
        guard !chosen.isEmpty else { return "" }
        return PromptFraming.wrap(tag: .lessonExamples, text: chosen.map { "- " + line($0) }.joined(separator: "\n"))
    }

    static func pick(_ lessons: [Lesson], style: NotesStyle?, limit: Int) -> [Lesson] {
        let newest = lessons.sorted { $0.date > $1.date }
        let same = newest.filter { $0.style == style }
        let other = newest.filter { $0.style != style }
        return Array((same + other).prefix(max(0, limit)))
    }

    static func line(_ lesson: Lesson) -> String {
        switch lesson.kind {
        case .notSent:
            "The user chose not to send this suggested AI task: \(item(lesson.before ?? lesson.after))"
        case .sentAnyway:
            "The user sent this task to an AI although it wasn't suggested: \(item(lesson.after ?? lesson.before))"
        case .edited:
            "The user changed \(item(lesson.before)) to \(item(lesson.after))"
        case .instruction:
            "The user asked for this change to the notes: \"\(clean(lesson.instruction ?? ""))\""
        }
    }

    static func item(_ item: Lesson.Item?) -> String {
        guard let item else { return "(nothing)" }
        let due = item.due.map { ", due \(clean($0))" } ?? ""
        return "\"\(clean(item.task))\" (\(clean(item.owner))\(due))"
    }

    /// One line, at most 200 characters.
    static func clean(_ text: String) -> String {
        String(text.split(whereSeparator: \.isNewline).joined(separator: " ").prefix(200))
    }
}
