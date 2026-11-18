import AVFoundation
import FluidAudio
import Foundation
import os

enum TranscriberState: Equatable, Sendable {
    case notLoaded
    case downloading(Double)  // 0...1
    case loading
    case ready
    case failed(String)
}

/// Wraps FluidAudio's Parakeet Unified 0.6B offline engine (int8, ANE).
/// Offline 15 s window model: best local WER (~1.8%) and ~190x realtime,
/// so live partials are done by re-transcribing the whole buffer.
actor Transcriber {
    private let log = Logger(subsystem: "com.alessio.murmur", category: "asr")
    private let manager = UnifiedAsrManager()
    private var vad: VadManager?

    /// Peak Silero speech probability a clip needs before it is transcribed.
    /// Parakeet turns short speech-free clips (a key click, a breath) into
    /// "Yeah." / "Okay."; those peak at 0.24-0.57 here, whispering at ~0.6,
    /// normal speech at 0.88+ (measured with murmur-cli).
    static let speechThreshold: Float = 0.5

    private(set) var state: TranscriberState = .notLoaded

    /// Download (if needed), load, and warm the models.
    func load(onState: @escaping @Sendable (TranscriberState) -> Void) async {
        guard state == .notLoaded || isFailed else { return }
        do {
            state = .downloading(0)
            onState(state)
            try await manager.loadModels(progressHandler: { progress in
                onState(.downloading(progress.fractionCompleted))
            })
            state = .loading
            onState(state)
            // Warm inference compiles the ANE graphs so the first real
            // dictation isn't slow.
            _ = try await manager.transcribe([Float](repeating: 0, count: 16_000))
            // Dictation still works without the gate, so a failed load is not fatal.
            do {
                vad = try await VadManager()
            } catch {
                log.error("VAD load failed, speech gate off: \(error.localizedDescription, privacy: .public)")
            }
            state = .ready
            onState(state)
            log.info("Parakeet Unified ready")
        } catch {
            let message = error.localizedDescription
            state = .failed(message)
            onState(state)
            log.error("ASR load failed: \(message, privacy: .public)")
        }
    }

    private var isFailed: Bool {
        if case .failed = state { return true }
        return false
    }

    /// Transcribe 16 kHz mono samples. Returns "" when the clip holds no speech.
    func transcribe(_ samples: [Float]) async throws -> String {
        guard state == .ready else { throw ASRError.notInitialized }
        if let vad, let speech = try? await vad.process(samples).map(\.probability).max(),
            speech < Self.speechThreshold {
            log.info("No speech in clip (peak probability \(speech, privacy: .public)); skipping")
            return ""
        }
        return try await manager.transcribe(samples)
    }
}
