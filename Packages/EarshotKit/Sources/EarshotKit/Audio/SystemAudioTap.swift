// Packages/EarshotKit/Sources/EarshotKit/Audio/SystemAudioTap.swift
import AVFoundation
import CoreAudio
import Foundation

struct CoreAudioError: Error, LocalizedError, CustomStringConvertible {
    let status: OSStatus
    let call: String
    var description: String { "\(call) failed: OSStatus \(status) '\(fourCC(status))'" }
    var errorDescription: String? { description }
}

func fourCC(_ status: OSStatus) -> String {
    let n = UInt32(bitPattern: status)
    let bytes = [24, 16, 8, 0].map { UInt8((n >> $0) & 0xFF) }
    let printable = bytes.allSatisfy { $0 >= 32 && $0 < 127 }
    return printable ? String(decoding: bytes, as: UTF8.self) : "\(status)"
}

func checkStatus(_ status: OSStatus, _ call: String) throws {
    guard status == noErr else { throw CoreAudioError(status: status, call: call) }
}

enum CoreAudioProps {
    static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                   mElement: kAudioObjectPropertyElementMain)
    }

    static func read<T: BitwiseCopyable>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, initial: T) throws -> T {
        var addr = address(selector)
        var value = initial
        var size = UInt32(MemoryLayout<T>.size)
        try checkStatus(AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &value),
                        "get '\(fourCC(OSStatus(bitPattern: selector)))'")
        return value
    }

    static func readString(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) throws -> String {
        var addr = address(selector)
        var cf: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        try checkStatus(AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &cf),
                        "get string '\(fourCC(OSStatus(bitPattern: selector)))'")
        guard let string = cf?.takeRetainedValue() else { throw CoreAudioError(status: -1, call: "nil CFString") }
        return string as String
    }

    /// pid to the Core Audio process object, which a tap needs to include or exclude a process.
    static func processObject(for pid: pid_t) throws -> AudioObjectID {
        var addr = address(kAudioHardwarePropertyTranslatePIDToProcessObject)
        var qualifier = pid
        var objectID = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        try checkStatus(AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr,
                                                   UInt32(MemoryLayout<pid_t>.size), &qualifier, &size, &objectID),
                        "TranslatePIDToProcessObject")
        return objectID
    }
}

extension AVAudioPCMBuffer {
    /// A deep copy, for handing a no-copy tap buffer to another thread. The original is only valid during the callback.
    func deepCopy() -> AVAudioPCMBuffer? {
        guard let copy = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameLength) else { return nil }
        copy.frameLength = frameLength
        let source = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: audioBufferList))
        let target = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
        for (from, to) in zip(source, target) {
            guard let fromData = from.mData, let toData = to.mData else { continue }
            memcpy(toData, fromData, Int(min(from.mDataByteSize, to.mDataByteSize)))
        }
        return copy
    }
}

/// A stereo mixdown of all system audio except Earshot itself, from a Core Audio process tap on a private,
/// tap-only aggregate device. Never add the output device to the aggregate: some devices then deliver two
/// buffers per cycle and the tap format no longer matches (verified).
final class SystemAudioTap: @unchecked Sendable {
    typealias Handler = @Sendable (AVAudioPCMBuffer, UInt64) -> Void

    private let ioQueue = DispatchQueue(label: "earshot.tap.io", qos: .userInitiated)
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?

    func start(handler: @escaping Handler) throws {
        let me = (try? CoreAudioProps.processObject(for: getpid())).map { [$0] } ?? []
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: me)
        description.uuid = UUID()
        description.name = "Earshot call audio"
        description.isPrivate = true
        description.muteBehavior = .unmuted
        do {
            try checkStatus(AudioHardwareCreateProcessTap(description, &tapID), "AudioHardwareCreateProcessTap")
            let tapUID = try CoreAudioProps.readString(tapID, kAudioTapPropertyUID)
            var asbd = try CoreAudioProps.read(tapID, kAudioTapPropertyFormat, initial: AudioStreamBasicDescription())
            guard let format = AVAudioFormat(streamDescription: &asbd) else {
                throw CoreAudioError(status: -1, call: "AVAudioFormat(streamDescription:)")
            }
            let composition: [String: Any] = [
                kAudioAggregateDeviceNameKey: "Earshot Tap",
                kAudioAggregateDeviceUIDKey: UUID().uuidString,
                kAudioAggregateDeviceIsPrivateKey: true,
                kAudioAggregateDeviceIsStackedKey: false,
                kAudioAggregateDeviceTapAutoStartKey: false,
                kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: tapUID, kAudioSubTapDriftCompensationKey: true]],
            ]
            try checkStatus(AudioHardwareCreateAggregateDevice(composition as CFDictionary, &aggregateID),
                      "AudioHardwareCreateAggregateDevice")
            try checkStatus(AudioDeviceCreateIOProcIDWithBlock(&ioProcID, aggregateID, ioQueue, Self.makeIOBlock(format, handler)),
                      "AudioDeviceCreateIOProcIDWithBlock")
            try checkStatus(AudioDeviceStart(aggregateID, ioProcID), "AudioDeviceStart")
        } catch {
            stop()
            throw error
        }
    }

    /// The stamp's host time, or now if the stamp doesn't carry one. A 0 would make the other track's offset
    /// "seconds since boot" and wreck the merge.
    static func hostTime(of stamp: AudioTimeStamp) -> UInt64 {
        stamp.mFlags.contains(.hostTimeValid) ? stamp.mHostTime : mach_absolute_time()
    }

    /// Built in a nonisolated static func: a block formed in a @MainActor context crashes when Core Audio calls it (verified).
    private static func makeIOBlock(_ format: AVAudioFormat, _ handler: @escaping Handler) -> AudioDeviceIOBlock {
        { _, inInputData, inInputTime, _, _ in
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: inInputData, deallocator: nil),
                  buffer.frameLength > 0 else { return }
            handler(buffer, hostTime(of: inInputTime.pointee))
        }
    }

    func stop() {
        if aggregateID != kAudioObjectUnknown {
            AudioDeviceStop(aggregateID, ioProcID)
            if let ioProcID { AudioDeviceDestroyIOProcID(aggregateID, ioProcID) }
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = AudioObjectID(kAudioObjectUnknown)
            ioProcID = nil
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
    }

    deinit { stop() }
}
