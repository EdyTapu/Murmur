import AppKit
import CoreGraphics
import Foundation
import os

/// Watches a single modifier-style hotkey (fn / right ⌘ / right ⌥) system-wide
/// via a listen-only CGEventTap and reports press/release.
///
/// A CGEventTap (not NSEvent global monitors) is required for the fn/globe key:
/// NSEvent monitors do not reliably receive fn flagsChanged events.
/// Requires Accessibility trust; without it the tap cannot be created.
///
/// The tap lives on its own dedicated thread, NOT the main run loop: macOS
/// disables a tap whose host run loop stalls past its timeout, and main-thread
/// stalls (audio engine spin-up, model warm-up) were getting the tap killed at
/// exactly the moment the user pressed the hotkey. A watchdog timer on the
/// same thread re-creates a missing tap (Accessibility granted late),
/// re-enables a tap the system disabled, and resyncs key state after any dead
/// window so a missed release can't eat the next hold.
@MainActor
final class HotkeyMonitor {
    var onKeyDown: (() -> Void)?
    var onKeyUp: (() -> Void)?

    private(set) var choice: HotkeyChoice = .fn
    private var thread: HotkeyTapThread?

    func start(choice: HotkeyChoice) {
        stop()
        self.choice = choice
        // DispatchQueue.main (not Task) so rapid down/up events stay FIFO.
        let thread = HotkeyTapThread(choice: choice) { [weak self] down in
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if down { self.onKeyDown?() } else { self.onKeyUp?() }
                }
            }
        }
        thread.start()
        self.thread = thread
    }

    func stop() {
        thread?.shutdown()
        thread = nil
    }
}

/// Dedicated thread that owns the CGEventTap and all of its mutable state.
/// The tap callback and the watchdog timer both run on this thread's run
/// loop, so `tap`/`isDown` need no locking.
private final class HotkeyTapThread: Thread, @unchecked Sendable {
    private let log = Logger(subsystem: "com.alessio.murmur", category: "hotkey")

    private let choice: HotkeyChoice
    private let onChange: @Sendable (Bool) -> Void

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var isDown = false

    init(choice: HotkeyChoice, onChange: @escaping @Sendable (Bool) -> Void) {
        self.choice = choice
        self.onChange = onChange
        super.init()
        name = "com.alessio.murmur.hotkey-tap"
        qualityOfService = .userInteractive
    }

    private var cgFlag: CGEventFlags {
        switch choice {
        case .fn: return .maskSecondaryFn
        case .rightCommand: return .maskCommand
        case .rightOption: return .maskAlternate
        }
    }

    // MARK: - Thread lifecycle

    override func main() {
        let listenAccess = CGPreflightListenEventAccess()
        let axTrusted = AXIsProcessTrusted()
        log.info("Tap thread starting: listenEventAccess=\(listenAccess, privacy: .public), axTrusted=\(axTrusted, privacy: .public)")
        if !createWorkingTap() {
            log.warning("Event tap creation failed (Accessibility not granted yet?); will retry")
        }
        let timer = CFRunLoopTimerCreateWithHandler(
            kCFAllocatorDefault, CFAbsoluteTimeGetCurrent() + 2.0, 2.0, 0, 0
        ) { [weak self] _ in
            self?.watchdogTick()
        }
        CFRunLoopAddTimer(CFRunLoopGetCurrent(), timer, .commonModes)
        while !isCancelled {
            CFRunLoopRun()
        }
        CFRunLoopTimerInvalidate(timer)
        teardownTap()
    }

    /// Stop the thread from any other thread. The stop is queued onto this
    /// thread's own run loop, so it cannot race run-loop entry.
    func shutdown() {
        cancel()
        perform(#selector(stopRunLoop), on: self, with: nil, waitUntilDone: false)
    }

    @objc private func stopRunLoop() {
        CFRunLoopStop(CFRunLoopGetCurrent())
    }

    // MARK: - Tap management (all on the tap thread)

    /// Prefer a listen-only tap (authorized by Input Monitoring), but fall
    /// back to an active pass-through tap (authorized by Accessibility, which
    /// the app requires anyway): macOS rejects enabling a listen-only
    /// keyboard tap without Input Monitoring, and it does so silently -
    /// creation succeeds but the tap can never be enabled.
    private func createWorkingTap() -> Bool {
        for options in [CGEventTapOptions.listenOnly, .defaultTap] {
            if createTap(options: options) {
                if let tap, CGEvent.tapIsEnabled(tap: tap) {
                    let mode = options == .listenOnly ? "listen-only" : "active pass-through"
                    log.info("Event tap active for \(self.choice.rawValue, privacy: .public) (\(mode, privacy: .public), dedicated thread)")
                    return true
                }
                log.warning("Tap created but enable was rejected (options=\(options.rawValue, privacy: .public)); trying next mode")
                teardownTap()
            }
        }
        return false
    }

    private func createTap(options: CGEventTapOptions) -> Bool {
        let mask = CGEventMask(1 << CGEventType.flagsChanged.rawValue)
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        guard
            let tap = CGEvent.tapCreate(
                tap: .cgSessionEventTap,
                place: .headInsertEventTap,
                options: options,
                eventsOfInterest: mask,
                callback: { _, type, event, userInfo in
                    guard let userInfo else { return Unmanaged.passUnretained(event) }
                    let thread = Unmanaged<HotkeyTapThread>.fromOpaque(userInfo)
                        .takeUnretainedValue()
                    thread.handleEvent(type: type, event: event)
                    // Always pass the event through unmodified.
                    return Unmanaged.passUnretained(event)
                },
                userInfo: selfPtr
            )
        else { return false }

        self.tap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    private func teardownTap() {
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
        }
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        runLoopSource = nil
        tap = nil
    }

    private func watchdogTick() {
        guard let tap else {
            if createWorkingTap() { syncWithHardware() }
            return
        }
        if !CGEvent.tapIsEnabled(tap: tap) {
            CGEvent.tapEnable(tap: tap, enable: true)
            let portValid = CFMachPortIsValid(tap)
            let nowEnabled = CGEvent.tapIsEnabled(tap: tap)
            log.warning("Watchdog found the event tap disabled; re-enabled (portValid=\(portValid, privacy: .public), nowEnabled=\(nowEnabled, privacy: .public))")
            syncWithHardware()
        }
    }

    // MARK: - Events

    private func handleEvent(type: CGEventType, event: CGEvent) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            // Re-enable synchronously - we are on the tap's own thread, so
            // recovery can't be delayed by a stalled main thread.
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            log.warning("Event tap was disabled by the system; re-enabled")
            syncWithHardware()
            return
        }
        guard type == .flagsChanged,
            event.getIntegerValueField(.keyboardEventKeycode) == Int64(choice.keyCode)
        else { return }
        setDown(event.flags.contains(cgFlag))
    }

    /// Events are lost while the tap is disabled; a missed press should still
    /// start recording and a missed release must not leave `isDown` stuck
    /// (which would swallow the next hold). Resync from real hardware state.
    private func syncWithHardware() {
        let down: Bool
        switch choice {
        case .fn:
            // fn has no per-key state query; the session flag is unambiguous
            // because only fn sets maskSecondaryFn.
            down = CGEventSource.flagsState(.combinedSessionState).contains(.maskSecondaryFn)
        case .rightCommand, .rightOption:
            down = CGEventSource.keyState(.combinedSessionState, key: CGKeyCode(choice.keyCode))
        }
        setDown(down)
    }

    private func setDown(_ down: Bool) {
        guard down != isDown else { return }
        isDown = down
        onChange(down)
    }
}
