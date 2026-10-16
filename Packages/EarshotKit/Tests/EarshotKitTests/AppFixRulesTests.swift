import Foundation
import Testing
@testable import EarshotKit

/// Switching off screen reading or the live assistant during a recording stops it at once (spec 4.1 and 9).
struct RecordingSwitchesTests {
    private func settings(_ change: (inout EarshotSettings) -> Void) -> EarshotSettings {
        var settings = EarshotSettings()
        change(&settings)
        return settings
    }

    @Test func turningScreenReadingOffStopsIt() {
        let on = settings { $0.readScreen = true }, off = settings { $0.readScreen = false }
        #expect(RecordingSwitches.stopsScreenReading(from: on, to: off))
        #expect(!RecordingSwitches.stopsScreenReading(from: on, to: on))
        #expect(!RecordingSwitches.stopsScreenReading(from: off, to: off))
        #expect(!RecordingSwitches.stopsScreenReading(from: off, to: on))
    }

    @Test func otherChangesLeaveScreenReadingAlone() {
        let on = settings { $0.readScreen = true }
        let changed = settings { $0.readScreen = true; $0.liveAssistant = true; $0.keepScreenshots = true }
        #expect(!RecordingSwitches.stopsScreenReading(from: on, to: changed))
    }

    @Test func turningTheLiveAssistantOffStopsIt() {
        let on = settings { $0.liveAssistant = true }, off = settings { $0.liveAssistant = false }
        #expect(RecordingSwitches.stopsLiveAssistant(from: on, to: off))
        #expect(!RecordingSwitches.stopsLiveAssistant(from: on, to: on))
        #expect(!RecordingSwitches.stopsLiveAssistant(from: off, to: on))
        #expect(!RecordingSwitches.stopsLiveAssistant(from: off, to: off))
    }

    @Test func thePanelLineIsPlain() {
        #expect(RecordingSwitches.liveOffLine == "The live assistant is off until the next recording.")
    }
}

/// "Write notes" on a finished Record meeting (spec 8 and the I2 fixes). Not named RecordingNotesTests: I2a's
/// pipeline tests use that name.
struct WriteNotesButtonTests {
    private func session(_ mode: Mode, recording: Bool = false, done: Bool = true) -> Session {
        var session = Session(id: "s1", folderName: "s1", title: nil, mode: mode, startedAt: at1530, endedAt: nil,
                              recording: recording, tracks: [], stages: [:], sent: [], warnings: [])
        for stage in mode.stages { session.stages[stage] = StageState(status: done ? .done : .pending) }
        return session
    }

    @Test func aFinishedRecordMeetingOffersWriteNotes() {
        #expect(RecordingNotes.canWrite(session(.record), busy: false))
        #expect(RecordingNotes.buttonLabel == "Write notes")
    }

    @Test func notWhileRecordingBusyOrUnfinished() {
        #expect(!RecordingNotes.canWrite(session(.record, recording: true), busy: false))
        #expect(!RecordingNotes.canWrite(session(.record), busy: true))
        #expect(!RecordingNotes.canWrite(session(.record, done: false), busy: false))
    }

    @Test func notesMeetingsDoNotOfferIt() {
        #expect(!RecordingNotes.canWrite(session(.notes), busy: false))
        #expect(!RecordingNotes.canWrite(session(.notesAndDo), busy: false))
    }
}

/// The library index is reconciled at launch, so meetings deleted in Finder disappear (spec 11.1).
struct LaunchIndexRefreshTests {
    let h = LibraryHarness()

    @Test func aMeetingDeletedInFinderLeavesTheIndex() throws {
        let kept = try h.meeting("Kept", daysAgo: 1, notes: LibraryHarness.notes("Kept"))
        let gone = try h.meeting("Gone", daysAgo: 2, notes: LibraryHarness.notes("Gone"))
        let missing = try h.meeting("Missing", daysAgo: 3, notes: LibraryHarness.notes("Missing"), index: false)
        try FileManager.default.removeItem(at: h.store.folder(gone))

        let problems = h.index.refreshAtLaunch(with: h.store, userName: "Stephen", now: at1530)

        #expect(problems.isEmpty)
        #expect(Set(h.index.entries().map(\.id)) == [kept.id, missing.id])
        #expect(h.index.reminders() != nil)
    }

    @Test func problemsAreReturnedNotThrown() throws {
        let blocked = try h.meeting("Blocked", daysAgo: 2, index: false)
        let fine = try h.meeting("Fine", daysAgo: 1, index: false)
        try FileManager.default.createDirectory(at: h.index.file(blocked.id), withIntermediateDirectories: true)

        let problems = h.index.refreshAtLaunch(with: h.store, userName: "", now: at1530)

        #expect(problems.count == 1)
        #expect(h.index.entry(id: fine.id) != nil)
        #expect(h.index.reminders() != nil)
    }
}
