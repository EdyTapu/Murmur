import CoreAudio
import Foundation

/// A selectable audio input device, identified by its stable CoreAudio UID
/// (device names can collide; UIDs survive replug and reboot).
struct AudioInputDevice: Identifiable, Equatable, Codable {
    enum Transport: String, Codable { case builtIn, bluetooth, virtual, other }

    let uid: String
    let name: String
    var transport: Transport = .other
    var id: String { uid }

    /// Name for lists; says when picking it would use a headset's microphone.
    var label: String { transport == .bluetooth ? name + " (Bluetooth)" : name }
}

/// CoreAudio enumeration of input-capable devices.
enum AudioDevices {
    static func inputDevices() -> [AudioInputDevice] {
        allDeviceIDs().compactMap { device in
            guard inputChannelCount(device) > 0,
                let uid = stringProperty(device, kAudioDevicePropertyDeviceUID),
                let name = stringProperty(device, kAudioObjectPropertyName),
                // The audio engine's own private aggregate, visible only inside this process.
                !name.hasPrefix("CADefaultDeviceAggregate")
            else { return nil }
            return AudioInputDevice(uid: uid, name: name, transport: transport(device))
        }
    }

    /// Which microphone to record from: the first ranked one that is
    /// connected, otherwise the system default - unless that is a Bluetooth
    /// headset. Opening a headset's mic drops the headphones into their
    /// low-quality call profile, so an unranked headset is never used while
    /// any other mic exists. Returns nil to follow the system default.
    static func chooseInput(
        ranked: [String], connected: [AudioInputDevice], systemDefaultUID: String?
    ) -> String? {
        if let preferred = ranked.first(where: { uid in connected.contains { $0.uid == uid } }) {
            return preferred
        }
        guard connected.first(where: { $0.uid == systemDefaultUID })?.transport == .bluetooth else { return nil }
        // Virtual devices (Zoom, BlackHole, aggregates) record silence unless something feeds them.
        let wired = connected.filter { $0.transport == .builtIn || $0.transport == .other }
        return (wired.first { $0.transport == .builtIn } ?? wired.first)?.uid
    }

    private static var defaultInputAddress: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
    }

    /// Make the microphone Murmur should use (`chooseInput`) the Mac's input
    /// device. The recorder can only follow the system default: pointing
    /// AVAudioEngine's input unit at a device of its own delivers no audio at
    /// all on macOS 27 (measured: zero buffers, with either device API).
    /// Returns true when the system default was changed.
    @discardableResult
    static func enforcePreferredInput() -> Bool {
        let systemDefault = defaultInputDeviceID()
        // Another app (FaceTime, Zoom) is recording from it: the headset is
        // already in its call profile, and moving the default away tears that
        // down mid-call and silences the headphones. Dictation records from
        // the headset instead, and `OutputMuter` pauses the call's sound meanwhile.
        if let systemDefault, isRunningSomewhere(systemDefault) { return false }
        guard
            let chosen = chooseInput(
                ranked: Prefs.micPriority.map(\.uid), connected: inputDevices(),
                systemDefaultUID: systemDefault.flatMap { stringProperty($0, kAudioDevicePropertyDeviceUID) }),
            var device = deviceID(forUID: chosen), device != systemDefault
        else { return false }
        var address = defaultInputAddress
        return AudioObjectSetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil,
            UInt32(MemoryLayout<AudioDeviceID>.size), &device) == noErr
    }

    /// The sample rate a device is currently running at. Connecting a display
    /// or headphones can change the built-in microphone's rate.
    static func sampleRate(of device: AudioDeviceID) -> Double? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var rate = Float64(0)
        var size = UInt32(MemoryLayout<Float64>.size)
        return AudioObjectGetPropertyData(device, &address, 0, nil, &size, &rate) == noErr ? rate : nil
    }

    /// Call `handler` on the main queue whenever the Mac's input device changes
    /// (headphones connecting, a mic being unplugged, the user picking another).
    static func onDefaultInputChange(_ handler: @escaping @Sendable () -> Void) {
        var address = defaultInputAddress
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &address, DispatchQueue.main) { _, _ in handler() }
    }

    static func deviceID(forUID uid: String) -> AudioDeviceID? {
        guard !uid.isEmpty else { return nil }
        return allDeviceIDs().first {
            inputChannelCount($0) > 0 && stringProperty($0, kAudioDevicePropertyDeviceUID) == uid
        }
    }

    static func defaultInputDeviceID() -> AudioDeviceID? {
        systemDevice(kAudioHardwarePropertyDefaultInputDevice)
    }

    /// The Mac's output device; headphones become it when they connect.
    static func defaultOutputDeviceID() -> AudioDeviceID? {
        systemDevice(kAudioHardwarePropertyDefaultOutputDevice)
    }

    static func outputDeviceIDs() -> [AudioDeviceID] {
        allDeviceIDs().filter { channelCount($0, scope: kAudioDevicePropertyScopeOutput) > 0 }
    }

    private static func systemDevice(_ selector: AudioObjectPropertySelector) -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device)
        return status == noErr && device != 0 ? device : nil
    }

    // MARK: - Internals

    static func isRunningSomewhere(_ device: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var running: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(device, &address, 0, nil, &size, &running) == noErr && running != 0
    }

    private static func allDeviceIDs() -> [AudioDeviceID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard
            AudioObjectGetPropertyDataSize(
                AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr,
            size > 0
        else { return [] }
        var devices = [AudioDeviceID](
            repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &devices)
                == noErr
        else { return [] }
        return devices
    }

    private static func transport(_ device: AudioDeviceID) -> AudioInputDevice.Transport {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr else { return .other }
        switch value {
        case kAudioDeviceTransportTypeBuiltIn: return .builtIn
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: return .bluetooth
        case kAudioDeviceTransportTypeVirtual, kAudioDeviceTransportTypeAggregate: return .virtual
        default: return .other
        }
    }

    private static func inputChannelCount(_ device: AudioDeviceID) -> Int {
        channelCount(device, scope: kAudioDevicePropertyScopeInput)
    }

    private static func channelCount(_ device: AudioDeviceID, scope: AudioObjectPropertyScope) -> Int {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr,
            size > 0
        else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(
            byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, raw) == noErr else {
            return 0
        }
        let bufferList = UnsafeMutableAudioBufferListPointer(
            raw.assumingMemoryBound(to: AudioBufferList.self))
        return bufferList.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    private static func stringProperty(
        _ device: AudioDeviceID, _ selector: AudioObjectPropertySelector
    ) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var value: CFString?
        var size = UInt32(MemoryLayout<CFString?>.size)
        let status = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(device, &address, 0, nil, &size, $0)
        }
        guard status == noErr, let value else { return nil }
        return value as String
    }
}
