import Foundation

/// Maps head-pointing measures to screen points, relative to a captured
/// neutral pose. No calibration overlay: neutral is wherever the user is
/// facing when the session starts (or on Recenter) and lands the cursor at
/// the screen centre; turning the head steers away from it.
struct HeadPointer {
    /// Cursor travel in screen-heights per unit of head measure (the
    /// Settings "sensitivity" slider). Screen height on both axes keeps the
    /// gain isotropic.
    var gain: Double

    private(set) var neutral: CGPoint?

    var isReady: Bool { neutral != nil }

    mutating func recenter(to measure: CGPoint) {
        neutral = measure
    }

    mutating func reset() {
        neutral = nil
    }

    /// Raw webcam frames are unmirrored (the user's right appears on the
    /// image's left) and Vision uses a bottom-left origin while CG screen
    /// coords are top-left - so both axes invert.
    func screenPoint(for measure: CGPoint, on screen: CGRect) -> CGPoint? {
        guard let neutral, screen.width > 1, screen.height > 1 else { return nil }
        let dx = -(measure.x - neutral.x) * gain * screen.height
        let dy = -(measure.y - neutral.y) * gain * screen.height
        return CGPoint(
            x: min(max(screen.midX + dx, screen.minX), screen.maxX - 1),
            y: min(max(screen.midY + dy, screen.minY), screen.maxY - 1))
    }
}
