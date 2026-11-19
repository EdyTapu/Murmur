import AVFoundation
import AudioToolbox
import Foundation
import os

/// Captures microphone audio into an in-memory buffer list.
///
/// The engine is prepared and warmed at launch and kept installed permanently;
/// recording start only flips a flag (plus `engine.start()` if paused). This is
/// the defense against the classic dictation-app race where lazy audio-engine
/// startup silently loses short utterances.
final class AudioRecorder: @unchecked Sendable {
    private let log = Logger(subsystem: "com.alessio.murmur", category: "audio")

    /// Replaced whenever the Mac's input device changes: an engine stays bound
    /// to the device that was the system default when it was created.
    private var engine = AVAudioEngine()
    private let lock = NSLock()
    private var buffers: [AVAudioPCMBuffer] = []
    private var collecting = false
    private var tapInstalled = false
    private var lastVoiceAt: Date = .distantPast
    private var peakLevel: Float = 0
    private var loudestRMS: Float = 0

    /// Called on the main queue, throttled, with a 0...1 mic level while collecting.
    var onLevel: (@Sendable (Float) -> Void)?
    private var lastLevelPush = Date.distantPast

    /// RMS threshold above which a buffer counts as "voice" for silence auto-stop.
    static let voiceRMSThreshold: Float = 0.015

    private var idlePauseTask: Task<Void, Never>?

    /// The devices and input sample rate the tap was built for. When the Mac's
    /// input no longer matches, the engine refuses to start (error -10868).
    /// The engine's I/O unit also spans the output device: after headphones
    /// become the output, the old engine starts but delivers no input at all.
    private var tapDevice: AudioDeviceID?
    private var tapOutputDevice: AudioDeviceID?
    private var tapSampleRate: Double = 0

    /// Set when the engine reports that its hardware configuration changed.
    /// From then on it starts but delivers no audio, even with the same
    /// devices and sample rate: connecting headphones rebuilds the engine while
    /// they are still in their call profile, and they switch to stereo after.
    private var configurationChanged = false
    /// Buffers the tap has received; tells a live microphone from a dead engine.
    private var tapCount = 0

    /// Record an `AVAudioEngineConfigurationChange`. False when it came from
    /// an engine that was already replaced.
    func noteConfigurationChange(from source: ObjectIdentifier?) -> Bool {
        guard source == ObjectIdentifier(engine) else { return false }
        configurationChanged = true
        return true
    }

    /// True when the engine's configuration, the Mac's input or output device, or the input's sample rate changed since the tap was installed.
    var isStale: Bool {
        guard tapInstalled else { return false }
        if configurationChanged { return true }
        guard let device = AudioDevices.defaultInputDeviceID() else { return false }
        return device != tapDevice || AudioDevices.sampleRate(of: device) != tapSampleRate
            || AudioDevices.defaultOutputDeviceID() != tapOutputDevice
    }

    // MARK: - Lifecycle

    /// Install the tap and prepare the engine. Call once after mic permission is granted.
    func prepare() {
        guard !tapInstalled else { return }
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            log.error("Input node has invalid format; is a microphone available?")
            return
        }
        input.installTap(onBus: 0, bufferSize: 2048, format: format) { [weak self] buffer, _ in
            self?.handleTap(buffer)
        }
        tapInstalled = true
        tapDevice = AudioDevices.defaultInputDeviceID()
        tapOutputDevice = AudioDevices.defaultOutputDeviceID()
        tapSampleRate = tapDevice.flatMap(AudioDevices.sampleRate(of:)) ?? format.sampleRate
        engine.prepare()
        log.info("Audio tap installed, format \(format.sampleRate, privacy: .public)Hz x\(format.channelCount, privacy: .public)")
    }

    /// Start over on the Mac's current input device. Call while idle.
    func reconfigureInputDevice() {
        engine.stop()
        if tapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        engine = AVAudioEngine()
        configurationChanged = false
        prepare()
    }

    /// Start over on the Mac's current devices and check that audio arrives.
    /// An engine built while a connecting headset is still switching profiles
    /// can come up dead, so this tries up to three times. Call while idle.
    func rebuild() async -> Bool {
        for attempt in 1...3 {
            // A dictation that started meanwhile owns the engine now.
            guard !Task.isCancelled, !isCollecting else { break }
            reconfigureInputDevice()
            if await warmUp() { return true }
            log.notice("Rebuilt audio engine delivered no audio (attempt \(attempt, privacy: .public))")
            try? await Task.sleep(for: .seconds(1))
        }
        return false
    }

    /// Spin the engine briefly so the audio unit is fully initialized, then pause.
    /// After this, `engine.start()` returns in a few ms.
    /// Returns whether the microphone delivered audio meanwhile.
    @discardableResult
    func warmUp() async -> Bool {
        prepare()
        guard tapInstalled else { return false }
        do {
            let before = buffersReceived
            try engine.start()
            try? await Task.sleep(for: .milliseconds(400))
            // Not a plain pause: a dictation may have started during the warm-up.
            pauseIfIdle()
            let delivered = buffersReceived != before
            log.notice("Audio engine warmed up; microphone delivered audio: \(delivered, privacy: .public)")
            return delivered
        } catch {
            log.error("Audio warm-up failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    private var buffersReceived: Int {
        lock.lock()
        defer { lock.unlock() }
        return tapCount
    }

    // MARK: - Recording

    /// Begin buffering mic audio. Returns immediately: if the engine was
    /// paused (idle grace period) it is restarted on a background task,
    /// because `AVAudioEngine.start()` can block for over a second on
    /// hardware spin-up and a main-thread stall gets the hotkey event tap
    /// disabled by macOS.
    func startCollecting(onEngineFailure: @escaping @Sendable () -> Void) {
        // The input changed while idle (another mic, or a new sample rate): rebuild first.
        if isStale {
            log.notice("Input device or format changed; rebuilding the audio engine")
            reconfigureInputDevice()
        }
        prepare()
        idlePauseTask?.cancel()
        lock.lock()
        buffers.removeAll()
        peakLevel = 0
        loudestRMS = 0
        lastVoiceAt = .distantPast
        collecting = true
        lock.unlock()

        guard !engine.isRunning else { return }
        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            do {
                try self.engine.start()
            } catch {
                // Most start failures are a format the tap no longer matches;
                // a fresh engine fixes that, so try once more before giving up.
                self.log.error("Engine start failed: \(error.localizedDescription, privacy: .public); rebuilding")
                self.reconfigureInputDevice()
                do {
                    try self.engine.start()
                } catch {
                    self.log.error("Engine start failed again: \(error.localizedDescription, privacy: .public)")
                    onEngineFailure()
                }
            }
        }
    }

    /// Stop collecting and return everything captured as 16 kHz mono Float samples.
    func stopCollecting() -> [Float] {
        lock.lock()
        collecting = false
        let captured = buffers
        buffers = []
        lock.unlock()

        // Grace period: keep the engine hot for rapid consecutive dictations.
        idlePauseTask?.cancel()
        idlePauseTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(8))
            guard let self, !Task.isCancelled else { return }
            self.pauseIfIdle()
        }
        return Self.samples16k(from: captured)
    }

    private var isCollecting: Bool {
        lock.lock()
        defer { lock.unlock() }
        return collecting
    }

    private func pauseIfIdle() {
        if !isCollecting, engine.isRunning {
            engine.pause()
            log.info("Audio engine paused after idle grace period")
        }
    }

    /// Copy of everything captured so far as 16 kHz mono samples (for live partials).
    func snapshot() -> [Float] {
        lock.lock()
        let captured = buffers
        lock.unlock()
        return Self.samples16k(from: captured)
    }

    /// Seconds of audio captured so far.
    var capturedDuration: TimeInterval {
        lock.lock()
        defer { lock.unlock() }
        guard let format = buffers.first?.format else { return 0 }
        let frames = buffers.reduce(0) { $0 + Int($1.frameLength) }
        return Double(frames) / format.sampleRate
    }

    /// Time since the last buffer that crossed the voice threshold (∞ if none yet).
    var secondsSinceLastVoice: TimeInterval {
        lock.lock()
        defer { lock.unlock() }
        guard lastVoiceAt != .distantPast else { return .infinity }
        return Date().timeIntervalSince(lastVoiceAt)
    }

    /// False while the microphone has delivered nothing but digital silence.
    var hasSignal: Bool {
        lock.lock()
        defer { lock.unlock() }
        return loudestRMS > 0.0001
    }

    var hasDetectedVoice: Bool {
        lock.lock()
        defer { lock.unlock() }
        return lastVoiceAt != .distantPast
    }

    // MARK: - Tap

    private func handleTap(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        tapCount += 1
        let isCollecting = collecting
        lock.unlock()
        guard isCollecting else { return }

        guard let copy = Self.copyBuffer(buffer) else { return }
        let rms = Self.rms(of: copy)

        lock.lock()
        buffers.append(copy)
        if rms > Self.voiceRMSThreshold { lastVoiceAt = Date() }
        loudestRMS = max(loudestRMS, rms)
        peakLevel = max(peakLevel * 0.7, rms)
        let level = min(1.0, peakLevel * 18)
        let shouldPush = Date().timeIntervalSince(lastLevelPush) > 0.05
        if shouldPush { lastLevelPush = Date() }
        lock.unlock()

        if shouldPush, let onLevel {
            DispatchQueue.main.async { onLevel(level) }
        }
    }

    // MARK: - Buffer math

    private static func copyBuffer(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard
            let copy = AVAudioPCMBuffer(
                pcmFormat: buffer.format, frameCapacity: buffer.frameLength)
        else { return nil }
        copy.frameLength = buffer.frameLength
        let channels = Int(buffer.format.channelCount)
        if let src = buffer.floatChannelData, let dst = copy.floatChannelData {
            for ch in 0..<channels {
                dst[ch].update(from: src[ch], count: Int(buffer.frameLength))
            }
        }
        return copy
    }

    private static func rms(of buffer: AVAudioPCMBuffer) -> Float {
        guard let data = buffer.floatChannelData, buffer.frameLength > 0 else { return 0 }
        let n = Int(buffer.frameLength)
        var sum: Float = 0
        let samples = data[0]
        for i in 0..<n { sum += samples[i] * samples[i] }
        return sqrt(sum / Float(n))
    }

    /// Concatenate + resample the captured buffers into 16 kHz mono Float samples
    /// (the Sendable currency the transcriber actor expects).
    static func samples16k(from captured: [AVAudioPCMBuffer]) -> [Float] {
        guard let mono = concatenateMono(captured) else { return [] }
        if mono.format.sampleRate == 16_000 {
            guard let data = mono.floatChannelData else { return [] }
            return Array(UnsafeBufferPointer(start: data[0], count: Int(mono.frameLength)))
        }
        guard
            let outFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1,
                interleaved: false),
            let converter = AVAudioConverter(from: mono.format, to: outFormat)
        else { return [] }

        let ratio = 16_000.0 / mono.format.sampleRate
        let capacity = AVAudioFrameCount(Double(mono.frameLength) * ratio) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: capacity) else {
            return []
        }

        var fed = false
        var conversionError: NSError?
        let status = converter.convert(to: out, error: &conversionError) { _, inputStatus in
            if fed {
                inputStatus.pointee = .endOfStream
                return nil
            }
            fed = true
            inputStatus.pointee = .haveData
            return mono
        }
        guard status != .error, conversionError == nil, let data = out.floatChannelData else {
            return []
        }
        return Array(UnsafeBufferPointer(start: data[0], count: Int(out.frameLength)))
    }

    /// Concatenate captured buffers into one mono buffer (channel 0) at native sample rate.
    private static func concatenateMono(_ captured: [AVAudioPCMBuffer]) -> AVAudioPCMBuffer? {
        guard let first = captured.first else { return nil }
        let totalFrames = captured.reduce(0) { $0 + Int($1.frameLength) }
        guard totalFrames > 0,
            let monoFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: first.format.sampleRate,
                channels: 1,
                interleaved: false),
            let out = AVAudioPCMBuffer(
                pcmFormat: monoFormat, frameCapacity: AVAudioFrameCount(totalFrames))
        else { return nil }

        var offset = 0
        guard let dst = out.floatChannelData else { return nil }
        for buffer in captured {
            guard let src = buffer.floatChannelData else { continue }
            let n = Int(buffer.frameLength)
            dst[0].advanced(by: offset).update(from: src[0], count: n)
            offset += n
        }
        out.frameLength = AVAudioFrameCount(offset)
        return out
    }
}
