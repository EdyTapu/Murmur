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
    /// Command Mode: the speech is an instruction rather than text to type.
    @Published var isCommand = false
    /// The app the text will be inserted into.
    @Published var targetApp: String?
    @Published var startedAt = Date()
}

/// The Flow Bar: a small black pill that floats above every app. A thin line
/// while idle (when "always visible" is on), it opens into an island while
/// dictating: the words being written on top, and below them the timer, the
/// waveform (centred) and the app the text is going to.
@MainActor
final class HUDController {
    let model = HUDModel()
    /// Clicking the idle pill starts hands-free dictation.
    var onClick: (() -> Void)?

    private var panel: NSPanel?
    private var hideTask: Task<Void, Never>?
    /// Where the mouse and the panel were when the current drag began.
    private var dragStart: (mouse: NSPoint, origin: NSPoint)?

    private static let idleSize = NSSize(width: 64, height: 26)
    static let activeSize = NSSize(width: 340, height: 116)

    private func ensurePanel() -> NSPanel {
        if let panel { return panel }
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: Self.idleSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.contentView = NSHostingView(
            rootView: HUDView(
                model: model,
                onClick: { [weak self] in self?.onClick?() },
                onDrag: { [weak self] ended in self?.drag(ended: ended) }))
        self.panel = panel
        return panel
    }

    /// Show the idle pill if the user wants the bar always visible. Call at launch
    /// and when that setting changes.
    func refreshIdle() {
        guard model.phase == .hidden else { return }
        if Prefs.flowBarAlwaysVisible {
            place(ensurePanel(), active: false)
            panel?.orderFrontRegardless()
        } else {
            panel?.orderOut(nil)
        }
    }

    func show(_ phase: HUDPhase) {
        hideTask?.cancel()
        var wasRecording = false
        if case .recording = model.phase { wasRecording = true }
        model.phase = phase
        if case .recording = phase, model.partialText.isEmpty || !wasRecording {
            model.partialText = ""
            model.level = 0
            model.startedAt = Date()
        }
        present()
    }

    func showResult(success: Bool, message: String, autoHideAfter seconds: Double = 1.4) {
        model.phase = .result(success: success, message: message)
        present()
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
        refreshIdle()
    }

    private func present() {
        let panel = ensurePanel()
        place(panel, active: true)
        panel.orderFrontRegardless()
    }

    // MARK: - Placement

    /// Centre of the pill's bottom edge. The user's dragged spot if there is
    /// one, otherwise bottom-centre of the screen the mouse is on.
    private func anchor() -> (point: NSPoint, screen: NSRect) {
        let mouse = NSEvent.mouseLocation
        let mouseScreen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        if let saved = Prefs.flowBarAnchor,
            let screen = NSScreen.screens.first(where: { NSMouseInRect(saved, $0.frame, false) }) {
            return (saved, screen.visibleFrame)
        }
        let frame = mouseScreen?.visibleFrame ?? .zero
        return (NSPoint(x: frame.midX, y: frame.minY + 22), frame)
    }

    private func place(_ panel: NSPanel, active: Bool) {
        let (point, screen) = anchor()
        let size = active ? Self.activeSize : Self.idleSize
        // Keep the whole bar on screen even when the pill sits at an edge.
        let x = min(max(point.x - size.width / 2, screen.minX), max(screen.minX, screen.maxX - size.width))
        let y = min(max(point.y, screen.minY), max(screen.minY, screen.maxY - size.height))
        panel.setFrame(NSRect(origin: NSPoint(x: x, y: y), size: size), display: true)
        // While dictating the bar is display-only, so it never blocks a click.
        panel.ignoresMouseEvents = active
    }

    /// The idle pill follows the mouse while dragged and remembers where it was dropped.
    /// Driven by the real mouse position: a gesture's own offsets jitter once the window moves.
    private func drag(ended: Bool) {
        guard let panel, model.phase == .hidden else { return }
        let mouse = NSEvent.mouseLocation
        let start = dragStart ?? (mouse, panel.frame.origin)
        dragStart = ended ? nil : start
        panel.setFrameOrigin(
            NSPoint(x: start.origin.x + mouse.x - start.mouse.x, y: start.origin.y + mouse.y - start.mouse.y))
        if ended {
            Prefs.setFlowBarAnchor(NSPoint(x: panel.frame.midX, y: panel.frame.minY))
            place(panel, active: false)  // back on screen if it was dropped past an edge
        }
    }
}

struct HUDView: View {
    @ObservedObject var model: HUDModel
    var onClick: () -> Void = {}
    /// Called while the idle pill is dragged; the argument is true when the drag ends.
    var onDrag: (Bool) -> Void = { _ in }

    private var idle: Bool { model.phase == .hidden }

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            Group {
                if idle {
                    Color.clear
                        .frame(width: 44, height: 9)
                } else {
                    island
                }
            }
            .background(
                RoundedRectangle(cornerRadius: idle ? 4.5 : 16)
                    .fill(.black.opacity(idle ? 0.78 : 1))
                    .shadow(color: .black.opacity(0.45), radius: 9, y: 3))
            .overlay(
                RoundedRectangle(cornerRadius: idle ? 4.5 : 16)
                    .strokeBorder(.white.opacity(0.16)))
            .padding(.bottom, 6)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // The whole idle window is the handle: the pill alone is too thin to grab.
        .contentShape(Rectangle())
        .onTapGesture { if idle { onClick() } }
        .gesture(
            DragGesture(minimumDistance: 3)
                .onChanged { _ in onDrag(false) }
                .onEnded { _ in onDrag(true) })
        .help(idle ? "Murmur is ready. Click for hands-free dictation, or drag to move." : "")
        .font(.system(size: 13, weight: .medium))
        .foregroundStyle(.white)
        .animation(.spring(response: 0.28, dampingFraction: 0.82), value: model.phase)
    }

    private var island: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !words.isEmpty {
                // Two lines that keep the newest words; older ones give way at the start.
                Text(words)
                    .lineLimit(2)
                    .truncationMode(.head)
                    .lineSpacing(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            // Equal flexible sides keep the waveform at the true centre.
            HStack(spacing: 8) {
                HStack(spacing: 0) { timer; Spacer(minLength: 0) }.frame(maxWidth: .infinity)
                indicator
                HStack(spacing: 0) { Spacer(minLength: 0); destination }.frame(maxWidth: .infinity)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(width: 300)
    }

    /// The text on top: words as they are recognized, or the outcome.
    private var words: String {
        if case .result(_, let message) = model.phase { return message }
        if model.partialText.isEmpty, model.isCommand, case .recording = model.phase { return "Say a command…" }
        return model.partialText
    }

    @ViewBuilder
    private var indicator: some View {
        switch model.phase {
        case .recording: LevelBars(level: model.level)
        case .transcribing: PulsingDots()
        case .polishing:
            HStack(spacing: 6) {
                Image(systemName: "sparkles").font(.system(size: 11, weight: .semibold))
                PulsingDots()
            }
        case .result(let success, _):
            Image(systemName: success ? "checkmark" : "exclamationmark.triangle.fill")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(success ? .green : .orange)
                .frame(height: 18)
        case .hidden: EmptyView()
        }
    }

    @ViewBuilder
    private var timer: some View {
        if case .recording = model.phase {
            TimelineView(.periodic(from: model.startedAt, by: 1)) { context in
                let seconds = max(0, Int(context.date.timeIntervalSince(model.startedAt)))
                Text(String(format: "%d:%02d", seconds / 60, seconds % 60))
                    .font(.system(size: 11, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(.white.opacity(0.55))
            }
        }
    }

    /// Where the text is going.
    @ViewBuilder
    private var destination: some View {
        if let app = model.targetApp, model.phase != .hidden {
            if case .result = model.phase {
            } else {
                Text(app)
                    .font(.system(size: 10.5, weight: .medium))
                    .lineLimit(1)
                    .foregroundStyle(.white.opacity(0.7))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(.white.opacity(0.13), in: Capsule())
            }
        }
    }
}

/// Live mic-level waveform.
struct LevelBars: View {
    var level: Float

    var body: some View {
        HStack(spacing: 2.5) {
            ForEach(0..<5, id: \.self) { index in
                Capsule()
                    .fill(.white)
                    .frame(width: 3, height: barHeight(index))
            }
        }
        .frame(height: 18)
        .animation(.linear(duration: 0.08), value: level)
    }

    private func barHeight(_ index: Int) -> CGFloat {
        let weights: [Float] = [0.5, 0.8, 1.0, 0.8, 0.5]
        let h = CGFloat(max(0.12, min(1, level)) * weights[index]) * 18
        return max(4, h)
    }
}

/// Three dots that pulse in turn while Murmur is working.
struct PulsingDots: View {
    @State private var on = false

    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<3, id: \.self) { index in
                Circle()
                    .fill(.white)
                    .frame(width: 5, height: 5)
                    .opacity(on ? 1 : 0.3)
                    .animation(.easeInOut(duration: 0.5).repeatForever().delay(Double(index) * 0.16), value: on)
            }
        }
        .frame(height: 18)
        .onAppear { on = true }
    }
}
