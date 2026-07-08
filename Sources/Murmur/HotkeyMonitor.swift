import AppKit
import Foundation
import os

/// Watches a single modifier-style hotkey (fn / right ⌘ / right ⌥) system-wide
/// via NSEvent global+local flagsChanged monitors and reports press/release.
///
/// Requires Accessibility trust; without it the global monitor receives nothing.
@MainActor
final class HotkeyMonitor {
    private let log = Logger(subsystem: "com.alessio.murmur", category: "hotkey")

    var onKeyDown: (() -> Void)?
    var onKeyUp: (() -> Void)?

    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var isDown = false
    private(set) var choice: HotkeyChoice = .fn

    func start(choice: HotkeyChoice) {
        stop()
        self.choice = choice
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            // Global monitor callbacks can arrive off the main thread.
            let keyCode = event.keyCode
            let flags = event.modifierFlags
            Task { @MainActor [weak self] in
                self?.handle(keyCode: keyCode, flags: flags)
            }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.handle(keyCode: event.keyCode, flags: event.modifierFlags)
            return event
        }
        log.info("Hotkey monitor started for \(choice.rawValue, privacy: .public)")
    }

    func stop() {
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        globalMonitor = nil
        localMonitor = nil
        isDown = false
    }

    private func handle(keyCode: UInt16, flags: NSEvent.ModifierFlags) {
        guard keyCode == choice.keyCode else { return }
        let down = flags.contains(choice.flag)
        guard down != isDown else { return }
        isDown = down
        if down {
            onKeyDown?()
        } else {
            onKeyUp?()
        }
    }
}
