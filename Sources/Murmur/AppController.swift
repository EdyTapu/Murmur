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
    let scratchpad = ScratchpadStore()
    private(set) lazy var stats = StatsStore(backfill: history.entries)
    private let muter = OutputMuter()
    let hud = HUDController()
    let gaze = GazeController()

    private let recorder = AudioRecorder()
    private let transcriber = Transcriber()
    private let hotkey = HotkeyMonitor()
    private let insertion = InsertionEngine()
    private let corrections = CorrectionWatcher()

    private var keyDownAt: Date?
    private var partialsTask: Task<Void, Never>?
    private var silenceTask: Task<Void, Never>?
    private var permissionPollTask: Task<Void, Never>?
    private var capturedContext: TargetContext?
    /// Set when the dictation key went down with ⌃ held: the speech is an instruction, not text.
    private var commandMode = false
    private var screenText: Task<String, Never>?

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
        // Before the engine first opens a microphone: never a Bluetooth headset's.
        AudioDevices.enforcePreferredInput()
        if micGranted {
            Task { await recorder.warmUp() }
        }
        AudioDevices.onDefaultInputChange { [weak self] in
            MainActor.assumeIsolated { self?.applyMicSelection() }
        }
        // Posted when hardware under the engine changes, e.g. the microphone's
        // sample rate after a display or headphones connect.
        NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.applyMicSelection() }
        }

        recorder.onLevel = { [weak self] level in
            MainActor.assumeIsolated {
                self?.hud.model.level = level
            }
        }

        hotkey.onKeyDown = { [weak self] in self?.hotkeyDown() }
        hotkey.onKeyUp = { [weak self] in self?.hotkeyUp() }
        hotkey.start(choice: Prefs.hotkey)
        restartShortcuts()

        gaze.toast = { [weak self] success, message in
            self?.hud.showResult(success: success, message: message)
        }
        gaze.registerHotkey()

        hud.onClick = { [weak self] in self?.toggleHandsFree() }
        hud.refreshIdle()

        corrections.onLearn = { [weak self] learned in
            guard let self else { return }
            for fix in learned {
                self.dictionary.learn(heard: fix.heard, corrected: fix.corrected)
                self.log.info("Learned \(fix.heard, privacy: .public) → \(fix.corrected, privacy: .public)")
            }
            self.stats.recordFixes(learned.count)
            // The HUD belongs to the dictation while one is running.
            if self.state == .idle {
                self.hud.showResult(
                    success: true,
                    message: "Learned " + learned.map(\.corrected).joined(separator: ", "),
                    autoHideAfter: 2.2)
            }
        }

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

    // MARK: - Global shortcuts + mic selection

    private var shortcutIDs: [UInt32] = []
    private var micChangeTask: Task<Void, Never>?

    /// (Re-)register every user-recorded shortcut from Prefs.
    func restartShortcuts() {
        suspendShortcuts()
        for action in ShortcutAction.allCases {
            guard let shortcut = Prefs.shortcut(action) else { continue }
            let id = HotkeyCenter.shared.register(
                keyCode: UInt32(shortcut.keyCode), carbonModifiers: shortcut.carbonModifiers
            ) { [weak self] in self?.perform(action) }
            if let id {
                shortcutIDs.append(id)
            } else {
                log.error("Shortcut \(shortcut.display, privacy: .public) could not be registered (taken by another app?)")
            }
        }
    }

    /// Temporarily release the shortcuts, e.g. while a recorder field is
    /// capturing keys (a registered combo never reaches local monitors).
    func suspendShortcuts() {
        shortcutIDs.forEach(HotkeyCenter.shared.unregister)
        shortcutIDs = []
    }

    private func perform(_ action: ShortcutAction) {
        switch action {
        case .toggle: toggleHandsFree()
        case .transform: showTransformMenu()
        case .scratchpad: AppShared.mainWindow.show(section: .scratchpad)
        }
    }

    /// Apply a changed mic preference. Waits for any in-flight dictation to
    /// end rather than yanking the device out from under it.
    func applyMicSelection() {
        micChangeTask?.cancel()
        micChangeTask = Task { [weak self] in
            while let self, self.state != .idle {
                try? await Task.sleep(for: .milliseconds(200))
                if Task.isCancelled { return }
            }
            guard let self, !Task.isCancelled else { return }
            AudioDevices.enforcePreferredInput()
            // Only when something really changed: a rebuild can itself post a
            // configuration change, and an unconditional one would loop.
            guard self.recorder.isStale else { return }
            self.recorder.reconfigureInputDevice()
            if self.micGranted { await self.recorder.warmUp() }
        }
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

    /// Undo anything that must not outlive the app (a muted output).
    func prepareToQuit() {
        muter.restore()
    }

    // MARK: - Hotkey handling

    private func hotkeyDown() {
        switch state {
        case .idle:
            keyDownAt = Date()
            commandMode = NSEvent.modifierFlags.contains(.control)
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
            commandMode = false
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

        // Commit what the last dictation's field taught us before this one is cleaned.
        corrections.stop()
        dictionary.reloadIfChanged()
        let target = insertion.captureContext()
        capturedContext = target
        // Read what is on screen while the user talks; it is ready by the time they stop.
        screenText = nil
        if Prefs.contextAwareness, let pid = target.appPID {
            screenText = Task.detached { ContextVocabulary.visibleText(pid: pid) }
        }
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
        hud.model.isCommand = commandMode
        hud.model.targetApp = target.appName
        hud.show(.recording(handsFree: handsFree))
        playSound("Tink")
        if Prefs.muteWhileDictating {
            // After the start sound has played, so it is still heard.
            Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(250))
                guard let self, case .recording = self.state else { return }
                self.muter.mute()
            }
        }
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
        muter.restore()

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
        muter.restore()
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
                if Date().timeIntervalSince(startedAt) > 2, !self.recorder.hasSignal {
                    self.hud.model.partialText = "No sound from the microphone"
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
        if commandMode {
            await runCommand(raw, context: context, duration: duration)
            return
        }

        // "None" still honors spoken commands (scratch that, new line) but edits nothing else.
        let level = Prefs.cleanupLevel
        var rules = RulesCleaner.clean(raw, removeFillers: true, spokenPunctuation: Prefs.spokenPunctuation)
        if level == .none, !rules.cancelled {
            rules.text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            rules.trailingNewlines = 0
        }
        if rules.cancelled {
            hud.showResult(success: true, message: "Scratched")
            return
        }
        var text = DictionaryStore.apply(
            rules.text, terms: dictionary.terms, snippets: dictionary.snippets)

        // Names and identifiers visible in the app, spelled the way the app spells them.
        var screenTerms: [String] = []
        if level != .none, let screenText {
            screenTerms = ContextVocabulary.terms(in: await screenText.value, isKnownWord: Self.isKnownWord)
            text = ContextVocabulary.apply(text, terms: screenTerms, isKnownWord: Self.isKnownWord)
        }

        // 3. Optional on-device LLM polish with per-app tone.
        if level == .medium, LLMCleaner.isAvailable, !text.isEmpty {
            hud.show(.polishing)
            let tone = Prefs.tone(for: context.category)
            if let polished = await LLMCleaner.clean(text, tone: tone, names: screenTerms) {
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

        await deliver(text, raw: raw, context: context, duration: duration, learn: true)
    }

    /// Insert `text`, record it, and report the outcome.
    private func deliver(_ text: String, raw: String, context: TargetContext, duration: Double?, learn: Bool) async {
        let outcome = await insertion.insert(text, context: context)

        // History - always.
        history.add(
            HistoryEntry(
                rawText: raw,
                finalText: text,
                appName: context.appName,
                appBundleID: context.appBundleID,
                outcome: outcome.historyLabel,
                duration: duration
            ))
        stats.record(text: text, seconds: duration, app: context.appName)

        if outcome.success {
            if learn {
                corrections.watch(
                    inserted: text, in: insertion.focusedElement(),
                    read: { [insertion] in insertion.stringValue(of: $0) })
            }
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

    static func isKnownWord(_ word: String) -> Bool {
        NSSpellChecker.shared.checkSpelling(of: word, startingAt: 0).location == NSNotFound
    }

    // MARK: - Command Mode + Transforms

    /// A spoken instruction: search the web, or have the on-device model
    /// rewrite the selection / write new text at the cursor.
    private func runCommand(_ raw: String, context: TargetContext, duration: Double) async {
        let rules = RulesCleaner.clean(raw, removeFillers: true, spokenPunctuation: false)
        guard !rules.cancelled, !rules.text.isEmpty else {
            hud.showResult(success: true, message: "Scratched")
            return
        }
        let selection = await insertion.selectedText()
        if let url = WebSearch.url(forCommand: rules.text, selection: selection) {
            NSWorkspace.shared.open(url)
            hud.showResult(success: true, message: "Searching the web")
            return
        }
        await rewrite(instruction: rules.text, selection: selection, spoken: raw, context: context, duration: duration)
    }

    private func rewrite(
        instruction: String, selection: String?, spoken: String, context: TargetContext, duration: Double?
    ) async {
        guard LLMCleaner.isAvailable else {
            hud.showResult(success: false, message: "This needs Apple Intelligence on this Mac", autoHideAfter: 2.2)
            return
        }
        hud.show(.polishing)
        guard let output = await LLMCleaner.run(instruction: instruction, selection: selection) else {
            hud.showResult(success: false, message: "Couldn't do that")
            return
        }
        // Pasting over the selection replaces it.
        await deliver(output, raw: spoken, context: context, duration: duration, learn: false)
    }

    /// Shortcut: pick a transform from a menu and apply it to the selection.
    private func showTransformMenu() {
        guard state == .idle else { return }
        let context = insertion.captureContext()
        Task { [weak self] in
            guard let self else { return }
            guard let selection = await self.insertion.selectedText(), !selection.isEmpty else {
                self.hud.showResult(success: false, message: "Select some text first")
                return
            }
            let menu = NSMenu()
            for transform in self.dictionary.transforms {
                menu.addItem(ClosureMenuItem(title: transform.name) { [weak self] in
                    Task {
                        // Busy while rewriting, so a dictation cannot start and insert on top of it.
                        guard let self, self.state == .idle else { return }
                        self.state = .finishing
                        defer { self.state = .idle }
                        await self.rewrite(
                            instruction: transform.prompt, selection: selection, spoken: transform.name,
                            context: context, duration: nil)
                    }
                })
            }
            menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
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

/// Menu item that runs a closure; NSMenuItem itself only takes a selector.
final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) { fatalError("not used") }

    @objc private func run() { handler() }
}

/// "Search for swift actors" in Command Mode opens a web search.
enum WebSearch {
    static func url(forCommand command: String, selection: String?) -> URL? {
        guard
            let match = command.range(
                of: #"^(search(\s+the\s+web)?(\s+for)?|google|look\s+up)\s+"#,
                options: [.regularExpression, .caseInsensitive])
        else { return nil }
        var query = String(command[match.upperBound...]).trimmingCharacters(in: .punctuationCharacters.union(.whitespaces))
        // "search for this" with text selected searches for the selection.
        if let selection = selection?.trimmingCharacters(in: .whitespacesAndNewlines), !selection.isEmpty {
            query = ["this", "that", "it"].contains(query.lowercased()) ? selection : query + " " + selection
        }
        guard !query.isEmpty else { return nil }
        var components = URLComponents(string: "https://www.google.com/search")
        components?.queryItems = [URLQueryItem(name: "q", value: String(query.prefix(300)))]
        return components?.url
    }
}
