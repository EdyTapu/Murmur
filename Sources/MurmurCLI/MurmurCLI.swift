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

            for path in args.dropFirst() {
                let url = URL(fileURLWithPath: path)
                let file = try AVAudioFile(forReading: url)
                guard
                    let buffer = AVAudioPCMBuffer(
                        pcmFormat: file.processingFormat,
                        frameCapacity: AVAudioFrameCount(file.length))
                else {
                    print("\(path): could not allocate buffer")
                    continue
                }
                try file.read(into: buffer)
                let duration = Double(file.length) / file.processingFormat.sampleRate

                let start = Date()
                let text = try await manager.transcribe(buffer)
                let elapsed = Date().timeIntervalSince(start)
                print(String(
                    format: "%@ (%.1fs audio) -> %.3fs\n  \"%@\"",
                    (path as NSString).lastPathComponent, duration, elapsed, text))
            }
        } catch {
            print("FAILED: \(error)")
            exit(1)
        }
    }
}
