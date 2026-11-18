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
    static let mainWindow = MainWindowController()
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var terminationSignal: DispatchSourceSignal?

    func applicationWillTerminate(_ notification: Notification) {
        AppShared.controller.prepareToQuit()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSLog("Murmur: applicationDidFinishLaunching")
        // `pkill Murmur` (what app/launch.sh does) sends SIGTERM, which skips
        // applicationWillTerminate; route it through a normal quit instead.
        signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        source.setEventHandler { NSApp.terminate(nil) }
        source.resume()
        terminationSignal = source
        // Must be read synchronously - the current Apple event is only valid
        // while it is being handled.
        let launchedAtLogin = Self.launchedAsLogInItem
        let controller = AppShared.controller
        controller.start()
        NSLog(
            "Murmur: started (mic=%d ax=%d)", controller.micGranted ? 1 : 0,
            controller.axTrusted ? 1 : 0)
        if needsOnboarding {
            if UserDefaults.standard.bool(forKey: PrefKey.onboardingDone) {
                // Onboarding was completed before, so a missing permission here
                // is usually a transient early-login TCC misread. The 2s
                // permission poll in AppController corrects it; only nag if
                // the permission is still missing after a grace period.
                NSLog("Murmur: permissions read missing at launch; deferring onboarding")
                Task { @MainActor in
                    for _ in 0..<15 {
                        try? await Task.sleep(for: .seconds(2))
                        if !self.needsOnboarding {
                            NSLog("Murmur: permissions recovered; onboarding skipped")
                            return
                        }
                    }
                    AppShared.onboarding.show(controller: AppShared.controller)
                    NSLog("Murmur: onboarding window shown after grace period")
                }
            } else {
                AppShared.onboarding.show(controller: controller)
                NSLog("Murmur: onboarding window shown")
            }
        } else if !launchedAtLogin {
            AppShared.mainWindow.show()
        }
    }

    /// Double-clicking Murmur.app while it is already running lands here:
    /// open the dashboard (Wispr-Flow style) instead of doing nothing.
    func applicationShouldHandleReopen(
        _ sender: NSApplication, hasVisibleWindows flag: Bool
    ) -> Bool {
        if needsOnboarding {
            AppShared.onboarding.show(controller: AppShared.controller)
        } else {
            AppShared.mainWindow.show()
        }
        return false
    }

    private var needsOnboarding: Bool {
        let controller = AppShared.controller
        return !UserDefaults.standard.bool(forKey: PrefKey.onboardingDone)
            || !controller.micGranted || !controller.axTrusted
    }

    /// True when this launch came from a login item, so the dashboard stays
    /// closed and the app starts as a quiet menu-bar item.
    private static var launchedAsLogInItem: Bool {
        guard let event = NSAppleEventManager.shared().currentAppleEvent else { return false }
        // 'oapp' open-application event carrying propData 'prdt' == 'lgit'.
        return event.eventID == AEEventID(0x6F61_7070)
            && event.paramDescriptor(forKeyword: AEKeyword(0x7072_6474))?.enumCodeValue
                == OSType(0x6C67_6974)
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
