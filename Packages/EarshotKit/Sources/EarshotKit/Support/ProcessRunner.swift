import Foundation

public struct ProcessOutput: Equatable, Sendable {
    public var status: Int32
    public var stdout: String
    public var stderr: String
    public var timedOut: Bool

    public init(status: Int32, stdout: String, stderr: String, timedOut: Bool) {
        self.status = status
        self.stdout = stdout
        self.stderr = stderr
        self.timedOut = timedOut
    }
}

public protocol ProcessRunning: Sendable {
    /// With `inheritEnvironment` the child gets Earshot's own environment with `environment` laid over it. Without
    /// it, the child's environment is exactly `environment`: every `claude` child runs this way (spec 3.1).
    func run(_ executable: String, _ arguments: [String], stdin: Data?, directory: URL?,
             environment: [String: String], inheritEnvironment: Bool, timeout: Duration) async throws -> ProcessOutput
}

extension ProcessRunning {
    /// The v1 call: `environment` is merged over Earshot's own.
    public func run(_ executable: String, _ arguments: [String], stdin: Data?, directory: URL?,
                    environment: [String: String], timeout: Duration) async throws -> ProcessOutput {
        try await run(executable, arguments, stdin: stdin, directory: directory, environment: environment,
                      inheritEnvironment: true, timeout: timeout)
    }
}

/// The programs a set of runners has started and not yet seen finish, so quitting the app can stop them all
/// instead of leaving them running on their own.
public final class ProcessRegistry: @unchecked Sendable {
    public static let shared = ProcessRegistry()

    private let lock = NSLock()
    private var live: [ObjectIdentifier: Process] = [:]
    private var stopping = false

    public init() {}

    public var count: Int { lock.withLock { live.count } }
    public var isStopping: Bool { lock.withLock { stopping } }

    /// False once `terminateAll()` has run: the caller must stop the program itself.
    func add(_ process: Process) -> Bool {
        lock.withLock {
            guard !stopping else { return false }
            live[ObjectIdentifier(process)] = process
            return true
        }
    }

    func remove(_ process: Process) {
        _ = lock.withLock { live.removeValue(forKey: ObjectIdentifier(process)) }
    }

    /// For quitting: from now on no program starts, and every one still running gets SIGTERM, then SIGKILL if it is
    /// still there after `grace` seconds. Their `run` calls throw `CancellationError`. Blocks for at most about
    /// `grace` seconds.
    public func terminateAll(grace: TimeInterval = 2) {
        let running = lock.withLock {
            stopping = true
            return Array(live.values)
        }
        for process in running where process.isRunning { process.terminate() }
        let deadline = Date().addingTimeInterval(grace)
        while running.contains(where: \.isRunning), Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
        for process in running where process.isRunning { kill(process.processIdentifier, SIGKILL) }
    }
}

/// Runs a program and collects what it prints. `timeout` and cancellation of the calling task both stop the
/// program, and neither waits on pipe I/O: the pipes are served by their own threads, never by the async pool.
public struct ProcessRunner: ProcessRunning {
    /// How long to keep reading after the program has gone, for a background child that still holds the pipes.
    static let pipeGrace: Duration = .seconds(1)
    /// How long a program gets to obey SIGTERM before it is sent SIGKILL.
    static let terminateGrace: Duration = .seconds(2)

    let registry: ProcessRegistry

    public init(registry: ProcessRegistry = .shared) {
        self.registry = registry
    }

    /// Throws `CancellationError` once the calling task is cancelled, after the program has been stopped, and when
    /// the registry stopped it (the app is quitting), so a stopped program never passes for a finished one.
    public func run(_ executable: String, _ arguments: [String], stdin: Data?, directory: URL?,
                    environment: [String: String], inheritEnvironment: Bool, timeout: Duration) async throws -> ProcessOutput {
        try Task.checkCancellation()
        if registry.isStopping { throw CancellationError() }
        signal(SIGPIPE, SIG_IGN)  // a child that exits before reading stdin must not kill the app
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let directory { process.currentDirectoryURL = directory }
        process.environment = inheritEnvironment
            ? ProcessInfo.processInfo.environment.merging(environment) { $1 } : environment
        let output = Pipe(), errors = Pipe(), input = Pipe()
        process.standardOutput = output
        process.standardError = errors
        process.standardInput = input
        try process.run()
        guard registry.add(process) else {
            // terminateAll() ran while this one was starting.
            await Self.stop(process)
            throw CancellationError()
        }
        defer { registry.remove(process) }
        // Read both streams while the child runs, so a full pipe never blocks it.
        let outRead = PipePump.reading(output.fileHandleForReading)
        let errRead = PipePump.reading(errors.fileHandleForReading)
        var pumps = [outRead, errRead]
        if let stdin, !stdin.isEmpty {
            pumps.append(PipePump.writing(stdin, to: input.fileHandleForWriting))
        } else {
            try? input.fileHandleForWriting.close()
        }
        let ending = await Self.wait(for: process, timeout: timeout)
        let stopped = ending == .cancelled || registry.isStopping
        await Self.settle(pumps, grace: stopped ? .zero : Self.pipeGrace)
        if stopped { throw CancellationError() }
        return ProcessOutput(status: process.isRunning ? -1 : process.terminationStatus,
                             stdout: String(decoding: outRead.data, as: UTF8.self),
                             stderr: String(decoding: errRead.data, as: UTF8.self),
                             timedOut: ending == .timedOut)
    }

    enum Ending { case exited, timedOut, cancelled }

    static func wait(for process: Process, timeout: Duration) async -> Ending {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while process.isRunning {
            if Task.isCancelled {
                await stop(process)
                return .cancelled
            }
            if ContinuousClock.now >= deadline {
                await stop(process)
                return .timedOut
            }
            await pause(milliseconds: 50)
        }
        return .exited
    }

    /// SIGTERM, then SIGKILL if the program is still there after `terminateGrace`.
    static func stop(_ process: Process) async {
        process.terminate()
        await pause(until: { !process.isRunning }, for: terminateGrace)
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        await pause(until: { !process.isRunning }, for: terminateGrace)
    }

    /// Lets the pumps reach the end of their pipes for up to `grace`, then stops them and waits for them to let go.
    static func settle(_ pumps: [PipePump], grace: Duration) async {
        await pause(until: { pumps.allSatisfy(\.isDone) }, for: grace)
        for pump in pumps { pump.stop() }
        await pause(until: { pumps.allSatisfy(\.isDone) }, for: .seconds(2))
    }

    static func pause(until condition: () -> Bool, for limit: Duration) async {
        let deadline = ContinuousClock.now.advanced(by: limit)
        while !condition(), ContinuousClock.now < deadline { await pause(milliseconds: 10) }
    }

    /// A sleep that cancelling the caller does not cut short, so clean-up after a cancel never spins.
    static func pause(milliseconds: Int) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(milliseconds)) { continuation.resume() }
        }
    }
}

/// Moves bytes between one pipe end and memory on a thread of its own. It polls in short slices instead of
/// blocking, so `stop()` always takes effect within one slice, and it closes its end of the pipe when it finishes.
final class PipePump: @unchecked Sendable {
    private static let sliceMilliseconds: Int32 = 100

    private let lock = NSLock()
    private var wanted = true
    private var finished = false
    private var collected = Data()

    var isDone: Bool { lock.withLock { finished } }
    var data: Data { lock.withLock { collected } }
    func stop() { lock.withLock { wanted = false } }

    private var shouldContinue: Bool { lock.withLock { wanted } }

    static func reading(_ handle: FileHandle) -> PipePump {
        let pump = PipePump()
        Thread.detachNewThread { pump.read(handle) }
        return pump
    }

    static func writing(_ data: Data, to handle: FileHandle) -> PipePump {
        let pump = PipePump()
        Thread.detachNewThread { pump.write(data, to: handle) }
        return pump
    }

    private func read(_ handle: FileHandle) {
        let descriptor = Self.nonBlocking(handle)
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while shouldContinue {
            guard Self.ready(descriptor, events: POLLIN) else { continue }
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count > 0 {
                lock.withLock { collected.append(contentsOf: buffer[..<count]) }
            } else if count == 0 || (errno != EINTR && errno != EAGAIN) {
                break  // end of the stream, or the pipe is unusable
            }
        }
        try? handle.close()
        lock.withLock { finished = true }
    }

    private func write(_ data: Data, to handle: FileHandle) {
        let descriptor = Self.nonBlocking(handle)
        data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count, shouldContinue {
                guard Self.ready(descriptor, events: POLLOUT) else { continue }
                let count = Darwin.write(descriptor, bytes.baseAddress! + offset, bytes.count - offset)
                if count > 0 {
                    offset += count
                } else if count < 0 && errno != EINTR && errno != EAGAIN {
                    break  // the child has gone (EPIPE) or the pipe is unusable
                }
            }
        }
        try? handle.close()
        lock.withLock { finished = true }
    }

    private static func nonBlocking(_ handle: FileHandle) -> Int32 {
        let descriptor = handle.fileDescriptor
        _ = fcntl(descriptor, F_SETFL, fcntl(descriptor, F_GETFL) | O_NONBLOCK)
        return descriptor
    }

    /// True when the descriptor can be read or written now (or has hung up or failed, which the next call reports).
    /// False after one idle slice or an interrupted wait, so the caller re-checks whether it should keep going.
    private static func ready(_ descriptor: Int32, events: Int32) -> Bool {
        var request = pollfd(fd: descriptor, events: Int16(events), revents: 0)
        return poll(&request, 1, sliceMilliseconds) > 0
    }
}
