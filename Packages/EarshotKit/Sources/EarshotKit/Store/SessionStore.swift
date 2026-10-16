import Foundation

/// One folder per meeting under `root`. `session.json` inside it is the record of truth.
public struct SessionStore: Sendable {
    public static let fileName = MeetingFile.session
    public let root: URL
    public let timeZone: TimeZone

    public init(root: URL, timeZone: TimeZone = .current) {
        self.root = root
        self.timeZone = timeZone
    }

    /// With `busyPID`, the `.busy` marker is written before session.json, so the app never sees the meeting as its
    /// own to recover or resume (spec 14.3).
    public func create(mode: Mode, title: String?, tracks: [TrackFile] = [], now: Date = Date(),
                       startedBy: StartTrigger = .manual, busyPID: Int32? = nil) throws -> Session {
        let start = now.wholeSeconds
        let stamp = Self.formatter("yyyy-MM-dd HHmm", timeZone).string(from: start)
        let id = Self.formatter("yyyy-MM-dd-HHmm", timeZone).string(from: start)
            + "-" + String(format: "%04x", UInt16.random(in: .min ... .max))
        let cleaned = title.map(Self.clean) ?? ""
        let name = try makeUniqueFolder(base: cleaned.isEmpty ? stamp : "\(stamp) \(cleaned)")
        let folder = root.appending(path: name, directoryHint: .isDirectory)
        if let busyPID {
            do {
                try Self.writeBusyMarker(pid: busyPID, to: folder.appending(path: MeetingFile.busy))
            } catch {
                try? FileManager.default.removeItem(at: folder)
                throw error
            }
        }
        var stages: [Stage: StageState] = [:]
        for stage in mode.stages { stages[stage] = StageState() }
        let session = Session(id: id, folderName: name, title: title, mode: mode, startedAt: start, endedAt: nil,
                              recording: true, tracks: tracks, stages: stages, sent: [], warnings: [],
                              startedBy: startedBy)
        try save(session)
        return session
    }

    public func folder(_ session: Session) -> URL {
        root.appending(path: session.folderName, directoryHint: .isDirectory)
    }

    public func file(_ session: Session, _ name: String) -> URL {
        folder(session).appending(path: name)
    }

    public func save(_ session: Session) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(session).write(to: file(session, Self.fileName), options: .atomic)
    }

    public func load(folderName: String) throws -> Session {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let url = root.appending(path: folderName, directoryHint: .isDirectory).appending(path: Self.fileName)
        var session = try decoder.decode(Session.self, from: Data(contentsOf: url))
        // The directory we read is the truth: the user may have renamed it in Finder since session.json was written.
        session.folderName = folderName
        return session
    }

    /// Every readable meeting, newest first.
    public func all() -> [Session] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        return names.compactMap { try? load(folderName: $0) }.sorted { $0.startedAt > $1.startedAt }
    }

    /// Call once at launch: closes recordings a crash left open and resets stages left running. A meeting another
    /// process is working on (its `.busy` PID is alive) is left alone and out of the result. Each meeting is
    /// re-read and saved under its folder lock, and checked for a busy marker again once the lock is held.
    @discardableResult
    public func recover(now: Date = Date()) throws -> [Session] {
        var out: [Session] = []
        for found in all() where !isBusy(found) {
            var copy = found
            guard Self.recoverInPlace(&copy, lastWrite: nil, now: now) else {
                out.append(found)
                continue
            }
            // One meeting that cannot be locked or saved must not stop the rest from recovering. It stays as it is
            // on disk, so the next launch tries it again, and it is left out of the result.
            let recovered: Session? = try? withLock(found) {
                guard var session = try? load(folderName: found.folderName), session.id == found.id,
                      !isBusy(session) else { return nil }
                if Self.recoverInPlace(&session, lastWrite: lastWrite(session), now: now) { try save(session) }
                return session
            }
            if let recovered { out.append(recovered) }
        }
        return out
    }

    /// At this many failures in a row a stage no longer resumes on its own; it waits for the user's Retry.
    public static let autoResumeLimit = 2

    /// The error on a stage that stopped part-way after it could no longer resume on its own.
    public static let interruptedError = "Interrupted. Press Retry to continue."

    /// Closes an open recording and resets running stages. A running stage at `autoResumeLimit` failures, or the
    /// next stage when it is pending at that count (a stage `earshot process` held back, cut off by a kill), becomes
    /// failed, so the menu offers Retry instead of "Waiting" forever. A later pending stage keeps its count as it is:
    /// it never started, and the pipeline asks before it sends anyway. True when anything changed.
    static func recoverInPlace(_ session: inout Session, lastWrite: Date?, now: Date) -> Bool {
        var changed = false
        if session.recording {
            session.recording = false
            session.endedAt = (lastWrite ?? now).wholeSeconds
            session.warnings.append("The recording was interrupted. The audio up to that point was kept.")
            changed = true
        }
        let next = session.nextStage
        for (stage, state) in session.stages where state.status == .running || state.status == .pending {
            if state.failures >= autoResumeLimit, state.status == .running || stage == next {
                session.stages[stage] = StageState(status: .failed, error: interruptedError, failures: state.failures)
            } else if state.status == .running {
                session.stages[stage]?.status = .pending
            } else {
                continue
            }
            changed = true
        }
        return changed
    }

    /// Meetings the pipeline should pick up on its own: stopped, unfinished, not failed twice in a row, and not
    /// busy in another process. Oldest first.
    public func resumable() -> [Session] {
        all().filter { session in
            guard !session.recording, let next = session.nextStage, !isBusy(session) else { return false }
            return (session.stages[next]?.failures ?? 0) < Self.autoResumeLimit
        }.sorted { $0.startedAt < $1.startedAt }
    }

    /// Renames the folder to carry the title, for example "2026-10-14 1530 Acme kickoff", and sets the title. Runs
    /// under the folder lock on what is on disk now, so changes saved since the caller read `session` are kept.
    /// The lock file moves with the folder; a writer waiting on it finds the meeting again by id.
    public func retitle(_ session: Session, to title: String) throws -> Session {
        try locked(session.id, hint: session) { current in
            var session = current
            let stamp = String(session.folderName.prefix(15))  // "yyyy-MM-dd HHmm"
            let cleaned = Self.clean(title)
            let target = try uniqueFolder(base: cleaned.isEmpty ? stamp : "\(stamp) \(cleaned)",
                                          except: session.folderName)
            if target != session.folderName {
                try FileManager.default.moveItem(at: folder(session),
                                                 to: root.appending(path: target, directoryHint: .isDirectory))
                session.folderName = target
            }
            session.title = title
            try save(session)
            return session
        }
    }

    static func clean(_ title: String) -> String {
        let unsafe = CharacterSet(charactersIn: "/:\\").union(.controlCharacters).union(.newlines)
        let words = title.components(separatedBy: unsafe).joined(separator: " ").split(whereSeparator: \.isWhitespace)
        return String(words.joined(separator: " ").prefix(60)).trimmingCharacters(in: .whitespaces)
    }

    func uniqueFolder(base: String, except: String? = nil) throws -> String {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var name = base
        var n = 2
        while name != except, FileManager.default.fileExists(atPath: root.appending(path: name).path) {
            name = "\(base) \(n)"
            n += 1
        }
        return name
    }

    /// Makes a new folder named `base`, or "`base` 2", "`base` 3"… when that name is taken, and returns its name.
    /// Each folder is made exclusively (mkdir fails when the name exists), so two meetings created at the same
    /// moment, in this process or another, never share one. `beforeEach` is for tests: it runs before each try.
    func makeUniqueFolder(base: String, beforeEach: (String) -> Void = { _ in }) throws -> String {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var n = 1
        while true {
            let name = n == 1 ? base : "\(base) \(n)"
            beforeEach(name)
            let path = root.appending(path: name, directoryHint: .isDirectory).path
            if mkdir(path, 0o755) == 0 { return name }
            let code = errno
            guard code == EEXIST else { throw Self.folderError(code, path: path) }
            n += 1
        }
    }

    /// The error FileManager would give for a failed mkdir, so the user sees the usual wording.
    static func folderError(_ code: Int32, path: String) -> CocoaError {
        let kind: CocoaError.Code = switch code {
        case EACCES, EPERM: .fileWriteNoPermission
        case ENOSPC: .fileWriteOutOfSpace
        case EROFS: .fileWriteVolumeReadOnly
        default: .fileWriteUnknown
        }
        return CocoaError(kind, userInfo: [NSFilePathErrorKey: path,
                                           NSUnderlyingErrorKey: POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)])
    }

    func lastWrite(_ session: Session) -> Date? {
        session.tracks.compactMap {
            try? FileManager.default.attributesOfItem(atPath: file(session, $0.file).path)[.modificationDate] as? Date
        }.max()
    }

    static func formatter(_ format: String, _ timeZone: TimeZone) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = format
        return formatter
    }
}

extension SessionStore {
    /// A meeting from an existing recording (a phone voice memo, say), copied in as one "Speaker" track.
    /// With `busyPID` the meeting is marked busy before anything is saved, as in `create`.
    public func importAudio(from source: URL, mode: Mode, startedAt: Date, duration: TimeInterval,
                            busyPID: Int32? = nil) throws -> Session {
        var session = try create(mode: mode, title: nil, now: startedAt, startedBy: .importFile, busyPID: busyPID)
        do {
            let name = "import." + (source.pathExtension.isEmpty ? "m4a" : source.pathExtension.lowercased())
            try FileManager.default.copyItem(at: source, to: file(session, name))
            session.recording = false
            session.endedAt = session.startedAt.addingTimeInterval(duration.rounded())
            session.tracks = [TrackFile(track: .speaker, file: name, offset: 0)]
            try save(session)
        } catch {
            // `create` left a meeting marked as recording; a failed import must not leave that ghost behind.
            try? FileManager.default.removeItem(at: folder(session))
            throw error
        }
        return session
    }
}

extension Session {
    /// The next stage, when it failed: the stage the menu offers Retry for.
    public var failedStage: Stage? { nextStage.flatMap { stages[$0]?.status == .failed ? $0 : nil } }
}
