import Foundation

/// One Core Audio client process at one moment.
public struct AudioProcessInfo: Equatable, Hashable, Sendable {
    public var pid: Int32
    public var bundleID: String?
    /// The process is taking input from any device, virtual ones included.
    public var runningInput: Bool
    public var runningOutput: Bool
    /// One of its input devices is a real microphone: the default input device, or a device that is not virtual
    /// and not an aggregate. Always false while `runningInput` is false.
    public var usesRealMicrophone: Bool

    public init(pid: Int32, bundleID: String?, runningInput: Bool, runningOutput: Bool, usesRealMicrophone: Bool) {
        self.pid = pid
        self.bundleID = bundleID
        self.runningInput = runningInput
        self.runningOutput = runningOutput
        self.usesRealMicrophone = usesRealMicrophone
    }
}

/// Where call detection reads which processes use audio. Reading needs no permission.
public protocol AudioProcessSource: Sendable {
    /// The processes connected to Core Audio right now.
    func processes() -> [AudioProcessInfo]
    /// Fires when the process list or a process's input or output state may have changed. Each call starts its own
    /// listeners, and they are removed when the stream ends or its consumer is cancelled. Changes can be missed or
    /// merged, so callers also poll.
    func changes() -> AsyncStream<Void>
}
