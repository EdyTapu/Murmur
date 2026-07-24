import AppKit
import Foundation
import Testing

@testable import Murmur

@Suite struct ToggleShortcutTests {
    @Test func requiresRealModifierForNormalKeys() {
        // Bare 'A' (keyCode 0) and shift-only must be rejected.
        #expect(ToggleShortcut(keyCode: 0, modifierFlags: []) == nil)
        #expect(ToggleShortcut(keyCode: 0, modifierFlags: [.shift]) == nil)
        #expect(ToggleShortcut(keyCode: 0, modifierFlags: [.command]) != nil)
        #expect(ToggleShortcut(keyCode: 0, modifierFlags: [.control, .shift]) != nil)
    }

    @Test func allowsBareFunctionKeys() {
        // F5 (keyCode 96) may stand alone.
        #expect(ToggleShortcut(keyCode: 96, modifierFlags: []) != nil)
    }

    @Test func stripsIrrelevantModifiers() {
        let shortcut = ToggleShortcut(
            keyCode: 0, modifierFlags: [.command, .capsLock, .function])
        #expect(shortcut?.modifierFlags == [.command])
    }

    @Test func carbonModifierMapping() throws {
        let shortcut = try #require(
            ToggleShortcut(keyCode: 0, modifierFlags: [.command, .option, .control, .shift]))
        // Carbon HIToolbox: cmdKey 0x100, shiftKey 0x200, optionKey 0x800, controlKey 0x1000.
        let expected: UInt32 = 0x100 | 0x200 | 0x800 | 0x1000
        #expect(shortcut.carbonModifiers == expected)
    }

    @Test func roundTripsThroughCodable() throws {
        let original = try #require(
            ToggleShortcut(keyCode: 49, modifierFlags: [.option, .command]))
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ToggleShortcut.self, from: data)
        #expect(decoded == original)
    }

    @Test func displayUsesStandardModifierOrderAndSpecialNames() {
        let shortcut = ToggleShortcut(
            keyCode: 49, modifierFlags: [.command, .shift, .option, .control])
        #expect(shortcut?.display == "⌃⌥⇧⌘Space")
        let arrows = ToggleShortcut(keyCode: 126, modifierFlags: [.control])
        #expect(arrows?.display == "⌃↑")
    }
}

@Suite struct AudioDevicesTests {
    @Test func enumerationDoesNotCrashAndFiltersBogusUIDs() {
        // Device presence varies by machine; the contract is: no crash,
        // every listed device has a non-empty uid + name, bogus UIDs resolve nil.
        let devices = AudioDevices.inputDevices()
        for device in devices {
            #expect(!device.uid.isEmpty)
            #expect(!device.name.isEmpty)
        }
        #expect(AudioDevices.deviceID(forUID: "definitely-not-a-real-uid") == nil)
        #expect(AudioDevices.deviceID(forUID: "") == nil)
    }
}
