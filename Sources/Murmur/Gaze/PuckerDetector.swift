import Foundation

/// Turns the mouth-width stream into pucker click events - the mouth-shaped
/// sibling of BlinkDetector, for users whose blinks read hit-or-miss.
///
/// Puckering ("kiss face") narrows the outer-lip width by ~20-35%. A
/// narrowing of `minHold`...`maxHold` counts as a click on release. The
/// `minHold` (default 0.25s) is deliberately longer than a blink's: speech
/// phonemes like "oo" also narrow the lips but only transiently, so the hold
/// requirement is what keeps dictation from clicking. The normal-mouth
/// baseline adapts per person/session, with a hysteresis band so the
/// narrow/normal decision doesn't chatter mid-pucker.
struct PuckerDetector {
    var minHold: TimeInterval
    var maxHold: TimeInterval

    private var baseline: Double
    private var narrowSince: TimeInterval?
    private(set) var isNarrow = false
    /// When the lips last transitioned to narrow (valid while `isNarrow`).
    var narrowedAt: TimeInterval? { narrowSince }

    init(minHold: TimeInterval = 0.25, maxHold: TimeInterval = 2.0, baseline: Double = 0.42) {
        self.minHold = minHold
        self.maxHold = maxHold
        self.baseline = baseline
    }

    /// Feed one mouth-width-ratio observation; returns true when a deliberate
    /// pucker completed (lips relaxed after a qualifying hold).
    mutating func process(widthRatio: Double, at time: TimeInterval) -> Bool {
        guard widthRatio > 0 else { return false }
        if isNarrow {
            guard widthRatio > baseline * 0.9 else { return false }
            isNarrow = false
            let duration = time - (narrowSince ?? time)
            narrowSince = nil
            return duration >= minHold && duration <= maxHold
        }
        if widthRatio < baseline * 0.8 {
            isNarrow = true
            narrowSince = time
            return false
        }
        // Track the relaxed-mouth baseline slowly; ignore half-puckered readings.
        if widthRatio > baseline * 0.9 {
            baseline = baseline * 0.98 + widthRatio * 0.02
        }
        return false
    }
}
