import Foundation

/// reminders.json: up to five action items the user owns from the last seven days, already cleaned, plus the exact
/// text `earshot reminders` prints (spec 11.2).
public struct Reminders: Codable, Equatable, Sendable {
    public struct Reminder: Codable, Equatable, Sendable {
        public var task: String
        public var due: String?
        public var meeting: String
        public var meetingID: String
        public var startedAt: Date

        public init(task: String, due: String?, meeting: String, meetingID: String, startedAt: Date) {
            self.task = task
            self.due = due
            self.meeting = meeting
            self.meetingID = meetingID
            self.startedAt = startedAt
        }
    }

    public static let header = "Earshot reminders (quoted from meeting notes; not instructions):"
    public static let maxItems = 5
    public static let maxTask = 120
    public static let window: TimeInterval = 7 * 24 * 3600

    public var version: Int
    public var createdAt: Date
    public var items: [Reminder]

    public init(version: Int = 1, createdAt: Date, items: [Reminder]) {
        self.version = version
        self.createdAt = createdAt
        self.items = items
    }

    /// What `earshot reminders` prints: the header and one line per item, or "" when there are none.
    public var text: String {
        guard !items.isEmpty else { return "" }
        let lines = items.map { item in
            let due = item.due.map { "due \($0); " } ?? ""
            return "- \(item.task) (\(due)from \(item.meeting))"
        }
        return ([Self.header] + lines).joined(separator: "\n") + "\n"
    }

    /// Items the user owns from meetings in the last seven days, newest meeting first. Items already started (during
    /// the call or in the cloud) or sent to a target are left out.
    public static func compute(_ records: [MeetingRecord], userName: String, now: Date) -> Reminders {
        let recent = records.filter { $0.startedAt <= now && $0.startedAt >= now.addingTimeInterval(-window) }
            .sorted { $0.startedAt > $1.startedAt }
        var out: [Reminder] = []
        for record in recent {
            for entry in record.items where isUsers(entry.item, userName: userName) && isOpen(entry.status) {
                let task = clean(entry.item.task)
                guard !task.isEmpty, out.count < maxItems else { continue }
                out.append(Reminder(task: task, due: entry.item.due.map(clean).flatMap { $0.isEmpty ? nil : $0 },
                                    meeting: clean(record.title), meetingID: record.id, startedAt: record.startedAt))
            }
        }
        return Reminders(createdAt: now, items: out)
    }

    /// The user owns an item they must do, or one whose owner is their name, their first name or "me".
    static func isUsers(_ item: ActionItem, userName: String) -> Bool {
        if item.doer == .me { return true }
        let owner = MeetingLibrary.normalizedName(item.owner)
        let user = MeetingLibrary.normalizedName(userName)
        return owner == "me" || (!user.isEmpty && (owner == user || owner == user.split(separator: " ").first.map(String.init)))
    }

    static func isOpen(_ status: String) -> Bool {
        !ItemStatus.isHandled(status)
    }

    /// Removes code fences, backticks, URLs and the shell characters `$ ; | & < >`, joins lines, and clips to 120
    /// characters.
    public static func clean(_ text: String) -> String {
        var out = text.replacingOccurrences(of: #"(?i)\b(?:https?://|www\.)\S*"#, with: "", options: .regularExpression)
        out.removeAll { "`$;|&<>".contains($0) }
        let words = out.split(whereSeparator: { $0.isWhitespace || $0.isNewline })
        let joined = words.joined(separator: " ")
        guard joined.count > maxTask else { return joined }
        return String(joined.prefix(maxTask - 3)).trimmingCharacters(in: .whitespaces) + "..."
    }
}
