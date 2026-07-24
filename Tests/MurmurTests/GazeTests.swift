import Foundation
import Testing

@testable import Murmur

@Suite struct OneEuroFilterTests {
    @Test func convergesToConstantInput() {
        var filter = OneEuroFilter()
        var out = 0.0
        for i in 0..<100 {
            out = filter.filter(10.0, at: Double(i) * 0.066)
        }
        #expect(abs(out - 10.0) < 0.01)
    }

    @Test func outputStaysBetweenOldAndNewOnStep() {
        var filter = OneEuroFilter()
        _ = filter.filter(0, at: 0)
        let stepped = filter.filter(100, at: 0.066)
        #expect(stepped > 0 && stepped <= 100)
    }

    @Test func firstSamplePassesThrough() {
        var filter = OneEuroFilter()
        #expect(filter.filter(42, at: 1.0) == 42)
    }
}

@Suite struct GazeMapperTests {
    /// Synthetic ground truth: gaze target is a noiseless linear function of
    /// the iris features. The fit should recover it almost exactly.
    @Test func recoversLinearMap() throws {
        var rng = SystemRandomNumberGenerator()
        var features: [[Double]] = []
        var targets: [CGPoint] = []
        for _ in 0..<200 {
            let f = (0..<GazeMapper.rawDimension).map { i -> Double in
                switch i {
                case 0...3: return Double.random(in: -0.15...0.15, using: &rng)
                case 4...6: return Double.random(in: -0.3...0.3, using: &rng)
                default: return Double.random(in: -5...5, using: &rng)
                }
            }
            let u = 0.5 + 2.0 * (f[0] + f[2]) + 0.3 * f[4]
            let v = 0.5 + 2.5 * (f[1] + f[3]) + 0.3 * f[5]
            features.append(f)
            targets.append(CGPoint(x: u, y: v))
        }
        let mapper = try #require(GazeMapper.fit(features: features, targets: targets))
        var worst = 0.0
        for (f, t) in zip(features, targets) {
            let p = try #require(mapper.predict(f))
            worst = max(worst, max(abs(p.x - t.x), abs(p.y - t.y)))
        }
        #expect(worst < 0.05)
    }

    @Test func refusesTooFewSamples() {
        let f = [[Double]](repeating: [Double](repeating: 0, count: 10), count: 5)
        let t = [CGPoint](repeating: .zero, count: 5)
        #expect(GazeMapper.fit(features: f, targets: t) == nil)
    }

    @Test func roundTripsThroughCodable() throws {
        let features = (0..<50).map { _ in
            (0..<10).map { _ in Double.random(in: -1...1) }
        }
        let targets = features.map { CGPoint(x: $0[0], y: $0[1]) }
        let mapper = try #require(GazeMapper.fit(features: features, targets: targets))
        let data = try JSONEncoder().encode(
            GazeCalibration(mapper: mapper, screenRect: CGRect(x: 0, y: 0, width: 1728, height: 1117)))
        let decoded = try JSONDecoder().decode(GazeCalibration.self, from: data)
        #expect(decoded.mapper == mapper)
        #expect(decoded.screenRect.width == 1728)
    }
}

@Suite struct BlinkDetectorTests {
    private func feed(
        _ detector: inout BlinkDetector, ear: Double, from: Double, to: Double
    ) -> Bool {
        var clicked = false
        var t = from
        while t < to {
            if detector.process(ear: ear, at: t) { clicked = true }
            t += 0.033
        }
        return clicked
    }

    @Test func deliberateBlinkClicks() {
        var d = BlinkDetector(minHold: 0.3, maxHold: 1.2)
        #expect(!feed(&d, ear: 0.28, from: 0, to: 2))       // open, settle baseline
        #expect(!feed(&d, ear: 0.05, from: 2, to: 2.45))    // held closed
        #expect(feed(&d, ear: 0.28, from: 2.45, to: 2.6))   // reopen → click
    }

    @Test func naturalBlinkIgnored() {
        var d = BlinkDetector(minHold: 0.3, maxHold: 1.2)
        _ = feed(&d, ear: 0.28, from: 0, to: 2)
        #expect(!feed(&d, ear: 0.05, from: 2, to: 2.1))     // ~100ms blink
        #expect(!feed(&d, ear: 0.28, from: 2.1, to: 2.5))   // reopen, too short
    }

    @Test func longClosureIgnored() {
        var d = BlinkDetector(minHold: 0.3, maxHold: 1.2)
        _ = feed(&d, ear: 0.28, from: 0, to: 2)
        #expect(!feed(&d, ear: 0.05, from: 2, to: 4))       // resting eyes
        #expect(!feed(&d, ear: 0.28, from: 4, to: 4.3))     // reopen, too long
    }

    /// Tracking sessions run with minHold 0: even a quick ~100ms natural
    /// blink (or wink, via the min-EAR signal) fires a click on reopen.
    @Test func zeroMinHoldClicksOnQuickBlink() {
        var d = BlinkDetector(minHold: 0, maxHold: 2.0)
        _ = feed(&d, ear: 0.28, from: 0, to: 1)
        #expect(!feed(&d, ear: 0.05, from: 1, to: 1.1))
        #expect(feed(&d, ear: 0.28, from: 1.1, to: 1.2))
    }

    @Test func zeroMinHoldStillIgnoresLongRest() {
        var d = BlinkDetector(minHold: 0, maxHold: 2.0)
        _ = feed(&d, ear: 0.28, from: 0, to: 1)
        #expect(!feed(&d, ear: 0.05, from: 1, to: 4))       // eyes rested shut
        #expect(!feed(&d, ear: 0.28, from: 4, to: 4.2))     // reopen, no click
    }

    @Test func seededBaselineDetectsRelativeBlink() {
        // A person with naturally narrow eyes (open EAR ~0.16): the generic
        // 0.26 baseline would read them as half-closed, but a seeded
        // detector clicks on their relative blink.
        var d = BlinkDetector(minHold: 0.3, maxHold: 1.2, baseline: 0.16)
        #expect(!feed(&d, ear: 0.16, from: 0, to: 1))
        #expect(!feed(&d, ear: 0.05, from: 1, to: 1.4))
        #expect(feed(&d, ear: 0.16, from: 1.4, to: 1.6))
    }

    @Test func reportsClosedStateWhileBlinking() {
        var d = BlinkDetector(minHold: 0.3, maxHold: 1.2)
        _ = feed(&d, ear: 0.28, from: 0, to: 1)
        #expect(!d.isClosed)
        _ = d.process(ear: 0.05, at: 1.05)
        #expect(d.isClosed)
        #expect(d.closedAt != nil)
    }
}
