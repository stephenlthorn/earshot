import AppKit
import Carbon.HIToolbox
import EarshotKit

/// Earshot's global hotkeys, through Carbon's `RegisterEventHotKey` (spec 8). They need no Accessibility or Input
/// Monitoring permission. Carbon calls the handler on the main thread, so it uses `MainActor.assumeIsolated`
/// (spec 17).
@MainActor
final class Hotkeys {
    enum Key: UInt32, CaseIterable {
        /// ⌃⌥⌘F: flag this moment.
        case flag = 1
        /// ⌃⌥⌘H: collapse the panel to a pill while sharing the screen.
        case sharing = 2

        var keyCode: UInt32 {
            switch self {
            case .flag: UInt32(kVK_ANSI_F)
            case .sharing: UInt32(kVK_ANSI_H)
            }
        }

        var combo: String {
            switch self {
            case .flag: LivePanelText.flagCombo
            case .sharing: LivePanelText.sharingCombo
            }
        }
    }

    static let modifiers = UInt32(controlKey | optionKey | cmdKey)
    /// "EARS", so the handler only answers Earshot's own hotkeys.
    nonisolated static let signature: OSType = 0x4541_5253

    private var registered: [Key: EventHotKeyRef] = [:]
    private var actions: [Key: @MainActor () -> Void] = [:]
    private var handler: EventHandlerRef?

    /// Registers `key` exclusively. False when the system refused it, for example because another app holds it.
    @discardableResult
    func register(_ key: Key, action: @escaping @MainActor () -> Void) -> Bool {
        unregister(key)
        guard installHandler() else { return false }
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(key.keyCode, Self.modifiers, EventHotKeyID(signature: Self.signature, id: key.rawValue),
                                         GetApplicationEventTarget(), OptionBits(kEventHotKeyExclusive), &ref)
        guard status == noErr, let ref else { return false }
        registered[key] = ref
        actions[key] = action
        return true
    }

    func unregister(_ key: Key) {
        if let ref = registered.removeValue(forKey: key) { UnregisterEventHotKey(ref) }
        actions[key] = nil
    }

    func unregisterAll() {
        Key.allCases.forEach(unregister)
    }

    fileprivate func fire(_ id: UInt32) {
        guard let key = Key(rawValue: id) else { return }
        actions[key]?()
    }

    /// One handler for every Earshot hotkey, installed once. The object lives as long as the app (LiveController
    /// owns it), so passing it unretained is safe.
    private func installHandler() -> Bool {
        guard handler == nil else { return true }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let me = Unmanaged.passUnretained(self).toOpaque()
        let status = InstallEventHandler(GetApplicationEventTarget(), hotkeyHandler, 1, &spec, me, &handler)
        return status == noErr
    }
}

/// The Carbon callback. It can't capture anything, so the Hotkeys object comes in through `userData`.
private let hotkeyHandler: EventHandlerUPP = { _, event, userData -> OSStatus in
    guard let event, let userData else { return OSStatus(eventNotHandledErr) }
    var id = EventHotKeyID()
    let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                   nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
    guard status == noErr, id.signature == Hotkeys.signature else { return OSStatus(eventNotHandledErr) }
    let hotkeys = Unmanaged<Hotkeys>.fromOpaque(userData)
    let key = id.id
    MainActor.assumeIsolated { hotkeys.takeUnretainedValue().fire(key) }
    return noErr
}
