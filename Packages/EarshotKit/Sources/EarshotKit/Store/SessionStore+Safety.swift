import Foundation

public enum SessionStoreError: Error, Equatable, LocalizedError {
    case notFound(String)
    case lockFailed(String)

    public var errorDescription: String? {
        switch self {
        case let .notFound(id): "The meeting \(id) wasn't found."
        case let .lockFailed(detail): "Earshot couldn't lock the meeting folder: \(detail)"
        }
    }
}

/// Reading and writing a meeting's files, one writer at a time (spec 14.3).
extension SessionStore {
    /// Reads `name` in the meeting folder.
    public func read<T: Decodable>(_ type: T.Type, _ session: Session, _ name: String) throws -> T {
        try JSONFiles.read(type, from: file(session, name))
    }

    /// Nil when the file doesn't exist.
    public func readIfPresent<T: Decodable>(_ type: T.Type, _ session: Session, _ name: String) throws -> T? {
        try JSONFiles.readIfPresent(type, from: file(session, name))
    }

    /// Writes `name` in the meeting folder atomically.
    public func write<T: Encodable>(_ value: T, _ session: Session, _ name: String) throws {
        try JSONFiles.write(value, to: file(session, name))
    }

    /// The meeting with this id. Folders named for its start time are tried first, then every folder, since the
    /// user may have renamed one in Finder.
    public func find(_ id: String) -> Session? {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        let stamp = Self.folderStamp(forID: id)
        let likely = names.filter { stamp != nil && $0.hasPrefix(stamp!) }
        for name in likely + names.filter({ !likely.contains($0) }) {
            if let session = try? load(folderName: name), session.id == id { return session }
        }
        return nil
    }

    /// Re-reads session.json, applies `mutate` and saves, holding an exclusive `flock` on `<folder>/.lock`, so a
    /// change made by another writer in between is never lost. `id` and `folderName` can't be changed here (use
    /// `retitle`).
    @discardableResult
    public func update(_ id: String, _ mutate: (inout Session) throws -> Void) throws -> Session {
        try locked(id, hint: nil) { current in
            var session = current
            try mutate(&session)
            session.id = current.id
            session.folderName = current.folderName
            try save(session)
            return session
        }
    }

    /// How many times `locked` looks for a folder that was renamed while it waited for the lock.
    static let lockAttempts = 5

    /// Finds the meeting (at `hint`'s folder first), takes its folder lock, re-reads session.json and runs `body`
    /// with it. When the folder was renamed (by `retitle`) while this waited for the lock, it finds it again.
    func locked<T>(_ id: String, hint: Session?, _ body: (Session) throws -> T) throws -> T {
        var candidate = hint.flatMap { hasSession($0.folderName, id: id) ? $0 : nil }
        for _ in 0 ..< Self.lockAttempts {
            guard let found = candidate ?? find(id) else { throw SessionStoreError.notFound(id) }
            candidate = nil
            let result: T?
            do {
                result = try withLock(found) { () -> T? in
                    guard hasSession(found.folderName, id: id) else { return nil }
                    return try body(try load(folderName: found.folderName))
                }
            } catch SessionStoreError.lockFailed(_) where !FileManager.default.fileExists(atPath: folder(found).path) {
                continue  // Renamed between finding it and opening the lock file.
            }
            if let result { return result }
        }
        throw SessionStoreError.notFound(id)
    }

    /// True when `folderName` holds the session.json of meeting `id`.
    func hasSession(_ folderName: String, id: String) -> Bool {
        let url = root.appending(path: folderName, directoryHint: .isDirectory).appending(path: Self.fileName)
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        return (try? load(folderName: folderName))?.id == id
    }

    /// Runs `body` while holding the meeting folder's lock.
    func withLock<T>(_ session: Session, _ body: () throws -> T) throws -> T {
        let path = file(session, MeetingFile.lock).path
        let descriptor = open(path, O_CREAT | O_RDWR | O_CLOEXEC, 0o644)
        guard descriptor >= 0 else { throw SessionStoreError.lockFailed(String(cString: strerror(errno))) }
        defer { close(descriptor) }
        while flock(descriptor, LOCK_EX) != 0 {
            guard errno == EINTR else { throw SessionStoreError.lockFailed(String(cString: strerror(errno))) }
        }
        defer { flock(descriptor, LOCK_UN) }
        return try body()
    }

    /// Marks the meeting as being worked on by process `pid` (by default this one), so the app leaves it alone.
    /// Prefer `create(..., busyPID:)` for a new meeting, which marks it before it is first saved.
    public func markBusy(_ session: Session, pid: Int32 = ProcessInfo.processInfo.processIdentifier) throws {
        try Self.writeBusyMarker(pid: pid, to: file(session, MeetingFile.busy))
    }

    public func clearBusy(_ session: Session) {
        try? FileManager.default.removeItem(at: file(session, MeetingFile.busy))
    }

    /// True while the process named in `.busy` is alive and is the same process that wrote it (its start time
    /// matches), so a PID that macOS reused for another program doesn't count. A marker left by a process that died
    /// doesn't count either.
    public func isBusy(_ session: Session) -> Bool {
        guard let data = try? Data(contentsOf: file(session, MeetingFile.busy)) else { return false }
        let fields = String(decoding: data, as: UTF8.self).split(whereSeparator: \.isWhitespace)
        guard let first = fields.first, let pid = Int32(first), Self.processIsAlive(pid) else { return false }
        guard fields.count >= 3, let seconds = Int(fields[1]), let micros = Int(fields[2]) else {
            return true  // A PID-only marker: alive is all we can check.
        }
        guard let started = Self.processStartTime(pid) else { return true }
        return started.seconds == seconds && started.micros == micros
    }

    /// `.busy` holds "<pid> <start seconds> <start microseconds>".
    static func writeBusyMarker(pid: Int32, to url: URL) throws {
        let start = processStartTime(pid).map { " \($0.seconds) \($0.micros)" } ?? ""
        try Data("\(pid)\(start)\n".utf8).write(to: url, options: .atomic)
    }

    static func processIsAlive(_ pid: Int32) -> Bool {
        guard pid > 0 else { return false }
        return kill(pid, 0) == 0 || errno == EPERM
    }

    /// When process `pid` started, from `sysctl(KERN_PROC_PID)`; nil when there is no such process.
    static func processStartTime(_ pid: Int32) -> (seconds: Int, micros: Int)? {
        guard pid > 0 else { return nil }
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0, size > 0 else { return nil }
        let start = info.kp_proc.p_un.__p_starttime
        return (Int(start.tv_sec), Int(start.tv_usec))
    }

    /// "2026-10-14-1530-a3f9" gives "2026-10-14 1530", the start of its folder name.
    static func folderStamp(forID id: String) -> String? {
        guard id.count >= 15 else { return nil }
        var stamp = Array(id.prefix(15))
        guard stamp[10] == "-" else { return nil }
        stamp[10] = " "
        return String(stamp)
    }
}
