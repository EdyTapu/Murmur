import Foundation

/// Wispr-Flow-style app categories used for per-app tone matching.
/// Precedence when an app could be several: personal messaging > email > work messaging > other.
enum AppCategory: String, CaseIterable {
    case personalMessaging
    case email
    case workMessaging
    case other

    var label: String {
        switch self {
        case .personalMessaging: return "Personal messaging"
        case .email: return "Email"
        case .workMessaging: return "Work messaging"
        case .other: return "Everything else"
        }
    }

    private static let personalIDs: Set<String> = [
        "com.apple.MobileSMS",
        "net.whatsapp.WhatsApp",
        "ru.keepcoder.Telegram",
        "org.telegram.desktop",
        "org.whispersystems.signal-desktop",
        "com.hnc.Discord",
        "com.facebook.archon",  // Messenger
    ]

    private static let emailIDs: Set<String> = [
        "com.apple.mail",
        "com.microsoft.Outlook",
        "com.readdle.smartemail-Mac",
        "com.superhuman.electron",
        "it.bloop.airmail2",
        "com.mimestream.Mimestream",
    ]

    private static let workIDs: Set<String> = [
        "com.tinyspeck.slackmacgap",
        "com.microsoft.teams2",
        "com.microsoft.teams",
        "us.zoom.xos",
        "com.linear",
        "notion.id",
    ]

    static func categorize(bundleID: String?) -> AppCategory {
        guard let id = bundleID else { return .other }
        if personalIDs.contains(id) { return .personalMessaging }
        if emailIDs.contains(id) { return .email }
        if workIDs.contains(id) { return .workMessaging }
        return .other
    }
}
