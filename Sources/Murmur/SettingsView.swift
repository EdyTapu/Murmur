import ServiceManagement
import SwiftUI

struct SettingsView: View {
    @ObservedObject var controller: AppController

    var body: some View {
        TabView {
            GeneralSettings(controller: controller)
                .tabItem { Label("General", systemImage: "gearshape") }
            CleanupSettings()
                .tabItem { Label("Cleanup", systemImage: "wand.and.stars") }
            GazeSettings(controller: controller)
                .tabItem { Label("Eye", systemImage: "eye") }
            DictionarySettings(store: controller.dictionary)
                .tabItem { Label("Dictionary", systemImage: "character.book.closed") }
            SnippetSettings(store: controller.dictionary)
                .tabItem { Label("Snippets", systemImage: "text.badge.plus") }
            TransformSettings(store: controller.dictionary)
                .tabItem { Label("Transforms", systemImage: "wand.and.stars") }
        }
        .frame(width: 520, height: 480)
    }
}

// MARK: - General

struct GeneralSettings: View {
    @ObservedObject var controller: AppController
    @AppStorage(PrefKey.hotkey) private var hotkey = HotkeyChoice.fn.rawValue
    @State private var micPriority = Prefs.micPriority
    @AppStorage(PrefKey.silenceAutoStop) private var silenceAutoStop = true
    @AppStorage(PrefKey.silenceSeconds) private var silenceSeconds = 2.5
    @AppStorage(PrefKey.soundFeedback) private var soundFeedback = true
    @AppStorage(PrefKey.muteWhileDictating) private var muteWhileDictating = true
    @AppStorage(PrefKey.flowBarAlwaysVisible) private var flowBarAlwaysVisible = true
    @AppStorage(PrefKey.historyRetention) private var historyRetention = HistoryRetention.forever.rawValue
    @AppStorage(PrefKey.syncFolder) private var syncFolder = ""
    @State private var inputDevices: [AudioInputDevice] = []
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?

    var body: some View {
        Form {
            Picker("Dictation key:", selection: $hotkey) {
                ForEach(HotkeyChoice.allCases) { choice in
                    Text(choice.label).tag(choice.rawValue)
                }
            }
            .onChange(of: hotkey) {
                controller.restartHotkey()
            }
            Text("Hold to talk; quick-tap for hands-free. Hold ⌃ as well for Command Mode: speak an instruction for the selected text, or say \u{201C}search for…\u{201D}.")
                .font(.caption)
                .foregroundStyle(.secondary)

            ShortcutRecorder(
                controller: controller, action: .toggle, title: "Toggle dictation:",
                help: "Press once to start hands-free dictation, again to stop. Combine ⌘, ⌥ or ⌃ with a key, or use a function key.")
            ShortcutRecorder(
                controller: controller, action: .transform, title: "Transform selection:",
                help: "Opens a menu of your transforms and rewrites the selected text with the one you pick.")
            ShortcutRecorder(
                controller: controller, action: .scratchpad, title: "Open scratchpad:",
                help: "Opens the scratchpad from any app.")

            Divider()

            LabeledContent("Microphones:") {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(micPriority.enumerated()), id: \.element.uid) { index, mic in
                        HStack(spacing: 6) {
                            Text("\(index + 1). \(mic.label)")
                                .foregroundStyle(inputDevices.contains { $0.uid == mic.uid } ? .primary : .secondary)
                            Spacer()
                            Button { moveMic(index, by: -1) } label: { Image(systemName: "chevron.up") }
                                .disabled(index == 0)
                                .help("Move up")
                            Button { moveMic(index, by: 1) } label: { Image(systemName: "chevron.down") }
                                .disabled(index == micPriority.count - 1)
                                .help("Move down")
                            Button { micPriority.remove(at: index) } label: { Image(systemName: "minus.circle") }
                                .help("Remove")
                        }
                        .buttonStyle(.borderless)
                    }
                    Menu(micPriority.isEmpty ? "System default" : "Add microphone") {
                        ForEach(inputDevices.filter { device in !micPriority.contains { $0.uid == device.uid } }) { device in
                            Button(device.label) { micPriority.append(device) }
                        }
                    }
                    .fixedSize()
                }
            }
            .onChange(of: micPriority) {
                Prefs.setMicPriority(micPriority)
                controller.applyMicSelection()
            }
            .onAppear {
                inputDevices = AudioDevices.inputDevices()
                // A device can be renamed, and an entry saved by an older build has no real name.
                micPriority = micPriority.map { saved in inputDevices.first { $0.uid == saved.uid } ?? saved }
            }
            Text("Murmur makes the first connected microphone in this list the Mac's input device, and leaves the input alone when the list is empty. It never lets a Bluetooth headset be the input unless you add that headset here, so your headphones keep full audio quality.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Divider()

            Toggle("Stop hands-free dictation after silence", isOn: $silenceAutoStop)
            if silenceAutoStop {
                Slider(value: $silenceSeconds, in: 1.5...6, step: 0.5) {
                    Text("Silence: \(silenceSeconds, specifier: "%.1f")s")
                }
            }

            Toggle("Sound feedback", isOn: $soundFeedback)
            Toggle("Mute other audio while dictating", isOn: $muteWhileDictating)
            Toggle("Keep the dictation bar on screen", isOn: $flowBarAlwaysVisible)
                .onChange(of: flowBarAlwaysVisible) {
                    controller.hud.refreshIdle()
                }
            HStack {
                Text("Drag the bar anywhere; click it for hands-free dictation.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Reset Position") {
                    Prefs.setFlowBarAnchor(nil)
                    controller.hud.refreshIdle()
                }
                .controlSize(.small)
            }

            Divider()

            Picker("History:", selection: $historyRetention) {
                ForEach(HistoryRetention.allCases) { Text($0.label).tag($0.rawValue) }
            }
            .onChange(of: historyRetention) {
                controller.history.prune()
            }

            LabeledContent("Sync folder:") {
                HStack(spacing: 6) {
                    Text(syncFolder.isEmpty ? "This Mac only" : (syncFolder as NSString).abbreviatingWithTildeInPath)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundStyle(.secondary)
                    Button("Choose…") {
                        let panel = NSOpenPanel()
                        panel.canChooseDirectories = true
                        panel.canChooseFiles = false
                        panel.canCreateDirectories = true
                        panel.prompt = "Sync Here"
                        if panel.runModal() == .OK, let url = panel.url {
                            syncFolder = url.path
                            controller.dictionary.relocate(to: url)
                        }
                    }
                    if !syncFolder.isEmpty {
                        Button("Stop") {
                            syncFolder = ""
                            controller.dictionary.relocate(to: nil)
                        }
                    }
                }
            }
            Text("Keeps your dictionary and snippets in a shared folder such as iCloud Drive. Choose the same folder in Murmur on your other Macs.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Divider()

            Toggle("Launch at login", isOn: $launchAtLogin)
                .onChange(of: launchAtLogin) {
                    do {
                        if launchAtLogin {
                            try SMAppService.mainApp.register()
                        } else {
                            try SMAppService.mainApp.unregister()
                        }
                        loginError = nil
                    } catch {
                        loginError = error.localizedDescription
                        launchAtLogin = SMAppService.mainApp.status == .enabled
                    }
                }
            if let loginError {
                Text(loginError).font(.caption).foregroundStyle(.red)
            }
        }
        .padding(20)
    }

    private func moveMic(_ index: Int, by offset: Int) {
        micPriority.swapAt(index, index + offset)
    }
}

/// "Record Shortcut" field for the hands-free toggle keybind. While recording,
/// a local key monitor captures the next combo; the registered Carbon hotkey
/// is suspended so re-recording the current combo works (a registered hotkey
/// never reaches local monitors). Esc cancels, ⌘/⌥/⌃ or an F-key is required.
struct ShortcutRecorder: View {
    @ObservedObject var controller: AppController
    let action: ShortcutAction
    let title: String
    let help: String
    @State private var shortcut: ToggleShortcut?
    @State private var recording = false
    @State private var monitor: Any?

    var body: some View {
        LabeledContent(title) {
            HStack(spacing: 6) {
                Button {
                    recording ? stopRecording() : startRecording()
                } label: {
                    Text(recording ? "Press keys… (esc cancels)" : (shortcut?.display ?? "Record Shortcut"))
                        .frame(minWidth: 130)
                }
                if shortcut != nil, !recording {
                    Button {
                        shortcut = nil
                        Prefs.setShortcut(nil, for: action)
                        controller.restartShortcuts()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.borderless)
                    .help("Remove shortcut")
                }
            }
        }
        .onAppear { shortcut = Prefs.shortcut(action) }
        Text(help)
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    private func startRecording() {
        recording = true
        controller.suspendShortcuts()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let plainEscape =
                event.keyCode == 53
                && event.modifierFlags
                    .intersection([.command, .option, .control, .shift]).isEmpty
            if plainEscape {
                stopRecording()
                return nil
            }
            guard
                let captured = ToggleShortcut(
                    keyCode: event.keyCode, modifierFlags: event.modifierFlags)
            else {
                NSSound.beep()
                return nil
            }
            shortcut = captured
            Prefs.setShortcut(captured, for: action)
            stopRecording()
            return nil
        }
    }

    private func stopRecording() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        recording = false
        controller.restartShortcuts()
    }
}

// MARK: - Cleanup

struct CleanupSettings: View {
    @AppStorage(PrefKey.cleanupLevel) private var level = Prefs.cleanupLevel.rawValue
    @AppStorage(PrefKey.spokenPunctuation) private var spokenPunctuation = true
    @AppStorage(PrefKey.contextAwareness) private var contextAwareness = true
    @AppStorage(PrefKey.tonePersonal) private var tonePersonal = Tone.casual.rawValue
    @AppStorage(PrefKey.toneWork) private var toneWork = Tone.neutral.rawValue
    @AppStorage(PrefKey.toneEmail) private var toneEmail = Tone.formal.rawValue
    @AppStorage(PrefKey.toneOther) private var toneOther = Tone.neutral.rawValue

    var body: some View {
        Form {
            Picker("Cleanup:", selection: $level) {
                ForEach(CleanupLevel.allCases) { Text($0.label).tag($0.rawValue) }
            }
            Text("Light removes fillers, keeps only your correction (\u{201C}at 2, actually 3\u{201D}), and formats spoken lists. Medium also fixes grammar and matches tone on-device, which adds a moment of latency.")
                .font(.caption)
                .foregroundStyle(.secondary)
            if !LLMCleaner.isAvailable {
                Text("Apple Intelligence is not available on this Mac, so Medium behaves like Light.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Toggle("Spoken punctuation (\u{201C}comma\u{201D}, \u{201C}question mark\u{201D})", isOn: $spokenPunctuation)
                .disabled(level == CleanupLevel.none.rawValue)
            Toggle("Match names and code on screen", isOn: $contextAwareness)
                .disabled(level == CleanupLevel.none.rawValue)
            Text("Reads the text visible in the app you dictate into so names and identifiers are spelled the same way. It is read on this Mac for one dictation and never stored.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Divider()

            if level == CleanupLevel.medium.rawValue {
                Picker("Personal messaging:", selection: $tonePersonal) {
                    ForEach(Tone.allCases) { Text($0.label).tag($0.rawValue) }
                }
                Picker("Work messaging:", selection: $toneWork) {
                    ForEach(Tone.allCases) { Text($0.label).tag($0.rawValue) }
                }
                Picker("Email:", selection: $toneEmail) {
                    ForEach(Tone.allCases) { Text($0.label).tag($0.rawValue) }
                }
                Picker("Everything else:", selection: $toneOther) {
                    ForEach(Tone.allCases) { Text($0.label).tag($0.rawValue) }
                }
            }
        }
        .padding(20)
    }
}

// MARK: - Eye control

struct GazeSettings: View {
    @ObservedObject var controller: AppController
    @ObservedObject var gaze: GazeController
    @AppStorage(PrefKey.headSensitivity) private var sensitivity = 3.5
    @AppStorage(PrefKey.gazeBlinkClick) private var blinkClick = true
    @AppStorage(PrefKey.gazePuckerClick) private var puckerClick = true
    @AppStorage(PrefKey.gazeSnap) private var snap = true
    @AppStorage(PrefKey.gazeSnapRadius) private var snapRadius = 150.0

    init(controller: AppController) {
        self.controller = controller
        self.gaze = controller.gaze
    }

    var body: some View {
        Form {
            LabeledContent("Status:") {
                Text(gaze.statusText)
                    .foregroundStyle(gaze.state == .off ? .secondary : Color.green)
            }
            Text("Press ⌃⌥E to start or stop head control. Point your face where you want the cursor; any blink or wink clicks. Tracking runs fully on-device (Apple Vision). Video never leaves this Mac.")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                Button(gaze.state == .off ? "Start Head Control" : "Stop Head Control") {
                    gaze.toggle()
                }
                Button("Recenter") {
                    gaze.recenter()
                }
                .disabled(gaze.state == .off)
                Button("Calibrate Range…") {
                    gaze.calibrateBounds()
                }
                .disabled(gaze.state == .starting || gaze.state == .calibrating)
            }
            Text("Recenter captures your current pose as \u{201C}cursor at screen centre\u{201D}. Calibrate Range walks you through facing the centre and each screen edge (hold each pose, no blinking needed) so your natural head sweep maps to the whole screen.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Divider()

            if gaze.boundsCalibrated {
                HStack {
                    Label("Range calibrated", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Spacer()
                    Button("Clear Range") {
                        gaze.clearBounds()
                    }
                }
                Text("Your edge sweep maps to the full screen; the sensitivity slider is not used. Clear it to go back to slider control.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Slider(value: $sensitivity, in: 1...10, step: 0.5) {
                    Text("Sensitivity: \(sensitivity, specifier: "%.1f")")
                }
                .onChange(of: sensitivity) {
                    gaze.applySensitivity()
                }
                Text("Higher = smaller head movements sweep the whole screen. Applies immediately - adjust while a session is running to dial in the feel.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Toggle("Blink to click", isOn: $blinkClick)
            if blinkClick {
                Text("Any blink or wink clicks where you were pointing just before your eyes closed.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Toggle("Pucker lips to click", isOn: $puckerClick)
            if puckerClick {
                Text("Purse your lips (kiss face) for a quarter second and release. A long \u{201C}oo\u{201D} while talking can also trigger it - pause head control while dictating long text.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Toggle("Snap clicks to windows and Dock icons", isOn: $snap)
            if snap {
                Slider(value: $snapRadius, in: 60...260, step: 10) {
                    Text("Snap radius: \(Int(snapRadius))px")
                }
            }
        }
        .padding(20)
    }
}

// MARK: - Dictionary

struct DictionarySettings: View {
    @ObservedObject var store: DictionaryStore
    @State private var newCanonical = ""
    @State private var newAliases = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Teach Murmur your words. Aliases are what the recognizer hears; the term is what gets typed.")
                .font(.caption)
                .foregroundStyle(.secondary)

            List {
                ForEach(store.terms) { term in
                    HStack {
                        Text(term.canonical).fontWeight(.medium)
                        Spacer()
                        Text(term.aliases.joined(separator: ", "))
                            .foregroundStyle(.secondary)
                        Button(role: .destructive) {
                            store.terms.removeAll { $0.id == term.id }
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                    }
                }
            }

            HStack {
                TextField("Term (e.g. Rojo)", text: $newCanonical)
                TextField("Heard as (comma-separated)", text: $newAliases)
                Button("Add") {
                    let aliases = newAliases
                        .components(separatedBy: ",")
                        .map { $0.trimmingCharacters(in: .whitespaces) }
                        .filter { !$0.isEmpty }
                    guard !newCanonical.isEmpty else { return }
                    store.terms.append(
                        DictionaryTerm(canonical: newCanonical, aliases: aliases))
                    newCanonical = ""
                    newAliases = ""
                }
                .disabled(newCanonical.isEmpty)
            }
        }
        .padding(20)
    }
}

// MARK: - Snippets

struct SnippetSettings: View {
    @ObservedObject var store: DictionaryStore
    @State private var newTrigger = ""
    @State private var newExpansion = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Say the trigger phrase as a whole dictation and Murmur types the expansion.")
                .font(.caption)
                .foregroundStyle(.secondary)

            List {
                ForEach(store.snippets) { snippet in
                    HStack {
                        Text("\u{201C}\(snippet.trigger)\u{201D}").fontWeight(.medium)
                        Spacer()
                        Text(snippet.expansion)
                            .lineLimit(1)
                            .foregroundStyle(.secondary)
                        Button(role: .destructive) {
                            store.snippets.removeAll { $0.id == snippet.id }
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                    }
                }
            }

            HStack {
                TextField("Trigger (e.g. insert my email)", text: $newTrigger)
                TextField("Expansion", text: $newExpansion)
                Button("Add") {
                    guard !newTrigger.isEmpty, !newExpansion.isEmpty else { return }
                    store.snippets.append(
                        Snippet(trigger: newTrigger, expansion: newExpansion))
                    newTrigger = ""
                    newExpansion = ""
                }
                .disabled(newTrigger.isEmpty || newExpansion.isEmpty)
            }
        }
        .padding(20)
    }
}

// MARK: - Transforms

struct TransformSettings: View {
    @ObservedObject var store: DictionaryStore
    @State private var newName = ""
    @State private var newPrompt = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Select text in any app, press the Transform shortcut (Settings), and pick one of these. The rewrite happens on this Mac with Apple Intelligence.")
                .font(.caption)
                .foregroundStyle(.secondary)
            if !LLMCleaner.isAvailable {
                Text("Apple Intelligence is not available on this Mac, so transforms cannot run.")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            List {
                ForEach(store.transforms) { transform in
                    HStack {
                        Text(transform.name).fontWeight(.medium)
                        Spacer()
                        Text(transform.prompt)
                            .lineLimit(1)
                            .foregroundStyle(.secondary)
                        Button(role: .destructive) {
                            store.transforms.removeAll { $0.id == transform.id }
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                    }
                }
            }

            HStack {
                TextField("Name (e.g. Shorten)", text: $newName)
                    .frame(maxWidth: 160)
                TextField("Instruction (e.g. Make this half as long)", text: $newPrompt)
                Button("Add") {
                    store.transforms.append(Transform(name: newName, prompt: newPrompt))
                    newName = ""
                    newPrompt = ""
                }
                .disabled(newName.isEmpty || newPrompt.isEmpty)
            }
        }
        .padding(20)
    }
}
