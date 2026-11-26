import AVFoundation
import AppKit
import Foundation
import CoreAudio
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

// Serialized: both tests drive the one real microphone.
@Suite(.serialized) struct AudioRecorderTests {
    /// The recorder once went silent because of how it selected its device,
    /// and nothing caught it. Opens the real microphone for about a second.
    @Test func capturesAudioFromTheInputDevice() async throws {
        guard AudioDevices.defaultInputDeviceID() != nil else { return }  // no microphone on this machine
        let recorder = AudioRecorder()
        await recorder.warmUp()
        recorder.startCollecting(onEngineFailure: {})
        try await Task.sleep(for: .milliseconds(1200))
        let samples = recorder.stopCollecting()
        #expect(samples.count > 8_000, "about a second was recorded, so at least half of it must arrive")

        // The same must hold after the input device changed and the engine was rebuilt.
        recorder.reconfigureInputDevice()
        await recorder.warmUp()
        recorder.startCollecting(onEngineFailure: {})
        try await Task.sleep(for: .milliseconds(1200))
        #expect(recorder.stopCollecting().count > 8_000)
    }

    /// Connecting a display or headphones changes the microphone's sample rate
    /// while Murmur sits idle. The engine then refused to start ("Couldn't
    /// start the microphone"). Flips the real device's rate and restores it.
    @Test func keepsCapturingAfterTheSampleRateChanges() async throws {
        guard let device = AudioDevices.defaultInputDeviceID(), let original = AudioDevices.sampleRate(of: device)
        else { return }
        func setRate(_ rate: Double) -> Bool {
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyNominalSampleRate,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain)
            var value = rate
            return AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<Float64>.size), &value) == noErr
        }
        let other: Double = original == 48_000 ? 44_100 : 48_000
        let recorder = AudioRecorder()
        await recorder.warmUp()
        guard setRate(other) else { return }  // a microphone with a single fixed rate
        defer { _ = setRate(original) }
        try await Task.sleep(for: .milliseconds(700))

        let failed = Flag()
        recorder.startCollecting(onEngineFailure: { failed.set() })
        try await Task.sleep(for: .milliseconds(1500))
        let samples = recorder.stopCollecting()
        #expect(!failed.value, "the engine must start after a rate change")
        #expect(samples.count > 8_000)
    }
}

extension AudioRecorderTests {
    /// Connecting headphones makes them the Mac's output device, which
    /// reconfigures the engine (its I/O unit spans input and output) while
    /// Murmur sits idle. Dictation then stopped working. Switches the real
    /// default output to another device and back.
    @Test func keepsCapturingAfterTheOutputDeviceChanges() async throws {
        guard AudioDevices.defaultInputDeviceID() != nil, let original = AudioDevices.defaultOutputDeviceID()
        else { return }
        let recorder = AudioRecorder()
        await recorder.warmUp()
        // Headphones run at their own rate (Bluetooth: 44.1 kHz or lower), so prefer a device that differs.
        let rate = AudioDevices.sampleRate(of: original)
        let candidates = AudioDevices.outputDeviceIDs().filter { $0 != original }
            .sorted { (AudioDevices.sampleRate(of: $0) != rate ? 0 : 1) < (AudioDevices.sampleRate(of: $1) != rate ? 0 : 1) }
        // Some devices (virtual ones) refuse to become the default output.
        guard candidates.contains(where: { AudioDevices.setDefaultOutput($0) && AudioDevices.defaultOutputDeviceID() == $0 })
        else { return }  // needs a second output device
        defer { _ = AudioDevices.setDefaultOutput(original) }
        try await Task.sleep(for: .milliseconds(1000))

        let failed = Flag()
        recorder.startCollecting(onEngineFailure: { failed.set() })
        try await Task.sleep(for: .milliseconds(1500))
        let samples = recorder.stopCollecting()
        #expect(!failed.value, "the engine must start after the output device changed")
        #expect(samples.count > 8_000)
    }

    /// A connecting headset flips the Mac's devices and settles within a
    /// second, back on the ones the engine was built for. Nothing looks
    /// changed afterwards, yet the engine is dead: only its own
    /// configuration-change notification says so. Switches the real default
    /// output to another device and straight back.
    @Test func keepsCapturingAfterTheOutputDeviceFlipsAndReturns() async throws {
        guard AudioDevices.defaultInputDeviceID() != nil, let original = AudioDevices.defaultOutputDeviceID()
        else { return }
        let recorder = AudioRecorder()
        let observer = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: nil, queue: nil
        ) { note in
            _ = recorder.noteConfigurationChange(from: (note.object as AnyObject?).map(ObjectIdentifier.init))
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        await recorder.warmUp()
        let candidates = AudioDevices.outputDeviceIDs().filter { $0 != original }
        guard candidates.contains(where: { AudioDevices.setDefaultOutput($0) && AudioDevices.defaultOutputDeviceID() == $0 })
        else { return }  // needs a second output device
        try await Task.sleep(for: .milliseconds(300))
        _ = AudioDevices.setDefaultOutput(original)
        // As long as the app waits: rebuilding while the devices still settle can hang inside AVFAudio.
        try await Task.sleep(for: .milliseconds(4500))

        #expect(recorder.isStale, "the engine's own notification must mark it stale")
        #expect(await recorder.rebuild(), "the rebuilt engine must deliver audio")
        recorder.startCollecting(onEngineFailure: {})
        try await Task.sleep(for: .milliseconds(1500))
        #expect(recorder.stopCollecting().count > 8_000)
    }
}

extension AudioRecorderTests {
    /// Dictating during a FaceTime call on a Bluetooth headset. Murmur used to
    /// move the Mac's input off the headset mic, which tore down the call's
    /// audio and left the headphones silent. Now the call keeps its headset,
    /// the dictation records from it, and the headphones are muted only while
    /// dictating. Needs a connected Bluetooth headset; the "call" is an engine
    /// on its microphone.
    @Test func dictationDuringACallKeepsTheHeadsetAndOnlyPausesItsSound() async throws {
        guard let original = AudioDevices.defaultInputDeviceID(),
            let headset = AudioDevices.inputDevices().first(where: { $0.transport == .bluetooth })
                .flatMap({ AudioDevices.deviceID(forUID: $0.uid) })
        else { return }  // needs a Bluetooth headset
        defer { _ = AudioDevices.setDefaultInput(original) }
        guard AudioDevices.setDefaultInput(headset) else { return }
        try await Task.sleep(for: .milliseconds(1500))

        let call = AVAudioEngine()
        let format = call.inputNode.outputFormat(forBus: 0)
        call.inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { _, _ in }
        try call.start()
        defer { call.stop() }
        try await Task.sleep(for: .milliseconds(2500))  // the headset switches to its call profile

        #expect(AudioDevices.isRunningSomewhere(headset))
        #expect(!AudioDevices.enforcePreferredInput(), "the call keeps its headset microphone")
        #expect(AudioDevices.defaultInputDeviceID() == headset)

        let recorder = AudioRecorder()
        await recorder.warmUp()
        let muter = await OutputMuter()
        let failed = Flag()
        recorder.startCollecting(onEngineFailure: { failed.set() })
        await muter.mute()
        let output = try #require(AudioDevices.defaultOutputDeviceID())
        #expect(isMuted(output) == true, "the call's sound pauses while dictating")
        // Long enough to pass the moment a headset that changes profile kills the engine (measured at 2.4 s).
        try await Task.sleep(for: .milliseconds(4000))
        let samples = recorder.stopCollecting()
        await muter.restore()
        #expect(isMuted(output) == false, "and comes back when the dictation ends")
        #expect(!failed.value)
        #expect(samples.count > 16_000 * 3, "the whole dictation is recorded from the headset")
    }

    private func isMuted(_ device: AudioDeviceID) -> Bool? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute, mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value != 0
    }
}

private extension AudioDevices {
    static func setDefaultOutput(_ device: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var value = device
        return AudioObjectSetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil,
            UInt32(MemoryLayout<AudioDeviceID>.size), &value) == noErr
    }

    static func setDefaultInput(_ device: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var value = device
        return AudioObjectSetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil,
            UInt32(MemoryLayout<AudioDeviceID>.size), &value) == noErr
    }
}

private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var raised = false
    var value: Bool { lock.withLock { raised } }
    func set() { lock.withLock { raised = true } }
}
