import Foundation

/// A dot-free range calibration: the head measures captured while the user
/// faced the screen centre and pointed at each screen edge. Maps the user's
/// actual comfortable head range onto the full screen, replacing the gain
/// slider guesswork. Sign-agnostic: no assumption about which way a measure
/// grows, so the mirror/origin questions can't break it.
struct HeadBounds: Codable, Equatable {
    var neutral: CGPoint
    /// measure.x while facing the screen's left / right edge.
    var leftX: Double
    var rightX: Double
    /// measure.y while facing the screen's top / bottom edge.
    var topY: Double
    var bottomY: Double

    /// Edges must straddle the neutral on both axes, by at least this much.
    static let minSpan = 0.02

    var isUsable: Bool {
        (leftX - Double(neutral.x)) * (rightX - Double(neutral.x)) < 0
            && abs(leftX - Double(neutral.x)) >= Self.minSpan
            && abs(rightX - Double(neutral.x)) >= Self.minSpan
            && (topY - Double(neutral.y)) * (bottomY - Double(neutral.y)) < 0
            && abs(topY - Double(neutral.y)) >= Self.minSpan
            && abs(bottomY - Double(neutral.y)) >= Self.minSpan
    }

    func screenPoint(for measure: CGPoint, on screen: CGRect) -> CGPoint {
        let u = Self.unit(Double(measure.x), lo: leftX, mid: Double(neutral.x), hi: rightX)
        let v = Self.unit(Double(measure.y), lo: bottomY, mid: Double(neutral.y), hi: topY)
        return CGPoint(
            x: min(screen.minX + CGFloat(u) * screen.width, screen.maxX - 1),
            // v = 1 means "facing the top edge", which is minY in CG coords.
            y: min(screen.maxY - CGFloat(v) * screen.height, screen.maxY - 1))
    }

    /// Piecewise-linear: lo → 0, mid → 0.5, hi → 1, clamped, working for
    /// either sign ordering of (lo, mid, hi).
    static func unit(_ m: Double, lo: Double, mid: Double, hi: Double) -> Double {
        let hiSide = hi - mid
        let loSide = lo - mid
        guard abs(hiSide) > 1e-9, abs(loSide) > 1e-9 else { return 0.5 }
        let d = m - mid
        if d * hiSide >= 0 {
            return min(1, 0.5 + 0.5 * d / hiSide)
        }
        return max(0, 0.5 - 0.5 * d / loSide)
    }

    /// Recenter: slide the whole calibrated map so `measure` becomes the new
    /// neutral, preserving the edge spans (seat shifts don't lose the ranges).
    mutating func translate(toNeutral measure: CGPoint) {
        let dx = Double(measure.x - neutral.x)
        let dy = Double(measure.y - neutral.y)
        neutral = measure
        leftX += dx
        rightX += dx
        topY += dy
        bottomY += dy
    }
}

/// Maps head-pointing measures to screen points, relative to a captured
/// neutral pose. Two modes: a calibrated `HeadBounds` range map when the
/// user has swept the screen edges, else the simple gain map (sensitivity
/// slider) around the session-start neutral.
struct HeadPointer {
    /// Cursor travel in screen-widths (x) / screen-heights (y) per unit of
    /// head measure (the Settings "sensitivity" slider). Per-axis scaling
    /// means the same comfortable head turn spans the full screen in each
    /// direction - on an ultrawide, height-based x gain felt like slogging.
    var gain: Double
    /// When set, the calibrated range map wins and `gain` is ignored.
    var bounds: HeadBounds?

    private(set) var neutral: CGPoint?

    var isReady: Bool { bounds != nil || neutral != nil }

    mutating func recenter(to measure: CGPoint) {
        neutral = measure
        bounds?.translate(toNeutral: measure)
    }

    mutating func reset() {
        neutral = nil
    }

    /// Raw webcam frames are unmirrored (the user's right appears on the
    /// image's left) and Vision uses a bottom-left origin while CG screen
    /// coords are top-left - so both axes invert in gain mode. (Bounds mode
    /// needs no sign reasoning: it interpolates between measured edges.)
    func screenPoint(for measure: CGPoint, on screen: CGRect) -> CGPoint? {
        guard screen.width > 1, screen.height > 1 else { return nil }
        if let bounds {
            return bounds.screenPoint(for: measure, on: screen)
        }
        guard let neutral else { return nil }
        let dx = -(measure.x - neutral.x) * gain * screen.width
        let dy = -(measure.y - neutral.y) * gain * screen.height
        return CGPoint(
            x: min(max(screen.midX + dx, screen.minX), screen.maxX - 1),
            y: min(max(screen.midY + dy, screen.minY), screen.maxY - 1))
    }
}
