import AppKit
import Carbon.HIToolbox
import Foundation
import os

/// A user-recordable keyboard shortcut (key + modifiers) for toggling dictation.
///
/// Stored in UserDefaults as JSON. Requires ⌘/⌥/⌃ (alone or combined, ⇧ may
/// ride along) unless the key is a function key, so a bare letter can never be
/// swallowed system-wide by accident.
struct ToggleShortcut: Codable, Equatable {
    let keyCode: UInt16
    /// NSEvent.ModifierFlags rawValue, reduced to ⌘⌥⌃⇧.
    let rawModifiers: UInt

    init?(keyCode: UInt16, modifierFlags: NSEvent.ModifierFlags) {
        let relevant = modifierFlags.intersection([.command, .option, .control, .shift])
        let hasRealModifier = !relevant.intersection([.command, .option, .control]).isEmpty
        guard hasRealModifier || Self.functionKeyCodes.contains(keyCode) else { return nil }
        self.keyCode = keyCode
        self.rawModifiers = relevant.rawValue
    }

    var modifierFlags: NSEvent.ModifierFlags { .init(rawValue: rawModifiers) }

    var carbonModifiers: UInt32 {
        var carbon: UInt32 = 0
        if modifierFlags.contains(.command) { carbon |= UInt32(cmdKey) }
        if modifierFlags.contains(.option) { carbon |= UInt32(optionKey) }
        if modifierFlags.contains(.control) { carbon |= UInt32(controlKey) }
        if modifierFlags.contains(.shift) { carbon |= UInt32(shiftKey) }
        return carbon
    }

    /// Human-readable form like "⌃⌥⇧⌘D", in the standard macOS modifier order.
    var display: String {
        var s = ""
        if modifierFlags.contains(.control) { s += "⌃" }
        if modifierFlags.contains(.option) { s += "⌥" }
        if modifierFlags.contains(.shift) { s += "⇧" }
        if modifierFlags.contains(.command) { s += "⌘" }
        return s + Self.keyName(for: keyCode)
    }

    static let functionKeyCodes: Set<UInt16> = [
        122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111, 105, 107, 113,
    ]

    private static let specialKeyNames: [UInt16: String] = [
        36: "↩", 48: "⇥", 49: "Space", 51: "⌫", 53: "⎋", 76: "⌤",
        114: "Help", 115: "↖", 116: "⇞", 117: "⌦", 119: "↘", 121: "⇟",
        123: "←", 124: "→", 125: "↓", 126: "↑",
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6",
        98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12",
        105: "F13", 107: "F14", 113: "F15",
    ]

    static func keyName(for keyCode: UInt16) -> String {
        if let name = specialKeyNames[keyCode] { return name }
        guard
            let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
            let layoutPtr = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
        else { return "Key \(keyCode)" }
        let layoutData = Unmanaged<CFData>.fromOpaque(layoutPtr).takeUnretainedValue() as Data

        var deadKeyState: UInt32 = 0
        var chars = [UniChar](repeating: 0, count: 4)
        var length = 0
        let status = layoutData.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> OSStatus in
            let layout = raw.baseAddress!.assumingMemoryBound(to: UCKeyboardLayout.self)
            return UCKeyTranslate(
                layout, keyCode, UInt16(kUCKeyActionDisplay), 0, UInt32(LMGetKbdType()),
                OptionBits(kUCKeyTranslateNoDeadKeysBit), &deadKeyState,
                chars.count, &length, &chars)
        }
        guard status == noErr, length > 0 else { return "Key \(keyCode)" }
        return String(utf16CodeUnits: chars, count: length).uppercased()
    }
}

/// Single owner of all Carbon RegisterEventHotKey registrations.
///
/// Carbon delivers every kEventHotKeyPressed to every installed handler, so
/// per-feature InstallEventHandler calls would cross-fire the moment a second
/// hotkey exists. This center installs ONE handler and dispatches by hotkey ID.
/// Carbon hotkeys consume the keystroke system-wide and need no event tap or
/// TCC grant, so they cannot interfere with the dictation CGEventTap.
@MainActor
final class HotkeyCenter {
    static let shared = HotkeyCenter()

    private let log = Logger(subsystem: "com.alessio.murmur", category: "hotkey-center")
    private static let signature = OSType(0x4D55_5248)  // 'MURH'

    private var handlerInstalled = false
    private var nextID: UInt32 = 1
    private var actions: [UInt32: () -> Void] = [:]
    private var refs: [UInt32: EventHotKeyRef] = [:]

    private init() {}

    /// Register a system-wide hotkey. Returns a token for unregister(), or
    /// nil when the combo is taken by another app.
    func register(
        keyCode: UInt32, carbonModifiers: UInt32, action: @escaping () -> Void
    ) -> UInt32? {
        installHandlerIfNeeded()
        let id = nextID
        nextID += 1
        let hotKeyID = EventHotKeyID(signature: Self.signature, id: id)
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(
            keyCode, carbonModifiers, hotKeyID, GetEventDispatcherTarget(), 0, &ref)
        guard status == noErr, let ref else {
            log.error("RegisterEventHotKey failed (status=\(status, privacy: .public))")
            return nil
        }
        actions[id] = action
        refs[id] = ref
        return id
    }

    func unregister(_ id: UInt32) {
        if let ref = refs.removeValue(forKey: id) {
            UnregisterEventHotKey(ref)
        }
        actions[id] = nil
    }

    private func installHandlerIfNeeded() {
        guard !handlerInstalled else { return }
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(
            GetEventDispatcherTarget(),
            { _, event, _ in
                guard let event else { return noErr }
                var hotKeyID = EventHotKeyID()
                GetEventParameter(
                    event, EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID), nil,
                    MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { HotkeyCenter.shared.fire(hotKeyID) }
                }
                return noErr
            },
            1, &eventType, nil, nil)
        handlerInstalled = true
    }

    private func fire(_ hotKeyID: EventHotKeyID) {
        guard hotKeyID.signature == Self.signature else { return }
        actions[hotKeyID.id]?()
    }
}
