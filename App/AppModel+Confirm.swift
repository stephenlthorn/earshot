import EarshotKit
import Foundation

/// One confirm window's worth of work: a meeting's action items, or only the new ones a Fix added.
struct ConfirmRequest: Identifiable {
    let id = UUID()
    let session: Session
    let notes: MeetingNotes
    /// live.json's to-dos, so items started during the call are shown locked.
    let live: [LiveItem]
    /// Notes indices to show, for the new items after a Fix; nil shows every item.
    let only: [Int]?
    /// The targets that will run.
    let targets: [String]
    /// Why a target that is switched on can't run. Sending to it fails with this, and Retry sends again.
    let problems: [String]
}

extension AppModel {
    /// The pipeline's confirm step (spec 5.3 and 6). The window opens unless `ConfirmPolicy` lets the user's
    /// "send without asking" stand; then the default selection goes, minus items started during the call.
    func askToConfirm(_ session: Session, _ notes: MeetingNotes, store: SessionStore) async -> [ActionItem]? {
        let live = Self.liveItems(session, in: store)
        guard ConfirmPolicy.mustAsk(session: session, settings: settings) else {
            return ConfirmDraft.defaultItems(notes: notes, live: live)
        }
        return await confirm(session, notes, live: live, only: nil)
    }

    /// The confirm window for the items a Fix added after Do already ran (spec 8). `targets`: the labels the window
    /// names when only some targets still need these items; nil names every switched-on target.
    func confirmNewItems(_ session: Session, _ notes: MeetingNotes, only: [Int],
                         targets: [String]? = nil) async -> [ActionItem]? {
        await confirm(session, notes, live: Self.liveItems(session, in: store), only: only, targets: targets)
    }

    private func confirm(_ session: Session, _ notes: MeetingNotes, live: [LiveItem], only: [Int]?,
                         targets: [String]? = nil) async -> [ActionItem]? {
        await withCheckedContinuation { reply in
            let request = ConfirmRequest(session: session, notes: notes, live: live, only: only,
                                         targets: targets ?? settings.doTargetLabels(),
                                         problems: settings.doTargetProblems())
            pendingConfirms.append((request, reply))
            if pendingConfirms.count == 1 { showConfirm() }
        }
    }

    /// Send (with the items and the lessons the window worked out) or Skip and close (nil, no lessons). Lessons are
    /// saved only on Send, with "Learn from my edits" on, and never in e2e runs (spec 6).
    func answerConfirm(_ items: [ActionItem]?, lessons: [Lesson] = []) {
        guard !pendingConfirms.isEmpty else { return }
        if items != nil { saveLessons(lessons) }
        pendingConfirms.removeFirst().reply.resume(returning: items)
        windows.close("confirm")
        if !pendingConfirms.isEmpty { showConfirm() }
    }

    func showConfirm() {
        windows.show("confirm", title: "Send action items", onClose: { [weak self] in self?.answerConfirm(nil) }) {
            ConfirmView(model: self)
        }
    }

    /// Stores lessons off the main actor, since the store may wait for another writer. A failure is shown in the
    /// menu, because the user expects Earshot to remember.
    func saveLessons(_ lessons: [Lesson]) {
        guard settings.learnFromEdits, !e2e, !lessons.isEmpty else { return }
        let store = LessonsStore(url: dataLocations.lessons)
        Task {
            do {
                try await Task.detached { try store.add(lessons) }.value
            } catch {
                banner = "Couldn't save what Earshot learned: \(error.localizedDescription)"
            }
        }
    }

    /// live.json's to-dos, or none when there is no file or it can't be read. The pipeline reads it again before
    /// sending, so an item started during the call is never sent twice.
    static func liveItems(_ session: Session, in store: SessionStore) -> [LiveItem] {
        ((try? store.readIfPresent(LiveFile.self, session, MeetingFile.live)) ?? nil)?.items ?? []
    }
}
