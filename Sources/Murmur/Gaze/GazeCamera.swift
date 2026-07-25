@preconcurrency import AVFoundation
import Foundation
import os

/// Owns the webcam during a head-control session: 640x480 BGRA at ~15 fps.
/// Frames go straight to the Vision tracker as CVPixelBuffers - no copy.
final class GazeCamera: NSObject, @unchecked Sendable {
    private static let log = Logger(subsystem: "com.alessio.murmur", category: "gaze-camera")

    /// Called synchronously on the capture queue with each frame;
    /// `alwaysDiscardsLateVideoFrames` provides the backpressure.
    var onFrame: (@Sendable (CVPixelBuffer) -> Void)?

    private let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "com.alessio.murmur.gaze-camera")
    private var configured = false

    static var authorized: Bool {
        AVCaptureDevice.authorizationStatus(for: .video) == .authorized
    }

    /// Start capture off the main thread (`startRunning` blocks).
    func start() throws {
        try configureIfNeeded()
        queue.async { [session] in
            if !session.isRunning { session.startRunning() }
        }
    }

    func stop() {
        queue.async { [session] in
            if session.isRunning { session.stopRunning() }
        }
    }

    private func configureIfNeeded() throws {
        guard !configured else { return }
        guard let device = AVCaptureDevice.default(for: .video) else {
            throw NSError(
                domain: "Murmur", code: 2,
                userInfo: [NSLocalizedDescriptionKey: "No camera found"])
        }
        session.beginConfiguration()
        session.sessionPreset = .vga640x480

        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input) else {
            session.commitConfiguration()
            throw NSError(
                domain: "Murmur", code: 3,
                userInfo: [NSLocalizedDescriptionKey: "Camera input rejected"])
        }
        session.addInput(input)

        let output = AVCaptureVideoDataOutput()
        output.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: queue)
        guard session.canAddOutput(output) else {
            session.commitConfiguration()
            throw NSError(
                domain: "Murmur", code: 4,
                userInfo: [NSLocalizedDescriptionKey: "Camera output rejected"])
        }
        session.addOutput(output)
        session.commitConfiguration()

        // 30 fps halves the sample interval vs the old 15 - visibly lower
        // cursor lag, and Vision landmarks are cheap enough on Apple silicon.
        if (try? device.lockForConfiguration()) != nil {
            device.activeVideoMinFrameDuration = CMTime(value: 1, timescale: 30)
            device.unlockForConfiguration()
        }
        configured = true
        Self.log.info("camera configured: \(device.localizedName, privacy: .public)")
    }
}

extension GazeCamera: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard let onFrame,
            let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer)
        else { return }
        onFrame(pixelBuffer)
    }
}
