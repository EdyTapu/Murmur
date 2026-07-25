import SwiftUI

struct MenuContent: View {
    @ObservedObject var controller: AppController

    var body: some View {
        Group {
            statusSection
            Divider()
            Button(handsFreeTitle) {
                controller.toggleHandsFree()
            }
            .disabled(!controller.isReady && !isRecording)
            Divider()
            Button(gazeTitle) {
                controller.gaze.toggle()
            }
            Button("Recenter Head Control") {
                controller.gaze.recenter()
            }
            .disabled(controller.gaze.state == .off)
            Divider()
            Button("Open Murmur") {
                AppShared.mainWindow.show()
            }
            Button("History…") {
                AppShared.mainWindow.show(section: .history)
            }
            Button("Settings…") {
                AppShared.mainWindow.show(section: .settings)
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

    private var gazeTitle: String {
        controller.gaze.state == .off
            ? "Start Eye Control (⌃⌥E)" : "Stop Eye Control (⌃⌥E)"
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
