import Foundation

/// The dispatch stage (spec 4.4, 6 and 12): what the user confirmed goes to each Do target, never an item that was
/// already started during the call, and edits made in the confirm window become a notes revision first.
extension Pipeline {
    /// Marks a meeting started by `earshot process` whose items.json a person chose in the confirm window. Until
    /// then the saved choice is the AI's, and Retry asks again (spec 2).
    static let personChoseMarker = ".items-chosen"

    static func leftOutWarning(_ count: Int) -> String {
        count == 1 ? "1 item was left out because it was started during the call."
            : "\(count) items were left out because they were started during the call."
    }

    func dispatch(_ meeting: Session) async throws -> Session {
        var session = meeting
        let config = config()
        let current = try JSONDecoder().decode(MeetingNotes.self, from: Data(contentsOf: store.file(session, "notes.json")))
        guard !current.actionItems.isEmpty else { return session }
        let targets = makeTargets()
        guard !targets.isEmpty else { return try warn(session, ["No Do targets are set up, so nothing was sent."]) }
        guard let chosen = try await chooseItems(session, notes: current, config: config) else {
            return try warn(session, ["Sending was skipped."])
        }
        session = chosen.session
        let notes = chosen.notes, items = chosen.items
        let markdown = (try? String(contentsOf: store.file(session, "notes.md"), encoding: .utf8)) ?? ""
        let payload = DoPayload(session: session, folder: store.folder(session), notes: notes, notesMarkdown: markdown,
                                transcriptPath: store.file(session, "transcript.md").path, items: items)
        // The payload drops items with no task, so ask it, not `items`, whether anything is left to send.
        guard !payload.items.isEmpty else {
            return try warn(session, ["No action items were picked, so nothing was sent."])
        }
        let json = try payload.encoded()
        var failures: [String] = []
        for target in targets where !session.sent.contains(target.id) {
            // Cut off part-way by a quit or crash: it may have done some of the work, so only Retry sends it again.
            if session.inFlight.contains(target.id), !target.repeatsSafely {
                failures.append(Self.interrupted(target.label))
                continue
            }
            // A live Start still running on this target (this meeting's or another's) finishes first (spec 3.2).
            try await lanes.acquire(target.id)
            let result: DispatchResult
            do {
                defer { lanes.release(target.id) }
                // On disk before the send starts, so a crash part-way is known on the next launch.
                session = try save(session) { if !$0.inFlight.contains(target.id) { $0.inFlight.append(target.id) } }
                result = await target.send(payload, json: json, folder: store.folder(session))
            }
            // The app is quitting: leave the mark on disk and the stage pending, with no failure counted.
            if result.interrupted { throw CancellationError() }
            if !result.ok { failures.append("\(target.label): \(result.detail)") }
            session = try save(session) { current in
                current.inFlight.removeAll { $0 == target.id }
                if result.ok, !current.sent.contains(target.id) { current.sent.append(target.id) }
                if let link = result.link { current.routineRuns[payload.session.id] = link }
            }
        }
        session = try warn(session, publish(session, config: config))
        if !failures.isEmpty { throw PipelineError.dispatchFailed(failures.joined(separator: "; ")) }
        return session
    }

    /// What to send: the choice saved on an earlier try, or else what the confirm window returns, with edits saved
    /// as a notes revision first. Items started during the call are left out, with a warning. Nil when the user
    /// chose not to send.
    func chooseItems(_ session: Session, notes: MeetingNotes, config: PipelineConfig) async throws
        -> (session: Session, notes: MeetingNotes, items: [ActionItem])? {
        var session = session, notes = notes
        let started = startedLiveItems(session)
        let returned: [ActionItem], items: [ActionItem], unstartedCount: Int
        if let saved = savedChoice(session) {
            returned = saved  // chosen on an earlier try; don't ask again
            items = Self.unstarted(saved, notes: notes, started: started)
            unstartedCount = items.count
        } else if let chosen = await confirm(session, notes) {
            returned = chosen
            // Each item records the payload that carries it, so its routine run is found later (spec 12).
            let tagged = Self.unstarted(Self.withSources(chosen, notes: notes), notes: notes, started: started)
                .map { item -> ActionItem in var item = item; item.payload = session.id; return item }
            unstartedCount = tagged.count
            (session, notes) = try reviseIfEdited(session, notes: notes, items: tagged, config: config)
            // items.json says what was sent, so it holds only what the payload carries.
            (session, items) = try carried(Self.unstarted(tagged, notes: notes, started: started), session)
            try Self.json(items).write(to: store.file(session, MeetingFile.items), options: .atomic)
            // `earshot process` holds the meeting while it runs, so a choice made without that is a person's.
            if session.startedBy == .cli, !store.isBusy(session) {
                try Data().write(to: store.file(session, Self.personChoseMarker), options: .atomic)
            }
        } else {
            return nil
        }
        // Only items started during the call count here; `carried` warns about the 20-item cap on its own.
        let dropped = returned.count - unstartedCount
        if dropped > 0 { session = try warn(session, [Self.leftOutWarning(dropped)]) }
        return (session, notes, items)
    }

    /// `items` cut to what one payload carries, with a warning for any past the cap. Without the confirm window
    /// ("Send without asking") more than `DoPayload.maxItems` can be picked.
    func carried(_ items: [ActionItem], _ session: Session) throws -> (Session, [ActionItem]) {
        let carried = DoPayload.carried(items)
        let over = items.filter { $0.task.fittedForReceiver(to: DoPayload.maxTask).nonBlank != nil }.count - carried.count
        return (over > 0 ? try warn(session, [DoPayload.overCapWarning(over)]) : session, carried)
    }

    /// items.json from an earlier try, unless it is a choice `earshot process` made for the AI that no person has
    /// confirmed.
    func savedChoice(_ session: Session) -> [ActionItem]? {
        let chosenByPerson = FileManager.default.fileExists(atPath: store.file(session, Self.personChoseMarker).path)
        guard session.startedBy != .cli || chosenByPerson else { return nil }
        return try? JSONDecoder().decode([ActionItem].self, from: Data(contentsOf: store.file(session, MeetingFile.items)))
    }

    /// Saves the confirmed edits as a notes revision. If that fails the send still goes ahead with a warning, and
    /// the notes are read again, since part of the revision may be on disk.
    func reviseIfEdited(_ session: Session, notes: MeetingNotes, items: [ActionItem], config: PipelineConfig) throws
        -> (Session, MeetingNotes) {
        guard let revised = Self.revised(notes, with: items) else { return (session, notes) }
        do {
            return (try writeRevision(session, notes: revised, config: config), revised)
        } catch {
            let latest = find(session.id) ?? session
            let onDisk = readOptional(MeetingNotes.self, latest, MeetingFile.notes) ?? notes
            let warning = "The edited items were sent, but the notes may not show the edits: \(Self.describe(error))"
            return (try warn(latest, [warning]), onDisk)
        }
    }

    /// The live to-dos that went out, or may have. Nil when live.json is there but can't be read, so nothing can be
    /// ruled out.
    func startedLiveItems(_ session: Session) -> [LiveItem]? {
        let url = store.file(session, MeetingFile.live)
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        return readOptional(LiveFile.self, session, MeetingFile.live)?.items.filter(\.status.isStarted)
    }

    /// `items` without any that were started during the call (spec 4.4), even if the confirm window returned them:
    /// an item whose notes item is linked to a started live to-do, whose source is one, or that is itself linked to
    /// one. With `started` nil (live.json unreadable), any item pointing at a live to-do is held back.
    static func unstarted(_ items: [ActionItem], notes: MeetingNotes, started: [LiveItem]?) -> [ActionItem] {
        let count = notes.actionItems.count
        guard let started else {
            return items.filter { item in
                let notesItem = notesIndex(item.source, count: count).map { notes.actionItems[$0] }
                return item.liveRef == nil && notesItem?.liveRef == nil && !(item.source ?? "").hasPrefix("L")
            }
        }
        guard !started.isEmpty else { return items }
        let linked = LiveDispatch.linked(notes.actionItems, live: started)
        return items.filter { item in
            if let index = notesIndex(item.source, count: count), linked.contains(index) { return false }
            if let source = item.source, started.contains(where: { $0.id == source }) { return false }
            return ItemStatus.linkedLiveItem(item, live: started) == nil
        }
    }

    /// The notes with each edited item's task, owner and due as the user sent them, or nil when nothing was edited.
    static func revised(_ notes: MeetingNotes, with items: [ActionItem]) -> MeetingNotes? {
        var revised = notes
        var changed = false
        for item in items {
            guard let index = notesIndex(item.source, count: notes.actionItems.count),
                  LessonDiff.isEdited(notes.actionItems[index], item) else { continue }
            let due = item.due?.trimmingCharacters(in: .whitespacesAndNewlines)
            revised.actionItems[index].task = item.task.trimmingCharacters(in: .whitespacesAndNewlines)
            revised.actionItems[index].owner = item.owner.trimmingCharacters(in: .whitespacesAndNewlines)
            revised.actionItems[index].due = due?.isEmpty == false ? due : nil
            changed = true
        }
        return changed ? revised : nil
    }
}
