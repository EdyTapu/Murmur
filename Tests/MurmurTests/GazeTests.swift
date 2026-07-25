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

@Suite struct HeadPointerTests {
    private let screen = CGRect(x: 0, y: 0, width: 1728, height: 1117)

    @Test func notReadyBeforeNeutral() {
        let pointer = HeadPointer(gain: 3.5)
        #expect(!pointer.isReady)
        #expect(pointer.screenPoint(for: .zero, on: screen) == nil)
    }

    @Test func neutralPoseLandsAtScreenCentre() throws {
        var pointer = HeadPointer(gain: 3.5)
        pointer.recenter(to: CGPoint(x: 0.04, y: -0.02))
        let point = try #require(
            pointer.screenPoint(for: CGPoint(x: 0.04, y: -0.02), on: screen))
        #expect(point == CGPoint(x: screen.midX, y: screen.midY))
    }

    /// Frames are unmirrored: turning the head right moves the nose toward
    /// image-left (measure.x down) and the cursor must move right (+x).
    /// Vision is bottom-left origin: looking up raises measure.y and the
    /// cursor must move up, which is -y in CG screen coords.
    @Test func axesInvertForMirrorAndOrigin() throws {
        var pointer = HeadPointer(gain: 3.5)
        pointer.recenter(to: .zero)
        let headRight = try #require(
            pointer.screenPoint(for: CGPoint(x: -0.05, y: 0), on: screen))
        #expect(headRight.x > screen.midX)
        #expect(headRight.y == screen.midY)
        let headUp = try #require(
            pointer.screenPoint(for: CGPoint(x: 0, y: 0.05), on: screen))
        #expect(headUp.y < screen.midY)
    }

    @Test func gainScalesPerAxisWithScreenSize() throws {
        var pointer = HeadPointer(gain: 2.0)
        pointer.recenter(to: .zero)
        // Horizontal travel scales with screen WIDTH (an ultrawide must not
        // take more head turn to cross than a tall screen), vertical with height.
        let acrossX = try #require(
            pointer.screenPoint(for: CGPoint(x: -0.1, y: 0), on: screen))
        #expect(abs((acrossX.x - screen.midX) - 0.1 * 2.0 * screen.width) < 0.001)
        let acrossY = try #require(
            pointer.screenPoint(for: CGPoint(x: 0, y: 0.1), on: screen))
        #expect(abs((screen.midY - acrossY.y) - 0.1 * 2.0 * screen.height) < 0.001)
    }

    @Test func clampsToScreen() throws {
        var pointer = HeadPointer(gain: 8)
        pointer.recenter(to: .zero)
        let far = try #require(
            pointer.screenPoint(for: CGPoint(x: -5, y: 5), on: screen))
        #expect(far.x == screen.maxX - 1)
        #expect(far.y == screen.minY)
    }

    @Test func offsetScreenClampUsesScreenBounds() throws {
        let second = CGRect(x: 1728, y: 100, width: 1512, height: 982)
        var pointer = HeadPointer(gain: 8)
        pointer.recenter(to: .zero)
        let far = try #require(
            pointer.screenPoint(for: CGPoint(x: 5, y: -5), on: second))
        #expect(far.x == second.minX)
        #expect(far.y == second.maxY - 1)
    }
}

@Suite struct EyeAspectRatioTests {
    @Test func openEyeReadsTallerThanClosed() {
        let open: [CGPoint] = [
            CGPoint(x: 0, y: 5), CGPoint(x: 10, y: 12), CGPoint(x: 20, y: 14),
            CGPoint(x: 30, y: 12), CGPoint(x: 40, y: 5), CGPoint(x: 20, y: 0),
        ]
        let closed: [CGPoint] = [
            CGPoint(x: 0, y: 5), CGPoint(x: 10, y: 6), CGPoint(x: 20, y: 6.5),
            CGPoint(x: 30, y: 6), CGPoint(x: 40, y: 5), CGPoint(x: 20, y: 4.5),
        ]
        let openEAR = FaceTracker.aspectRatio(of: open)
        let closedEAR = FaceTracker.aspectRatio(of: closed)
        #expect(openEAR > 0.3)
        #expect(closedEAR < 0.1)
        #expect(openEAR > closedEAR * 3)
    }

    @Test func degenerateInputsReturnZero() {
        #expect(FaceTracker.aspectRatio(of: []) == 0)
        #expect(FaceTracker.aspectRatio(of: [CGPoint(x: 1, y: 1)]) == 0)
        // Zero width must not divide by zero.
        let vertical = [
            CGPoint(x: 5, y: 0), CGPoint(x: 5, y: 1),
            CGPoint(x: 5, y: 2), CGPoint(x: 5, y: 3),
        ]
        #expect(FaceTracker.aspectRatio(of: vertical) == 0)
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
