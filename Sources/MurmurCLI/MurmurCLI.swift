import AVFoundation
import FluidAudio
import Foundation

final class ProgressReporter: @unchecked Sendable {
    private let lock = NSLock()
    private var lastShown = -10.0

    func report(_ fraction: Double) {
        let pct = fraction * 100
        lock.lock()
        defer { lock.unlock() }
        guard pct - lastShown >= 10 else { return }
        lastShown = pct
        print(String(format: "download: %.0f%%", pct))
    }
}

/// Headless harness: downloads/loads the same Parakeet Unified models the app
/// uses, transcribes a WAV file, and reports timing. Used for pipeline
/// verification and latency measurement without the GUI.
@main
struct MurmurCLI {
    static func main() async {
        let args = CommandLine.arguments
        guard args.count >= 2 else {
            print("usage: murmur-cli <audio.wav> [more.wav ...]")
            exit(2)
        }

        let manager = UnifiedAsrManager()
        do {
            let loadStart = Date()
            let reporter = ProgressReporter()
            try await manager.loadModels(progressHandler: { progress in
                reporter.report(progress.fractionCompleted)
            })
            print(String(format: "models loaded in %.2fs", Date().timeIntervalSince(loadStart)))

            // Warm-up pass (compiles ANE graphs).
            let warmStart = Date()
            _ = try await manager.transcribe([Float](repeating: 0, count: 16_000))
            print(String(format: "warm-up in %.2fs", Date().timeIntervalSince(warmStart)))

            // Same Silero VAD the app uses to reject non-speech before transcribing.
            let vad = try await VadManager()

            for path in args.dropFirst() {
                let samples = try AudioConverter().resampleAudioFile(URL(fileURLWithPath: path))
                let duration = Double(samples.count) / 16_000

                let start = Date()
                let text = try await manager.transcribe(samples)
                let elapsed = Date().timeIntervalSince(start)
                let vadStart = Date()
                let speech = try await vad.process(samples).map(\.probability).max() ?? 0
                let vadElapsed = Date().timeIntervalSince(vadStart)
                print(String(
                    format: "%@ (%.1fs audio) -> %.3fs, vad %.3fs, speech %.2f\n  \"%@\"",
                    (path as NSString).lastPathComponent, duration, elapsed, vadElapsed, speech, text))
            }
        } catch {
            print("FAILED: \(error)")
            exit(1)
        }
    }
}
