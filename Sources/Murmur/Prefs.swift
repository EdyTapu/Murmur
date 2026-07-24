import Foundation
import SwiftUI

/// UserDefaults-backed preference keys, shared between views (@AppStorage) and controllers.
enum PrefKey {
    static let hotkey = "hotkey"
    static let toggleShortcut = "toggleShortcut"
    static let micDeviceUID = "micDeviceUID"
    static let fillerRemoval = "fillerRemoval"
    static let aiCleanup = "aiCleanup"
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
    static let gazeSnap = "gazeSnap"
    static let gazeSnapRadius = "gazeSnapRadius"
    static let gazeCalibrationData = "gazeCalibrationData"
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
    /// Optional user-recorded shortcut that toggles hands-free dictation.
    static var toggleShortcut: ToggleShortcut? {
        guard let data = defaults.data(forKey: PrefKey.toggleShortcut) else { return nil }
        return try? JSONDecoder().decode(ToggleShortcut.self, from: data)
    }
    static func setToggleShortcut(_ shortcut: ToggleShortcut?) {
        if let shortcut, let data = try? JSONEncoder().encode(shortcut) {
            defaults.set(data, forKey: PrefKey.toggleShortcut)
        } else {
            defaults.removeObject(forKey: PrefKey.toggleShortcut)
        }
    }
    /// CoreAudio UID of the preferred input device; empty = system default.
    static var micDeviceUID: String {
        defaults.string(forKey: PrefKey.micDeviceUID) ?? ""
    }
    static var fillerRemoval: Bool {
        defaults.object(forKey: PrefKey.fillerRemoval) as? Bool ?? true
    }
    static var aiCleanup: Bool {
        defaults.bool(forKey: PrefKey.aiCleanup)
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
    static var gazeSnap: Bool {
        defaults.object(forKey: PrefKey.gazeSnap) as? Bool ?? true
    }
    static var gazeSnapRadius: Double {
        let v = defaults.double(forKey: PrefKey.gazeSnapRadius)
        return v > 0 ? v : 150
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
