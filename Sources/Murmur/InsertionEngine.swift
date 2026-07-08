import AppKit
import ApplicationServices
import Carbon
import Foundation
import os

struct TargetContext: Sendable {
    var appName: String?
    var appBundleID: String?
    var appPID: pid_t?
    var secureInputActive: Bool
    var category: AppCategory { AppCategory.categorize(bundleID: appBundleID) }
}

enum InsertionMethod: String, Sendable {
    case ax
    case paste
    case appleScript
    case none
}

struct InsertionOutcome: Sendable {
    var success: Bool
    var method: InsertionMethod
    var reason: String?

    var historyLabel: String {
        success ? method.rawValue : "history-only:\(reason ?? "failed")"
    }
}

/// Inserts text into the focused field of the frontmost app using a
/// three-tier fallback: direct Accessibility insertion, clipboard+Cmd+V
/// (with pasteboard snapshot/restore), then AppleScript keystroke.
@MainActor
final class InsertionEngine {
    private let log = Logger(subsystem: "com.alessio.murmur", category: "insert")

    /// Marker type so clipboard managers ignore our transient pasteboard write.
    private static let concealedType = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")

    // MARK: - Context capture

    func captureContext() -> TargetContext {
        let app = NSWorkspace.shared.frontmostApplication
        return TargetContext(
            appName: app?.localizedName,
            appBundleID: app?.bundleIdentifier,
            appPID: app?.processIdentifier,
            secureInputActive: IsSecureEventInputEnabled()
        )
    }

    // MARK: - Insertion

    func insert(_ text: String, context: TargetContext) async -> InsertionOutcome {
        guard !text.isEmpty else {
            return InsertionOutcome(success: false, method: .none, reason: "empty")
        }
        if IsSecureEventInputEnabled() {
            return InsertionOutcome(success: false, method: .none, reason: "secure-input")
        }
        guard AXIsProcessTrusted() else {
            return InsertionOutcome(success: false, method: .none, reason: "no-accessibility")
        }

        if Prefs.preferAXInsertion, insertViaAX(text) {
            return InsertionOutcome(success: true, method: .ax)
        }
        if await insertViaPaste(text) {
            return InsertionOutcome(success: true, method: .paste)
        }
        if await insertViaAppleScript(text) {
            return InsertionOutcome(success: true, method: .appleScript)
        }
        return InsertionOutcome(success: false, method: .none, reason: "all-tiers-failed")
    }

    // MARK: Tier 1 - direct AX insertion

    /// Insert by setting kAXSelectedText on the focused element.
    /// Only attempted when the field's value is readable, so success can be
    /// VERIFIED by re-reading - otherwise a silent AX failure followed by a
    /// paste would double-insert.
    private func insertViaAX(_ text: String) -> Bool {
        let systemWide = AXUIElementCreateSystemWide()
        var focusedRef: CFTypeRef?
        let focusErr = AXUIElementCopyAttributeValue(
            systemWide, kAXFocusedUIElementAttribute as CFString, &focusedRef)
        guard focusErr == .success, let focusedRef,
            CFGetTypeID(focusedRef) == AXUIElementGetTypeID()
        else { return false }
        let element = focusedRef as! AXUIElement

        // Never type into ourselves.
        var pid: pid_t = 0
        AXUIElementGetPid(element, &pid)
        if pid == ProcessInfo.processInfo.processIdentifier { return false }

        // Selected-text insertion must be settable.
        var settable = DarwinBoolean(false)
        AXUIElementIsAttributeSettable(element, kAXSelectedTextAttribute as CFString, &settable)
        guard settable.boolValue else { return false }

        // Value must be readable BEFORE, so we can verify AFTER.
        guard let before = stringValue(of: element) else { return false }
        // Skip huge documents; verification would be unreliable/expensive.
        guard before.utf16.count < 200_000 else { return false }

        let setErr = AXUIElementSetAttributeValue(
            element, kAXSelectedTextAttribute as CFString, text as CFTypeRef)
        guard setErr == .success else { return false }

        guard let after = stringValue(of: element), after != before, after.contains(text) else {
            log.info("AX insertion unverified; falling back to paste")
            return false
        }
        return true
    }

    private func stringValue(of element: AXUIElement) -> String? {
        var valueRef: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &valueRef)
        guard err == .success else { return nil }
        return valueRef as? String
    }

    // MARK: Tier 2 - clipboard + Cmd+V

    private func insertViaPaste(_ text: String) async -> Bool {
        let pasteboard = NSPasteboard.general
        let saved = snapshotPasteboard(pasteboard)

        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        pasteboard.setString("", forType: Self.concealedType)

        guard postCmdV() else {
            restorePasteboard(pasteboard, items: saved)
            return false
        }

        // Give the target app time to consume the paste before restoring.
        let delay = Prefs.clipboardRestoreDelay
        try? await Task.sleep(for: .milliseconds(Int(delay * 1000)))
        restorePasteboard(pasteboard, items: saved)
        return true
    }

    private func snapshotPasteboard(_ pasteboard: NSPasteboard) -> [[NSPasteboard.PasteboardType: Data]] {
        (pasteboard.pasteboardItems ?? []).map { item in
            var record: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                if let data = item.data(forType: type) {
                    record[type] = data
                }
            }
            return record
        }
    }

    private func restorePasteboard(
        _ pasteboard: NSPasteboard, items: [[NSPasteboard.PasteboardType: Data]]
    ) {
        pasteboard.clearContents()
        guard !items.isEmpty else { return }
        let restored = items.map { record -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (type, data) in record {
                item.setData(data, forType: type)
            }
            return item
        }
        pasteboard.writeObjects(restored)
    }

    private func postCmdV() -> Bool {
        guard let source = CGEventSource(stateID: .combinedSessionState) else { return false }
        let vKey: CGKeyCode = 9
        guard
            let keyDown = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: true),
            let keyUp = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: false)
        else { return false }
        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
        return true
    }

    // MARK: Tier 3 - AppleScript keystroke

    private func insertViaAppleScript(_ text: String) async -> Bool {
        // Types the text directly (no clipboard) via System Events.
        let escaped = text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let script = "tell application \"System Events\" to keystroke \"\(escaped)\""
        guard let appleScript = NSAppleScript(source: script) else { return false }
        var error: NSDictionary?
        appleScript.executeAndReturnError(&error)
        if let error {
            log.warning("AppleScript insertion failed: \(error, privacy: .public)")
            return false
        }
        return true
    }
}
