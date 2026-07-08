import AppKit
import SwiftUI

@main
struct MurmurApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var controller = AppShared.controller

    var body: some Scene {
        MenuBarExtra {
            MenuContent(controller: controller)
        } label: {
            Image(systemName: menuIcon)
        }

        Window("Murmur History", id: "history") {
            HistoryWindowView(controller: controller)
        }
        .defaultSize(width: 620, height: 500)

        Settings {
            SettingsView(controller: controller)
        }
    }

    private var menuIcon: String {
        switch controller.state {
        case .idle:
            return controller.isReady ? "waveform" : "waveform.slash"
        case .recording:
            return "waveform.badge.mic"
        case .finishing:
            return "waveform.badge.magnifyingglass"
        }
    }
}

/// Shared instances reachable from both the App struct and the AppDelegate.
@MainActor
enum AppShared {
    static let controller = AppController()
    static let onboarding = OnboardingWindowController()
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSLog("Murmur: applicationDidFinishLaunching")
        Task { @MainActor in
            let controller = AppShared.controller
            controller.start()
            NSLog(
                "Murmur: started (mic=%d ax=%d)", controller.micGranted ? 1 : 0,
                controller.axTrusted ? 1 : 0)
            let needsOnboarding =
                !UserDefaults.standard.bool(forKey: PrefKey.onboardingDone)
                || !controller.micGranted || !controller.axTrusted
            if needsOnboarding {
                AppShared.onboarding.show(controller: controller)
                NSLog("Murmur: onboarding window shown")
            }
        }
    }
}

/// Plain AppKit window for onboarding - menu-bar apps can't reliably open
/// SwiftUI Window scenes from the app delegate at launch.
@MainActor
final class OnboardingWindowController {
    private var window: NSWindow?

    func show(controller: AppController) {
        if let window {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 560),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Welcome to Murmur"
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: OnboardingView(controller: controller))
        window.center()
        self.window = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func close() {
        window?.close()
    }
}
