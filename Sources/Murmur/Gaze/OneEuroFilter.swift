import Foundation

/// One Euro filter (Casiez et al.): adaptive low-pass that smooths jitter at
/// rest but tracks fast movement with little lag - the standard choice for
/// noisy pointing signals like webcam gaze.
struct OneEuroFilter {
    /// Cutoff at rest (Hz). Lower = steadier cursor when fixating.
    var minCutoff: Double
    /// How much the cutoff opens up with speed. Higher = snappier saccades.
    var beta: Double
    /// Cutoff for the derivative estimate (Hz).
    var dCutoff: Double

    private var lastValue: Double?
    private var lastDeriv = 0.0
    private var lastTime: TimeInterval?

    /// Defaults tuned for webcam gaze: a low resting cutoff keeps the cursor
    /// steady while fixating (webcam iris jitter is large), and a modest beta
    /// still lets deliberate glances across the screen move quickly.
    init(minCutoff: Double = 0.3, beta: Double = 0.5, dCutoff: Double = 1.0) {
        self.minCutoff = minCutoff
        self.beta = beta
        self.dCutoff = dCutoff
    }

    mutating func filter(_ value: Double, at time: TimeInterval) -> Double {
        guard let prev = lastValue, let prevTime = lastTime, time > prevTime else {
            lastValue = value
            lastTime = time
            return value
        }
        let dt = time - prevTime
        let deriv = (value - prev) / dt
        let da = Self.alpha(cutoff: dCutoff, dt: dt)
        let smoothDeriv = da * deriv + (1 - da) * lastDeriv
        let cutoff = minCutoff + beta * abs(smoothDeriv)
        let a = Self.alpha(cutoff: cutoff, dt: dt)
        let result = a * value + (1 - a) * prev
        lastValue = result
        lastDeriv = smoothDeriv
        lastTime = time
        return result
    }

    mutating func reset() {
        lastValue = nil
        lastDeriv = 0
        lastTime = nil
    }

    private static func alpha(cutoff: Double, dt: Double) -> Double {
        let tau = 1.0 / (2.0 * .pi * cutoff)
        return 1.0 / (1.0 + tau / dt)
    }
}
