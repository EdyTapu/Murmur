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
        case tracking
    }

    private let log = Logger(subsystem: "com.alessio.murmur", category: "gaze")

    @Published private(set) var state: State = .off

    /// Surface toasts through the shared HUD (wired up by AppController).
    var toast: ((Bool, String) -> Void)?

    private var tracker: FaceTracker?
    private var camera: GazeCamera?
    private var pointer = HeadPointer(gain: Prefs.headSensitivity)
    /// Head tuning: higher cutoff + strong beta = the filter opens right up
    /// on deliberate motion (the "cursor slogs behind" fix) while still
    /// settling at rest; the head signal is clean enough to afford it.
    private var filterX = OneEuroFilter(minCutoff: 1.5, beta: 3.0)
    private var filterY = OneEuroFilter(minCutoff: 1.5, beta: 3.0)
    /// Last few raw mapped points; a component-wise median kills the
    /// single-frame landmark spikes that One Euro alone would let through.
    private var recentRaw: [CGPoint] = []
    private var blink = BlinkDetector(minHold: 0.1)
    /// Median-of-3 EAR window: Vision eye contours spike on single frames,
    /// and a raw spike below the closed threshold reads as a blink.
    private var recentEARs: [Double] = []
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

    var statusText: String {
        switch state {
        case .off: return "Head control off"
        case .starting: return "Starting head control…"
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

    /// Live sensitivity change from the Settings slider - no session restart.
    func applySensitivity() {
        pointer.gain = Prefs.headSensitivity
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
        camera?.stop()
        camera = nil
        tracker = nil
        pointer.reset()
        neutralSamples = nil
        filterX.reset()
        filterY.reset()
        recentRaw.removeAll()
        recentEARs.removeAll()
        trail.removeAll()
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
        pointer = HeadPointer(gain: Prefs.headSensitivity)
        neutralSamples = []
        blink = BlinkDetector(minHold: 0.1)
        recentEARs = []
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
                    toast?(true, "Head control on - blink to click, ⌃⌥E to stop")
                } else {
                    toast?(true, "Recentered")
                }
            }
            return
        }
        guard state == .tracking else { return }

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
        postMouse(.mouseMoved, at: clamped)
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
