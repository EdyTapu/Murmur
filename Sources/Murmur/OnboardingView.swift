import SwiftUI

struct OnboardingView: View {
    @ObservedObject var controller: AppController

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Murmur").font(.system(size: 28, weight: .bold, design: .rounded))
                Text("Hold a key. Speak. Polished text lands wherever your cursor is - all on-device.")
                    .foregroundStyle(.secondary)
            }

            GroupBox("Permissions") {
                VStack(alignment: .leading, spacing: 12) {
                    PermissionRow(
                        title: "Microphone",
                        detail: "Needed to hear you. Audio never leaves this Mac. If no prompt appears, click the circle to continue - dictation still works.",
                        granted: controller.micGranted,
                        action: { controller.requestMicAccess() },
                        onToggleCircle: { controller.assumeMicGranted() }
                    )
                    PermissionRow(
                        title: "Accessibility",
                        detail: "Needed to watch the hotkey and type into other apps.",
                        granted: controller.axTrusted,
                        action: { controller.requestAXTrust() }
                    )
                }
                .padding(6)
            }

            GroupBox("Speech model") {
                HStack {
                    modelStatus
                    Spacer()
                }
                .padding(6)
            }

            GroupBox("How to dictate") {
                VStack(alignment: .leading, spacing: 6) {
                    Label("Hold \(Prefs.hotkey.label) and speak, release to insert", systemImage: "hand.point.up.left")
                    Label("Quick-tap \(Prefs.hotkey.label) for hands-free; tap again to stop", systemImage: "hands.and.sparkles")
                    Label("Say \u{201C}scratch that\u{201D} to cancel a dictation", systemImage: "arrow.uturn.backward")
                }
                .padding(6)
            }

            Text("Tip: set System Settings → Keyboard → \u{201C}Press 🌐 key to\u{201D} → \u{201C}Do Nothing\u{201D} so the fn key is free for Murmur.")
                .font(.caption)
                .foregroundStyle(.secondary)

            if !controller.axTrusted {
                Text("Accessibility is required for the hotkey and typing. Grant it above, then this closes.")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            HStack {
                Spacer()
                Button("Done") {
                    UserDefaults.standard.set(true, forKey: PrefKey.onboardingDone)
                    AppShared.onboarding.close()
                }
                .keyboardShortcut(.defaultAction)
                // Only Accessibility is truly required to gate on; the mic grant
                // can read as "inherited" during development, so don't block on it.
                .disabled(!controller.axTrusted)
            }
        }
        .padding(24)
        .frame(width: 480)
    }

    @ViewBuilder
    private var modelStatus: some View {
        switch controller.asrState {
        case .notLoaded:
            Label("Waiting to load", systemImage: "clock")
        case .downloading(let fraction):
            VStack(alignment: .leading, spacing: 6) {
                Label("Downloading Parakeet (~600 MB, one time)…", systemImage: "arrow.down.circle")
                ProgressView(value: fraction)
            }
        case .loading:
            Label("Loading and warming up…", systemImage: "gearshape.2")
        case .ready:
            Label("Ready - Parakeet Unified 0.6B on the Neural Engine", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .failed(let message):
            Label("Failed: \(message)", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
        }
    }
}

struct PermissionRow: View {
    let title: String
    let detail: String
    let granted: Bool
    let action: () -> Void
    var onToggleCircle: (() -> Void)? = nil

    var body: some View {
        HStack(alignment: .top) {
            Image(systemName: granted ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(granted ? .green : .secondary)
                .font(.title3)
                .contentShape(Circle())
                .onTapGesture { onToggleCircle?() }
                .help(onToggleCircle == nil ? "" : "Click to mark as enabled")
            VStack(alignment: .leading, spacing: 2) {
                Text(title).fontWeight(.semibold)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if !granted {
                Button("Grant…", action: action)
            }
        }
    }
}
