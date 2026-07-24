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
        }
        .frame(width: 520, height: 420)
    }
}

// MARK: - General

struct GeneralSettings: View {
    @ObservedObject var controller: AppController
    @AppStorage(PrefKey.hotkey) private var hotkey = HotkeyChoice.fn.rawValue
    @AppStorage(PrefKey.silenceAutoStop) private var silenceAutoStop = true
    @AppStorage(PrefKey.silenceSeconds) private var silenceSeconds = 2.5
    @AppStorage(PrefKey.soundFeedback) private var soundFeedback = true
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
            Text("Hold to talk; quick-tap for hands-free.")
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
}

// MARK: - Cleanup

struct CleanupSettings: View {
    @AppStorage(PrefKey.fillerRemoval) private var fillerRemoval = true
    @AppStorage(PrefKey.aiCleanup) private var aiCleanup = false
    @AppStorage(PrefKey.tonePersonal) private var tonePersonal = Tone.casual.rawValue
    @AppStorage(PrefKey.toneWork) private var toneWork = Tone.neutral.rawValue
    @AppStorage(PrefKey.toneEmail) private var toneEmail = Tone.formal.rawValue
    @AppStorage(PrefKey.toneOther) private var toneOther = Tone.neutral.rawValue

    var body: some View {
        Form {
            Toggle("Remove filler words (um, uh…)", isOn: $fillerRemoval)

            Divider()

            Toggle("AI polish (on-device Apple Intelligence)", isOn: $aiCleanup)
                .disabled(!LLMCleaner.isAvailable)
            if !LLMCleaner.isAvailable {
                Text("Apple Intelligence is not available on this Mac, so the AI polish pass is disabled.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("Collapses self-corrections (\u{201C}at 2… actually 3\u{201D}), fixes grammar, and matches tone to the app you're dictating into. Adds a moment of latency.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if aiCleanup {
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
    @AppStorage(PrefKey.gazeBlinkClick) private var blinkClick = true
    @AppStorage(PrefKey.gazeSnap) private var snap = true
    @AppStorage(PrefKey.gazeSnapRadius) private var snapRadius = 150.0

    init(controller: AppController) {
        self.controller = controller
        self.gaze = controller.gaze
    }

    var body: some View {
        Form {
            if gaze.isInstalled {
                LabeledContent("Status:") {
                    Text(gaze.statusText)
                        .foregroundStyle(gaze.state == .off ? .secondary : Color.green)
                }
                Text("Press ⌃⌥E to start or stop an eye-control session. Look where you want the cursor; any blink or wink clicks.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HStack {
                    Button(gaze.state == .off ? "Start Eye Control" : "Stop Eye Control") {
                        gaze.toggle()
                    }
                    Button(gaze.isCalibrated ? "Recalibrate…" : "Calibrate…") {
                        gaze.recalibrate()
                    }
                }

                Divider()

                Toggle("Blink to click", isOn: $blinkClick)
                if blinkClick {
                    Text("Any blink or wink clicks where you were looking just before your eyes closed.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Toggle("Snap clicks to windows and Dock icons", isOn: $snap)
                if snap {
                    Slider(value: $snapRadius, in: 60...260, step: 10) {
                        Text("Snap radius: \(Int(snapRadius))px")
                    }
                }
            } else {
                Text("Eye control isn't set up yet")
                    .fontWeight(.medium)
                Text("Run this once in the Murmur folder, then relaunch Murmur:")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("zsh app/setup_gaze.sh")
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(6)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
                Text("It installs the on-device MediaPipe eye tracker (~600 MB, Python) into Application Support. Video never leaves this Mac.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
