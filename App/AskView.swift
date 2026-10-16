import EarshotKit
import Observation
import SwiftUI

extension AppModel {
    /// "Ask…" on a meeting row (spec 8): one window per meeting. When it's already open it only comes to the front,
    /// so an unsaved Fix and the offer to send new items are kept. Closing it stops a question or Fix still running.
    func showAsk(_ session: Session) {
        let id = "ask-\(session.id)"
        guard !windows.bringToFront(id) else { return }
        let controller = AskController(model: self, sessionID: session.id)
        let title = session.title ?? session.folderName
        windows.show(id, title: "Ask about \(title)", size: AskView.size, onClose: { controller.close() }) {
            AskView(controller: controller)
        }
    }

    /// Read from the meeting's stages, not the disk, because every menu row asks on every render.
    func hasTranscript(_ session: Session) -> Bool { AskRules.hasTranscript(session) }
}

/// Ask a meeting a question, or have Claude fix its notes (spec 8). Everything slow runs off the main actor.
@MainActor @Observable
final class AskController {
    enum Tab: Hashable { case ask, fix }

    /// The meeting as read from its folder.
    struct Snapshot: Sendable {
        var session: Session
        var notes: MeetingNotes?
        var lines: [TranscriptLine]
        var entries: [QAEntry]
    }

    static let notesChanged = "The notes changed since you asked for this fix. Fix again."
    static let stillWorking = "Earshot is still working on this meeting. Save when it's done."

    let model: AppModel
    let sessionID: String
    var tab = Tab.ask
    private(set) var session: Session?
    private(set) var notes: MeetingNotes?
    private(set) var lines: [TranscriptLine] = []
    private(set) var entries: [QAEntry] = []
    private(set) var loaded = false
    /// The pipeline is working on this meeting, so Fix waits.
    private(set) var running = false

    var question = ""
    private(set) var asking = false
    var instruction = ""
    private(set) var fixing = false
    private(set) var saving = false
    private(set) var revised: MeetingNotes?
    /// The notes the shown Fix started from. Save refuses when notes.json no longer matches them.
    private(set) var fixBase: MeetingNotes?
    private(set) var diff: NotesDiff?
    /// After Do already ran: the items saved Fixes added that haven't gone out yet, for "Send the N new items…".
    private(set) var pendingItems: [ActionItem] = []
    /// What each target took from "Send the N new items…" (target id to items, `source` stripped), so a later try
    /// sends each item only to the targets still missing it. Kept across Fixes: an item is the same item after one.
    private(set) var delivered: [String: Set<ActionItem>] = [:]
    private(set) var sending = false
    var error: String?
    var status: String?
    @ObservationIgnored private var askTask: Task<Void, Never>?
    @ObservationIgnored private var fixTask: Task<Void, Never>?

    init(model: AppModel, sessionID: String) {
        self.model = model
        self.sessionID = sessionID
    }

    var canFix: Bool { AskRules.canFix(hasNotes: notes != nil, running: running) && !saving }

    /// The pending new items by their index in the current notes.
    var newItems: [Int] { notes.map { AskRules.indices(of: pendingItems, in: $0) } ?? [] }

    func load() async {
        await reload()
        guard session != nil else { return }
        loaded = true
        await refreshRunning()
    }

    /// Reads the meeting again. A Fix waiting for Save is dropped when the notes under it changed.
    func reload() async {
        guard let found = await read() else {
            error = "This meeting is gone."
            return
        }
        if revised != nil, found.notes != fixBase {
            discard()
            error = Self.notesChanged
        }
        session = found.session
        notes = found.notes
        lines = found.lines
        entries = found.entries
    }

    func read() async -> Snapshot? {
        let store = model.store, id = sessionID, userName = model.settings.userName
        return await Task.detached { () -> Snapshot? in
            guard let session = store.find(id) else { return nil }
            let notes = try? store.readIfPresent(MeetingNotes.self, session, MeetingFile.notes)
            let segments = (try? store.readIfPresent([Segment].self, session, MeetingFile.transcript)) ?? nil
            let lines = TranscriptLine.lines(segments ?? [], names: [:], userName: userName)
            let entries = (try? QAStore(folder: store.folder(session)).entries()) ?? []
            return Snapshot(session: session, notes: notes ?? nil, lines: lines, entries: entries)
        }.value
    }

    /// When the pipeline finishes with the meeting, its notes may be new (written, or revised by confirm edits), so
    /// they are read again.
    func refreshRunning() async {
        let wasRunning = running
        running = await model.pipeline.isRunning(sessionID)
        if wasRunning, !running { await reload() }
    }

    func startAsk() {
        guard askTask == nil else { return }
        askTask = Task {
            await ask()
            askTask = nil
        }
    }

    func startFix() {
        guard fixTask == nil else { return }
        fixTask = Task {
            await fix()
            fixTask = nil
        }
    }

    /// The window closed: stop a question or Fix still waiting on Claude, which also stops its claude child.
    func close() {
        askTask?.cancel()
        fixTask?.cancel()
    }

    func ask() async {
        let text = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !asking, let session else { return }
        asking = true
        defer { asking = false }
        error = nil
        do {
            let qa = MeetingQA(client: try model.settings.claudeClient(secrets: model.keychain),
                               model: model.settings.model(for: .ask))
            let answer = try await qa.ask(question: text, notes: notes, transcript: lines, flags: session.flags)
            let entry = QAEntry(question: text, answer: answer, askedAt: Date(), model: qa.model)
            let folder = model.store.folder(session)
            entries = try await Task.detached { try QAStore(folder: folder).append(entry) }.value.entries
            question = ""
        } catch where Task.isCancelled {
            return
        } catch {
            self.error = Self.describe(error)
        }
    }

    /// Fixes the notes as they are on disk now, not as they were when the window opened.
    func fix() async {
        let text = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !fixing, revised == nil else { return }
        fixing = true
        defer { fixing = false }
        error = nil
        status = nil
        await refreshRunning()
        await reload()
        guard !running, let notes, let session else { return }
        do {
            let fixer = NotesFixer(client: try model.settings.claudeClient(secrets: model.keychain),
                                   model: model.settings.model(for: .fix), effort: model.settings.effort(for: .fix))
            let result = try await fixer.fix(instruction: text, notes: notes, transcript: lines, flags: session.flags)
            guard !Task.isCancelled else { return }
            fixBase = notes
            revised = result
            diff = NotesDiff.compare(notes, result)
        } catch where Task.isCancelled {
            return
        } catch {
            self.error = Self.describe(error)
        }
    }

    func discard() {
        revised = nil
        fixBase = nil
        diff = nil
    }

    /// Writes the revision through the pipeline, which also re-renders the page and updates the index, and keeps the
    /// instruction as a lesson when "Learn from my edits" is on. Refused when notes.json changed since the Fix.
    func save() async {
        guard let revised, let old = fixBase, !saving else { return }
        saving = true
        defer { saving = false }
        error = nil
        await refreshRunning()
        guard !running else {
            error = Self.stillWorking
            return
        }
        guard let current = await read(), current.notes == old else {
            discard()
            error = Self.notesChanged
            return
        }
        let settings = model.settings
        let meetingStore = model.store, meetingID = sessionID
        let meeting = await Task.detached { meetingStore.find(meetingID) }.value
        // Kept under the meeting's own style (its profile's), the one its notes were written in (spec 5.3).
        let style = meeting.map { ProfileRules.style(session: $0, settings: settings) } ?? settings.style
        let lesson = settings.learnFromEdits && !model.e2e
            ? LessonDiff.instruction(instruction, style: style, title: old.title, date: Date()) : nil
        do {
            try await model.pipeline.saveRevision(sessionID: sessionID, notes: revised, lesson: lesson)
        } catch {
            self.error = Self.describe(error)
            return
        }
        let store = model.store, id = sessionID
        let (fresh, itemsChosen) = await Task.detached { () -> (Session?, Bool) in
            guard let session = store.find(id) else { return (nil, false) }
            return (session, FileManager.default.fileExists(atPath: store.file(session, MeetingFile.items).path))
        }.value
        let ran = fresh.map { AskRules.doAlreadyRan($0, itemsChosen: itemsChosen) } ?? false
        pendingItems = ran && settings.anyTargetOn ? AskRules.pending(pendingItems, old: old, new: revised) : []
        notes = revised
        discard()
        instruction = ""
        await reload()
        status = "Saved. The notes, the page and the index are updated."
        model.refresh()
    }

    /// "Send the N new items…": the normal confirm window for just those items, then the pipeline sends them with
    /// their own payload id. Each target that is on gets only the items it hasn't taken yet, and the window names
    /// only the targets still missing some. The offer stays until every target that is on has the items, so a failed
    /// send can be tried again.
    func sendNewItems() async {
        let offered = newItems
        guard let notes, !offered.isEmpty, !sending else { return }
        guard let session = model.store.find(sessionID) else { return }
        sending = true
        defer { sending = false }
        error = nil
        let before = model.settings.targets(secrets: model.keychain)
        guard !before.isEmpty else {
            status = Self.noTargetOn
            return
        }
        let missing = Set(AskRules.targetsMissing(pendingItems, targets: before.map(\.id), delivered: delivered))
        guard !missing.isEmpty else {
            pendingItems = []
            status = Self.everyTargetHasThem
            return
        }
        let labels = delivered.isEmpty ? nil
            : before.filter { missing.contains($0.id) && !($0 is UnavailableTarget) }.map(\.label)
        guard let items = await model.confirmNewItems(session, notes, only: offered, targets: labels) else { return }
        let on = model.settings.targets(secrets: model.keychain).map(\.id)
        guard !on.isEmpty else {
            status = Self.noTargetOn
            return
        }
        let sends = AskRules.extraSends(items, targets: on, delivered: delivered)
        var results: [String: DispatchResult] = [:]
        do {
            for send in sends {
                let sent = try await model.pipeline.sendExtra(sessionID: sessionID, items: send.items,
                                                              targets: send.targets)
                delivered = AskRules.delivered(delivered, after: send, results: sent)
                results.merge(sent) { _, new in new }
            }
            status = !items.isEmpty && sends.isEmpty ? Self.everyTargetHasThem : summary(results)
        } catch {
            self.error = Self.describe(error)
            // A send that stopped part-way still says which targets took the items before it stopped.
            if !results.isEmpty { status = summary(results) }
        }
        if !items.isEmpty, AskRules.targetsMissing(items, targets: on, delivered: delivered).isEmpty { pendingItems = [] }
        model.refresh()
    }

    static let everyTargetHasThem = "Every target that is on already has these items."
    static let noTargetOn = "No target is switched on. Switch one on in Settings to send these."

    func summary(_ results: [String: DispatchResult]) -> String {
        let labels = Dictionary(model.settings.targets(secrets: model.keychain).map { ($0.id, $0.label) },
                                uniquingKeysWith: { first, _ in first })
        let lines = results.keys.sorted().map { id -> String in
            let label = labels[id] ?? id
            guard let result = results[id], !result.ok else { return "Sent to \(label)." }
            return "\(label): \(result.detail)"
        }
        return lines.isEmpty ? "Nothing was sent." : lines.joined(separator: "\n")
    }

    static func describe(_ error: any Error) -> String {
        String(((error as? LocalizedError)?.errorDescription ?? error.localizedDescription).prefix(300))
    }
}

struct AskView: View {
    /// The size the window opens at. It can be resized from there.
    static let size = CGSize(width: 560, height: 520)
    @Bindable var controller: AskController

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("Ask or fix", selection: $controller.tab) {
                Text("Ask").tag(AskController.Tab.ask)
                Text("Fix the notes").tag(AskController.Tab.fix)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            if !controller.loaded {
                ProgressView().frame(maxWidth: .infinity)
            } else if controller.tab == .ask {
                AskPane(controller: controller)
            } else {
                FixPane(controller: controller)
            }
            if let error = controller.error { Text(error).font(.caption).foregroundStyle(Brand.redText) }
            if let status = controller.status { Text(status).font(.caption).foregroundStyle(.secondary) }
        }
        .padding(20)
        .frame(minWidth: 480, idealWidth: 560, maxWidth: .infinity, minHeight: 400, idealHeight: 520,
               maxHeight: .infinity)
        .task { await controller.load() }
        .onChange(of: controller.model.activity[controller.sessionID]) { Task { await controller.refreshRunning() } }
    }
}

struct AskPane: View {
    @Bindable var controller: AskController

    var body: some View {
        // The newest answer is scrolled into view when it arrives, and when the window opens on earlier ones.
        ScrollViewReader { reader in
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if controller.entries.isEmpty {
                        Text("Ask about what was said, who agreed to what, or what was decided. Answers quote the "
                            + "time it was said.").foregroundStyle(.secondary)
                    }
                    ForEach(Array(controller.entries.enumerated()), id: \.offset) { index, entry in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(entry.question).bold()
                            Text(entry.answer).textSelection(.enabled)
                        }
                        .id(index)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: .infinity)
            .onAppear { scrollToNewest(reader, animated: false) }
            .onChange(of: controller.entries.count) { scrollToNewest(reader, animated: true) }
        }
        HStack {
            TextField("Ask a question", text: $controller.question, axis: .vertical)
                .lineLimit(1...4)
                .onSubmit { controller.startAsk() }
            Button(controller.asking ? "Asking…" : "Ask") { controller.startAsk() }
                .keyboardShortcut(.defaultAction)
                .disabled(controller.asking || controller.question.trimmingCharacters(in: .whitespaces).isEmpty)
        }
    }
}

extension AskPane {
    private func scrollToNewest(_ reader: ScrollViewProxy, animated: Bool) {
        guard !controller.entries.isEmpty else { return }
        let newest = controller.entries.count - 1
        if animated {
            withAnimation { reader.scrollTo(newest, anchor: .top) }
        } else {
            reader.scrollTo(newest, anchor: .top)
        }
    }
}

struct FixPane: View {
    @Bindable var controller: AskController

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if controller.notes == nil {
                Text("This meeting has no notes to fix yet.").foregroundStyle(.secondary)
            } else if controller.running {
                Text("Earshot is still working on this meeting. Fix is available when it's done.")
                    .foregroundStyle(.secondary)
            }
            Text("Say what's wrong, for example \"Ashley owns the proposal, not me\" or \"add the pricing decision\".")
                .font(.caption).foregroundStyle(.secondary)
            TextField("What should change?", text: $controller.instruction, axis: .vertical)
                .lineLimit(2...5)
                .disabled(!controller.canFix || controller.revised != nil)
            HStack {
                Button(controller.fixing ? "Fixing…" : "Fix") { controller.startFix() }
                    .disabled(!controller.canFix || controller.fixing || controller.revised != nil
                        || controller.instruction.trimmingCharacters(in: .whitespaces).isEmpty)
                if controller.fixing { ProgressView().controlSize(.small) }
            }
            if let diff = controller.diff { review(diff) }
            if !controller.newItems.isEmpty {
                Button(AskRules.sendNewItemsLabel(controller.newItems.count)) { Task { await controller.sendNewItems() } }
                    .disabled(controller.sending)
            }
            Spacer()
        }
    }

    func review(_ diff: NotesDiff) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                Text(diff.text)
                ForEach(Array(diff.added.enumerated()), id: \.offset) { _, item in
                    Label(item.task, systemImage: "plus.circle").foregroundStyle(Brand.greenText)
                        .accessibilityLabel("Added: \(item.task)")
                }
                ForEach(Array(diff.removed.enumerated()), id: \.offset) { _, item in
                    Label(item.task, systemImage: "minus.circle").foregroundStyle(Brand.redText)
                        .accessibilityLabel("Removed: \(item.task)")
                }
                ForEach(Array(diff.changed.enumerated()), id: \.offset) { _, change in
                    Label("\(change.before.task) → \(change.after.task) (\(change.after.owner))",
                          systemImage: "pencil.circle")
                        .accessibilityLabel("Changed: \(change.before.task), now \(change.after.task), "
                            + "owner \(change.after.owner)")
                }
                HStack {
                    Button("Discard") { controller.discard() }
                    Spacer()
                    Button(controller.saving ? "Saving…" : "Save") { Task { await controller.save() } }
                        .keyboardShortcut(.defaultAction)
                        .disabled(controller.saving || diff.isEmpty || !controller.canFix)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
