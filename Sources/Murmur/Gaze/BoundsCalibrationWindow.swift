import AppKit
import SwiftUI

/// One step of the dot-free range calibration: face the centre, then point
/// the face at each screen edge. Every capture is dwell-based - hold the
/// pose ~0.7s and it advances automatically. No blinking required.
enum BoundsStep: Int, CaseIterable {
    case center
    case left
    case right
    case top
    case bottom

    var instruction: String {
        switch self {
        case .center: return "Face the centre of the screen"
        case .left: return "Point your face at the LEFT edge"
        case .right: return "Point your face at the RIGHT edge"
        case .top: return "Point your face at the TOP edge"
        case .bottom: return "Point your face at the BOTTOM edge"
        }
    }

    var symbol: String {
        switch self {
        case .center: return "target"
        case .left: return "arrow.left"
        case .right: return "arrow.right"
        case .top: return "arrow.up"
        case .bottom: return "arrow.down"
        }
    }

    var edgeAlignment: Alignment? {
        switch self {
        case .center: return nil
        case .left: return .leading
        case .right: return .trailing
        case .top: return .top
        case .bottom: return .bottom
        }
    }
}

@MainActor
final class BoundsCalibrationModel: ObservableObject {
    @Published var step: BoundsStep = .center
    /// 0...1 dwell fill while the pose is held steady.
    @Published var progress: Double = 0
    @Published var faceVisible = false
}

/// Translucent full-screen overlay driving the range calibration. The panel
/// is non-activating so the frontmost app keeps focus; ⌃⌥E or the Cancel
/// button aborts.
@MainActor
final class BoundsCalibrationWindowController {
    private var panel: NSPanel?

    func show(on screen: NSScreen, model: BoundsCalibrationModel, onCancel: @escaping () -> Void) {
        close()
        let panel = NSPanel(
            contentRect: screen.frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .screenSaver
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = NSHostingView(
            rootView: BoundsCalibrationView(model: model, onCancel: onCancel))
        panel.setFrame(screen.frame, display: true)
        panel.orderFrontRegardless()
        self.panel = panel
    }

    func close() {
        panel?.orderOut(nil)
        panel = nil
    }
}

struct BoundsCalibrationView: View {
    @ObservedObject var model: BoundsCalibrationModel
    let onCancel: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.55)

            // Highlight the edge being captured.
            if let alignment = model.step.edgeAlignment {
                edgeBar(alignment)
            }

            VStack(spacing: 18) {
                Image(systemName: model.step.symbol)
                    .font(.system(size: 54, weight: .bold))
                    .foregroundStyle(Color.accentColor)
                Text(model.step.instruction)
                    .font(.system(size: 30, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                Text(model.faceVisible
                    ? "Hold still - it captures automatically"
                    : "Face the camera…")
                    .font(.title3)
                    .foregroundStyle(.white.opacity(0.7))
                ProgressView(value: model.progress)
                    .frame(width: 260)
                    .tint(Color.accentColor)
                Button("Cancel (⌃⌥E)") { onCancel() }
                    .buttonStyle(.bordered)
                    .padding(.top, 8)
            }
        }
        .ignoresSafeArea()
    }

    private func edgeBar(_ alignment: Alignment) -> some View {
        let horizontal = alignment == .leading || alignment == .trailing
        return Rectangle()
            .fill(Color.accentColor.opacity(0.85))
            .frame(
                width: horizontal ? 10 : nil,
                height: horizontal ? nil : 10)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: alignment)
    }
}
