import Foundation
import Testing
@testable import EarshotKit

private final class Clock: @unchecked Sendable {
    let now = Locked(at1530)
    func advance(_ seconds: TimeInterval) { now.update { $0 = $0.addingTimeInterval(seconds) } }
}

private func meeting(_ store: SessionStore, title: String = "Acme kickoff") throws -> Session {
    try store.create(mode: .notesAndDo, title: title, now: at1530)
}

private func liveItem(_ id: String, _ task: String, status: LiveItem.Status = .suggested) -> LiveItem {
    LiveItem(id: id, task: task, owner: "Stephen", aiDoable: true, why: "promised", firstSeen: 5, status: status)
}

private func onDisk(_ store: SessionStore, _ session: Session) throws -> LiveFile {
    try store.read(LiveFile.self, session, MeetingFile.live)
}

/// The files set aside next to live.json, as their bytes.
private func setAside(_ store: SessionStore, _ session: Session) throws -> [Data] {
    let folder = store.folder(session)
    return try FileManager.default.contentsOfDirectory(atPath: folder.path)
        .filter { $0.hasPrefix("live.unreadable-") && $0.hasSuffix(".json") }
        .map { try Data(contentsOf: folder.appending(path: $0)) }
}

/// A live.json with a sending item, an item with no task (it can't be decoded) and a status from a newer version.
private let partlyReadable = Data("""
{"version":1,"segments":[],"items":[
 {"id":"L1","task":"Draft the scope","owner":"Stephen","aiDoable":true,"firstSeen":5,"status":"sending","target":"webhook"},
 {"id":"L2","owner":"Stephen","aiDoable":true,"firstSeen":6,"status":"done"},
 {"id":"L3","task":"Book the venue","owner":"Stephen","aiDoable":true,"firstSeen":7,"status":"archived"}]}
""".utf8)

struct LiveStoreTests {
    @Test func aStatusChangeIsWrittenAtOnce() throws {
        let store = SessionStore(root: tempDir(), timeZone: newYork)
        let session = try meeting(store)
        let live = LiveStore(store: store, session: session)
        live.replaceItems([liveItem("L1", "Draft the scope"), liveItem("L2", "Book the venue")])
        try live.setStatus("L1", .sending, target: "webhook")
        var file = try onDisk(store, session)
        #expect(file.version == 1)
        #expect(file.items[0].status == .sending && file.items[0].target == "webhook")
        try live.setStatus("L1", .startedInCloud, target: "routine", detail: "Run created", link: "https://claude.ai/x")
        file = try onDisk(store, session)
        #expect(file.items[0] == LiveItem(id: "L1", task: "Draft the scope", owner: "Stephen", aiDoable: true,
                                          why: "promised", firstSeen: 5, status: .startedInCloud, target: "routine",
                                          detail: "Run created", link: "https://claude.ai/x"))
        #expect(live.items == file.items)
    }

    @Test func anUnknownItemThrows() throws {
        let store = SessionStore(root: tempDir(), timeZone: newYork)
        let live = LiveStore(store: store, session: try meeting(store))
        #expect(throws: LiveStore.Failure.unknownItem("L7")) { try live.setStatus("L7", .dismissed) }
    }

    @Test func aStatusThatCantBeSavedThrowsAndChangesNothing() throws {
        let store = SessionStore(root: tempDir(), timeZone: newYork)
        let session = try meeting(store)
        let live = LiveStore(store: store, session: session)
        live.replaceItems([liveItem("L1", "Draft the scope")])
        try FileManager.default.removeItem(at: store.file(session, MeetingFile.live))
        try FileManager.default.createDirectory(at: store.file(session, MeetingFile.live), withIntermediateDirectories: false)
        #expect(throws: (any Error).self) { try live.setStatus("L1", .sending, target: "webhook") }
        #expect(live.items[0].status == .suggested)
    }

    @Test func replacingItemsKeepsTheStatusesTheStoreOwns() throws {
        let store = SessionStore(root: tempDir(), timeZone: newYork)
        let session = try meeting(store)
        let live = LiveStore(store: store, session: session)
        live.replaceItems([liveItem("L1", "Draft the scope"), liveItem("L2", "Book the venue"),
                           liveItem("L3", "Call Dana")])
        try live.setStatus("L1", .running, target: "claude-code")
        try live.setStatus("L2", .dismissed)
        // A merge made from an older copy: L1 and L2 still look suggested, L3 changed, L4 is new, and nothing is lost.
        live.replaceItems([liveItem("L1", "Draft the scope, changed"), liveItem("L2", "Book the venue, changed"),
                           liveItem("L4", "Send the price list")])
        let items = try onDisk(store, session).items
        #expect(items.map(\.id) == ["L1", "L2", "L4", "L3"])
        #expect(items[0] == LiveItem(id: "L1", task: "Draft the scope", owner: "Stephen", aiDoable: true, why: "promised",
                                     firstSeen: 5, status: .running, target: "claude-code"))
        #expect(items[1].task == "Book the venue" && items[1].status == .dismissed)
        #expect(items[2].status == .suggested)
    }

    @Test func segmentsAreSavedAtMostEveryFiveSecondsAndOnFlush() throws {
        let store = SessionStore(root: tempDir(), timeZone: newYork)
        let session = try meeting(store)
        let clock = Clock()
        let live = LiveStore(store: store, session: session, now: { clock.now.get })
        let first = Segment(track: .me, start: 0, end: 2, text: "Hello")
        live.appendSegments([first])
        #expect(try onDisk(store, session).segments == [first])
        clock.advance(4)
        let second = Segment(track: .them, start: 2, end: 4, text: "Hi there")
        live.appendSegments([second])
        #expect(try onDisk(store, session).segments == [first])
        clock.advance(1)
        let third = Segment(track: .me, start: 4, end: 6, text: "Shall we start")
        live.appendSegments([third])
        #expect(try onDisk(store, session).segments == [first, second, third])
        let fourth = Segment(track: .them, start: 6, end: 8, text: "Yes")
        live.appendSegments([fourth])
        #expect(try onDisk(store, session).segments.count == 3)
        live.flush()
        #expect(try onDisk(store, session).segments == [first, second, third, fourth])
        #expect(live.segments.count == 4 && live.lastError == nil)
    }

    @Test func aStatusWriteAlsoSavesWaitingSegments() throws {
        let store = SessionStore(root: tempDir(), timeZone: newYork)
        let session = try meeting(store)
        let live = LiveStore(store: store, session: session, now: { at1530 })
        live.replaceItems([liveItem("L1", "Draft the scope")])
        live.appendSegments([Segment(track: .me, start: 0, end: 2, text: "One")])
        live.appendSegments([Segment(track: .me, start: 2, end: 4, text: "Two")])
        try live.setStatus("L1", .dismissed)
        #expect(try onDisk(store, session).segments.count == 2)
    }

    @Test func aFailedSegmentWriteIsKeptAsTheLastErrorAndRetried() throws {
        let store = SessionStore(root: tempDir(), timeZone: newYork)
        let session = try meeting(store)
        let live = LiveStore(store: store, session: session)
        let url = store.file(session, MeetingFile.live)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        live.appendSegments([Segment(track: .me, start: 0, end: 2, text: "One")])
        #expect(live.lastError != nil)
        try FileManager.default.removeItem(at: url)
        live.flush()
        #expect(live.lastError == nil)
        #expect(try onDisk(store, session).segments.count == 1)
    }

    @Test func anExistingFileIsLoadedSoNothingIsLost() throws {
        let store = SessionStore(root: tempDir(), timeZone: newYork)
        let session = try meeting(store)
        let saved = LiveFile(items: [liveItem("L1", "Draft the scope", status: .done)],
                             segments: [Segment(track: .me, start: 0, end: 1, text: "Hi")])
        try store.write(saved, session, MeetingFile.live)
        let live = LiveStore(store: store, session: session)
        #expect(live.items == saved.items && live.segments == saved.segments)
        #expect(live.folder == store.folder(session))
    }

    @Test func anUnreadableFileIsSetAsideBeforeAnythingIsWritten() throws {
        let store = SessionStore(root: tempDir(), timeZone: newYork)
        let session = try meeting(store)
        let url = store.file(session, MeetingFile.live)
        try Data("not json".utf8).write(to: url)
        let live = LiveStore(store: store, session: session)
        #expect(live.items.isEmpty)
        live.replaceItems([liveItem("L1", "Draft the scope")])
        #expect(try setAside(store, session) == [Data("not json".utf8)])
        #expect(try onDisk(store, session).items.map(\.id) == ["L1"])
        #expect(live.lastError == nil)
    }

    @Test func aFileThatCantBeOpenedIsSetAsideToo() throws {
        let store = SessionStore(root: tempDir(), timeZone: newYork)
        let session = try meeting(store)
        let url = store.file(session, MeetingFile.live)
        let saved = LiveFile(items: [liveItem("L1", "Draft the scope", status: .done)])
        try store.write(saved, session, MeetingFile.live)
        let original = try Data(contentsOf: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: url.path)
        let live = LiveStore(store: store, session: session)
        live.appendSegments([Segment(track: .me, start: 0, end: 1, text: "Hi")])
        let folder = store.folder(session)
        let name = try #require(try FileManager.default.contentsOfDirectory(atPath: folder.path)
            .first { $0.hasPrefix("live.unreadable-") })
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: folder.appending(path: name).path)
        #expect(try Data(contentsOf: folder.appending(path: name)) == original)
        #expect(try onDisk(store, session).segments.count == 1)
    }

    @Test func aPartlyReadableFileIsCopiedAsideBeforeItIsRewritten() throws {
        let store = SessionStore(root: tempDir(), timeZone: newYork)
        let session = try meeting(store)
        try partlyReadable.write(to: store.file(session, MeetingFile.live))
        let live = LiveStore(store: store, session: session)
        #expect(live.items.map(\.id) == ["L1", "L3"])
        live.replaceItems([liveItem("L4", "Send the price list")])
        #expect(try setAside(store, session) == [partlyReadable])
        #expect(try onDisk(store, session).items.map(\.id) == ["L4", "L1", "L3"])
    }

    @Test func aCleanFileIsNeverCopied() throws {
        let store = SessionStore(root: tempDir(), timeZone: newYork)
        let session = try meeting(store)
        try store.write(LiveFile(items: [liveItem("L1", "Draft the scope", status: .done)]), session, MeetingFile.live)
        let live = LiveStore(store: store, session: session)
        live.replaceItems([liveItem("L2", "Book the venue")])
        #expect(try setAside(store, session).isEmpty)
    }

    @Test func recoverLeavesAPartlyReadableFileAsItIs() throws {
        let store = SessionStore(root: tempDir(), timeZone: newYork)
        let partly = try meeting(store, title: "Partly")
        let fine = try meeting(store, title: "Fine")
        try partlyReadable.write(to: store.file(partly, MeetingFile.live))
        try store.write(LiveFile(items: [liveItem("L1", "a", status: .running)]), fine, MeetingFile.live)
        #expect(throws: LiveStore.Failure.partlyUnreadable(store.folder(partly).lastPathComponent)) {
            try LiveStore.recover(in: store)
        }
        #expect(try Data(contentsOf: store.file(partly, MeetingFile.live)) == partlyReadable)
        #expect(try onDisk(store, fine).items[0].status == .interrupted)
    }

    @Test func recoverMarksSendingAndRunningAsInterruptedInEveryMeeting() throws {
        let store = SessionStore(root: tempDir(), timeZone: newYork)
        let first = try meeting(store, title: "First")
        let second = try meeting(store, title: "Second")
        let third = try meeting(store, title: "Third")
        var sending = liveItem("L1", "a", status: .sending)
        sending.target = "webhook"
        let items = [sending, liveItem("L2", "b", status: .running),
                     liveItem("L3", "c", status: .done), liveItem("L4", "d", status: .queued),
                     liveItem("L5", "e", status: .suggested), liveItem("L6", "f", status: .failed)]
        try store.write(LiveFile(items: items, segments: [Segment(track: .me, start: 0, end: 1, text: "Hi")]),
                        first, MeetingFile.live)
        try store.write(LiveFile(items: [liveItem("L1", "a", status: .running)]), second, MeetingFile.live)
        try LiveStore.recover(in: store)
        let recovered = try onDisk(store, first)
        #expect(recovered.items.map(\.status) == [.interrupted, .interrupted, .done, .suggested, .suggested, .failed])
        #expect(recovered.items[0].target == "webhook" && recovered.segments.count == 1)
        #expect(try onDisk(store, second).items.map(\.status) == [.interrupted])
        #expect(try store.readIfPresent(LiveFile.self, third, MeetingFile.live) == nil)
        // A second run changes nothing.
        let before = try Data(contentsOf: store.file(first, MeetingFile.live))
        try LiveStore.recover(in: store)
        #expect(try Data(contentsOf: store.file(first, MeetingFile.live)) == before)
    }

    @Test func recoverLeavesBusyMeetingsAloneAndCarriesOnPastABadFile() throws {
        let store = SessionStore(root: tempDir(), timeZone: newYork)
        let busy = try meeting(store, title: "Busy")
        let broken = try meeting(store, title: "Broken")
        let fine = try meeting(store, title: "Fine")
        try store.write(LiveFile(items: [liveItem("L1", "a", status: .sending)]), busy, MeetingFile.live)
        try store.markBusy(busy)
        try Data("not json".utf8).write(to: store.file(broken, MeetingFile.live))
        try store.write(LiveFile(items: [liveItem("L1", "a", status: .sending)]), fine, MeetingFile.live)
        #expect(throws: (any Error).self) { try LiveStore.recover(in: store) }
        #expect(try onDisk(store, busy).items[0].status == .sending)
        #expect(try onDisk(store, fine).items[0].status == .interrupted)
        store.clearBusy(busy)
    }
}
