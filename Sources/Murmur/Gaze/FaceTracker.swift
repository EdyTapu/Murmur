import CoreVideo
import Foundation
import Vision
import os

/// One tracked video frame: where the head is pointing plus eye openness.
struct HeadSample: Sendable {
    let face: Bool
    /// Nose-tip offset from the face-box centre, in face-box-size units.
    /// Translation-invariant: sliding the whole head sideways moves nose and
    /// box together, so only *turning* the head changes the measure - which
    /// is exactly the "where my face is pointing" signal.
    let measure: CGPoint
    let earLeft: Double
    let earRight: Double
    /// Outer-lip width over face-box width; drops ~20-35% on a lip pucker.
    let mouthWidthRatio: Double

    static let noFace = HeadSample(
        face: false, measure: .zero, earLeft: 0, earRight: 0, mouthWidthRatio: 0)
}

/// On-device face landmark tracking via Apple Vision - replaces the old
/// Python/MediaPipe child process (no venv, no pipes, no model download).
/// `process` runs synchronously on the camera queue; `alwaysDiscardsLateVideoFrames`
/// on the capture output provides the backpressure.
final class FaceTracker: @unchecked Sendable {
    private static let log = Logger(subsystem: "com.alessio.murmur", category: "face-tracker")

    /// Called on the camera queue with one sample per processed frame.
    var onSample: (@Sendable (HeadSample) -> Void)?

    /// Sequence handler: lets Vision reuse tracking state across video frames.
    private let sequence = VNSequenceRequestHandler()

    /// EMA-smoothed face-box size (camera-queue only). The box size divides
    /// every measure, so frame-to-frame box wobble multiplies straight into
    /// cursor jitter - but real size changes (leaning in/out) are slow, so a
    /// heavy EMA is safe. Reset when the face is lost.
    private var smoothedBoxSize: CGSize?

    func process(_ pixelBuffer: CVPixelBuffer) {
        let request = VNDetectFaceLandmarksRequest()
        do {
            try sequence.perform([request], on: pixelBuffer, orientation: .up)
        } catch {
            Self.log.error("Vision perform failed: \(error.localizedDescription, privacy: .public)")
            onSample?(.noFace)
            return
        }
        let size = CGSize(
            width: CVPixelBufferGetWidth(pixelBuffer),
            height: CVPixelBufferGetHeight(pixelBuffer))
        guard let observation = request.results?.first,
            let sample = sample(from: observation, imageSize: size)
        else {
            smoothedBoxSize = nil
            onSample?(.noFace)
            return
        }
        onSample?(sample)
    }

    /// Conversion from a Vision face observation, in image pixel space
    /// (landmark regions are box-normalized; the box aspect changes with pose,
    /// so EAR and the nose measure are computed in pixels).
    private func sample(from observation: VNFaceObservation, imageSize: CGSize) -> HeadSample? {
        guard let landmarks = observation.landmarks else { return nil }
        let box = VNImageRectForNormalizedRect(
            observation.boundingBox, Int(imageSize.width), Int(imageSize.height))
        guard box.width > 1, box.height > 1 else { return nil }

        // Divide by the EMA-smoothed box size, not the instantaneous one.
        let boxSize: CGSize
        if let prev = smoothedBoxSize {
            boxSize = CGSize(
                width: prev.width * 0.9 + box.width * 0.1,
                height: prev.height * 0.9 + box.height * 0.1)
        } else {
            boxSize = box.size
        }
        smoothedBoxSize = boxSize

        // Average ALL noseCrest points (bridge to tip), not just the tip:
        // the whole crest moves together with head rotation, and the mean of
        // ~6 landmarks carries ~1/sqrt(6) of the single-point jitter that was
        // shaking the cursor. Fall back to the nose-region centroid.
        let region = landmarks.noseCrest ?? landmarks.nose
        guard let points = region?.pointsInImage(imageSize: imageSize), !points.isEmpty
        else { return nil }
        let nosePoint = CGPoint(
            x: points.map(\.x).reduce(0, +) / CGFloat(points.count),
            y: points.map(\.y).reduce(0, +) / CGFloat(points.count))

        let measure = CGPoint(
            x: (nosePoint.x - box.midX) / boxSize.width,
            y: (nosePoint.y - box.midY) / boxSize.height)

        let earLeft = landmarks.leftEye.map {
            Self.aspectRatio(of: $0.pointsInImage(imageSize: imageSize))
        }
        let earRight = landmarks.rightEye.map {
            Self.aspectRatio(of: $0.pointsInImage(imageSize: imageSize))
        }
        // Outer-lip width, face-box-relative: the pucker-to-click signal.
        var mouthWidthRatio = 0.42
        if let lips = landmarks.outerLips {
            let lipPoints = lips.pointsInImage(imageSize: imageSize)
            if let minX = lipPoints.map(\.x).min(), let maxX = lipPoints.map(\.x).max(),
                boxSize.width > 0 {
                mouthWidthRatio = Double((maxX - minX) / boxSize.width)
            }
        }
        return HeadSample(
            face: true,
            measure: measure,
            earLeft: earLeft ?? 0.3,
            earRight: earRight ?? 0.3,
            mouthWidthRatio: mouthWidthRatio)
    }

    /// Eye Aspect Ratio from an eye contour: bounding height over width.
    /// Open eyes sit around 0.3-0.5, a closed lid collapses toward ~0.1; the
    /// BlinkDetector's adaptive baseline absorbs per-person differences.
    static func aspectRatio(of points: [CGPoint]) -> Double {
        guard points.count >= 4 else { return 0 }
        let xs = points.map(\.x)
        let ys = points.map(\.y)
        let width = (xs.max() ?? 0) - (xs.min() ?? 0)
        let height = (ys.max() ?? 0) - (ys.min() ?? 0)
        guard width > 0 else { return 0 }
        return Double(height / width)
    }
}
