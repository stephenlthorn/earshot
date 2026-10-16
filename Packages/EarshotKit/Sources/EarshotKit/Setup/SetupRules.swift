import Foundation

/// Which welcome window opens at launch (spec 15): onboarding for a new user, "New in Earshot 0.3" once for an
/// upgrading one (from 0.1 or 0.2).
public enum WelcomeSheet: Equatable, Sendable {
    case onboarding
    case whatsNew

    /// The `onboardedVersion` a user has once they have seen this version's welcome.
    /// 3 is "New in Earshot 0.3", the local model provider.
    public static let currentVersion = 3

    /// - Parameters:
    ///   - onboarded: v1's flag, set when the first onboarding was finished.
    ///   - onboardedVersion: the saved setting.
    public static func which(onboarded: Bool, onboardedVersion: Int) -> WelcomeSheet? {
        guard onboardedVersion < currentVersion else { return nil }
        return onboarded ? .whatsNew : .onboarding
    }

    /// What's New also lists what 0.2 added, for users coming from 0.1 (who never saw "New in v0.2").
    public static func shows02Points(onboardedVersion: Int) -> Bool { onboardedVersion < 2 }
}

/// Advice Settings and onboarding give about Claude use (spec 3.1 and 3.3).
public enum ClaudeAdvice {
    public static let proHint = "On a Pro plan, Sonnet is a good choice for notes. Leave the live assistant off "
        + "so your usage lasts."
    public static let defaultCallsLine = "About 40 live calls an hour at the default interval"
    /// The live assistant's interval choices, in seconds (spec 4.3).
    public static let liveIntervals = [60, 90, 120, 180]
    /// The model names Settings suggests.
    public static let suggestedModels = ["claude-opus-5-5", "claude-sonnet-5-5"]

    /// True when Claude Code is signed in to a Pro plan.
    public static func isProPlan(_ status: ClaudeCodeStatus?) -> Bool {
        guard let status, status.state == .ready else { return false }
        return status.subscription?.lowercased() == "pro"
    }

    /// How many live passes an hour of talk can use at `interval` seconds.
    public static func callsPerHour(interval: Int) -> Int {
        interval > 0 ? Int((3600.0 / Double(interval)).rounded()) : 0
    }

    public static func callsLine(interval: Int) -> String {
        "About \(callsPerHour(interval: interval)) live calls an hour"
    }
}

/// The one-time offer to move from `auto` or `bypassPermissions` to `restricted` (spec 14.2).
public enum PermissionNotice {
    public static let text = "Claude Code now has a Restricted mode: it only reads and writes files in the work "
        + "folder and can't run commands. It's the safer choice for work that comes from meetings."
    static let offeredModes: Set<String> = ["auto", "bypassPermissions"]

    public static func shouldOffer(permissionMode: String, dismissed: Bool) -> Bool {
        !dismissed && offeredModes.contains(permissionMode)
    }

    /// True when finishing `sheet` settles the offer for good: a new user never had a v1 mode to move from, and an
    /// upgrading user without auto or bypassPermissions saved has nothing to be offered. A later choice of Auto by
    /// hand then never brings the notice up.
    public static func answeredByWelcome(_ sheet: WelcomeSheet, permissionMode: String) -> Bool {
        sheet == .onboarding || !offeredModes.contains(permissionMode)
    }
}

/// What a meeting row opens (spec 10): notes.html, then notes.md, then the folder.
public enum MeetingOpener {
    public static func target(folder: URL, exists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> URL {
        [MeetingFile.notesPage, MeetingFile.notesMarkdown].map { folder.appending(path: $0) }
            .first { exists($0.path) } ?? folder
    }
}

/// When Ask and Fix are offered, and what a Fix adds (spec 8).
public enum AskRules {
    /// Ask needs a transcript, so it is hidden for Record-only meetings and while recording.
    public static func canAsk(_ session: Session, hasTranscript: Bool) -> Bool {
        hasTranscript && !session.recording
    }

    /// Fix needs notes to fix, and the pipeline must not be working on the meeting.
    public static func canFix(hasNotes: Bool, running: Bool) -> Bool {
        hasNotes && !running
    }

    /// True when a Notes + Do meeting already went through Do: its stage finished, or items were chosen
    /// (items.json exists, for example after a send that failed). Then Fix's new items are offered separately.
    public static func doAlreadyRan(_ session: Session, itemsChosen: Bool) -> Bool {
        guard session.mode == .notesAndDo else { return false }
        return session.stages[.dispatch]?.status == .done || itemsChosen
    }

    /// Ask's row check without reading the disk: the transcribe stage finished, so transcript.json was written.
    public static func hasTranscript(_ session: Session) -> Bool {
        session.stages[.transcribe]?.status == .done
    }

    /// The indices in `new` of the action items a Fix added (`NotesDiff`'s added items), in order.
    public static func newItems(old: MeetingNotes, new: MeetingNotes) -> [Int] {
        indices(of: NotesDiff.compare(old, new).added, in: new)
    }

    /// Where `items` sit in `notes`, in notes order. Each notes item matches one copy at most, and `source` is ignored.
    public static func indices(of items: [ActionItem], in notes: MeetingNotes) -> [Int] {
        var left = items.map(NotesDiff.stripped)
        return notes.actionItems.indices.filter { index in
            guard let match = left.firstIndex(of: NotesDiff.stripped(notes.actionItems[index])) else { return false }
            left.remove(at: match)
            return true
        }
    }

    /// The new items still waiting to be sent after a Fix from `old` to `new`: the earlier unsent ones carried through
    /// it (a changed one follows its change, a removed one drops out) plus the ones this Fix added, in notes order.
    public static func pending(_ earlier: [ActionItem], old: MeetingNotes, new: MeetingNotes) -> [ActionItem] {
        let diff = NotesDiff.compare(old, new)
        let carried = earlier.map(NotesDiff.stripped).map { item in
            diff.changed.first { $0.before == item }?.after ?? item
        }
        return indices(of: carried + diff.added, in: new).map { NotesDiff.stripped(new.actionItems[$0]) }
    }

    /// True when every target took the new items, so the offer to send them can go.
    public static func sentToEveryTarget(_ results: [String: DispatchResult]) -> Bool {
        !results.isEmpty && results.values.allSatisfy(\.ok)
    }

    public static func sendNewItemsLabel(_ count: Int) -> String {
        count == 1 ? "Send the 1 new item…" : "Send the \(count) new items…"
    }
}
