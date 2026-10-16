import Foundation

/// One thing the user taught Earshot by changing its suggestions (spec 6).
public struct Lesson: Codable, Equatable, Sendable, Identifiable {
    public enum Kind: String, Codable, CaseIterable, Sendable {
        case notSent = "not_sent"
        case sentAnyway = "sent_anyway"
        case edited
        case instruction
    }

    /// An action item as it was before or after the change.
    public struct Item: Codable, Equatable, Hashable, Sendable {
        public var task: String
        public var owner: String
        public var due: String?

        public init(task: String, owner: String, due: String? = nil) {
            self.task = task
            self.owner = owner
            self.due = due
        }

        public init(_ item: ActionItem) { self.init(task: item.task, owner: item.owner, due: item.due) }
    }

    public var id: String
    public var date: Date
    public var style: NotesStyle
    public var kind: Kind
    public var before: Item?
    public var after: Item?
    /// The user's words, for `instruction`.
    public var instruction: String?
    public var meetingTitle: String

    public init(id: String = UUID().uuidString, date: Date, style: NotesStyle, kind: Kind, before: Item? = nil,
                after: Item? = nil, instruction: String? = nil, meetingTitle: String) {
        self.id = id
        self.date = date
        self.style = style
        self.kind = kind
        self.before = before
        self.after = after
        self.instruction = instruction
        self.meetingTitle = meetingTitle
    }

    enum CodingKeys: String, CodingKey { case id, date, style, kind, before, after, instruction, meetingTitle }

    /// A lesson of a kind this version doesn't know fails here, so `LessonsFile` drops it; a style it doesn't know
    /// becomes `general`.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(id: c.lenient(String.self, .id) ?? UUID().uuidString, date: try c.decode(Date.self, forKey: .date),
                  style: c.lenientCase(NotesStyle.self, .style) ?? .general, kind: try c.decode(Kind.self, forKey: .kind),
                  before: c.lenient(Item.self, .before), after: c.lenient(Item.self, .after),
                  instruction: c.lenient(String.self, .instruction),
                  meetingTitle: c.lenient(String.self, .meetingTitle) ?? "")
    }
}

/// lessons.json in Application Support: newest first.
public struct LessonsFile: Codable, Equatable, Sendable {
    public var version: Int
    public var lessons: [Lesson]

    public init(version: Int = 1, lessons: [Lesson] = []) {
        self.version = version
        self.lessons = lessons
    }

    enum CodingKeys: String, CodingKey { case version, lessons }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = c.lenient(Int.self, .version) ?? 1
        lessons = c.lossy(Lesson.self, .lessons)
    }
}
