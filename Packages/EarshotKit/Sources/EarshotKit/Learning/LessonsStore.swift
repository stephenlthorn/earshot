import Foundation

/// lessons.json in Application Support (spec 6): `{version: 1, lessons: [Lesson]}`, newest first, at most
/// `maxLessons`, every text clipped to `maxTextLength`.
///
/// The app and the CLI may both write it, so every write takes an exclusive `flock` on a lock file next to it,
/// re-reads the file under that lock and replaces it atomically. A lesson another process added in between is
/// never lost, and a reader never sees half a file.
///
/// A write never silently loses what this version can't read. A file that doesn't decode, or that holds anything
/// a rewrite would drop (a lesson kind or style from a newer version, an extra key), is copied to
/// `lessons.json.corrupt` first. A file a newer version wrote (`version` above 1) is never rewritten by `add`.
public struct LessonsStore: Sendable {
    public static let maxLessons = 200
    public static let maxTextLength = 200
    /// The `version` this build writes.
    static let fileVersion = 1
    /// How long a write waits between tries for the lock.
    static let lockRetry: Duration = .milliseconds(10)

    /// Where lessons.json sits inside Application Support.
    static let applicationSupportPath = "Earshot/lessons.json"

    public static var defaultURL: URL {
        URL.applicationSupportDirectory.appending(path: applicationSupportPath)
    }

    /// lessons.json for the user whose home folder is `home`, for the command line, which runs against the home it
    /// is given.
    public static func defaultURL(home: URL) -> URL {
        home.appending(path: "Library/Application Support", directoryHint: .isDirectory).appending(path: applicationSupportPath)
    }

    public let url: URL
    /// How long `add` and `clear` wait for another writer before they throw `Failure.busy`.
    let lockWait: Duration

    public init(url: URL = LessonsStore.defaultURL) {
        self.init(url: url, lockWait: .seconds(2))
    }

    init(url: URL, lockWait: Duration) {
        self.url = url
        self.lockWait = lockWait
    }

    /// Every lesson, newest first. Empty when the file is missing, unreadable or corrupt.
    public func all() -> [Lesson] {
        guard let file = try? JSONFiles.readIfPresent(LessonsFile.self, from: url) else { return [] }
        return Self.newestFirst(file.lessons)
    }

    public var count: Int { all().count }

    /// See `add(_: [Lesson])`. Blocks; UI code calls it off the main actor.
    public func add(_ lesson: Lesson) throws {
        try add([lesson])
    }

    /// Adds `lessons` in front of the saved ones, keeps one lesson per id (the first: a new lesson replaces a saved
    /// one with its id), keeps the newest `maxLessons` and clips every text. An `instruction` lesson with no text
    /// is dropped.
    ///
    /// This blocks on file IO and waits up to two seconds for the lock while another process writes, so UI code
    /// calls it off the main actor (for example in `Task.detached`).
    /// - Throws: `Failure.busy` when the lock stays taken, `Failure.newerFile` when a newer version wrote the file,
    ///   or the read or write error. An unreadable file is never overwritten.
    public func add(_ lessons: [Lesson]) throws {
        let incoming = lessons.map(Self.clipped).filter(Self.isWorthKeeping)
        guard !incoming.isEmpty else { return }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try withLock {
            let merged = Self.newestFirst(Self.uniqueByID(incoming + (try readForWrite())))
            let file = LessonsFile(version: Self.fileVersion, lessons: Array(merged.prefix(Self.maxLessons)))
            try JSONFiles.write(file, to: url)
        }
    }

    /// Forgets every lesson ("Forget what Earshot learned"), including a file kept aside earlier. It also clears a
    /// file a newer version wrote, because the user asked to forget.
    ///
    /// Like `add`, this blocks, so UI code calls it off the main actor.
    public func clear() throws {
        guard FileManager.default.fileExists(atPath: folder.path) else { return }
        try withLock {
            if FileManager.default.fileExists(atPath: asideURL.path) {
                try FileManager.default.removeItem(at: asideURL)
            }
            guard FileManager.default.fileExists(atPath: url.path) else { return }
            try JSONFiles.write(LessonsFile(version: Self.fileVersion), to: url)
        }
    }

    // MARK: - Reading for a write

    /// The saved lessons, read under the lock. When the rewrite that follows would lose anything, the file is
    /// copied aside first; a file from a newer version throws instead.
    private func readForWrite() throws -> [Lesson] {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return []
        }
        let decoded: LessonsFile
        do {
            decoded = try JSONFiles.decoder().decode(LessonsFile.self, from: data)
        } catch is DecodingError {
            try keepAside()
            return []
        }
        switch try Self.fidelity(of: data, decoded: decoded) {
        case .complete: break
        case .partial: try keepAside()
        case .newer: throw Failure.newerFile
        }
        return decoded.lessons
    }

    enum Fidelity { case complete, partial, newer }

    /// Whether writing `decoded` back would give the same JSON as `data`. A missing `version` or `lessons` counts
    /// as the default this version writes.
    static func fidelity(of data: Data, decoded: LessonsFile) throws -> Fidelity {
        guard var raw = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return .partial }
        if let version = raw["version"] as? NSNumber, version.doubleValue > Double(fileVersion) { return .newer }
        raw["version"] = raw["version"] ?? fileVersion
        raw["lessons"] = raw["lessons"] ?? [Any]()
        let rewritten = LessonsFile(version: fileVersion, lessons: decoded.lessons)
        let again = try JSONSerialization.jsonObject(with: JSONFiles.encoder().encode(rewritten))
        return NSDictionary(dictionary: raw).isEqual(again) ? .complete : .partial
    }

    /// Copies lessons.json to lessons.json.corrupt, replacing an older copy.
    private func keepAside() throws {
        if FileManager.default.fileExists(atPath: asideURL.path) {
            try FileManager.default.removeItem(at: asideURL)
        }
        try FileManager.default.copyItem(at: url, to: asideURL)
    }

    // MARK: - Shaping lessons

    /// Sorted by date, newest first; lessons with the same date keep their order.
    static func newestFirst(_ lessons: [Lesson]) -> [Lesson] {
        lessons.enumerated()
            .sorted { $0.element.date != $1.element.date ? $0.element.date > $1.element.date : $0.offset < $1.offset }
            .map(\.element)
    }

    /// The first lesson for each id, in order.
    static func uniqueByID(_ lessons: [Lesson]) -> [Lesson] {
        var seen = Set<String>()
        return lessons.filter { seen.insert($0.id).inserted }
    }

    /// False for an `instruction` lesson whose text is empty.
    static func isWorthKeeping(_ lesson: Lesson) -> Bool {
        lesson.kind != .instruction || !(lesson.instruction ?? "").isEmpty
    }

    static func clipped(_ lesson: Lesson) -> Lesson {
        var copy = lesson
        copy.before = lesson.before.map(clipped)
        copy.after = lesson.after.map(clipped)
        copy.instruction = lesson.instruction.map { clip($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
        copy.meetingTitle = clip(lesson.meetingTitle)
        return copy
    }

    static func clipped(_ item: Lesson.Item) -> Lesson.Item {
        Lesson.Item(task: clip(item.task), owner: clip(item.owner), due: item.due.map(clip))
    }

    static func clip(_ text: String) -> String {
        String(text.prefix(maxTextLength))
    }

    // MARK: - Files and the lock

    private var folder: URL { url.deletingLastPathComponent() }

    private var asideURL: URL { folder.appending(path: url.lastPathComponent + ".corrupt") }

    /// The lock file sits next to lessons.json, because the atomic write replaces lessons.json itself.
    private var lockURL: URL { folder.appending(path: "." + url.lastPathComponent + ".lock") }

    /// Runs `body` while holding an exclusive `flock` on the lock file, trying every `lockRetry` for up to
    /// `lockWait`.
    private func withLock<T>(_ body: () throws -> T) throws -> T {
        let descriptor = open(lockURL.path, O_CREAT | O_RDWR | O_CLOEXEC, 0o644)
        guard descriptor >= 0 else { throw Failure.lockFailed(String(cString: strerror(errno))) }
        defer { close(descriptor) }
        let tries = max(1, Int((lockWait / Self.lockRetry).rounded(.up)))
        var tried = 0
        while flock(descriptor, LOCK_EX | LOCK_NB) != 0 {
            guard errno == EWOULDBLOCK || errno == EINTR else {
                throw Failure.lockFailed(String(cString: strerror(errno)))
            }
            tried += 1
            guard tried < tries else { throw Failure.busy }
            Thread.sleep(forTimeInterval: Self.seconds(Self.lockRetry))
        }
        defer { flock(descriptor, LOCK_UN) }
        return try body()
    }

    private static func seconds(_ duration: Duration) -> TimeInterval {
        let parts = duration.components
        return TimeInterval(parts.seconds) + TimeInterval(parts.attoseconds) / 1e18
    }

    public enum Failure: Error, Equatable, LocalizedError {
        case lockFailed(String)
        /// Another process held the lock for longer than the store waits.
        case busy
        /// lessons.json has a `version` above the one this build writes.
        case newerFile

        public var errorDescription: String? {
            switch self {
            case .lockFailed(let reason): "Earshot couldn't save what it learned: \(reason)."
            case .busy: "Earshot couldn't save what it learned because another copy was saving. Try again."
            case .newerFile: "A newer version of Earshot saved what it learned, so this version won't change it. "
                + "Update Earshot to keep learning."
            }
        }
    }
}
