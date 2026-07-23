import AppKit
import AVFoundation
import Foundation
import os

enum DictationState: Equatable {
    case idle
    case recording(handsFree: Bool)
    case finishing
}

/// Central coordinator: hotkey → record → transcribe → clean → insert → history.
@MainActor
final class AppController: ObservableObject {
    private let log = Logger(subsystem: "com.alessio.murmur", category: "app")

    @Published private(set) var state: DictationState = .idle
    @Published private(set) var asrState: TranscriberState = .notLoaded
    @Published private(set) var micGranted = false
    @Published private(set) var axTrusted = false

    let history = HistoryStore()
    let dictionary = DictionaryStore()
    let hud = HUDController()
    let gaze = GazeController()

    private let recorder = AudioRecorder()
    private let transcriber = Transcriber()
    private let hotkey = HotkeyMonitor()
    private let insertion = InsertionEngine()

    private var keyDownAt: Date?
    private var partialsTask: Task<Void, Never>?
    private var silenceTask: Task<Void, Never>?
    private var permissionPollTask: Task<Void, Never>?
    private var capturedContext: TargetContext?

    /// Hold shorter than this = "tap" → hands-free; longer = push-to-talk.
    private let tapThreshold: TimeInterval = 0.35
    /// Hard cap on a single dictation session.
    private let maxSessionSeconds: TimeInterval = 600

    var isReady: Bool { micGranted && axTrusted && asrState == .ready }

    // MARK: - Startup

    func start() {
        axTrusted = AXIsProcessTrusted()
        let rawStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        log.info("Launch: mic authorizationStatus=\(rawStatus.rawValue, privacy: .public), axTrusted=\(self.axTrusted, privacy: .public)")
        refreshMicStatus()
        if micGranted {
            Task { await recorder.warmUp() }
        }

        recorder.onLevel = { [weak self] level in
            MainActor.assumeIsolated {
                self?.hud.model.level = level
            }
        }

        hotkey.onKeyDown = { [weak self] in self?.hotkeyDown() }
        hotkey.onKeyUp = { [weak self] in self?.hotkeyUp() }
        hotkey.start(choice: Prefs.hotkey)

        gaze.toast = { [weak self] success, message in
            self?.hud.showResult(success: success, message: message)
        }
        gaze.registerHotkey()

        // Proactively fire the mic prompt on first launch so the system dialog
        // appears (and the app registers in the Microphone privacy list) without
        // the user having to find a button.
        if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
                Task { @MainActor in
                    self?.micGranted = granted
                    if granted { await self?.recorder.warmUp() }
                }
            }
        }

        Task { await self.loadModels() }
        pollPermissionsUntilGranted()
    }

    func restartHotkey() {
        hotkey.start(choice: Prefs.hotkey)
    }

    private func loadModels() async {
        await transcriber.load { [weak self] newState in
            Task { @MainActor in
                self?.asrState = newState
            }
        }
    }

    // MARK: - Permissions

    /// Set when the user clicks the mic circle to say "trust me, it works" -
    /// keeps the 2s status poll from flipping the UI back to ungranted.
    private var micAssumedGranted = false

    func refreshMicStatus() {
        if micAssumedGranted {
            micGranted = true
            return
        }
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        micGranted = status == .authorized
    }

    /// User override: mark the mic as granted and warm the engine.
    /// The real OS grant may be inherited (dev launch), so this just unblocks the UI.
    func assumeMicGranted() {
        micAssumedGranted = true
        micGranted = true
        Task { await recorder.warmUp() }
    }

    func requestMicAccess() {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        // The system prompt only appears from `.notDetermined`. In any other
        // state (previously denied, or reset races) send the user straight to
        // the Microphone pane so the button is never a no-op.
        guard status == .notDetermined else {
            openPrivacyPane("Privacy_Microphone")
            return
        }
        AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
            Task { @MainActor in
                self?.micGranted = granted
                if granted {
                    await self?.recorder.warmUp()
                } else {
                    self?.openPrivacyPane("Privacy_Microphone")
                }
            }
        }
    }

    func requestAXTrust() {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        axTrusted = AXIsProcessTrustedWithOptions(options)
        if !axTrusted {
            openPrivacyPane("Privacy_Accessibility")
        }
    }

    func openPrivacyPane(_ anchor: String) {
        if let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Permissions granted in System Settings don't notify us; poll briefly.
    private func pollPermissionsUntilGranted() {
        permissionPollTask?.cancel()
        permissionPollTask = Task { [weak self] in
            for _ in 0..<600 {
                try? await Task.sleep(for: .seconds(2))
                guard let self, !Task.isCancelled else { return }
                let wasGranted = self.micGranted
                self.axTrusted = AXIsProcessTrusted()
                self.refreshMicStatus()
                if self.micGranted, !wasGranted {
                    await self.recorder.warmUp()
                }
                if self.micGranted, self.axTrusted { return }
            }
        }
    }

    // MARK: - Hotkey handling

    private func hotkeyDown() {
        switch state {
        case .idle:
            keyDownAt = Date()
            beginRecording(handsFree: false)
        case .recording(handsFree: true):
            // Press while hands-free = stop.
            keyDownAt = nil
            finishRecording()
        case .recording(handsFree: false), .finishing:
            break
        }
    }

    private func hotkeyUp() {
        guard case .recording(handsFree: false) = state, let downAt = keyDownAt else { return }
        let heldFor = Date().timeIntervalSince(downAt)
        keyDownAt = nil
        if heldFor < tapThreshold {
            // Quick tap → switch to hands-free; stops on next press or silence.
            state = .recording(handsFree: true)
            hud.show(.recording(handsFree: true))
        } else {
            finishRecording()
        }
    }

    // MARK: - Recording

    func toggleHandsFree() {
        switch state {
        case .idle:
            beginRecording(handsFree: true)
        case .recording:
            finishRecording()
        case .finishing:
            break
        }
    }

    private func beginRecording(handsFree: Bool) {
        guard micGranted else {
            hud.showResult(success: false, message: "Grant microphone access in Murmur settings")
            return
        }
        guard asrState == .ready else {
            hud.showResult(success: false, message: modelNotReadyMessage)
            return
        }

        capturedContext = insertion.captureContext()
        // The engine restart (if paused) happens off-main inside the recorder;
        // failure is rare and surfaces here asynchronously.
        recorder.startCollecting(onEngineFailure: { [weak self] in
            Task { @MainActor in
                guard let self, case .recording = self.state else { return }
                self.cancelRecording()
                self.hud.showResult(success: false, message: "Couldn't start the microphone")
            }
        })

        state = .recording(handsFree: handsFree)
        hud.show(.recording(handsFree: handsFree))
        playSound("Tink")
        startPartialsLoop()
        startSilenceWatch()
    }

    private var modelNotReadyMessage: String {
        switch asrState {
        case .downloading(let fraction):
            return "Downloading speech model… \(Int(fraction * 100))%"
        case .loading:
            return "Loading speech model…"
        case .failed:
            return "Speech model failed to load - see settings"
        default:
            return "Speech model not ready yet"
        }
    }

    private func finishRecording() {
        guard case .recording = state else { return }
        state = .finishing
        partialsTask?.cancel()
        silenceTask?.cancel()
        hud.show(.transcribing)

        let samples = recorder.stopCollecting()
        let context = capturedContext ?? insertion.captureContext()
        capturedContext = nil

        Task { [weak self] in
            await self?.processDictation(samples: samples, context: context)
        }
    }

    private func cancelRecording() {
        partialsTask?.cancel()
        silenceTask?.cancel()
        _ = recorder.stopCollecting()
        capturedContext = nil
        state = .idle
        hud.hide()
    }

    // MARK: - Live partials

    private func startPartialsLoop() {
        partialsTask?.cancel()
        partialsTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(700))
                guard let self, !Task.isCancelled else { return }
                guard case .recording = self.state else { return }
                let duration = self.recorder.capturedDuration
                guard duration > 0.6, duration < 120 else { continue }
                let snapshot = self.recorder.snapshot()
                guard !snapshot.isEmpty else { continue }
                let text = (try? await self.transcriber.transcribe(snapshot)) ?? ""
                guard case .recording = self.state, !text.isEmpty else { continue }
                self.hud.model.partialText = text
            }
        }
    }

    // MARK: - Hands-free silence auto-stop

    private func startSilenceWatch() {
        silenceTask?.cancel()
        silenceTask = Task { [weak self] in
            let startedAt = Date()
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                guard let self, !Task.isCancelled else { return }
                guard case .recording(let handsFree) = self.state else { return }
                if Date().timeIntervalSince(startedAt) > self.maxSessionSeconds {
                    self.finishRecording()
                    return
                }
                if handsFree, Prefs.silenceAutoStop, self.recorder.hasDetectedVoice,
                    self.recorder.secondsSinceLastVoice > Prefs.silenceSeconds {
                    self.finishRecording()
                    return
                }
            }
        }
    }

    // MARK: - Pipeline

    private func processDictation(samples: [Float], context: TargetContext) async {
        defer { state = .idle }

        guard !samples.isEmpty else {
            hud.showResult(success: false, message: "Didn't catch that")
            return
        }
        let duration = Double(samples.count) / 16_000
        guard duration > 0.25 else {
            hud.hide()
            return
        }

        // If the buffer is essentially pure silence, recording ran but the mic
        // delivered nothing - almost always a missing real permission (e.g. the
        // onboarding was clicked through without the OS grant). Say so plainly
        // instead of the vague "didn't catch that".
        let peak = samples.reduce(Float(0)) { max($0, abs($1)) }
        let realStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        log.info("Dictation: \(duration, privacy: .public)s captured, peak=\(peak, privacy: .public), micStatus=\(realStatus.rawValue, privacy: .public)")
        if peak < 0.0005 {
            if realStatus != .authorized {
                hud.showResult(
                    success: false,
                    message: "No mic signal - grant Microphone in System Settings",
                    autoHideAfter: 3.0)
                openPrivacyPane("Privacy_Microphone")
            } else {
                hud.showResult(success: false, message: "No sound detected - check your mic input")
            }
            return
        }

        // 1. Transcribe.
        let raw: String
        do {
            raw = try await transcriber.transcribe(samples)
        } catch {
            hud.showResult(success: false, message: "Transcription failed")
            log.error("transcribe failed: \(error.localizedDescription, privacy: .public)")
            return
        }
        guard !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            hud.showResult(success: false, message: "Didn't catch that")
            return
        }

        // 2. Rules cleanup (fillers, commands) + dictionary + snippets.
        let rules = RulesCleaner.clean(raw, removeFillers: Prefs.fillerRemoval)
        if rules.cancelled {
            hud.showResult(success: true, message: "Scratched")
            return
        }
        var text = DictionaryStore.apply(
            rules.text, terms: dictionary.terms, snippets: dictionary.snippets)

        // 3. Optional on-device LLM polish with per-app tone.
        if Prefs.aiCleanup, LLMCleaner.isAvailable, !text.isEmpty {
            hud.show(.polishing)
            let tone = Prefs.tone(for: context.category)
            if let polished = await LLMCleaner.clean(text, tone: tone) {
                text = DictionaryStore.apply(
                    polished, terms: dictionary.terms, snippets: dictionary.snippets)
            }
        }

        if rules.trailingNewlines > 0 {
            text += String(repeating: "\n", count: rules.trailingNewlines)
        }

        guard !text.isEmpty else {
            hud.showResult(success: false, message: "Didn't catch that")
            return
        }

        // 4. Insert.
        let outcome = await insertion.insert(text, context: context)

        // 5. History - always.
        history.add(
            HistoryEntry(
                rawText: raw,
                finalText: text,
                appName: context.appName,
                appBundleID: context.appBundleID,
                outcome: outcome.historyLabel
            ))

        if outcome.success {
            playSound("Pop")
            hud.showResult(success: true, message: resultPreview(text))
        } else {
            // Nothing is ever lost: leave it on the clipboard too.
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            let reason = outcome.reason == "secure-input"
                ? "Secure field - copied to clipboard"
                : "Couldn't insert - copied to clipboard"
            hud.showResult(success: false, message: reason, autoHideAfter: 2.2)
        }
    }

    private func resultPreview(_ text: String) -> String {
        let flat = text.replacingOccurrences(of: "\n", with: " ")
        return flat.count > 60 ? "…" + String(flat.suffix(57)) : flat
    }

    private func playSound(_ name: String) {
        guard Prefs.soundFeedback else { return }
        let sound = NSSound(named: NSSound.Name(name))
        sound?.volume = 0.3
        sound?.play()
    }
}
