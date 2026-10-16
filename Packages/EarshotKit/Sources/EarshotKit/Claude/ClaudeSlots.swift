import Foundation

/// The cross-process limit for structured `claude` children (spec 3.2). `ClaudeGate` limits one process; the app,
/// the `earshot` tool and the plugin hook are separate processes, and many `claude` children refreshing one login at
/// once can sign the user out. So each structured call also holds one of `count` slot files in
/// `~/Library/Application Support/Earshot/Locks`, with an exclusive `flock`.
///
/// The system drops a `flock` when its holder exits, however it exits, so a crashed holder never blocks anyone. A
/// slot folder that can't be made or opened never blocks a call either: the call then runs without this limit.
public struct ClaudeSlots: Sendable {
    /// Where the slot files sit inside Application Support.
    static let applicationSupportPath = "Earshot/Locks"

    public static let shared = ClaudeSlots(
        folder: URL.applicationSupportDirectory.appending(path: applicationSupportPath, directoryHint: .isDirectory))

    /// The slot folder for the user whose home folder is `home`, for the command line, which runs against the home
    /// it is given.
    public static func defaultFolder(home: URL) -> URL {
        home.appending(path: "Library/Application Support", directoryHint: .isDirectory)
            .appending(path: applicationSupportPath, directoryHint: .isDirectory)
    }

    public let folder: URL
    /// How many structured calls may run at once across every Earshot process.
    public let count: Int
    /// How long to wait between tries while every slot is taken.
    public let retry: Duration
    /// How many tries a call that may be skipped (a live pass) makes before it gives up.
    public let skipTries: Int
    let sleep: @Sendable (Duration) async throws -> Void

    public init(folder: URL, count: Int = 2, retry: Duration = .milliseconds(250), skipTries: Int = 3,
                sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) {
        self.folder = folder
        self.count = max(1, count)
        self.retry = retry
        self.skipTries = max(1, skipTries)
        self.sleep = sleep
    }

    /// Slot file `index`, counted from 0: "structured-1.lock" for the first.
    public func slotFile(_ index: Int) -> URL { folder.appending(path: "structured-\(index + 1).lock") }

    /// Runs `body` while holding a slot. With `skipIfBusy`, returns nil when no slot is free after `skipTries`
    /// short tries; otherwise waits for one. A caller cancelled while it waits throws `CancellationError`.
    public func run<T: Sendable>(skipIfBusy: Bool, _ body: @Sendable () async throws -> T) async throws -> T? {
        var tries = 0
        while true {
            switch acquire() {
            case let .held(descriptor):
                defer { Self.release(descriptor) }
                return try await body()
            case .unavailable:
                return try await body()
            case .busy:
                tries += 1
                if skipIfBusy, tries >= skipTries { return nil }
                try Task.checkCancellation()
                try await sleep(retry)
            }
        }
    }

    enum Acquired: Equatable {
        /// The open descriptor that holds the lock.
        case held(Int32)
        /// Every slot is held by another call.
        case busy
        /// No slot file could be opened or locked for another reason.
        case unavailable
    }

    /// One try at every slot, without waiting.
    func acquire() -> Acquired {
        guard (try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)) != nil else {
            return .unavailable
        }
        var anyBusy = false
        for index in 0..<count {
            // Close-on-exec, so a `claude` child never inherits the descriptor and keeps the slot after we let go.
            let descriptor = open(slotFile(index).path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
            guard descriptor >= 0 else { continue }
            if flock(descriptor, LOCK_EX | LOCK_NB) == 0 { return .held(descriptor) }
            if errno == EWOULDBLOCK || errno == EINTR { anyBusy = true }
            close(descriptor)
        }
        return anyBusy ? .busy : .unavailable
    }

    static func release(_ descriptor: Int32) {
        flock(descriptor, LOCK_UN)
        close(descriptor)
    }
}
