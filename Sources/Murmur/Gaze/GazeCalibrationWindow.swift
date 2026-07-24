import AppKit
import SwiftUI

/// Live model the calibration overlay renders from; the GazeController
/// drives it as samples come in.
@MainActor
final class GazeCalibrationModel: ObservableObject {
    /// Normalized (0...1, origin top-left) positions of the 9 targets.
    static let points: [CGPoint] = {
        let coords: [CGFloat] = [0.06, 0.5, 0.94]
        var pts: [CGPoint] = []
        for y in coords { for x in coords { pts.append(CGPoint(x: x, y: y)) } }
        return pts
    }()

    @Published var pointIndex = 0
    @Published var progress: Double = 0
    @Published var faceVisible = true
    /// Enough gaze samples buffered - waiting for the user's deliberate
    /// blink to capture this point.
    @Published var awaitingBlink = false

    var currentPoint: CGPoint { Self.points[min(pointIndex, Self.points.count - 1)] }
}

/// Fullscreen borderless overlay that shows the calibration dots.
@MainActor
final class GazeCalibrationWindowController {
    private var window: NSWindow?
    private var escMonitor: Any?

    func show(on screen: NSScreen, model: GazeCalibrationModel, onCancel: @escaping () -> Void) {
        let window = NSWindow(
            contentRect: screen.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false,
            screen: screen
        )
        window.level = .screenSaver
        window.isOpaque = false
        window.backgroundColor = .clear
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: GazeCalibrationView(model: model))
        window.setFrame(screen.frame, display: true)
        self.window = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)

        escMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 {  // esc
                onCancel()
                return nil
            }
            return event
        }
    }

    func close() {
        if let escMonitor {
            NSEvent.removeMonitor(escMonitor)
            self.escMonitor = nil
        }
        window?.orderOut(nil)
        window = nil
    }
}

struct GazeCalibrationView: View {
    @ObservedObject var model: GazeCalibrationModel

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.black.opacity(0.88)

                VStack(spacing: 8) {
                    Text("Look at the dot, then blink to capture it")
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(.white)
                    Text(hint)
                        .font(.callout)
                        .foregroundStyle(hintColor)
                    Text("Point \(model.pointIndex + 1) of \(GazeCalibrationModel.points.count) · take your time · esc to cancel")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                calibrationDot
                    .position(
                        x: model.currentPoint.x * geo.size.width,
                        y: model.currentPoint.y * geo.size.height)
                    .animation(.easeInOut(duration: 0.45), value: model.pointIndex)
            }
            .ignoresSafeArea()
        }
    }

    private var hint: String {
        if !model.faceVisible {
            return "Can't see your eyes - check lighting and face the camera"
        }
        if model.awaitingBlink {
            return "Blink to capture this dot"
        }
        return "Keep looking at the dot…"
    }

    private var hintColor: Color {
        if !model.faceVisible { return .orange }
        if model.awaitingBlink { return .green }
        return .secondary
    }

    private var calibrationDot: some View {
        ZStack {
            Circle()
                .stroke(Color.white.opacity(0.25), lineWidth: 4)
                .frame(width: 44, height: 44)
            Circle()
                .trim(from: 0, to: model.progress)
                .stroke(
                    model.awaitingBlink ? Color.green : Color.accentColor,
                    style: StrokeStyle(lineWidth: 4, lineCap: .round))
                .frame(width: 44, height: 44)
                .rotationEffect(.degrees(-90))
            Circle()
                .fill(model.awaitingBlink ? Color.green : Color.white)
                .frame(width: 14, height: 14)
        }
    }
}
