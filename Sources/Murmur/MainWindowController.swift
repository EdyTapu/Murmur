import AppKit
import SwiftUI

/// Sections of the main dashboard window's sidebar.
enum MainSection: String, CaseIterable, Identifiable {
    case home
    case history
    case scratchpad
    case dictionary
    case snippets
    case settings

    var id: String { rawValue }

    var label: String {
        switch self {
        case .home: return "Home"
        case .history: return "History"
        case .scratchpad: return "Scratchpad"
        case .dictionary: return "Dictionary"
        case .snippets: return "Snippets"
        case .settings: return "Settings"
        }
    }

    var icon: String {
        switch self {
        case .home: return "house"
        case .history: return "clock.arrow.circlepath"
        case .scratchpad: return "note.text"
        case .dictionary: return "character.book.closed"
        case .snippets: return "text.badge.plus"
        case .settings: return "gearshape"
        }
    }
}

/// Shared selection state so menu items can deep-link into a section.
@MainActor
final class MainWindowState: ObservableObject {
    @Published var section: MainSection = .home
}

/// Plain AppKit window for the Wispr-Flow-style dashboard - menu-bar apps
/// can't reliably open SwiftUI Window scenes from the app delegate, and this
/// window also drives the Dock-icon dance: the app becomes a regular app
/// (Dock icon, Cmd-Tab) while the dashboard is open and drops back to a pure
/// menu-bar accessory when it closes.
@MainActor
final class MainWindowController: NSObject, NSWindowDelegate {
    let state = MainWindowState()
    private var window: NSWindow?

    func show(section: MainSection? = nil) {
        if let section {
            state.section = section
        }
        NSApp.setActivationPolicy(.regular)
        if window == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 920, height: 600),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.title = "Murmur"
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.contentView = NSHostingView(
                rootView: MainWindowView(controller: AppShared.controller, state: state))
            if !window.setFrameAutosaveName("MurmurMainWindow") || window.frame.origin == .zero {
                window.center()
            }
            self.window = window
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        // Back to a pure menu-bar app when the dashboard closes.
        NSApp.setActivationPolicy(.accessory)
    }
}
