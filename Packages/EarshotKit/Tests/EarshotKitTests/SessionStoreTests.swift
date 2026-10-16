import Foundation
import Testing
@testable import EarshotKit

struct SessionStoreTests {
    let store = SessionStore(root: tempDir(), timeZone: newYork)

    @Test func createMakesADatedFolderWithPendingStages() throws {
        let s = try store.create(mode: .notesAndDo, title: "Acme kickoff", now: at1530)
        #expect(s.folderName == "2026-10-14 1530 Acme kickoff")
        #expect(s.id.wholeMatch(of: /2026-10-14-1530-[0-9a-f]{4}/) != nil)
        #expect(s.recording)
        #expect(Set(s.stages.keys) == [.transcribe, .notes, .dispatch, .compress])
        #expect(s.stages.values.allSatisfy { $0.status == .pending })
        #expect(FileManager.default.fileExists(atPath: store.file(s, "session.json").path))
    }

    @Test func eachModeRunsItsStagesInOrder() {
        #expect(Mode.record.stages == [.compress])
        #expect(Mode.notes.stages == [.transcribe, .notes, .compress])
        #expect(Mode.notesAndDo.stages == [.transcribe, .notes, .dispatch, .compress])
    }

    @Test func titlesAreCleanedAndFoldersStayUnique() throws {
        let a = try store.create(mode: .record, title: "Acme / kickoff:\nv2", now: at1530)
        let b = try store.create(mode: .record, title: "Acme / kickoff:\nv2", now: at1530)
        let c = try store.create(mode: .record, title: nil, now: at1530)
        #expect(a.folderName == "2026-10-14 1530 Acme kickoff v2")
        #expect(b.folderName == "2026-10-14 1530 Acme kickoff v2 2")
        #expect(c.folderName == "2026-10-14 1530")
    }

    @Test func meetingsCreatedAtTheSameMomentNeverShareAFolder() throws {
        let count = 48
        let made = Locked<[Result<Session, any Error>]>([])
        let store = store
        DispatchQueue.concurrentPerform(iterations: count) { _ in
            let result = Result { try store.create(mode: .record, title: "Standup", now: at1530) }
            made.update { $0.append(result) }
        }
        let sessions = try made.get.map { try $0.get() }
        #expect(Set(sessions.map(\.folderName)).count == count)
        #expect(Set(store.all().map(\.id)) == Set(sessions.map(\.id)), "each folder holds its own meeting")
    }

    @Test func aFolderMadeBetweenTheCheckAndTheCreateIsSkipped() throws {
        let base = "2026-10-14 1530 Race"
        // Someone else takes the first two names while Earshot picks one.
        let name = try store.makeUniqueFolder(base: base) { candidate in
            if candidate == base || candidate == "\(base) 2" {
                try? FileManager.default.createDirectory(at: store.root.appending(path: candidate),
                                                         withIntermediateDirectories: true)
            }
        }
        #expect(name == "\(base) 3")
        #expect(try FileManager.default.contentsOfDirectory(atPath: store.root.path).sorted() == [base, "\(base) 2", "\(base) 3"])
    }

    @Test func aSaveFolderThatCantBeWrittenFailsPlainly() throws {
        try FileManager.default.createDirectory(at: store.root, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: store.root.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: store.root.path) }
        let error = #expect(throws: CocoaError.self) {
            try store.create(mode: .record, title: "Locked out", now: at1530)
        }
        #expect(error?.code == .fileWriteNoPermission)
    }

    @Test func saveAndLoadRoundTrip() throws {
        var s = try store.create(mode: .notes, title: "Sync", now: at1530)
        s.recording = false
        s.endedAt = at1530.addingTimeInterval(600)
        s.tracks = [TrackFile(track: .me, file: "mic.caf", offset: 0), TrackFile(track: .them, file: "system.caf", offset: 0.25)]
        s.stages[.transcribe] = StageState(status: .failed, error: "boom", failures: 1)
        try store.save(s)
        #expect(try store.load(folderName: s.folderName) == s)
    }

    @Test func aSessionJSONWrittenBeforeInFlightExistedStillLoads() throws {
        let s = try store.create(mode: .notesAndDo, title: "Older version", now: at1530)
        let url = store.file(s, SessionStore.fileName)
        var object = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        #expect(object.removeValue(forKey: "inFlight") != nil)
        try JSONSerialization.data(withJSONObject: object).write(to: url)
        let loaded = try store.load(folderName: s.folderName)
        #expect(loaded.inFlight.isEmpty && loaded == s)
    }

    @Test func recoverResetsRunningStagesAndClosesRecordings() throws {
        var s = try store.create(mode: .notes, title: "Crash", now: at1530)
        s.stages[.transcribe]?.status = .running
        try store.save(s)
        let recovered = try #require(try store.recover(now: at1530.addingTimeInterval(60)).first)
        #expect(recovered.recording == false)
        #expect(recovered.endedAt != nil)
        #expect(recovered.stages[.transcribe]?.status == .pending)
        #expect(recovered.warnings.contains { $0.contains("interrupted") })
        #expect(try store.load(folderName: s.folderName) == recovered)
    }

    @Test func resumableSkipsRecordingFinishedAndTwiceFailed() throws {
        var pending = try store.create(mode: .notes, title: "Pending", now: at1530)
        pending.recording = false
        try store.save(pending)
        _ = try store.create(mode: .notes, title: "Still recording", now: at1530)
        var done = try store.create(mode: .record, title: "Done", now: at1530)
        done.recording = false
        done.stages[.compress]?.status = .done
        try store.save(done)
        var failed = try store.create(mode: .notes, title: "Failed twice", now: at1530)
        failed.recording = false
        failed.stages[.transcribe] = StageState(status: .failed, error: "x", failures: 2)
        try store.save(failed)
        #expect(store.resumable().map(\.title) == ["Pending"])
    }

    @Test func retitleRenamesTheFolderAndKeepsFiles() throws {
        let s = try store.create(mode: .notes, title: nil, now: at1530)
        try Data("audio".utf8).write(to: store.file(s, "mic.caf"))
        let renamed = try store.retitle(s, to: "Acme: pilot dates")
        #expect(renamed.folderName == "2026-10-14 1530 Acme pilot dates")
        #expect(renamed.title == "Acme: pilot dates")
        #expect(FileManager.default.fileExists(atPath: store.file(renamed, "mic.caf").path))
        #expect(try store.load(folderName: renamed.folderName) == renamed)
    }

    @Test func loadUsesTheFolderItWasReadFrom() throws {
        let s = try store.create(mode: .notes, title: "Moved in Finder", now: at1530)
        try FileManager.default.moveItem(at: store.folder(s), to: store.root.appending(path: "renamed", directoryHint: .isDirectory))
        #expect(try store.load(folderName: "renamed").folderName == "renamed")
        #expect(store.all().first?.folderName == "renamed")
    }

    @Test func recoverKeepsGoingPastASessionItCannotSave() throws {
        let good = try store.create(mode: .notes, title: "Good", now: at1530)
        // Newer than `good`, so `all()` hands it to recover first.
        let bad = try store.create(mode: .notes, title: "Bad", now: at1530.addingTimeInterval(60))
        // An atomic write needs to create a file next to session.json, so a read-only folder cannot be saved.
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: store.folder(bad).path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: store.folder(bad).path) }

        let recovered = try store.recover(now: at1530.addingTimeInterval(120))

        #expect(recovered.map(\.folderName) == [good.folderName])
        #expect(try store.load(folderName: good.folderName).recording == false)
    }

    @Test func readAndWriteHelpersUseTheMeetingFolder() throws {
        let s = try store.create(mode: .notes, title: "Files", now: at1530)
        #expect(try store.readIfPresent(MeetingBrief.self, s, MeetingFile.brief) == nil)
        let brief = MeetingBrief(eventID: nil, model: "m", createdAt: at1530, headline: "H")
        try store.write(brief, s, MeetingFile.brief)
        #expect(try store.read(MeetingBrief.self, s, MeetingFile.brief) == brief)
        try Data("{".utf8).write(to: store.file(s, MeetingFile.qa))
        #expect(throws: (any Error).self) { try store.readIfPresent(QAFile.self, s, MeetingFile.qa) }
    }

    @Test func updateRereadsSoAnotherWritersChangeSurvives() throws {
        let s = try store.create(mode: .notes, title: "Flags", now: at1530)
        var stale = s
        // Someone else adds a flag after we read the session.
        try store.update(s.id) { $0.flags.append(Flag(offset: 5, source: .hotkey)) }
        stale.stages[.transcribe]?.status = .done
        let updated = try store.update(s.id) { $0.stages[.transcribe] = stale.stages[.transcribe] }
        #expect(updated.flags == [Flag(offset: 5, source: .hotkey)])
        #expect(updated.stages[.transcribe]?.status == .done)
        #expect(try store.load(folderName: s.folderName) == updated)
    }

    @Test func updateKeepsTheIdAndFolderAndFindsRenamedFolders() throws {
        let s = try store.create(mode: .notes, title: "Moved", now: at1530)
        try FileManager.default.moveItem(at: store.folder(s), to: store.root.appending(path: "elsewhere", directoryHint: .isDirectory))
        let updated = try store.update(s.id) { session in
            session.id = "other"
            session.folderName = "nowhere"
            session.notesRevision = 3
        }
        #expect(updated.id == s.id && updated.folderName == "elsewhere" && updated.notesRevision == 3)
        #expect(throws: SessionStoreError.notFound("missing")) { try store.update("missing") { _ in } }
    }

    @Test func concurrentUpdatesNeverLoseAChange() async throws {
        let s = try store.create(mode: .notes, title: "Busy", now: at1530)
        let store = self.store
        await withTaskGroup(of: Void.self) { group in
            for n in 0..<24 {
                group.addTask {
                    _ = try? store.update(s.id) { $0.flags.append(Flag(offset: Double(n), source: .panel)) }
                }
            }
        }
        let flags = try store.load(folderName: s.folderName).flags
        #expect(Set(flags.map(\.offset)) == Set((0..<24).map(Double.init)))
    }

    @Test func aLiveBusyMarkerKeepsRecoverAndResumeAway() throws {
        var busy = try store.create(mode: .notes, title: "CLI meeting", now: at1530)
        busy.stages[.transcribe]?.status = .running
        busy.recording = false
        try store.save(busy)
        try store.markBusy(busy)
        #expect(store.isBusy(busy))
        #expect(try store.recover(now: at1530).isEmpty)
        #expect(try store.load(folderName: busy.folderName).stages[.transcribe]?.status == .running)
        #expect(store.resumable().isEmpty)

        store.clearBusy(busy)
        #expect(!store.isBusy(busy))
        #expect(try store.recover(now: at1530).map(\.id) == [busy.id])
        #expect(store.resumable().map(\.id) == [busy.id])
    }

    @Test func aMarkerFromADeadProcessDoesNotCount() throws {
        let s = try store.create(mode: .notes, title: "Stale", now: at1530)
        try store.markBusy(s, pid: Int32.max)
        #expect(!store.isBusy(s))
        try Data("garbage".utf8).write(to: store.file(s, MeetingFile.busy))
        #expect(!store.isBusy(s))
        #expect(SessionStore.processIsAlive(ProcessInfo.processInfo.processIdentifier))
        #expect(!SessionStore.processIsAlive(0))
    }

    @Test func aRecordingMeetingThatIsBusyIsLeftUntouched() throws {
        let s = try store.create(mode: .notes, title: "CLI recording", now: at1530, busyPID: ProcessInfo.processInfo.processIdentifier)
        let before = try Data(contentsOf: store.file(s, MeetingFile.session))
        #expect(try store.recover(now: at1530).isEmpty)
        #expect(try Data(contentsOf: store.file(s, MeetingFile.session)) == before)
        #expect(try store.load(folderName: s.folderName).recording)
    }

    @Test func createAndImportCanMarkTheMeetingBusyBeforeItIsSaved() throws {
        let pid = ProcessInfo.processInfo.processIdentifier
        let created = try store.create(mode: .notes, title: "CLI", now: at1530, busyPID: pid)
        #expect(store.isBusy(created))
        let source = tempDir().appending(path: "memo.m4a")
        try Data("memo".utf8).write(to: source)
        let imported = try store.importAudio(from: source, mode: .notes, startedAt: at1530, duration: 60, busyPID: pid)
        #expect(store.isBusy(imported) && imported.nextStage == .transcribe && !imported.recording)
        #expect(store.resumable().isEmpty)
        #expect(try store.recover(now: at1530).isEmpty)
        store.clearBusy(imported)
        #expect(store.resumable().map(\.id) == [imported.id])
        // Without a PID nothing is marked.
        #expect(!store.isBusy(try store.create(mode: .notes, title: nil, now: at1530)))
    }

    @Test func aReusedPIDDoesNotKeepAMeetingBusy() throws {
        let s = try store.create(mode: .notes, title: "Reused", now: at1530)
        let pid = ProcessInfo.processInfo.processIdentifier
        try store.markBusy(s)
        let marker = try String(contentsOf: store.file(s, MeetingFile.busy), encoding: .utf8)
        #expect(marker.split(separator: " ").count == 3)
        #expect(store.isBusy(s))
        // The same PID, but a process that started at another time: the marker's owner is gone.
        try Data("\(pid) 12345 0\n".utf8).write(to: store.file(s, MeetingFile.busy))
        #expect(!store.isBusy(s))
        // A marker with only a PID still counts while that PID is alive.
        try Data("\(pid)\n".utf8).write(to: store.file(s, MeetingFile.busy))
        #expect(store.isBusy(s))
    }

    @Test func retitleKeepsChangesMadeSinceTheCallerReadTheSession() throws {
        let s = try store.create(mode: .notes, title: nil, now: at1530)
        try store.update(s.id) { $0.flags.append(Flag(offset: 3, source: .hotkey)) }
        let renamed = try store.retitle(s, to: "Acme")
        #expect(renamed.flags == [Flag(offset: 3, source: .hotkey)] && renamed.title == "Acme")
        #expect(try store.load(folderName: renamed.folderName) == renamed)
        // A caller holding an old folder name still finds the meeting.
        let again = try store.retitle(s, to: "Acme pricing")
        #expect(again.folderName == "2026-10-14 1530 Acme pricing" && again.flags.count == 1)
    }

    @Test func updatesRacingARetitleAreNeverLost() async throws {
        let s = try store.create(mode: .notes, title: nil, now: at1530)
        let store = self.store
        await withTaskGroup(of: Void.self) { group in
            for n in 0..<16 {
                group.addTask {
                    _ = try? store.update(s.id) { $0.flags.append(Flag(offset: Double(n), source: .panel)) }
                }
                if n == 8 { group.addTask { _ = try? store.retitle(s, to: "Renamed mid flight") } }
            }
        }
        let found = try #require(store.find(s.id))
        #expect(found.folderName == "2026-10-14 1530 Renamed mid flight" && found.title == "Renamed mid flight")
        #expect(Set(found.flags.map(\.offset)) == Set((0..<16).map(Double.init)))
    }

    @Test func importsAreStartedByImportAndCreateTakesATrigger() throws {
        let source = tempDir().appending(path: "memo.m4a")
        try Data("memo".utf8).write(to: source)
        let imported = try store.importAudio(from: source, mode: .notes, startedAt: at1530, duration: 60)
        #expect(imported.startedBy == .importFile)
        #expect(try store.load(folderName: imported.folderName).startedBy == .importFile)
        #expect(try store.create(mode: .notes, title: nil, now: at1530, startedBy: .cli).startedBy == .cli)
        #expect(store.find(imported.id)?.folderName == imported.folderName)
    }
}

