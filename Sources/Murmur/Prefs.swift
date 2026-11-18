import Foundation
import SwiftUI

/// UserDefaults-backed preference keys, shared between views (@AppStorage) and controllers.
enum PrefKey {
    static let hotkey = "hotkey"
    static let toggleShortcut = "toggleShortcut"
    static let micDeviceUID = "micDeviceUID"
    static let micPriority = "micPriority"
    static let fillerRemoval = "fillerRemoval"
    static let aiCleanup = "aiCleanup"
    static let cleanupLevel = "cleanupLevel"
    static let muteWhileDictating = "muteWhileDictating"
    static let historyRetention = "historyRetention"
    static let syncFolder = "syncFolder"
    static let spokenPunctuation = "spokenPunctuation"
    static let contextAwareness = "contextAwareness"
    static let flowBarAlwaysVisible = "flowBarAlwaysVisible"
    static let flowBarAnchor = "flowBarAnchor"
    static let tonePersonal = "tonePersonal"
    static let toneWork = "toneWork"
    static let toneEmail = "toneEmail"
    static let toneOther = "toneOther"
    static let silenceAutoStop = "silenceAutoStop"
    static let silenceSeconds = "silenceSeconds"
    static let clipboardRestoreDelay = "clipboardRestoreDelay"
    static let preferAXInsertion = "preferAXInsertion"
    static let soundFeedback = "soundFeedback"
    static let onboardingDone = "onboardingDone"
    static let gazeBlinkClick = "gazeBlinkClick"
    static let gazePuckerClick = "gazePuckerClick"
    static let gazeSnap = "gazeSnap"
    static let gazeSnapRadius = "gazeSnapRadius"
    static let headSensitivity = "headSensitivity"
    static let headBounds = "headBounds"
}

/// The user-recordable global shortcuts. The raw value is the UserDefaults key.
enum ShortcutAction: String, CaseIterable {
    case toggle = "toggleShortcut"
    case transform = "transformShortcut"
    case scratchpad = "scratchpadShortcut"

    var defaultShortcut: ToggleShortcut? {
        // ⌥S opens the scratchpad, as in Wispr Flow.
        self == .scratchpad ? ToggleShortcut(keyCode: 1, modifierFlags: .option) : nil
    }
}

enum HotkeyChoice: String, CaseIterable, Identifiable {
    case fn
    case rightCommand
    case rightOption

    var id: String { rawValue }

    var label: String {
        switch self {
        case .fn: return "fn / 🌐"
        case .rightCommand: return "Right ⌘"
        case .rightOption: return "Right ⌥"
        }
    }

    var keyCode: UInt16 {
        switch self {
        case .fn: return 63
        case .rightCommand: return 54
        case .rightOption: return 61
        }
    }

    var flag: NSEvent.ModifierFlags {
        switch self {
        case .fn: return .function
        case .rightCommand: return .command
        case .rightOption: return .option
        }
    }
}

/// How long dictations stay in History.
enum HistoryRetention: String, CaseIterable, Identifiable {
    case forever
    case day
    case never

    var id: String { rawValue }

    var label: String {
        switch self {
        case .forever: return "Keep the last 1,000"
        case .day: return "Delete after 24 hours"
        case .never: return "Never store"
        }
    }
}

/// How much Murmur edits a dictation.
enum CleanupLevel: String, CaseIterable, Identifiable {
    case none
    case light
    case medium

    var id: String { rawValue }

    var label: String {
        switch self {
        case .none: return "None (raw transcript)"
        case .light: return "Light (fillers, corrections, formatting)"
        case .medium: return "Medium (Light + AI polish)"
        }
    }
}

enum Tone: String, CaseIterable, Identifiable {
    case neutral
    case formal
    case casual
    case veryCasual

    var id: String { rawValue }

    var label: String {
        switch self {
        case .neutral: return "Neutral (clean only)"
        case .formal: return "Formal"
        case .casual: return "Casual"
        case .veryCasual: return "Very casual"
        }
    }

    var promptDescription: String {
        switch self {
        case .neutral:
            return "Keep the speaker's natural tone; do not shift formality."
        case .formal:
            return "Use a polished, professional register suitable for documents and email."
        case .casual:
            return "Use a relaxed, friendly register; contractions are fine."
        case .veryCasual:
            return "Use a very informal chat register: lowercase-style informality is fine, keep it light and brief."
        }
    }
}

struct Prefs {
    static var defaults: UserDefaults { .standard }

    static var hotkey: HotkeyChoice {
        HotkeyChoice(rawValue: defaults.string(forKey: PrefKey.hotkey) ?? "") ?? .fn
    }
    static func shortcut(_ action: ShortcutAction) -> ToggleShortcut? {
        guard let data = defaults.data(forKey: action.rawValue) else { return action.defaultShortcut }
        return try? JSONDecoder().decode(ToggleShortcut.self, from: data)
    }
    static func setShortcut(_ shortcut: ToggleShortcut?, for action: ShortcutAction) {
        // Empty data means "removed on purpose"; a missing key gets the default.
        defaults.set(shortcut.flatMap { try? JSONEncoder().encode($0) } ?? Data(), forKey: action.rawValue)
    }
    static var flowBarAlwaysVisible: Bool {
        defaults.object(forKey: PrefKey.flowBarAlwaysVisible) as? Bool ?? true
    }
    /// Where the user dragged the bar (centre of its bottom edge, screen coordinates).
    static var flowBarAnchor: NSPoint? {
        defaults.string(forKey: PrefKey.flowBarAnchor).map(NSPointFromString)
    }
    static func setFlowBarAnchor(_ point: NSPoint?) {
        defaults.set(point.map(NSStringFromPoint), forKey: PrefKey.flowBarAnchor)
    }
    static var contextAwareness: Bool {
        defaults.object(forKey: PrefKey.contextAwareness) as? Bool ?? true
    }
    /// Microphones in order of preference; the first connected one is used.
    /// Falls back to the single-mic setting this list replaced.
    static var micPriority: [AudioInputDevice] {
        if let data = defaults.data(forKey: PrefKey.micPriority),
            let list = try? JSONDecoder().decode([AudioInputDevice].self, from: data) {
            return list
        }
        let legacy = defaults.string(forKey: PrefKey.micDeviceUID) ?? ""
        return legacy.isEmpty ? [] : [AudioInputDevice(uid: legacy, name: "Saved microphone")]
            .map { saved in AudioDevices.inputDevices().first { $0.uid == saved.uid } ?? saved }
    }
    static func setMicPriority(_ list: [AudioInputDevice]) {
        defaults.set(try? JSONEncoder().encode(list), forKey: PrefKey.micPriority)
    }
    /// Falls back to the two toggles this setting replaced.
    static var cleanupLevel: CleanupLevel {
        if let level = CleanupLevel(rawValue: defaults.string(forKey: PrefKey.cleanupLevel) ?? "") { return level }
        if defaults.bool(forKey: PrefKey.aiCleanup) { return .medium }
        return defaults.object(forKey: PrefKey.fillerRemoval) as? Bool ?? true ? .light : .none
    }
    static var muteWhileDictating: Bool {
        defaults.object(forKey: PrefKey.muteWhileDictating) as? Bool ?? true
    }
    static var historyRetention: HistoryRetention {
        HistoryRetention(rawValue: defaults.string(forKey: PrefKey.historyRetention) ?? "") ?? .forever
    }
    /// Folder (for example in iCloud Drive) that holds the dictionary and
    /// snippets so several Macs share them; nil keeps them on this Mac.
    static var syncFolder: URL? {
        defaults.string(forKey: PrefKey.syncFolder).flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
    }
    static var spokenPunctuation: Bool {
        defaults.object(forKey: PrefKey.spokenPunctuation) as? Bool ?? true
    }
    static var silenceAutoStop: Bool {
        defaults.object(forKey: PrefKey.silenceAutoStop) as? Bool ?? true
    }
    static var silenceSeconds: Double {
        let v = defaults.double(forKey: PrefKey.silenceSeconds)
        return v > 0 ? v : 2.5
    }
    static var clipboardRestoreDelay: Double {
        let v = defaults.double(forKey: PrefKey.clipboardRestoreDelay)
        return v > 0 ? v : 0.35
    }
    static var preferAXInsertion: Bool {
        defaults.object(forKey: PrefKey.preferAXInsertion) as? Bool ?? true
    }
    static var soundFeedback: Bool {
        defaults.object(forKey: PrefKey.soundFeedback) as? Bool ?? true
    }
    static var gazeBlinkClick: Bool {
        defaults.object(forKey: PrefKey.gazeBlinkClick) as? Bool ?? true
    }
    static var gazePuckerClick: Bool {
        defaults.object(forKey: PrefKey.gazePuckerClick) as? Bool ?? true
    }
    static var gazeSnap: Bool {
        defaults.object(forKey: PrefKey.gazeSnap) as? Bool ?? true
    }
    static var gazeSnapRadius: Double {
        let v = defaults.double(forKey: PrefKey.gazeSnapRadius)
        return v > 0 ? v : 150
    }
    /// Head-pointer gain: cursor travel in screen-widths/heights per head-measure unit.
    static var headSensitivity: Double {
        let v = defaults.double(forKey: PrefKey.headSensitivity)
        return v > 0 ? v : 3.5
    }
    /// Calibrated head range (edge sweep); nil = use the sensitivity slider.
    static var headBounds: HeadBounds? {
        guard let data = defaults.data(forKey: PrefKey.headBounds) else { return nil }
        return try? JSONDecoder().decode(HeadBounds.self, from: data)
    }
    static func setHeadBounds(_ bounds: HeadBounds?) {
        if let bounds, let data = try? JSONEncoder().encode(bounds) {
            defaults.set(data, forKey: PrefKey.headBounds)
        } else {
            defaults.removeObject(forKey: PrefKey.headBounds)
        }
    }

    static func tone(for category: AppCategory) -> Tone {
        let key: String
        switch category {
        case .personalMessaging: key = PrefKey.tonePersonal
        case .workMessaging: key = PrefKey.toneWork
        case .email: key = PrefKey.toneEmail
        case .other: key = PrefKey.toneOther
        }
        return Tone(rawValue: defaults.string(forKey: key) ?? "") ?? .neutral
    }
}
