import Foundation

extension LibraryIndex {
    /// The reconcile pass at launch (spec 11.1): rebuilds missing or stale entries, drops entries whose folder is gone
    /// (a meeting deleted in Finder), then rewrites reminders.json from what is left. Best effort: it never throws,
    /// and returns what went wrong, for the log.
    public func refreshAtLaunch(with store: SessionStore, userName: String, now: Date) -> [String] {
        var problems: [String] = []
        do {
            try reconcile(with: store, userName: userName)
        } catch {
            problems.append("Couldn't reconcile the library index: \(error.localizedDescription)")
        }
        do {
            try writeReminders(userName: userName, now: now)
        } catch {
            problems.append("Couldn't write reminders.json: \(error.localizedDescription)")
        }
        return problems
    }
}
