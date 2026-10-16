import CoreAudio
import Foundation

/// Reads Core Audio's process objects (macOS 14 and later). Reading them opens no audio IO, so it needs no
/// permission. Listener blocks are built in nonisolated static functions and all run on one serial queue.
public struct CoreAudioProcessSource: AudioProcessSource {
    /// Every listener of every `changes()` stream runs here.
    static let queue = DispatchQueue(label: "earshot.detect.listeners")

    public init() {}

    public func processes() -> [AudioProcessInfo] {
        let defaultInput = HAL.defaultInputDevice()
        return HAL.processObjects().compactMap { HAL.info(for: $0, defaultInput: defaultInput) }
    }

    public func changes() -> AsyncStream<Void> {
        let (stream, continuation) = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
        let watcher = Watcher(continuation: continuation)
        continuation.onTermination = { _ in watcher.stop() }
        watcher.start()
        return stream
    }

    /// A real microphone is the default input device, or any device that is not virtual, not an aggregate and of
    /// a known transport (built-in, USB, Bluetooth and so on).
    static func isRealMicrophone(transportType: UInt32, isDefaultInput: Bool) -> Bool {
        if isDefaultInput { return true }
        let notReal: Set<UInt32> = [kAudioDeviceTransportTypeUnknown, kAudioDeviceTransportTypeVirtual,
                                    kAudioDeviceTransportTypeAggregate, kAudioDeviceTransportTypeAutoAggregate]
        return !notReal.contains(transportType)
    }

    /// Whether a process that is running input uses a real microphone: any of its input devices is the default
    /// input or a real device. When Core Audio lists no input devices, whether the default input is running at all.
    static func usesRealMicrophone(inputDevices: [(id: AudioObjectID, transport: UInt32)], defaultInput: AudioObjectID?,
                                   defaultInputRunningSomewhere: @autoclosure () -> Bool) -> Bool {
        guard !inputDevices.isEmpty else { return defaultInput != nil && defaultInputRunningSomewhere() }
        return inputDevices.contains { isRealMicrophone(transportType: $0.transport, isDefaultInput: $0.id == defaultInput) }
    }

    /// Listens to the process list, the default input device and each process's input and output state.
    /// Its state is only touched on `CoreAudioProcessSource.queue`, hence `@unchecked Sendable`.
    final class Watcher: @unchecked Sendable {
        private let continuation: AsyncStream<Void>.Continuation
        private var systemBlock: AudioObjectPropertyListenerBlock?
        private var processBlocks: [AudioObjectID: AudioObjectPropertyListenerBlock] = [:]
        private var stopped = false

        private static let systemAddresses = [kAudioHardwarePropertyProcessObjectList,
                                              kAudioHardwarePropertyDefaultInputDevice]
        private static let processAddresses = [kAudioProcessPropertyIsRunningInput, kAudioProcessPropertyIsRunningOutput]

        init(continuation: AsyncStream<Void>.Continuation) { self.continuation = continuation }

        func start() {
            CoreAudioProcessSource.queue.async { [self] in
                guard !stopped else { return }
                let block = Self.makeBlock(self, rescan: true)
                systemBlock = block
                for selector in Self.systemAddresses {
                    var address = HAL.address(selector)
                    _ = AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address,
                                                            CoreAudioProcessSource.queue, block)
                }
                watchProcesses()
            }
        }

        func stop() {
            CoreAudioProcessSource.queue.async { [self] in
                guard !stopped else { return }
                stopped = true
                if let systemBlock {
                    for selector in Self.systemAddresses {
                        var address = HAL.address(selector)
                        _ = AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address,
                                                                   CoreAudioProcessSource.queue, systemBlock)
                    }
                }
                systemBlock = nil
                for id in Array(processBlocks.keys) { unwatch(id) }
            }
        }

        /// Built in a nonisolated static func so the block never inherits an actor context (spec 17).
        private static func makeBlock(_ watcher: Watcher, rescan: Bool) -> AudioObjectPropertyListenerBlock {
            { [weak watcher] _, _ in watcher?.changed(rescan: rescan) }
        }

        /// On the queue.
        private func changed(rescan: Bool) {
            guard !stopped else { return }
            if rescan { watchProcesses() }
            continuation.yield()
        }

        /// On the queue: listens to new process objects and forgets ones that are gone.
        private func watchProcesses() {
            let current = Set(HAL.processObjects())
            for id in Array(processBlocks.keys) where !current.contains(id) { unwatch(id) }
            for id in current where processBlocks[id] == nil {
                let block = Self.makeBlock(self, rescan: false)
                var added = false
                for selector in Self.processAddresses {
                    var address = HAL.address(selector)
                    added = AudioObjectAddPropertyListenerBlock(id, &address, CoreAudioProcessSource.queue, block) == noErr
                        || added
                }
                if added { processBlocks[id] = block }
            }
        }

        /// On the queue.
        private func unwatch(_ id: AudioObjectID) {
            guard let block = processBlocks.removeValue(forKey: id) else { return }
            for selector in Self.processAddresses {
                var address = HAL.address(selector)
                _ = AudioObjectRemovePropertyListenerBlock(id, &address, CoreAudioProcessSource.queue, block)
            }
        }
    }

    /// Core Audio property reads. A copy of the few helpers needed here, so Detect doesn't depend on Audio.
    enum HAL {
        static func address(_ selector: AudioObjectPropertySelector,
                            _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
            AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
        }

        static func objects(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                            _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> [AudioObjectID] {
            var address = address(selector, scope)
            var size: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(object, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
            var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
            guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &ids) == noErr else { return [] }
            return Array(ids.prefix(Int(size) / MemoryLayout<AudioObjectID>.size))
        }

        static func value<T: BitwiseCopyable>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                                              initial: T) -> T? {
            var address = address(selector)
            var value = initial
            var size = UInt32(MemoryLayout<T>.size)
            return AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr ? value : nil
        }

        static func string(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
            var address = address(selector)
            var cf: Unmanaged<CFString>?
            var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &cf) == noErr, let cf else { return nil }
            let string = cf.takeRetainedValue() as String  // The header says the caller releases it.
            return string.isEmpty ? nil : string
        }

        static func processObjects() -> [AudioObjectID] {
            objects(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyProcessObjectList)
        }

        static func defaultInputDevice() -> AudioObjectID? {
            value(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultInputDevice,
                  initial: AudioObjectID(kAudioObjectUnknown)).flatMap { $0 == kAudioObjectUnknown ? nil : $0 }
        }

        static func info(for object: AudioObjectID, defaultInput: AudioObjectID?) -> AudioProcessInfo? {
            guard let pid = value(object, kAudioProcessPropertyPID, initial: pid_t(-1)), pid > 0 else { return nil }
            let input = value(object, kAudioProcessPropertyIsRunningInput, initial: UInt32(0)) == 1
            let output = value(object, kAudioProcessPropertyIsRunningOutput, initial: UInt32(0)) == 1
            return AudioProcessInfo(pid: pid, bundleID: string(object, kAudioProcessPropertyBundleID),
                                    runningInput: input, runningOutput: output,
                                    usesRealMicrophone: input && usesRealMicrophone(object, defaultInput: defaultInput))
        }

        /// Reads the process's input devices and their transports for `CoreAudioProcessSource.usesRealMicrophone`.
        static func usesRealMicrophone(_ object: AudioObjectID, defaultInput: AudioObjectID?) -> Bool {
            let devices = objects(object, kAudioProcessPropertyDevices, kAudioObjectPropertyScopeInput).map { device in
                (id: device, transport: value(device, kAudioDevicePropertyTransportType, initial: UInt32(0)) ?? 0)
            }
            return CoreAudioProcessSource.usesRealMicrophone(
                inputDevices: devices, defaultInput: defaultInput,
                defaultInputRunningSomewhere: defaultInput.map {
                    value($0, kAudioDevicePropertyDeviceIsRunningSomewhere, initial: UInt32(0)) == 1
                } ?? false)
        }
    }
}
