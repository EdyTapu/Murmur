import Foundation

/// Turns the Eye Aspect Ratio stream into deliberate-blink click events.
///
/// Natural blinks last ~100-150 ms, so only a hold of `minHold`...`maxHold`
/// counts as a click; longer closures (resting, looking down at the keyboard)
/// are ignored. The open-eye EAR baseline adapts per person/session, with a
/// hysteresis band so the closed/open decision doesn't chatter mid-blink.
struct BlinkDetector {
    var minHold: TimeInterval
    var maxHold: TimeInterval

    private var baseline = 0.26
    private var closedSince: TimeInterval?
    private(set) var isClosed = false
    /// When the eyes last transitioned to closed (valid while `isClosed`).
    var closedAt: TimeInterval? { closedSince }

    init(minHold: TimeInterval = 0.3, maxHold: TimeInterval = 1.2) {
        self.minHold = minHold
        self.maxHold = maxHold
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
