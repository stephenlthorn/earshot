import Foundation
import Testing
@testable import EarshotKit

/// Stopping a recording (spec 14.3): it is always closed on disk, and waiting on the screen reader never holds up the
/// notes for long. Plus who a notification can reach (spec 7.2).
extension StartTests {
    @Suite struct FinishRecordingTests {
        let store = SessionStore(root: tempDir(), timeZone: newYork)
        let track = TrackFile(track: .me, file: "mic.caf", offset: 0)
        let ended = at1530.addingTimeInterval(1800)

        @Test func closesTheMeetingOnDiskAndKeepsWhatWasSavedDuringTheRecording() throws {
            let session = try store.create(mode: .notes, title: "Acme", now: at1530)
            _ = try store.update(session.id) { $0.calendarEvent = StartTests.event() }
            let closed = try store.finishRecording(session, tracks: [track], warnings: ["quiet"], endedAt: ended)
            let saved = try #require(store.find(session.id))
            #expect(saved == closed)
            #expect(!saved.recording)
            #expect(saved.endedAt == ended)
            #expect(saved.tracks == [track])
            #expect(saved.warnings == ["quiet"])
            #expect(saved.calendarEvent == StartTests.event())
        }

        @Test func aMissingSessionFileIsWrittenFromMemory() throws {
            let session = try store.create(mode: .notes, title: "Acme", now: at1530)
            try FileManager.default.removeItem(at: store.file(session, SessionStore.fileName))
            try store.finishRecording(session, tracks: [track], warnings: [], endedAt: ended)
            let saved = try store.load(folderName: session.folderName)
            #expect(!saved.recording)
            #expect(saved.endedAt == ended)
            #expect(saved.tracks == [track])
        }

        @Test func aBrokenSessionFileIsWrittenFromMemory() throws {
            let session = try store.create(mode: .notes, title: "Acme", now: at1530)
            try Data("{ not json".utf8).write(to: store.file(session, SessionStore.fileName))
            try store.finishRecording(session, tracks: [track], warnings: ["w"], endedAt: ended)
            let saved = try store.load(folderName: session.folderName)
            #expect(!saved.recording)
            #expect(saved.warnings == ["w"])
        }

        @Test func throwsOnlyWhenNeitherWayCanSave() throws {
            let session = try store.create(mode: .notes, title: "Acme", now: at1530)
            try FileManager.default.removeItem(at: store.folder(session))
            #expect(throws: (any Error).self) {
                try store.finishRecording(session, tracks: [], warnings: [], endedAt: ended)
            }
        }
    }

    @Suite struct TaskWaitTests {
        @Test func aFinishedTaskIsDoneAtOnce() async {
            let task = Task<Void, Never> {}
            #expect(await TaskWait.finished(task, within: .seconds(5)))
        }

        @Test func aTaskThatHangsIsGivenUpOnAfterTheLimit() async {
            let hung = Task<Void, Never> { try? await Task.sleep(for: .seconds(60)) }
            let started = ContinuousClock.now
            #expect(!(await TaskWait.finished(hung, within: .milliseconds(100))))
            #expect(ContinuousClock.now - started < .seconds(5))
            hung.cancel()
        }
    }

    @Suite struct NotificationReachTests {
        @Test func onlyAllowedNotificationsThatShowAnAlertReachTheUser() {
            #expect(NotificationRoute.reachesUser(allowed: true, provisional: false, alertsShown: true))
            #expect(!NotificationRoute.reachesUser(allowed: true, provisional: false, alertsShown: false))
            #expect(!NotificationRoute.reachesUser(allowed: false, provisional: false, alertsShown: true))
            // Provisional notifications go quietly to Notification Center.
            #expect(!NotificationRoute.reachesUser(allowed: false, provisional: true, alertsShown: true))
        }
    }
}
