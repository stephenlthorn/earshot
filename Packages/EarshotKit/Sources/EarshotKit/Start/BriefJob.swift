import Foundation

/// Writes `brief.json` for a recording that just started (spec 5.5): it finds related meetings, asks the quick model
/// when `BriefWriter.shouldWrite` allows it, and saves the brief atomically. It never throws: a failure is returned
/// for the log, and no brief is shown.
public struct BriefJob: Sendable {
    public enum Outcome: Equatable, Sendable {
        case written(MeetingBrief)
        case skipped
        case failed(String)
    }

    public var store: SessionStore
    public var library: MeetingLibrary
    public var settings: EarshotSettings
    public var makeClient: @Sendable () throws -> any ClaudeClient
    public var now: @Sendable () -> Date
    public var timeZone: TimeZone

    public init(store: SessionStore, library: MeetingLibrary, settings: EarshotSettings,
                makeClient: @escaping @Sendable () throws -> any ClaudeClient,
                now: @escaping @Sendable () -> Date = { Date() }, timeZone: TimeZone = .current) {
        self.store = store
        self.library = library
        self.settings = settings
        self.makeClient = makeClient
        self.now = now
        self.timeZone = timeZone
    }

    /// Writes the brief only while the meeting is still recording. A brief that arrives after Stop, or after the job
    /// was cancelled, is dropped: the notes stage reads brief.json, and a retried notes stage must see the same input
    /// as the first run (spec 5.5).
    public func run(sessionID: String) async -> Outcome {
        guard let session = store.find(sessionID) else { return .failed("The meeting \(sessionID) wasn't found.") }
        guard session.recording else { return .skipped }
        let history = MeetingHistory.related(to: session, library: library, userName: settings.userName, now: now())
        guard BriefWriter.shouldWrite(event: session.calendarEvent, history: history, mode: session.mode,
                                      settings: settings) else { return .skipped }
        do {
            let writer = BriefWriter(client: try makeClient(), model: settings.model(for: .brief))
            let brief = try await writer.write(event: session.calendarEvent, title: session.title, history: history,
                                               userName: settings.userName, timeZone: timeZone, now: now())
            guard !Task.isCancelled else { return .skipped }
            // Under the folder lock Stop also takes, so the brief lands before Stop closes the meeting or not at all.
            // The meeting is found again, in case its folder was renamed while Claude was working.
            let written = try store.locked(sessionID, hint: session) { current -> Bool in
                guard current.recording else { return false }
                try store.write(brief, current, MeetingFile.brief)
                return true
            }
            return written ? .written(brief) : .skipped
        } catch {
            return .failed(error.localizedDescription)
        }
    }
}
