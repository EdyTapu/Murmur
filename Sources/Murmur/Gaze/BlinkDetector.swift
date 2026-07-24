import Foundation

/// Turns the Eye Aspect Ratio stream into blink click events.
///
/// A closure of `minHold`...`maxHold` counts as a click on reopen. Tracking
/// sessions use `minHold` 0 so any blink or wink fires instantly; calibration
/// keeps a small minimum so stray natural blinks don't capture a dot early.
/// Closures past `maxHold` (resting, looking down at the keyboard) are
/// ignored. The open-eye EAR baseline adapts per person/session, with a
/// hysteresis band so the closed/open decision doesn't chatter mid-blink.
struct BlinkDetector {
    var minHold: TimeInterval
    var maxHold: TimeInterval

    private var baseline: Double
    private var closedSince: TimeInterval?
    private(set) var isClosed = false
    /// When the eyes last transitioned to closed (valid while `isClosed`).
    var closedAt: TimeInterval? { closedSince }

    /// `baseline` seeds the open-eye EAR estimate; pass the median open EAR
    /// measured during calibration so the very first blinks of a session
    /// already use this person's eye shape instead of a generic default.
    init(minHold: TimeInterval = 0, maxHold: TimeInterval = 2.0, baseline: Double = 0.26) {
        self.minHold = minHold
        self.maxHold = maxHold
        self.baseline = baseline
    }

    /// Feed one EAR observation; returns true when a deliberate blink
    /// completed (eyes reopened after a qualifying hold).
    mutating func process(ear: Double, at time: TimeInterval) -> Bool {
        if isClosed {
            guard ear > baseline * 0.75 else { return false }
            isClosed = false
            let duration = time - (closedSince ?? time)
            closedSince = nil
            return duration >= minHold && duration <= maxHold
        }
        if ear < baseline * 0.55 {
            isClosed = true
            closedSince = time
            return false
        }
        // Track the open-eye baseline slowly; ignore half-closed readings.
        if ear > baseline * 0.8 {
            baseline = baseline * 0.98 + ear * 0.02
        }
        return false
    }
}
