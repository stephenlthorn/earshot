import Foundation

/// The one rule for what happened to each notes action item (spec 14.4). The page, the index, MCP and the CLI all
/// use it.
public enum ItemStatus {
    public static let startedDuringCall = "Started during the call"
    /// Sent to the routine target after the call, which answered with a run (spec 12).
    public static let startedInCloud = "Started in the cloud"
    public static let notSent = "Not sent"
    public static let notSentYet = "Not sent yet"
    /// Word similarity at or above this links an item to a live to-do when the model gave no `live_ref`.
    public static let similarityThreshold = 0.6

    /// One status per item in `notes.actionItems`, in order. A sent item is "Started in the cloud" when the routine
    /// run that took it is known (`cloudRuns`); otherwise "Sent to <targets>".
    /// - Parameters:
    ///   - items: items.json, or nil when it doesn't exist.
    ///   - sent: `Session.sent`, the Do target ids that succeeded.
    ///   - live: the live to-dos from live.json.
    ///   - cloudRuns: each item's routine run, from `cloudRuns(notes:items:session:)`; missing means none.
    public static func compute(notes: MeetingNotes, items: [ActionItem]?, sent: [String], live: [LiveItem],
                               cloudRuns: [String?] = []) -> [String] {
        notes.actionItems.enumerated().map { index, item in
            if linkedLiveItem(item, live: live.filter(\.status.isStarted)) != nil { return startedDuringCall }
            if let items, !sent.isEmpty, items.contains(where: { matches($0, notesItem: item, index: index) }) {
                let run = index < cloudRuns.count ? cloudRuns[index] : nil
                return run != nil ? startedInCloud : sentText(sent)
            }
            return items == nil ? notSentYet : notSent
        }
    }

    /// True for a status that means the item needs nothing more from the user: started during the call, started
    /// in the cloud, or sent to a target. Reminders and MCP's open items leave these out.
    public static func isHandled(_ status: String) -> Bool {
        status == startedDuringCall || status == startedInCloud || status.hasPrefix("Sent to ")
    }

    static let routineTarget = "routine"

    /// The routine run that took each notes item, in order, or nil. An items.json entry that names its payload has
    /// the run `routineRuns[<payload>]` (the newest such entry wins). An entry with no payload (v1 and earlier v2
    /// files) falls back to the meeting's run, `routineRun(for:)`, when the routine took the meeting's items.
    public static func cloudRuns(notes: MeetingNotes, items: [ActionItem]?, session: Session) -> [String?] {
        notes.actionItems.indices.map { index in
            let entries = (items ?? []).filter { matches($0, notesItem: notes.actionItems[index], index: index) }
            if let run = entries.compactMap({ $0.payload.flatMap { link(session, $0) } }).last { return run }
            guard entries.contains(where: { $0.payload == nil }), session.sent.contains(routineTarget) else { return nil }
            return routineRun(for: session)
        }
    }

    /// The run recorded for payload `key`, or nil when there is none or it is blank.
    static func link(_ session: Session, _ key: String) -> String? {
        session.routineRuns[key].flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
    }

    /// The meeting-wide run, for items.json entries that don't name their payload: the run of the meeting's own
    /// send (`routineRuns[<id>]`), else the newest extra send's (`<id>-r<n>-<hash>`, or `<id>-r<n>` from earlier
    /// versions; highest n). Nil when there is none.
    public static func routineRun(for session: Session) -> String? {
        if let own = link(session, session.id) { return own }
        let prefix = session.id + "-r"
        let revisions = session.routineRuns.keys.compactMap { key -> (Int, String)? in
            guard key.hasPrefix(prefix), link(session, key) != nil,
                  let number = Int(key.dropFirst(prefix.count).prefix { $0 != "-" }) else { return nil }
            return (number, key)
        }
        // Sends within one revision are told apart by key, so the choice is the same every time.
        return revisions.max { ($0.0, $0.1) < ($1.0, $1.1) }.flatMap { link(session, $0.1) }
    }

    /// The live to-do among `live` that a notes item points at: its `live_ref` when set, otherwise (only when
    /// `live_ref` is null) the most similar task at or above the threshold.
    public static func linkedLiveItem(_ item: ActionItem, live: [LiveItem]) -> LiveItem? {
        if let ref = item.liveRef { return live.first { $0.id == ref } }
        let scored = live.map { ($0, TranscriptMerger.similarity($0.task, item.task)) }
            .filter { $0.1 >= similarityThreshold }
        return scored.max { $0.1 < $1.1 }?.0
    }

    /// The items.json `source` for notes item `index` (counted from 0): "n1" for the first.
    public static func source(forNotesIndex index: Int) -> String { "n\(index + 1)" }

    /// "Sent to Claude Code, Webhook".
    public static func sentText(_ sent: [String]) -> String {
        "Sent to " + sent.map(targetLabel).joined(separator: ", ")
    }

    static func targetLabel(_ id: String) -> String {
        switch id {
        case "claude-code": "Claude Code"
        case "webhook": "Webhook"
        case "command": "Command"
        case "routine": "Claude Code routine"
        default: id
        }
    }

    /// An items.json entry is notes item `index` when its source says so. v1 wrote no source, so then the same
    /// task text is the match.
    static func matches(_ entry: ActionItem, notesItem: ActionItem, index: Int) -> Bool {
        if let source = entry.source { return source == self.source(forNotesIndex: index) }
        return entry.task == notesItem.task
    }
}
