import AppKit
import SwiftUI

enum HUDPhase: Equatable {
    case hidden
    case recording(handsFree: Bool)
    case transcribing
    case polishing
    case result(success: Bool, message: String)
}

@MainActor
final class HUDModel: ObservableObject {
    @Published var phase: HUDPhase = .hidden
    @Published var partialText: String = ""
    @Published var level: Float = 0
}

/// Floating, non-activating pill near the bottom of the screen -
/// shows recording state, live mic level, and streaming partial text.
@MainActor
final class HUDController {
    let model = HUDModel()
    private var panel: NSPanel?
    private var hideTask: Task<Void, Never>?

    private func ensurePanel() -> NSPanel {
        if let panel { return panel }
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 76),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.contentView = NSHostingView(rootView: HUDView(model: model))
        self.panel = panel
        return panel
    }

    func show(_ phase: HUDPhase) {
        hideTask?.cancel()
        model.phase = phase
        if case .recording = phase {
            model.partialText = ""
            model.level = 0
        }
        let panel = ensurePanel()
        position(panel)
        panel.orderFrontRegardless()
    }

    func showResult(success: Bool, message: String, autoHideAfter seconds: Double = 1.4) {
        model.phase = .result(success: success, message: message)
        let panel = ensurePanel()
        position(panel)
        panel.orderFrontRegardless()
        hideTask?.cancel()
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            self?.hide()
        }
    }

    func hide() {
        hideTask?.cancel()
        model.phase = .hidden
        model.partialText = ""
        panel?.orderOut(nil)
    }

    private func position(_ panel: NSPanel) {
        let screen = screenWithMouse() ?? NSScreen.main
        guard let screen else { return }
        let frame = screen.visibleFrame
        let size = panel.frame.size
        let origin = NSPoint(
            x: frame.midX - size.width / 2,
            y: frame.minY + 28
        )
        panel.setFrameOrigin(origin)
    }

    private func screenWithMouse() -> NSScreen? {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
    }
}

struct HUDView: View {
    @ObservedObject var model: HUDModel

    var body: some View {
        VStack {
            Spacer(minLength: 0)
            content
                .padding(.horizontal, 18)
                .padding(.vertical, 10)
                .background(.ultraThinMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(.white.opacity(0.12)))
                .shadow(color: .black.opacity(0.35), radius: 12, y: 4)
                .padding(.bottom, 4)
        }
        .frame(maxWidth: .infinity)
        .animation(.easeInOut(duration: 0.15), value: model.phase)
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .hidden:
            EmptyView()
        case .recording(let handsFree):
            HStack(spacing: 10) {
                LevelBars(level: model.level)
                if model.partialText.isEmpty {
                    Text(handsFree ? "Listening (hands-free)…" : "Listening…")
                        .foregroundStyle(.secondary)
                } else {
                    Text(model.partialText)
                        .lineLimit(1)
                        .truncationMode(.head)
                        .frame(maxWidth: 400, alignment: .trailing)
                }
            }
            .font(.system(size: 14, weight: .medium, design: .rounded))
        case .transcribing:
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text(model.partialText.isEmpty ? "Transcribing…" : model.partialText)
                    .lineLimit(1)
                    .truncationMode(.head)
                    .frame(maxWidth: 400, alignment: .trailing)
                    .foregroundStyle(.secondary)
            }
            .font(.system(size: 14, weight: .medium, design: .rounded))
        case .polishing:
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text("Polishing…").foregroundStyle(.secondary)
            }
            .font(.system(size: 14, weight: .medium, design: .rounded))
        case .result(let success, let message):
            HStack(spacing: 8) {
                Image(systemName: success ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(success ? .green : .orange)
                Text(message)
                    .lineLimit(1)
            }
            .font(.system(size: 14, weight: .medium, design: .rounded))
        }
    }
}

/// Simple animated mic-level indicator.
struct LevelBars: View {
    var level: Float

    var body: some View {
        HStack(spacing: 2.5) {
            ForEach(0..<5, id: \.self) { index in
                Capsule()
                    .fill(Color.red)
                    .frame(width: 3.5, height: barHeight(index))
            }
        }
        .frame(height: 20)
        .animation(.linear(duration: 0.08), value: level)
    }

    private func barHeight(_ index: Int) -> CGFloat {
        let weights: [Float] = [0.5, 0.8, 1.0, 0.8, 0.5]
        let h = CGFloat(max(0.12, min(1, level)) * weights[index]) * 20
        return max(4, h)
    }
}
