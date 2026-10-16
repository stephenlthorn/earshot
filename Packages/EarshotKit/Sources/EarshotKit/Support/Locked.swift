import Foundation

/// A small lock-protected value, for state shared with audio callbacks and with the pipeline's closures.
public final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value
    public init(_ value: Value) { self.value = value }
    public var get: Value { lock.withLock { value } }
    public func update(_ change: (inout Value) -> Void) { lock.withLock { change(&value) } }
}
