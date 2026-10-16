import Foundation

/// The single writer of a meeting's live.json (spec 4.5 and 14.3). Every write is atomic. A status change is
/// written at once, before the call returns; new segments at most every `segmentInterval`; everything on `flush()`.
public final class LiveStore: @unchecked Sendable {
    public enum Failure: Error, Equatable, LocalizedError {
        case unknownItem(String)
        /// Some of the meeting's live to-dos couldn't be read, so recover() left its live.json as it was. The value
        /// is the meeting folder's name.
        case partlyUnreadable(String)

        public var errorDescription: String? {
            switch self {
            case let .unknownItem(id): "The live to-do \(id) wasn't found."
            case let .partlyUnreadable(folder):
                "Some live to-dos in \(folder) couldn't be read, so Earshot left them as they were."
            }
        }
    }

    /// New segments are written at most this often.
    public static let segmentInterval: TimeInterval = 5
    /// A live.json that can't be read in full is kept as "live.unreadable-<time>-<n>.json" before it is replaced.
    static let unreadablePrefix = "live.unreadable-"

    public let store: SessionStore
    private let now: @Sendable () -> Date
    private let lock = NSLock()
    /// The meeting as last found on disk. Its folder can be renamed during a write's life (the pipeline retitles the
    /// meeting after Stop while live Start runs go on), so writes follow it by id.
    private var current: Session
    private var file: LiveFile
    private var lastSegmentWrite = Date.distantPast
    private var dirty = false
    private var writeError: (any Error)?
    /// Set while a live.json that couldn't be read in full still has to be kept aside. No write happens until it is,
    /// so the to-dos it holds (the record of what went out) are never overwritten.
    private var keepAside: Keep?

    private enum Keep {
        /// It couldn't be read at all, so nothing of it is in memory: it is moved.
        case move
        /// Some items couldn't be decoded, or have a status from a newer version: a copy is kept.
        case copy
    }

    /// Loads the meeting's live.json when there is one, so a reopened meeting keeps its to-dos. A file that can't be
    /// read in full is kept aside, as "live.unreadable-<time>-<n>.json", before the first write replaces it.
    public init(store: SessionStore, session: Session, now: @escaping @Sendable () -> Date = { Date() }) {
        self.store = store
        current = session
        self.now = now
        let url = store.file(session, MeetingFile.live)
        guard FileManager.default.fileExists(atPath: url.path) else {
            file = LiveFile()
            return
        }
        do {
            let data = try Data(contentsOf: url)
            file = try JSONFiles.decoder().decode(LiveFile.self, from: data)
            if !Self.isComplete(data, file) { keepAside = .copy }
        } catch {
            file = LiveFile()
            writeError = error
            keepAside = .move
        }
    }

    /// The meeting, at the folder live.json was last written to or found in.
    public var session: Session { lock.withLock { current } }
    public var folder: URL { lock.withLock { store.folder(current) } }
    public var url: URL { lock.withLock { store.file(current, MeetingFile.live) } }
    public var items: [LiveItem] { lock.withLock { file.items } }
    public var segments: [Segment] { lock.withLock { file.segments } }
    /// The last write that failed, if the one after it hasn't succeeded yet. Segment and item writes never throw, so
    /// a full disk can't stop a recording; the next write tries again.
    public var lastError: (any Error)? { lock.withLock { writeError } }

    /// Sets the item's status, target, detail and link (nil clears them) and writes live.json before returning. When
    /// the write fails, nothing changes and the error is thrown.
    public func setStatus(_ id: String, _ status: LiveItem.Status, target: String? = nil, detail: String? = nil,
                          link: String? = nil) throws {
        try change(id) { item in
            item.status = status
            item.target = target
            item.detail = detail
            item.link = link
        }
    }

    /// Records Start: the item becomes `queued` for `target`, with the words of `snapshot` (the row as drawn, which
    /// is what will be sent), so live.json matches the payload even if a merge changed the row since it was drawn.
    /// Written at once; when the write fails, nothing changes and the error is thrown.
    public func queue(_ snapshot: LiveItem, target: String) throws {
        try change(snapshot.id) { item in
            item.task = snapshot.task
            item.owner = snapshot.owner
            item.due = snapshot.due
            item.aiDoable = snapshot.aiDoable
            item.why = snapshot.why
            item.status = .queued
            item.target = target
            item.detail = nil
            item.link = nil
        }
    }

    private func change(_ id: String, _ edit: (inout LiveItem) -> Void) throws {
        try lock.withLock {
            guard let index = file.items.firstIndex(where: { $0.id == id }) else { throw Failure.unknownItem(id) }
            var next = file
            edit(&next.items[index])
            try write(next)
        }
    }

    /// Takes the items from a merge and writes them at once. The store owns each item's status: an item it already
    /// has keeps its status, target, detail and link, and one that is no longer `suggested` is kept exactly as it is.
    /// Items missing from `items` are kept, so nothing is ever lost. Change a status with `setStatus`.
    public func replaceItems(_ items: [LiveItem]) {
        lock.withLock {
            let stored = Dictionary(file.items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            let incoming = Set(items.map(\.id))
            var next = file
            next.items = items.map { item in
                guard let known = stored[item.id] else { return item }
                guard known.status == .suggested else { return known }
                var kept = item
                kept.status = known.status
                kept.target = known.target
                kept.detail = known.detail
                kept.link = known.link
                return kept
            } + file.items.filter { !incoming.contains($0.id) }
            file = next
            dirty = true
            try? write(file)
        }
    }

    /// Adds final live segments. They are written when `segmentInterval` has passed since the last segment write,
    /// otherwise with the next write or `flush()`.
    public func appendSegments(_ segments: [Segment]) {
        guard !segments.isEmpty else { return }
        lock.withLock {
            file.segments += segments
            dirty = true
            if now().timeIntervalSince(lastSegmentWrite) >= Self.segmentInterval { try? write(file) }
        }
    }

    /// Writes anything not yet written, for example at stop.
    public func flush() {
        lock.withLock {
            guard dirty || writeError != nil else { return }
            try? write(file)
        }
    }

    /// Call with the lock held. On success `next` becomes the file; on failure the error is kept and thrown. When
    /// the meeting's folder was renamed since the last write, it is found again by id and written there.
    private func write(_ next: LiveFile) throws {
        do {
            do {
                try writeHere(next)
            } catch {
                guard relocate() else { throw error }
                try writeHere(next)
            }
        } catch {
            writeError = error
            throw error
        }
        file = next
        dirty = false
        writeError = nil
        lastSegmentWrite = now()
    }

    private func writeHere(_ next: LiveFile) throws {
        try setAsideIfNeeded()
        try store.write(next, current, MeetingFile.live)
    }

    /// Call with the lock held. True when the meeting is no longer in its folder and was found in another one.
    private func relocate() -> Bool {
        guard !store.hasSession(current.folderName, id: current.id), let moved = store.find(current.id),
              moved.folderName != current.folderName else { return false }
        current = moved
        return true
    }

    /// Call with the lock held. Keeps a live.json that couldn't be read in full, once; throws while it can't.
    private func setAsideIfNeeded() throws {
        guard let keep = keepAside else { return }
        let url = store.file(current, MeetingFile.live)
        let stamp = Int(now().timeIntervalSince1970)
        let folder = store.folder(current)
        var attempt = 0
        var target = folder.appending(path: "\(Self.unreadablePrefix)\(stamp)-\(attempt).json")
        while FileManager.default.fileExists(atPath: target.path) {
            attempt += 1
            target = folder.appending(path: "\(Self.unreadablePrefix)\(stamp)-\(attempt).json")
        }
        switch keep {
        case .move:
            if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.moveItem(at: url, to: target)
            }
        case .copy:
            try FileManager.default.copyItem(at: url, to: target)
        }
        keepAside = nil
    }

    /// True when every item and segment in `data` was decoded into `file`, and no status is from a newer version.
    static func isComplete(_ data: Data, _ file: LiveFile) -> Bool {
        guard let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        let items = raw["items"] as? [Any] ?? []
        let segments = raw["segments"] as? [Any] ?? []
        guard items.count == file.items.count, segments.count == file.segments.count else { return false }
        return items.allSatisfy { entry in
            guard let status = (entry as? [String: Any])?["status"] else { return true }
            return (status as? String).flatMap(LiveItem.Status.init(rawValue:)) != nil
        }
    }

    /// Call once at launch, before any recording: in every meeting, a live to-do left `sending` or `running` becomes
    /// `interrupted` (it may have gone out, so it is never sent again on its own), and one left `queued` becomes
    /// `suggested` (it never went out). Meetings another process is working on are left alone. A meeting whose
    /// live.json can't be read or written doesn't stop the others; the first such error is thrown at the end. A file
    /// that can't be read in full (an item that won't decode, a status from a newer version) is never rewritten,
    /// since that would drop what couldn't be read; it gives `Failure.partlyUnreadable`.
    public static func recover(in store: SessionStore) throws {
        var firstError: (any Error)?
        for session in store.all() where !store.isBusy(session) {
            do {
                let url = store.file(session, MeetingFile.live)
                guard FileManager.default.fileExists(atPath: url.path) else { continue }
                let data = try Data(contentsOf: url)
                var file = try JSONFiles.decoder().decode(LiveFile.self, from: data)
                guard isComplete(data, file) else {
                    throw Failure.partlyUnreadable(store.folder(session).lastPathComponent)
                }
                var changed = false
                for index in file.items.indices {
                    switch file.items[index].status {
                    case .sending, .running:
                        file.items[index].status = .interrupted
                        changed = true
                    case .queued:
                        file.items[index].status = .suggested
                        file.items[index].target = nil
                        changed = true
                    default:
                        break
                    }
                }
                if changed { try store.write(file, session, MeetingFile.live) }
            } catch {
                firstError = firstError ?? error
            }
        }
        if let firstError { throw firstError }
    }
}
