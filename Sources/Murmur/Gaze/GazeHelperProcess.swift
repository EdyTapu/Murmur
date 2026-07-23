import Foundation
import os

/// One frame's worth of gaze data from the Python helper.
struct GazeSample: Sendable {
    let face: Bool
    let features: [Double]
    let earLeft: Double
    let earRight: Double
}

/// Spawns and talks to `gaze_helper.py` (MediaPipe FaceLandmarker in the
/// gaze venv). Murmur owns the camera; the helper is a pure stdin→stdout
/// feature extractor with no camera or network access of its own, so all TCC
/// stays attributed to Murmur.app.
///
/// One instance per session - `Process` cannot be relaunched.
final class GazeHelperProcess: @unchecked Sendable {
    private static let log = Logger(subsystem: "com.alessio.murmur", category: "gaze-helper")

    /// Called on an arbitrary queue for every parsed feature line.
    var onSample: (@Sendable (GazeSample) -> Void)?
    /// Called once when the helper prints its ready handshake.
    var onReady: (@Sendable () -> Void)?
    /// Called when the helper exits (crash, EOF, or kill).
    var onExit: (@Sendable (Int32) -> Void)?

    private let process = Process()
    private let stdinPipe = Pipe()
    private let stdoutPipe = Pipe()
    private let stderrPipe = Pipe()
    private let writeQueue = DispatchQueue(label: "com.alessio.murmur.gaze-write")
    private let stateLock = NSLock()
    private var pendingFrames = 0
    private var lineBuffer = Data()
    private var running = false

    // MARK: - Install locations

    static var supportDir: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Murmur")
    }
    static var venvPython: URL {
        supportDir.appendingPathComponent("gaze-env/bin/python")
    }
    static var modelFile: URL {
        supportDir.appendingPathComponent("face_landmarker.task")
    }
    static var helperScript: URL? {
        if let bundled = Bundle.main.url(forResource: "gaze_helper", withExtension: "py") {
            return bundled
        }
        // Dev fallback: running the bare SwiftPM binary out of .build/.
        let fromSource = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("app/gaze_helper.py")
        return FileManager.default.fileExists(atPath: fromSource.path) ? fromSource : nil
    }

    /// True when the one-time `zsh app/setup_gaze.sh` install has been done.
    static var isInstalled: Bool {
        FileManager.default.fileExists(atPath: venvPython.path)
            && FileManager.default.fileExists(atPath: modelFile.path)
            && helperScript != nil
    }

    // MARK: - Lifecycle

    func start() throws {
        guard let script = Self.helperScript else {
            throw NSError(
                domain: "Murmur", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "gaze_helper.py not found"])
        }
        process.executableURL = Self.venvPython
        process.arguments = [script.path, Self.modelFile.path]
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.terminationHandler = { [weak self] proc in
            guard let self else { return }
            self.stateLock.lock()
            let wasRunning = self.running
            self.running = false
            self.stateLock.unlock()
            Self.log.info("gaze helper exited status=\(proc.terminationStatus, privacy: .public)")
            if wasRunning { self.onExit?(proc.terminationStatus) }
        }

        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            self?.consume(handle.availableData)
        }
        // Drain stderr so glog's startup chatter can't fill the pipe and
        // block the helper.
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil }
        }

        try process.run()
        stateLock.lock()
        running = true
        stateLock.unlock()
        Self.log.info("gaze helper started pid=\(self.process.processIdentifier, privacy: .public)")
    }

    func stop() {
        stateLock.lock()
        let wasRunning = running
        running = false
        stateLock.unlock()
        guard wasRunning else { return }
        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        try? stdinPipe.fileHandleForWriting.close()
        if process.isRunning { process.terminate() }
    }

    // MARK: - Frames in

    private static let magic: UInt32 = 0x475A_4652  // 'GZFR'

    /// Queue a BGRA frame for the helper. Frames arriving while two are
    /// already in flight are dropped - the camera must never outrun MediaPipe
    /// into unbounded pipe backlog (which would show up as cursor lag).
    func send(width: Int, height: Int, bytesPerRow: Int, pixels: Data) {
        stateLock.lock()
        guard running, pendingFrames < 2 else {
            stateLock.unlock()
            return
        }
        pendingFrames += 1
        stateLock.unlock()

        writeQueue.async { [weak self] in
            guard let self else { return }
            defer {
                self.stateLock.lock()
                self.pendingFrames -= 1
                self.stateLock.unlock()
            }
            var header = Data(capacity: 16)
            for value in [Self.magic, UInt32(width), UInt32(height), UInt32(bytesPerRow)] {
                withUnsafeBytes(of: value.littleEndian) { header.append(contentsOf: $0) }
            }
            do {
                try self.stdinPipe.fileHandleForWriting.write(contentsOf: header)
                try self.stdinPipe.fileHandleForWriting.write(contentsOf: pixels)
            } catch {
                // Broken pipe - the termination handler reports the death.
            }
        }
    }

    // MARK: - Lines out

    private struct HelperLine: Decodable {
        let ready: Int?
        let face: Int?
        let f: [Double]?
        let earL: Double?
        let earR: Double?
    }

    private func consume(_ data: Data) {
        guard !data.isEmpty else { return }
        lineBuffer.append(data)
        while let newline = lineBuffer.firstIndex(of: 0x0A) {
            let line = lineBuffer.subdata(in: lineBuffer.startIndex..<newline)
            lineBuffer.removeSubrange(lineBuffer.startIndex...newline)
            guard let parsed = try? JSONDecoder().decode(HelperLine.self, from: line) else {
                continue
            }
            if parsed.ready == 1 {
                onReady?()
                continue
            }
            guard let face = parsed.face else { continue }
            let sample = GazeSample(
                face: face == 1 && parsed.f?.count == GazeMapper.rawDimension,
                features: parsed.f ?? [],
                earLeft: parsed.earL ?? 0,
                earRight: parsed.earR ?? 0)
            onSample?(sample)
        }
    }
}
