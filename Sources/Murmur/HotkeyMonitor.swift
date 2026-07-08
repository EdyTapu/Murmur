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
@MainActor
final class HotkeyMonitor {
    private let log = Logger(subsystem: "com.alessio.murmur", category: "hotkey")

    var onKeyDown: (() -> Void)?
    var onKeyUp: (() -> Void)?

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var isDown = false
    private var retryTask: Task<Void, Never>?
    private(set) var choice: HotkeyChoice = .fn

    private var cgFlag: CGEventFlags {
        switch choice {
        case .fn: return .maskSecondaryFn
        case .rightCommand: return .maskCommand
        case .rightOption: return .maskAlternate
        }
    }

    func start(choice: HotkeyChoice) {
        stop()
        self.choice = choice
        guard createTap() else {
            log.warning("Event tap creation failed (Accessibility not granted yet?); will retry")
            scheduleRetry()
            return
        }
        log.info("Event tap active for \(choice.rawValue, privacy: .public)")
    }

    func stop() {
        retryTask?.cancel()
        retryTask = nil
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        runLoopSource = nil
        tap = nil
        isDown = false
    }

    /// Keep trying to create the tap until Accessibility is granted.
    private func scheduleRetry() {
        retryTask?.cancel()
        retryTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3))
                guard let self, !Task.isCancelled else { return }
                if self.tap != nil { return }
                if self.createTap() {
                    self.log.info("Event tap active after retry")
                    return
                }
            }
        }
    }

    private func createTap() -> Bool {
        let mask = CGEventMask(1 << CGEventType.flagsChanged.rawValue)
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        guard
            let tap = CGEvent.tapCreate(
                tap: .cgSessionEventTap,
                place: .headInsertEventTap,
                options: .listenOnly,
                eventsOfInterest: mask,
                callback: { _, type, event, userInfo in
                    guard let userInfo else { return Unmanaged.passUnretained(event) }
                    let monitor = Unmanaged<HotkeyMonitor>.fromOpaque(userInfo)
                        .takeUnretainedValue()
                    monitor.handleEvent(type: type, event: event)
                    return Unmanaged.passUnretained(event)
                },
                userInfo: selfPtr
            )
        else { return false }

        self.tap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    /// Called on the run-loop thread the tap is scheduled on (main).
    private nonisolated func handleEvent(type: CGEventType, event: CGEvent) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            // macOS disables slow taps; re-enable ours (listen-only, cheap).
            Task { @MainActor [weak self] in
                guard let self, let tap = self.tap else { return }
                CGEvent.tapEnable(tap: tap, enable: true)
                self.log.warning("Event tap was disabled by the system; re-enabled")
            }
            return
        }
        guard type == .flagsChanged else { return }
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        let flags = event.flags
        Task { @MainActor [weak self] in
            self?.handle(keyCode: keyCode, flags: flags)
        }
    }

    private func handle(keyCode: Int64, flags: CGEventFlags) {
        guard keyCode == Int64(choice.keyCode) else { return }
        let down = flags.contains(cgFlag)
        guard down != isDown else { return }
        isDown = down
        if down {
            onKeyDown?()
        } else {
            onKeyUp?()
        }
    }
}
