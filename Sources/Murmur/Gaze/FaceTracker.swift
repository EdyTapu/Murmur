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

    static let noFace = HeadSample(face: false, measure: .zero, earLeft: 0, earRight: 0)
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
            let sample = Self.sample(from: observation, imageSize: size)
        else {
            onSample?(.noFace)
            return
        }
        onSample?(sample)
    }

    /// Pure conversion from a Vision face observation, in image pixel space
    /// (landmark regions are box-normalized; the box aspect changes with pose,
    /// so EAR and the nose measure are computed in pixels).
    static func sample(from observation: VNFaceObservation, imageSize: CGSize) -> HeadSample? {
        guard let landmarks = observation.landmarks else { return nil }
        let box = VNImageRectForNormalizedRect(
            observation.boundingBox, Int(imageSize.width), Int(imageSize.height))
        guard box.width > 1, box.height > 1 else { return nil }

        // Nose tip: the last noseCrest point runs bridge -> tip; fall back to
        // the nose region centroid if the crest is missing.
        let nosePoint: CGPoint
        if let crest = landmarks.noseCrest,
            let tip = crest.pointsInImage(imageSize: imageSize).last {
            nosePoint = tip
        } else if let nose = landmarks.nose {
            let points = nose.pointsInImage(imageSize: imageSize)
            guard !points.isEmpty else { return nil }
            nosePoint = CGPoint(
                x: points.map(\.x).reduce(0, +) / CGFloat(points.count),
                y: points.map(\.y).reduce(0, +) / CGFloat(points.count))
        } else {
            return nil
        }

        let measure = CGPoint(
            x: (nosePoint.x - box.midX) / box.width,
            y: (nosePoint.y - box.midY) / box.height)

        let earLeft = landmarks.leftEye.map {
            Self.aspectRatio(of: $0.pointsInImage(imageSize: imageSize))
        }
        let earRight = landmarks.rightEye.map {
            Self.aspectRatio(of: $0.pointsInImage(imageSize: imageSize))
        }
        return HeadSample(
            face: true,
            measure: measure,
            earLeft: earLeft ?? 0.3,
            earRight: earRight ?? 0.3)
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
