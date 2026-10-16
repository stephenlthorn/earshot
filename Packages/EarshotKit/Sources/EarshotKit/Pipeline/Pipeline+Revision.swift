import CryptoKit
import Foundation

/// Notes revisions and what the app does with a meeting after its stages (spec 6, 8 and 11.1).
extension Pipeline {
    /// Writes notes-r<n>.json (old), the new notes.json/md/html, bumps notesRevision, updates the index. Throws if the meeting is running.
    public func saveRevision(sessionID: String, notes: MeetingNotes, lesson: Lesson?) async throws {
        let session = try claim(sessionID)
        defer { running.remove(sessionID) }
        let config = config()
        let saved = try writeRevision(session, notes: notes, config: config)
        guard let lesson, config.learnFromEdits, let lessons = config.lessons else { return }
        do {
            try lessons.add(lesson)
        } catch {
            // The notes are saved; only the lesson is lost, so this is a warning, not a failed Save.
            _ = try? warn(saved, ["The notes were saved, but Earshot couldn't save what it learned: \(Self.describe(error))"])
        }
    }

    /// Sends extra items (from Fix) to the switched-on targets with payload id `extraPayloadID`; returns per-target results.
    /// With `targets`, only the switched-on targets with those ids, so a retry after a partial failure never sends
    /// the items twice to a target that took them.
    public func sendExtra(sessionID: String, items: [ActionItem],
                          targets only: Set<String>? = nil) async throws -> [String: DispatchResult] {
        var session = try claim(sessionID)
        defer { running.remove(sessionID) }
        // items.json is the dispatch stage's record for Retry until that stage is done, so nothing is added before.
        guard !session.mode.stages.contains(.dispatch) || session.stages[.dispatch]?.status == .done else {
            throw PipelineError.sendNotFinished
        }
        let config = config()
        let notes = try store.read(MeetingNotes.self, session, MeetingFile.notes)
        let unstarted = Self.unstarted(Self.withSources(items, notes: notes), notes: notes,
                                       started: startedLiveItems(session))
        if unstarted.count < items.count {
            session = try warn(session, [Self.leftOutWarning(items.count - unstarted.count)])
        }
        let chosen: [ActionItem]
        (session, chosen) = try carried(unstarted, session)
        let payloadID = Self.extraPayloadID(sessionID: session.id, revision: session.notesRevision, items: chosen)
        var revision = session
        revision.id = payloadID
        let markdown = (try? String(contentsOf: store.file(session, MeetingFile.notesMarkdown), encoding: .utf8)) ?? ""
        let payload = DoPayload(session: revision, folder: store.folder(session), notes: notes, notesMarkdown: markdown,
                                transcriptPath: store.file(session, MeetingFile.transcriptMarkdown).path, items: chosen)
        let targets = makeTargets().filter { only?.contains($0.id) ?? true }
        guard !payload.items.isEmpty, !targets.isEmpty else { return [:] }
        let json = try payload.encoded()
        var results: [String: DispatchResult] = [:]
        var problems: [String] = []
        for target in targets {
            try await lanes.acquire(target.id)  // one run at a time per target, with live Starts too (spec 3.2)
            let result = await target.send(payload, json: json, folder: store.folder(session))
            lanes.release(target.id)
            results[target.id] = result
            guard let link = result.link else { continue }
            do {
                session = try save(session) { $0.routineRuns[payloadID] = link }
            } catch {
                problems.append("\(Self.notRecordedWarning) \(Self.describe(error))")
            }
        }
        let succeeded = targets.map(\.id).filter { results[$0]?.ok == true }
        if !succeeded.isEmpty {
            (session, problems) = recordExtra(payload.items, payload: payloadID, to: succeeded, session, problems)
        }
        _ = try? warn(session, problems + publish(session, config: config))
        return results
    }

    /// The payload id of an extra send: "<id>-r<notes revision>-<8 hex>", the hex from the tasks of the items it
    /// carries, in the order it carries them. A receiver that keeps done-state per id and item position sees a send
    /// with other items, or the same items in another order, as new, and an identical retry as a repeat. Always within a receiver's `[A-Za-z0-9-]{1,64}`: an id too long
    /// for the suffix is cut from its end.
    public static func extraPayloadID(sessionID: String, revision: Int, items: [ActionItem]) -> String {
        let tasks = items.map(\.task).joined(separator: "\n")
        let hash = SHA256.hash(data: Data(tasks.utf8)).prefix(4).map { String(format: "%02x", $0) }.joined()
        let suffix = "-r\(revision)-\(hash)"
        return String(sessionID.prefix(max(0, extraPayloadIDLimit - suffix.count))) + suffix
    }

    /// The longest payload id a receiver takes.
    static let extraPayloadIDLimit = 64

    /// The start of the warning when targets took extra items but Earshot couldn't write that down.
    static let notRecordedWarning = "The new items were sent, but Earshot couldn't record it:"

    /// After an extra send: adds the items to items.json, each naming `payloadID` as the payload that carried it,
    /// and the targets that took them to `sent`. With the stage done, `sent` is no longer a retry record, so it can say where these items went too. A failure is a warning,
    /// never a thrown error, because the targets have the items and the caller needs their results.
    func recordExtra(_ items: [ActionItem], payload payloadID: String, to succeeded: [String], _ session: Session,
                     _ problems: [String]) -> (Session, [String]) {
        var problems = problems
        let carried = items.map { item -> ActionItem in var item = item; item.payload = payloadID; return item }
        do {
            try recordSent(carried, for: session)
        } catch {
            problems.append("\(Self.notRecordedWarning) \(Self.describe(error))")
        }
        do {
            let saved = try save(session) { current in
                for id in succeeded where !current.sent.contains(id) { current.sent.append(id) }
            }
            return (saved, problems)
        } catch {
            return (session, problems + ["\(Self.notRecordedWarning) \(Self.describe(error))"])
        }
    }

    /// Re-renders notes.html and rewrites the index entry.
    public func reindex(sessionID: String) async {
        guard let session = find(sessionID) else { return }
        _ = try? warn(session, publish(session, config: config()))
    }

    /// The meeting, marked as being worked on here. Throws `PipelineError.meetingBusy` while it records, while its
    /// stages run here, or while `earshot process` works on it.
    func claim(_ sessionID: String) throws -> Session {
        guard !running.contains(sessionID) else { throw PipelineError.meetingBusy }
        guard let session = find(sessionID) else { throw SessionStoreError.notFound(sessionID) }
        guard !session.recording, !store.isBusy(session) else { throw PipelineError.meetingBusy }
        running.insert(sessionID)
        return session
    }

    /// Keeps the current notes as notes-r<current revision>.json (never replacing a kept copy, so a crash part-way
    /// never loses the older text), bumps `notesRevision`, writes the new notes.json and notes.md, matches items.json
    /// to the new notes, then re-renders notes.html and the index entry. The count goes up before the notes change,
    /// so a failed save of the count leaves the notes as they were. The new notes never carry the code-side `source`.
    func writeRevision(_ session: Session, notes: MeetingNotes, config: PipelineConfig) throws -> Session {
        let current = find(session.id) ?? session
        let old = store.file(current, MeetingFile.notes)
        let previous = readOptional(MeetingNotes.self, current, MeetingFile.notes)
        let kept = store.file(current, MeetingFile.notesRevision(current.notesRevision))
        if FileManager.default.fileExists(atPath: old.path), !FileManager.default.fileExists(atPath: kept.path) {
            try FileManager.default.copyItem(at: old, to: kept)
        }
        var clean = notes
        for index in clean.actionItems.indices { clean.actionItems[index].source = nil }
        let saved = try save(current) { $0.notesRevision += 1 }
        try writeNotesFiles(clean, for: saved, config: config)
        return try warn(saved, retagItems(saved, old: previous, new: clean) + publish(saved, config: config))
    }

    /// Rewrites items.json so each entry names its item in the new notes (see `retagged`). Best effort: a failure is
    /// a warning, because the notes are already saved.
    func retagItems(_ session: Session, old: MeetingNotes?, new: MeetingNotes) -> [String] {
        guard let entries = readOptional([ActionItem].self, session, MeetingFile.items) else { return [] }
        let retagged = Self.retagged(entries, old: old, new: new)
        guard retagged != entries else { return [] }
        do {
            try Self.json(retagged).write(to: store.file(session, MeetingFile.items), options: .atomic)
            return []
        } catch {
            return ["The list of sent items couldn't be matched to the edited notes: \(Self.describe(error))"]
        }
    }

    /// Adds `items` to items.json, so the page and the index show them as sent. Items already there are not added
    /// twice.
    func recordSent(_ items: [ActionItem], for session: Session) throws {
        let url = store.file(session, MeetingFile.items)
        var saved = (try? JSONDecoder().decode([ActionItem].self, from: Data(contentsOf: url))) ?? []
        for item in items where !saved.contains(item) { saved.append(item) }
        try Self.json(saved).write(to: url, options: .atomic)
    }
}
