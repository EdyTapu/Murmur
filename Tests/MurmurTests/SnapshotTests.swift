import AppKit
import SwiftUI
import Testing

@testable import Murmur

/// Renders the app's views to PNG files so the UI can be inspected without
/// screen recording. Does nothing unless MURMUR_SNAPSHOT_DIR is set:
///   MURMUR_SNAPSHOT_DIR=/tmp/shots swift test --filter Snapshot
@Suite struct SnapshotTests {
    @MainActor private func render(_ view: some View, size: NSSize, dark: Bool = true, to name: String, in dir: String) throws {
        let host = NSHostingView(
            rootView: view.frame(width: size.width, height: size.height)
                .background(Color(nsColor: .windowBackgroundColor))
                .environment(\.colorScheme, dark ? .dark : .light))
        host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        // Let SwiftUI settle (onAppear, lazy grids) before capturing.
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: rep)
        try rep.representation(using: .png, properties: [:])?
            .write(to: URL(fileURLWithPath: dir).appendingPathComponent(name + ".png"))
    }

    @MainActor @Test func renderEverything() throws {
        guard let dir = ProcessInfo.processInfo.environment["MURMUR_SNAPSHOT_DIR"] else { return }
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)

        // The dictation bar in each state, on a desktop-like backdrop.
        let states: [(String, HUDPhase, String, Float)] = [
            ("bar-idle", .hidden, "", 0),
            ("bar-listening", .recording(handsFree: false), "", 0.5),
            ("bar-command", .recording(handsFree: false), "", 0.5),
            ("bar-words", .recording(handsFree: false), "Push, commit it, and put it on edytapu.dev", 0.8),
            ("bar-long", .recording(handsFree: true), "I need three things from the store today and I also want to remember to call the dentist before five", 0.6),
            ("bar-transcribing", .transcribing, "and put it on edytapu.dev", 0),
            ("bar-polishing", .polishing, "", 0),
            ("bar-done", .result(success: true, message: "Push, commit it, and put it on edytapu.dev"), "", 0),
            ("bar-failed", .result(success: false, message: "Couldn't insert - copied to clipboard"), "", 0),
        ]
        for (name, phase, text, level) in states {
            let model = HUDModel()
            model.phase = phase
            model.partialText = text
            model.level = level
            model.targetApp = "T3 Code"
            model.startedAt = Date().addingTimeInterval(-7)
            model.isCommand = name == "bar-command"
            let backdrop = LinearGradient(colors: [Color(red: 0.19, green: 0.25, blue: 0.42), Color(red: 0.08, green: 0.08, blue: 0.12)], startPoint: .top, endPoint: .bottom)
            try render(HUDView(model: model).background(backdrop), size: HUDController.activeSize, to: name, in: dir)
        }

        // Dashboard pages, backed by throwaway stores.
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        let controller = AppController()
        let state = MainWindowState()
        for section in MainSection.allCases {
            state.section = section
            try render(
                MainWindowView(controller: controller, state: state), size: NSSize(width: 980, height: 700),
                to: "page-" + section.rawValue, in: dir)
        }
    }
}
