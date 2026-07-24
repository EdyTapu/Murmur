import AVFoundation
import AppKit
import Carbon.HIToolbox
import Foundation
import os

/// Eye control: look where you want the cursor, blink to click.
///
/// Session pipeline: ⌃⌥E → camera frames → gaze_helper.py (MediaPipe) →
/// feature vector → calibrated ridge map → median + One Euro smoothing →
/// cursor. Any blink or wink clicks, snapping to the nearest window
/// title bar or Dock icon so the ~1-2° webcam gaze error still hits the
/// app you meant. First session runs a 9-point calibration overlay.
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

    /// Surface toasts through the shared HUD (wired up by AppController).
    var toast: ((Bool, String) -> Void)?

    private var helper: GazeHelperProcess?
    private var camera: GazeCamera?
    private var calibration = GazeCalibration.load()
    private var filterX = OneEuroFilter()
    private var filterY = OneEuroFilter()
    /// Last few raw mapped points; a component-wise median kills the
    /// single-frame landmark spikes that One Euro alone would let through.
    private var recentRaw: [CGPoint] = []
    private var blink = BlinkDetector()
    /// Recent smoothed cursor positions - a blink click lands where the user
    /// was looking just *before* the eyelids started corrupting the iris fit.
    private var trail: [(time: TimeInterval, point: CGPoint)] = []
    private var suppressCursorUntil: TimeInterval = 0
    private var readyTimeoutTask: Task<Void, Never>?

    var isInstalled: Bool { GazeHelperProcess.isInstalled }
    var isCalibrated: Bool { calibration != nil }

    var statusText: String {
        switch state {
        case .off: return "Eye control off"
        case .starting: return "Starting eye control…"
        case .calibrating: return "Calibrating…"
        case .tracking: return "Eye control on - blink to click"
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
            stopSession(toastMessage: "Eye control off")
        }
    }

    func start(forceCalibration: Bool = false) {
        guard state == .off else {
            if forceCalibration { beginCalibration() }
            return
        }
        guard isInstalled else {
            toast?(false, "Eye control needs setup - see Settings → Eye")
            AppShared.mainWindow.show(section: .settings)
            return
        }
        if forceCalibration { calibration = nil }

        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            proceedStart()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in
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

    func recalibrate() {
        if state == .off {
            start(forceCalibration: true)
        } else {
            beginCalibration()
        }
    }

    func stopSession(toastMessage: String? = nil) {
        let wasOff = state == .off
        state = .off
        readyTimeoutTask?.cancel()
        readyTimeoutTask = nil
        closeCalibrationUI()
        camera?.stop()
        camera = nil
        helper?.stop()
        helper = nil
        filterX.reset()
        filterY.reset()
        recentRaw.removeAll()
        trail.removeAll()
        if let toastMessage, !wasOff { toast?(true, toastMessage) }
    }

    private func cameraDenied() {
        toast?(false, "Grant Camera access to use eye control")
        if let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera") {
            NSWorkspace.shared.open(url)
        }
    }

    private func proceedStart() {
        state = .starting
        toast?(true, "Starting eye control…")

        let helper = GazeHelperProcess()
        helper.onReady = { [weak self] in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.helperReady() }
            }
        }
        helper.onSample = { [weak self] sample in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.handle(sample) }
            }
        }
        helper.onExit = { [weak self] status in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.state != .off else { return }
                    self.log.error("gaze helper died mid-session status=\(status, privacy: .public)")
                    self.stopSession()
                    self.toast?(false, "Eye tracking stopped unexpectedly")
                }
            }
        }

        let camera = GazeCamera()
        camera.onFrame = { [weak helper] width, height, bytesPerRow, pixels in
            helper?.send(
                width: width, height: height, bytesPerRow: bytesPerRow, pixels: pixels)
        }

        do {
            try helper.start()
            try camera.start()
        } catch {
            helper.stop()
            camera.stop()
            state = .off
            toast?(false, "Couldn't start eye tracking: \(error.localizedDescription)")
            return
        }
        self.helper = helper
        self.camera = camera

        // MediaPipe imports take a few seconds; give up if the handshake
        // never arrives (broken venv, wrong python).
        readyTimeoutTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(25))
            guard let self, !Task.isCancelled, self.state == .starting else { return }
            self.stopSession()
            self.toast?(false, "Eye tracking helper didn't start - re-run app/setup_gaze.sh")
        }
    }

    private func helperReady() {
        guard state == .starting else { return }
        readyTimeoutTask?.cancel()
        readyTimeoutTask = nil
        if let calibration {
            state = .tracking
            blink = BlinkDetector(baseline: calibration.openEAR ?? 0.26)
            toast?(true, "Eye control on - blink to click, ⌃⌥E to stop")
        } else {
            beginCalibration()
        }
    }

    // MARK: - Calibration

    private var calibModel: GazeCalibrationModel?
    private var calibWindowController: GazeCalibrationWindowController?
    /// Completed points' samples (one inner array per captured dot).
    private var calibSamples: [[[Double]]] = []
    /// Rolling clean samples for the current dot; a blink freezes the ones
    /// from just before the eyelids moved.
    private var calibBuffer: [(time: TimeInterval, features: [Double])] = []
    private var calibBlink = BlinkDetector()
    private var calibEARs: [Double] = []
    private var calibScreenCG: CGRect = .zero
    private var settleUntil: TimeInterval = 0
    private var lastCleanSampleAt: TimeInterval = 0
    private let samplesPerPoint = 12

    private func beginCalibration() {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        closeCalibrationUI()
        state = .calibrating
        calibScreenCG = Self.cgRect(of: screen)
        calibSamples = []
        calibBuffer = []
        calibEARs = []
        // Sessions click on any blink, but capturing a dot keeps a small
        // minimum hold so a stray natural blink doesn't grab it early.
        calibBlink = BlinkDetector(minHold: 0.15, maxHold: 1.6)
        let model = GazeCalibrationModel()
        calibModel = model
        let windowController = GazeCalibrationWindowController()
        calibWindowController = windowController
        let now = CACurrentMediaTime()
        settleUntil = now + 1.2
        lastCleanSampleAt = now
        windowController.show(on: screen, model: model) { [weak self] in
            self?.stopSession(toastMessage: "Calibration cancelled")
        }
    }

    private func closeCalibrationUI() {
        calibWindowController?.close()
        calibWindowController = nil
        calibModel = nil
        calibSamples = []
        calibBuffer = []
    }

    /// User-paced: each dot waits for a deliberate blink and captures the
    /// gaze samples from just before it - nothing advances until the user is
    /// ready, and every dot doubles as blink-click practice.
    private func handleCalibration(_ sample: GazeSample) {
        guard let model = calibModel else { return }
        model.faceVisible = sample.face
        let now = CACurrentMediaTime()

        // Nothing clean for a long stretch means the tracker can't see the
        // eyes at all - bail with a diagnosis instead of hanging forever.
        if now - lastCleanSampleAt > 20 {
            stopSession()
            toast?(false, "Couldn't track your eyes - improve lighting and retry")
            return
        }
        guard sample.face else { return }

        let closedAt = calibBlink.closedAt
        let blinked = calibBlink.process(
            ear: min(sample.earLeft, sample.earRight), at: now)
        if blinked {
            captureCalibrationPoint(blinkStart: closedAt ?? now, at: now)
            return
        }
        // Closing/closed eyes corrupt the iris fit; keep them out of the buffer.
        if calibBlink.isClosed { return }
        guard now >= settleUntil,
            min(sample.earLeft, sample.earRight) > 0.15
        else { return }

        lastCleanSampleAt = now
        calibBuffer.append((now, sample.features))
        if calibBuffer.count > 40 { calibBuffer.removeFirst(calibBuffer.count - 40) }
        // Track the *narrower* eye - the session blink detector watches
        // min(earL, earR) so winks count, and the baseline must match.
        calibEARs.append(min(sample.earLeft, sample.earRight))
        if calibEARs.count > 500 { calibEARs.removeFirst(calibEARs.count - 500) }
        model.progress = min(Double(calibBuffer.count) / Double(samplesPerPoint), 1)
        model.awaitingBlink = calibBuffer.count >= samplesPerPoint
    }

    private func captureCalibrationPoint(blinkStart: TimeInterval, at now: TimeInterval) {
        guard let model = calibModel else { return }
        // Only samples from before the eyelids started descending.
        let usable = calibBuffer.filter { $0.time <= blinkStart - 0.1 }.suffix(samplesPerPoint)
        guard usable.count >= 6 else { return }  // blinked too early - keep looking

        calibSamples.append(usable.map(\.features))
        calibBuffer.removeAll()
        if Prefs.soundFeedback {
            let sound = NSSound(named: "Tink")
            sound?.volume = 0.25
            sound?.play()
        }
        if calibSamples.count == GazeCalibrationModel.points.count {
            finishCalibration()
        } else {
            model.pointIndex = calibSamples.count
            model.progress = 0
            model.awaitingBlink = false
            settleUntil = now + 0.85
            lastCleanSampleAt = now
        }
    }

    private func finishCalibration() {
        var features: [[Double]] = []
        var targets: [CGPoint] = []
        for (index, samples) in calibSamples.enumerated() {
            for f in samples {
                features.append(f)
                targets.append(GazeCalibrationModel.points[index])
            }
        }
        let openEAR = calibEARs.isEmpty ? nil : calibEARs.sorted()[calibEARs.count / 2]
        closeCalibrationUI()
        guard let mapper = GazeMapper.fit(features: features, targets: targets) else {
            stopSession()
            toast?(false, "Calibration failed - please try again")
            return
        }
        let calibration = GazeCalibration(
            mapper: mapper, screenRect: calibScreenCG, openEAR: openEAR)
        calibration.save()
        self.calibration = calibration
        filterX.reset()
        filterY.reset()
        recentRaw.removeAll()
        blink = BlinkDetector(baseline: openEAR ?? 0.26)
        state = .tracking
        toast?(true, "Calibrated - blink to click, ⌃⌥E to stop")
    }

    // MARK: - Tracking

    private func handle(_ sample: GazeSample) {
        switch state {
        case .calibrating:
            handleCalibration(sample)
        case .tracking:
            handleTracking(sample)
        case .off, .starting:
            break
        }
    }

    private func handleTracking(_ sample: GazeSample) {
        guard let calibration else { return }
        let now = CACurrentMediaTime()

        if Prefs.gazeBlinkClick {
            // min(earL, earR) so closing either eye - blink or wink - clicks.
            let closedAt = blink.closedAt
            let clicked = blink.process(
                ear: min(sample.earLeft, sample.earRight), at: now)
            if clicked {
                performClick(lookedAtBefore: closedAt ?? now)
                return
            }
            // Eyes closed: the iris features are garbage, freeze the cursor.
            if blink.isClosed { return }
        }

        guard sample.face, now >= suppressCursorUntil,
            let normalized = calibration.mapper.predict(sample.features)
        else { return }

        let rect = calibration.screenRect
        let u = min(max(normalized.x, 0), 1)
        let v = min(max(normalized.y, 0), 1)
        let raw = CGPoint(
            x: rect.minX + u * rect.width,
            y: rect.minY + v * rect.height)
        recentRaw.append(raw)
        if recentRaw.count > 3 { recentRaw.removeFirst(recentRaw.count - 3) }
        let median = CGPoint(
            x: Self.median(recentRaw.map(\.x)),
            y: Self.median(recentRaw.map(\.y)))
        let smoothed = CGPoint(
            x: filterX.filter(median.x, at: now),
            y: filterY.filter(median.y, at: now))
        let clamped = CGPoint(
            x: min(max(smoothed.x, rect.minX), rect.maxX - 1),
            y: min(max(smoothed.y, rect.minY), rect.maxY - 1))

        trail.append((now, clamped))
        if trail.count > 60 { trail.removeFirst(trail.count - 60) }
        postMouse(.mouseMoved, at: clamped)
    }

    // MARK: - Clicking

    private func performClick(lookedAtBefore blinkStart: TimeInterval) {
        // Where the user was looking ~120ms before the eyelids moved.
        let lookupTime = blinkStart - 0.12
        let looked = trail.last(where: { $0.time <= lookupTime })?.point
            ?? trail.first?.point
        guard var target = looked else { return }

        if Prefs.gazeSnap, let snapped = snapTarget(near: target) {
            target = snapped
        }
        let now = CACurrentMediaTime()
        suppressCursorUntil = now + 0.35
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
        log.info("gaze click at (\(Int(target.x), privacy: .public), \(Int(target.y), privacy: .public))")
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

    /// A webcam can't do pixel-accurate gaze; snapping the click to the
    /// nearest plausible target (window title bars, Dock icons) is what makes
    /// "look at an app and blink" reliable.
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
