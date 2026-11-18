import CoreAudio
import Foundation

/// Mutes the Mac's output while a dictation records, so music does not leak
/// into the microphone, and restores it afterwards.
@MainActor
final class OutputMuter {
    /// The device we muted, if any. Only our own mute is ever undone.
    private var muted: AudioDeviceID?

    func mute() {
        guard muted == nil, let device = AudioDevices.defaultOutputDeviceID(), Self.isMuted(device) == false else { return }
        if Self.setMuted(true, on: device) { muted = device }
    }

    func restore() {
        if let device = muted { _ = Self.setMuted(false, on: device) }
        muted = nil
    }

    private static var muteAddress = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyMute, mScope: kAudioDevicePropertyScopeOutput,
        mElement: kAudioObjectPropertyElementMain)

    /// nil when the device has no mute control.
    private static func isMuted(_ device: AudioDeviceID) -> Bool? {
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(device, &muteAddress, 0, nil, &size, &value) == noErr else { return nil }
        return value != 0
    }

    private static func setMuted(_ on: Bool, on device: AudioDeviceID) -> Bool {
        var value: UInt32 = on ? 1 : 0
        return AudioObjectSetPropertyData(
            device, &muteAddress, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value) == noErr
    }
}
