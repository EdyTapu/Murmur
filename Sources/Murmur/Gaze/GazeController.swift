import AVFoundation
import AppKit
import Carbon.HIToolbox
import Foundation
import os

/// Head control: point your face where you want the cursor, blink to click.
///
/// Session pipeline: ⌃⌥E → camera frames → Vision face landmarks
/// (FaceTracker, all on-device Swift - no Python child) → nose-vs-face-box
/// head measure → neutral-relative HeadPointer map → median + One Euro
/// smoothing → cursor. Any blink or wink clicks, snapping to the nearest
/// window title bar or Dock icon. No calibration: the pose you hold when the
/// session starts becomes "screen centre"; Recenter re-captures it.
@MainActor
final class GazeController: ObservableObject {
    enum State: Equatable {
        case off
        case starting
        case calibrating
        case tracking
    }

    private let log = Logger(subsystem: "com.alessio.murmur", category: "gaze")

    @Published private(set) var state: State = .off
    /// Whether a saved edge-sweep range calibration is in use.
    @Published private(set) var boundsCalibrated = Prefs.headBounds != nil

    /// Surface toasts through the shared HUD (wired up by AppController).
    var toast: ((Bool, String) -> Void)?

    private var tracker: FaceTracker?
    private var camera: GazeCamera?
    private var pointer = HeadPointer(gain: Prefs.headSensitivity)
    /// Head tuning, round 4: minCutoff down for a calmer resting cursor
    /// ("still jitters a bit"), beta up so deliberate motion stays snappy -
    /// that split is exactly what One Euro's two knobs are for. Source-level
    /// noise also dropped (FaceTracker EMAs the face-box divisor).
    private var filterX = OneEuroFilter(minCutoff: 0.6, beta: 2.0)
    private var filterY = OneEuroFilter(minCutoff: 0.6, beta: 2.0)
    /// Last cursor position actually posted; movements under the deadband
    /// are dropped so the cursor holds perfectly still at rest.
    private var lastPosted: CGPoint?
    private let deadbandPx: CGFloat = 4
    /// Last few raw mapped points; a component-wise median kills the
    /// single-frame landmark spikes that One Euro alone would let through.
    private var recentRaw: [CGPoint] = []
    private var blink = BlinkDetector(minHold: 0.1)
    private var pucker = PuckerDetector()
    /// Median-of-3 EAR window: Vision eye contours spike on single frames,
    /// and a raw spike below the closed threshold reads as a blink.
    private var recentEARs: [Double] = []
    /// Same median-of-3 treatment for the mouth-width pucker signal.
    private var recentWidths: [Double] = []
    /// Refractory period after a click so a flappy EAR can't click-storm.
    private var clickCooldownUntil: TimeInterval = 0
    /// Recent smoothed cursor positions - a blink click lands where the user
    /// was pointing just *before* the head dipped with the blink.
    private var trail: [(time: TimeInterval, point: CGPoint)] = []
    private var suppressCursorUntil: TimeInterval = 0
    private var readyTimeoutTask: Task<Void, Never>?
    private var screenRect: CGRect = .zero

    /// Head measures being averaged into a (new) neutral pose; non-nil while
    /// capture is in progress (session start and Recenter both use this).
    private var neutralSamples: [CGPoint]?
    private let neutralSampleCount = 10

    // MARK: - Range calibration state

    /// Set when Calibrate Range was clicked while off: run it once tracking starts.
    private var pendingCalibration = false
    private var calibModel: BoundsCalibrationModel?
    private var calibWindow: BoundsCalibrationWindowController?
    /// Rolling recent measures for the current step (~0.7s at 30fps).
    private var calibBuffer: [CGPoint] = []
    private var calibCaptured: [BoundsStep: CGPoint] = [:]
    private var calibSettleUntil: TimeInterval = 0
    private var calibStartedAt: TimeInterval = 0
    /// When the current step began accepting samples (drives relaxation).
    private var calibStepStartedAt: TimeInterval = 0
    private let calibWindowSize = 20
    /// Pose is "held" when the outlier-trimmed spread stays inside this.
    /// 0.025 matches real micro-sway + landmark noise; the first cut (0.014
    /// raw max-min) was stricter than a human head can hold and the bar
    /// stuck forever on the first target.
    private let calibStableSpread = 0.025
    /// The threshold relaxes by this much every 4s stuck on a step, so
    /// calibration always progresses (capped at 2x the base).
    private let calibRelaxPer4s = 0.006
    /// Edge poses must differ from centre by at least this on the step's axis.
    private let calibMinEdgeDelta = 0.02

    var statusText: String {
        switch state {
        case .off: return "Head control off"
        case .starting: return "Starting head control…"
        case .calibrating: return "Calibrating range…"
        case .tracking: return "Head control on - blink to click"
        }
    }

    // MARK: - Hotkey (⌃⌥E)

    /// Registered through HotkeyCenter (Carbon): system-wide, consumes the
    /// keystroke, and needs no event tap or extra TCC grant - so it can't
    /// interfere with the dictation hotkey's CGEventTap.
    func registerHotkey() {
        _ = HotkeyCenter.shared.register(
            keyCode: UInt32(kVK_ANSI_E), carbonModifiers: UInt32(controlKey | optionKey)
        ) { [weak self] in self?.toggle() }
    }

    // MARK: - Session lifecycle

    func toggle() {
        if state == .off {
            start()
        } else {
            stopSession(toastMessage: "Head control off")
        }
    }

    func start() {
        guard state == .off else { return }
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            proceedStart()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                Task { @MainActor [weak self] in
                    if granted {
                        self?.proceedStart()
                    } else {
                        self?.cameraDenied()
                    }
                }
            }
        default:
            cameraDenied()
        }
    }

    /// Live sensitivity change from the Settings slider - no session restart.
    func applySensitivity() {
        pointer.gain = Prefs.headSensitivity
    }

    /// Run the dot-free range calibration (centre + four screen edges,
    /// dwell-captured). Starts the camera first if no session is running.
    func calibrateBounds() {
        if state == .off {
            pendingCalibration = true
            start()
        } else if state == .tracking {
            beginBoundsCalibration()
        }
    }

    /// Drop the saved range and fall back to the sensitivity slider.
    func clearBounds() {
        Prefs.setHeadBounds(nil)
        pointer.bounds = nil
        boundsCalibrated = false
    }

    /// Capture the current pose as the new neutral (cursor lands at screen
    /// centre when holding it). Starts a session when off.
    func recenter() {
        guard state != .off else {
            start()
            return
        }
        neutralSamples = []
        toast?(true, "Recentering - hold your pose…")
    }

    func stopSession(toastMessage: String? = nil) {
        let wasOff = state == .off
        state = .off
        readyTimeoutTask?.cancel()
        readyTimeoutTask = nil
        closeCalibrationUI()
        pendingCalibration = false
        camera?.stop()
        camera = nil
        tracker = nil
        pointer.reset()
        neutralSamples = nil
        filterX.reset()
        filterY.reset()
        recentRaw.removeAll()
        recentEARs.removeAll()
        recentWidths.removeAll()
        trail.removeAll()
        lastPosted = nil
        if let toastMessage, !wasOff { toast?(true, toastMessage) }
    }

    private func cameraDenied() {
        toast?(false, "Grant Camera access to use head control")
        if let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera") {
            NSWorkspace.shared.open(url)
        }
    }

    private func proceedStart() {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        state = .starting
        screenRect = Self.cgRect(of: screen)
        pointer = HeadPointer(gain: Prefs.headSensitivity, bounds: Prefs.headBounds)
        boundsCalibrated = pointer.bounds != nil
        neutralSamples = []
        blink = BlinkDetector(minHold: 0.1)
        pucker = PuckerDetector()
        recentEARs = []
        recentWidths = []
        toast?(true, "Starting head control - face the screen…")

        let tracker = FaceTracker()
        tracker.onSample = { [weak self] sample in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.handle(sample) }
            }
        }
        let camera = GazeCamera()
        camera.onFrame = { [weak tracker] pixelBuffer in
            tracker?.process(pixelBuffer)
        }
        do {
            try camera.start()
        } catch {
            camera.stop()
            state = .off
            toast?(false, "Couldn't start the camera: \(error.localizedDescription)")
            return
        }
        self.tracker = tracker
        self.camera = camera

        // If no face ever shows up, stop with a diagnosis instead of hanging.
        readyTimeoutTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(15))
            guard let self, !Task.isCancelled, self.state == .starting else { return }
            self.stopSession()
            self.toast?(false, "Couldn't find your face - check lighting and try again")
        }
    }

    // MARK: - Tracking

    private func handle(_ sample: HeadSample) {
        guard state != .off else { return }
        let now = CACurrentMediaTime()

        // Neutral capture (session start or Recenter): average a short burst
        // of face measures while the user holds the pose they want centred.
        if neutralSamples != nil {
            guard sample.face else { return }
            neutralSamples?.append(sample.measure)
            if let samples = neutralSamples, samples.count >= neutralSampleCount {
                let neutral = CGPoint(
                    x: Self.median(samples.map(\.x)),
                    y: Self.median(samples.map(\.y)))
                pointer.recenter(to: neutral)
                neutralSamples = nil
                filterX.reset()
                filterY.reset()
                recentRaw.removeAll()
                if state == .starting {
                    readyTimeoutTask?.cancel()
                    readyTimeoutTask = nil
                    state = .tracking
                    if pendingCalibration {
                        pendingCalibration = false
                        beginBoundsCalibration()
                    } else {
                        toast?(true, "Head control on - blink to click, ⌃⌥E to stop")
                    }
                } else {
                    toast?(true, "Recentered")
                }
            }
            return
        }
        if state == .calibrating {
            handleCalibration(sample)
            return
        }
        guard state == .tracking else { return }

        if Prefs.gazePuckerClick, sample.face {
            recentWidths.append(sample.mouthWidthRatio)
            if recentWidths.count > 3 { recentWidths.removeFirst(recentWidths.count - 3) }
            let narrowedAt = pucker.narrowedAt
            let clicked = pucker.process(widthRatio: Self.median(recentWidths), at: now)
            if clicked, now >= clickCooldownUntil {
                performClick(pointedAtBefore: narrowedAt ?? now)
                return
            }
        }
        if Prefs.gazeBlinkClick, sample.face {
            // min(earL, earR) so closing either eye - blink or wink - clicks.
            recentEARs.append(min(sample.earLeft, sample.earRight))
            if recentEARs.count > 3 { recentEARs.removeFirst(recentEARs.count - 3) }
            let closedAt = blink.closedAt
            let clicked = blink.process(ear: Self.median(recentEARs), at: now)
            if clicked, now >= clickCooldownUntil {
                performClick(pointedAtBefore: closedAt ?? now)
                return
            }
            // Mid-blink the landmark fit wobbles; freeze the cursor.
            if blink.isClosed { return }
        }

        guard sample.face, now >= suppressCursorUntil,
            let raw = pointer.screenPoint(for: sample.measure, on: screenRect)
        else { return }

        recentRaw.append(raw)
        if recentRaw.count > 3 { recentRaw.removeFirst(recentRaw.count - 3) }
        let median = CGPoint(
            x: Self.median(recentRaw.map(\.x)),
            y: Self.median(recentRaw.map(\.y)))
        let smoothed = CGPoint(
            x: filterX.filter(median.x, at: now),
            y: filterY.filter(median.y, at: now))
        let clamped = CGPoint(
            x: min(max(smoothed.x, screenRect.minX), screenRect.maxX - 1),
            y: min(max(smoothed.y, screenRect.minY), screenRect.maxY - 1))

        trail.append((now, clamped))
        if trail.count > 60 { trail.removeFirst(trail.count - 60) }
        // Deadband: don't post sub-noise movements, so the cursor is rock
        // still at rest instead of shimmering.
        if let lastPosted, hypot(clamped.x - lastPosted.x, clamped.y - lastPosted.y) < deadbandPx {
            return
        }
        lastPosted = clamped
        postMouse(.mouseMoved, at: clamped)
    }

    // MARK: - Range calibration (centre + four edges, dwell-captured)

    private func beginBoundsCalibration() {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        closeCalibrationUI()
        state = .calibrating
        calibBuffer = []
        calibCaptured = [:]
        let now = CACurrentMediaTime()
        calibSettleUntil = now + 1.0
        calibStartedAt = now
        calibStepStartedAt = now + 1.0
        let model = BoundsCalibrationModel()
        calibModel = model
        let window = BoundsCalibrationWindowController()
        calibWindow = window
        window.show(on: screen, model: model) { [weak self] in
            self?.stopSession(toastMessage: "Calibration cancelled")
        }
    }

    private func closeCalibrationUI() {
        calibWindow?.close()
        calibWindow = nil
        calibModel = nil
        calibBuffer = []
        calibCaptured = [:]
    }

    private func handleCalibration(_ sample: HeadSample) {
        guard let model = calibModel else { return }
        let now = CACurrentMediaTime()
        model.faceVisible = sample.face

        // Never seeing a stable pose for this long means something is wrong
        // (bad lighting, camera angle) - bail with a diagnosis.
        if now - calibStartedAt > 90 {
            stopSession()
            toast?(false, "Calibration timed out - check lighting and try again")
            return
        }
        guard sample.face, now >= calibSettleUntil else { return }

        calibBuffer.append(sample.measure)
        if calibBuffer.count > calibWindowSize {
            calibBuffer.removeFirst(calibBuffer.count - calibWindowSize)
        }
        let filled = Double(calibBuffer.count) / Double(calibWindowSize)
        guard calibBuffer.count == calibWindowSize else {
            model.progress = filled * 0.5
            return
        }

        let xs = calibBuffer.map(\.x)
        let ys = calibBuffer.map(\.y)
        let spread = max(robustSpread(xs), robustSpread(ys))
        // Relax the stillness bar the longer the user is stuck, so a shaky
        // setup still completes (the captured value is a median anyway).
        let stuckFor = now - calibStepStartedAt
        let threshold = min(
            calibStableSpread * 2,
            calibStableSpread + calibRelaxPer4s * (stuckFor / 4).rounded(.down))
        let held = spread <= threshold
        let median = CGPoint(x: Self.median(xs), y: Self.median(ys))

        // Edge steps must actually differ from centre on their axis, so
        // resting at centre can't accidentally capture an edge.
        var distinctEnough = true
        if let centre = calibCaptured[.center] {
            switch model.step {
            case .left, .right:
                distinctEnough = abs(Double(median.x - centre.x)) >= calibMinEdgeDelta
            case .top, .bottom:
                distinctEnough = abs(Double(median.y - centre.y)) >= calibMinEdgeDelta
            case .center:
                break
            }
        }
        guard held, distinctEnough else {
            // Honest feedback: show how close to "held" the pose is instead
            // of a frozen half bar.
            let closeness = distinctEnough ? min(1, threshold / max(spread, 1e-6)) : 0
            model.progress = 0.5 + 0.45 * closeness
            return
        }
        model.progress = 1

        calibCaptured[model.step] = median
        if Prefs.soundFeedback {
            let sound = NSSound(named: "Tink")
            sound?.volume = 0.25
            sound?.play()
        }
        if let next = BoundsStep(rawValue: model.step.rawValue + 1) {
            model.step = next
            model.progress = 0
            calibBuffer = []
            calibSettleUntil = now + 0.9
            calibStepStartedAt = now + 0.9
        } else {
            finishBoundsCalibration()
        }
    }

    private func finishBoundsCalibration() {
        defer { closeCalibrationUI() }
        guard let centre = calibCaptured[.center],
            let left = calibCaptured[.left], let right = calibCaptured[.right],
            let top = calibCaptured[.top], let bottom = calibCaptured[.bottom]
        else {
            stopSession()
            toast?(false, "Calibration failed - please try again")
            return
        }
        let bounds = HeadBounds(
            neutral: centre,
            leftX: Double(left.x), rightX: Double(right.x),
            topY: Double(top.y), bottomY: Double(bottom.y))
        guard bounds.isUsable else {
            stopSession()
            toast?(false, "Edges weren't distinct enough - try again with bigger head turns")
            return
        }
        Prefs.setHeadBounds(bounds)
        pointer.bounds = bounds
        pointer.recenter(to: centre)
        boundsCalibrated = true
        filterX.reset()
        filterY.reset()
        recentRaw.removeAll()
        lastPosted = nil
        state = .tracking
        toast?(true, "Range calibrated - blink to click, ⌃⌥E to stop")
        log.info("bounds calibrated: neutral=(\(centre.x, privacy: .public), \(centre.y, privacy: .public)) spans x=[\(bounds.leftX, privacy: .public), \(bounds.rightX, privacy: .public)] y=[\(bounds.bottomY, privacy: .public), \(bounds.topY, privacy: .public)]")
    }

    // MARK: - Clicking

    private func performClick(pointedAtBefore blinkStart: TimeInterval) {
        // Where the user was pointing ~120ms before the eyelids moved.
        let lookupTime = blinkStart - 0.12
        let pointed = trail.last(where: { $0.time <= lookupTime })?.point
            ?? trail.first?.point
        guard var target = pointed else { return }

        if Prefs.gazeSnap, let snapped = snapTarget(near: target) {
            target = snapped
        }
        let now = CACurrentMediaTime()
        suppressCursorUntil = now + 0.35
        clickCooldownUntil = now + 1.0
        filterX.reset()
        filterY.reset()
        recentRaw.removeAll()

        postMouse(.mouseMoved, at: target)
        postMouse(.leftMouseDown, at: target)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            Self.postMouseStatic(.leftMouseUp, at: target)
        }
        if Prefs.soundFeedback {
            let sound = NSSound(named: "Pop")
            sound?.volume = 0.2
            sound?.play()
        }
        log.info("head click at (\(Int(target.x), privacy: .public), \(Int(target.y), privacy: .public))")
    }

    private func postMouse(_ type: CGEventType, at point: CGPoint) {
        Self.postMouseStatic(type, at: point)
    }

    private static func postMouseStatic(_ type: CGEventType, at point: CGPoint) {
        CGEvent(
            mouseEventSource: nil, mouseType: type,
            mouseCursorPosition: point, mouseButton: .left
        )?.post(tap: .cghidEventTap)
    }

    // MARK: - Snap targets

    /// Head pointing is coarse; snapping the click to the nearest plausible
    /// target (window title bars, Dock icons) is what makes "face an app and
    /// blink" reliable.
    private func snapTarget(near point: CGPoint) -> CGPoint? {
        let radius = Prefs.gazeSnapRadius
        let candidates = windowTitlePoints() + dockIconCenters()
        return
            candidates
            .map { (point: $0, distance: hypot($0.x - point.x, $0.y - point.y)) }
            .filter { $0.distance <= radius }
            .min { $0.distance < $1.distance }?
            .point
    }

    private func windowTitlePoints() -> [CGPoint] {
        guard
            let info = CGWindowListCopyWindowInfo(
                [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]]
        else { return [] }
        return info.compactMap { entry in
            guard (entry[kCGWindowLayer as String] as? Int) == 0,
                (entry[kCGWindowOwnerName as String] as? String) != "Murmur",
                let bounds = entry[kCGWindowBounds as String] as? [String: CGFloat],
                let x = bounds["X"], let y = bounds["Y"],
                let width = bounds["Width"], let height = bounds["Height"],
                width > 160, height > 90
            else { return nil }
            // Center of the title bar: focuses the window without pressing
            // anything inside it.
            return CGPoint(x: x + width / 2, y: y + 14)
        }
    }

    private func dockIconCenters() -> [CGPoint] {
        guard
            let dock = NSRunningApplication.runningApplications(
                withBundleIdentifier: "com.apple.dock"
            ).first
        else { return [] }
        let app = AXUIElementCreateApplication(dock.processIdentifier)
        var childrenRef: CFTypeRef?
        AXUIElementCopyAttributeValue(app, kAXChildrenAttribute as CFString, &childrenRef)
        guard let lists = childrenRef as? [AXUIElement] else { return [] }

        var centers: [CGPoint] = []
        for list in lists {
            var itemsRef: CFTypeRef?
            AXUIElementCopyAttributeValue(list, kAXChildrenAttribute as CFString, &itemsRef)
            guard let items = itemsRef as? [AXUIElement] else { continue }
            for item in items {
                var posRef: CFTypeRef?
                var sizeRef: CFTypeRef?
                AXUIElementCopyAttributeValue(item, kAXPositionAttribute as CFString, &posRef)
                AXUIElementCopyAttributeValue(item, kAXSizeAttribute as CFString, &sizeRef)
                var position = CGPoint.zero
                var size = CGSize.zero
                if let posRef, CFGetTypeID(posRef) == AXValueGetTypeID(),
                    AXValueGetValue(posRef as! AXValue, .cgPoint, &position),
                    let sizeRef, CFGetTypeID(sizeRef) == AXValueGetTypeID(),
                    AXValueGetValue(sizeRef as! AXValue, .cgSize, &size),
                    size.width > 0
                {
                    centers.append(
                        CGPoint(x: position.x + size.width / 2, y: position.y + size.height / 2))
                }
            }
        }
        return centers
    }

    private static func median(_ values: [CGFloat]) -> CGFloat {
        let sorted = values.sorted()
        return sorted[sorted.count / 2]
    }

    private static func median(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        return sorted[sorted.count / 2]
    }

    // MARK: - Geometry

    /// NSScreen frames are bottom-left-origin Cocoa coords; CGEvents use
    /// top-left-origin global coords flipped about the primary screen.
    private static func cgRect(of screen: NSScreen) -> CGRect {
        let primaryMaxY = NSScreen.screens.first?.frame.maxY ?? 0
        let f = screen.frame
        return CGRect(
            x: f.minX, y: primaryMaxY - f.maxY, width: f.width, height: f.height)
    }
}
