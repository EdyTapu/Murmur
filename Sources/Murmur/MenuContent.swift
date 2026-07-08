import SwiftUI

struct MenuContent: View {
    @ObservedObject var controller: AppController
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Group {
            statusSection
            Divider()
            Button(handsFreeTitle) {
                controller.toggleHandsFree()
            }
            .disabled(!controller.isReady && !isRecording)
            Divider()
            Button("History…") {
                openWindow(id: "history")
                NSApp.activate(ignoringOtherApps: true)
            }
            Button("Settings…") {
                openSettings()
                NSApp.activate(ignoringOtherApps: true)
            }
            Button("Setup Guide…") {
                AppShared.onboarding.show(controller: controller)
            }
            Divider()
            Button("Quit Murmur") {
                NSApp.terminate(nil)
            }
        }
    }

    private var isRecording: Bool {
        if case .recording = controller.state { return true }
        return false
    }

    private var handsFreeTitle: String {
        isRecording ? "Stop Dictation" : "Start Hands-Free Dictation"
    }

    @ViewBuilder
    private var statusSection: some View {
        switch controller.asrState {
        case .notLoaded, .loading:
            Text("Loading speech model…")
        case .downloading(let fraction):
            Text("Downloading speech model… \(Int(fraction * 100))%")
        case .failed(let message):
            Text("Model error: \(message)").foregroundStyle(.red)
        case .ready:
            if !controller.micGranted {
                Text("⚠️ Microphone access needed")
            } else if !controller.axTrusted {
                Text("⚠️ Accessibility access needed")
            } else {
                Text("Hold \(Prefs.hotkey.label) and speak · tap for hands-free")
            }
        }
    }
}
