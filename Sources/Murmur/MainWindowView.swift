import AppKit
import SwiftUI

/// The Wispr-Flow-style dashboard: sidebar with Home (stats + recent),
/// History, Scratchpad, Dictionary, Snippets, and Settings.
struct MainWindowView: View {
    @ObservedObject var controller: AppController
    @ObservedObject var state: MainWindowState

    var body: some View {
        NavigationSplitView {
            List(
                selection: Binding<MainSection?>(
                    get: { state.section },
                    set: { if let section = $0 { state.section = section } }
                )
            ) {
                Section {
                    ForEach([MainSection.home, .history, .scratchpad]) { section in
                        Label(section.label, systemImage: section.icon).tag(section)
                    }
                }
                Section("Personalize") {
                    ForEach([MainSection.dictionary, .snippets, .settings]) { section in
                        Label(section.label, systemImage: section.icon).tag(section)
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 170, ideal: 190)
        } detail: {
            detail
                .navigationTitle(state.section.label)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 780, minHeight: 500)
    }

    @ViewBuilder
    private var detail: some View {
        switch state.section {
        case .home:
            HomeSection(controller: controller, history: controller.history)
        case .history:
            HistorySection(history: controller.history)
        case .scratchpad:
            ScratchpadSection(history: controller.history)
        case .dictionary:
            DictionarySettings(store: controller.dictionary)
        case .snippets:
            SnippetSettings(store: controller.dictionary)
        case .settings:
            SettingsSection(controller: controller)
        }
    }
}

// MARK: - Home

struct HomeSection: View {
    @ObservedObject var controller: AppController
    @ObservedObject var history: HistoryStore
    @ObservedObject var gaze: GazeController

    init(controller: AppController, history: HistoryStore) {
        self.controller = controller
        self.history = history
        self.gaze = controller.gaze
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                statusCard
                gazeCard
                statTiles
                recent
            }
            .padding(24)
            .frame(maxWidth: 700, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
    }

    // MARK: Status

    private var isRecording: Bool {
        if case .recording = controller.state { return true }
        return false
    }

    private var statusText: String {
        switch controller.asrState {
        case .notLoaded, .loading:
            return "Loading speech model…"
        case .downloading(let fraction):
            return "Downloading speech model… \(Int(fraction * 100))%"
        case .failed(let message):
            return "Model error: \(message)"
        case .ready:
            if !controller.micGranted { return "Microphone access needed" }
            if !controller.axTrusted { return "Accessibility access needed" }
            if isRecording { return "Listening…" }
            return "Hold \(Prefs.hotkey.label) and speak · quick-tap for hands-free"
        }
    }

    private var statusHealthy: Bool {
        controller.isReady || isRecording
    }

    private var statusCard: some View {
        HStack(spacing: 12) {
            Image(systemName: isRecording ? "waveform.badge.mic" : "waveform")
                .font(.title2)
                .foregroundStyle(statusHealthy ? Color.accentColor : .orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(statusText)
                    .font(.headline)
                Text("Everything runs on this Mac - audio never leaves the device.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button(isRecording ? "Stop Dictation" : "Start Hands-Free") {
                controller.toggleHandsFree()
            }
            .disabled(!controller.isReady && !isRecording)
        }
        .padding(16)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
    }

    // MARK: Eye control

    private var gazeCard: some View {
        HStack(spacing: 12) {
            Image(systemName: "eye")
                .font(.title2)
                .foregroundStyle(gaze.state == .off ? Color.secondary : Color.accentColor)
            VStack(alignment: .leading, spacing: 2) {
                Text(gaze.statusText)
                    .font(.headline)
                Text("Point your face to move the cursor, blink to click · ⌃⌥E toggles anywhere.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button(gaze.state == .off ? "Start" : "Stop") {
                gaze.toggle()
            }
            Button("Recenter") {
                gaze.recenter()
            }
            .disabled(gaze.state == .off)
        }
        .padding(16)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
    }

    // MARK: Stats

    private static func wordCount(_ text: String) -> Int {
        text.split(whereSeparator: \.isWhitespace).count
    }

    private var totalWords: Int {
        history.entries.reduce(0) { $0 + Self.wordCount($1.finalText) }
    }

    private var wordsThisWeek: Int {
        let calendar = Calendar.current
        return history.entries
            .filter { calendar.isDate($0.date, equalTo: Date(), toGranularity: .weekOfYear) }
            .reduce(0) { $0 + Self.wordCount($1.finalText) }
    }

    private var dayStreak: Int {
        let calendar = Calendar.current
        let days = Set(history.entries.map { calendar.startOfDay(for: $0.date) })
        var day = calendar.startOfDay(for: Date())
        // A quiet today shouldn't break yesterday's streak.
        if !days.contains(day) {
            day = calendar.date(byAdding: .day, value: -1, to: day) ?? day
        }
        var streak = 0
        while days.contains(day) {
            streak += 1
            guard let previous = calendar.date(byAdding: .day, value: -1, to: day) else { break }
            day = previous
        }
        return streak
    }

    private var statTiles: some View {
        HStack(spacing: 12) {
            StatTile(value: "\(totalWords)", label: "Words dictated")
            StatTile(value: "\(history.entries.count)", label: "Dictations")
            StatTile(value: "\(wordsThisWeek)", label: "Words this week")
            StatTile(value: "\(dayStreak)", label: "Day streak")
        }
    }

    // MARK: Recent

    private var recent: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Recent dictations")
                .font(.title3.bold())
            if history.entries.isEmpty {
                Text("Nothing yet - click into any text field, hold \(Prefs.hotkey.label), and speak.")
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 12)
            } else {
                VStack(spacing: 0) {
                    ForEach(history.entries.prefix(5)) { entry in
                        HistoryRow(entry: entry)
                            .padding(.vertical, 8)
                        if entry.id != history.entries.prefix(5).last?.id {
                            Divider()
                        }
                    }
                }
                .padding(.horizontal, 16)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
            }
        }
    }
}

struct StatTile: View {
    let value: String
    let label: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(value)
                .font(.system(size: 26, weight: .bold, design: .rounded))
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
    }
}

// MARK: - History

struct HistorySection: View {
    @ObservedObject var history: HistoryStore
    @State private var search = ""
    @State private var confirmClear = false

    private var filtered: [HistoryEntry] {
        guard !search.isEmpty else { return history.entries }
        return history.entries.filter {
            $0.finalText.localizedCaseInsensitiveContains(search)
                || ($0.appName?.localizedCaseInsensitiveContains(search) ?? false)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                TextField("Search dictations…", text: $search)
                    .textFieldStyle(.roundedBorder)
                Button("Clear History", role: .destructive) {
                    confirmClear = true
                }
                .disabled(history.entries.isEmpty)
            }
            .padding(10)

            Divider()

            if filtered.isEmpty {
                Spacer()
                Text(search.isEmpty ? "Dictations will appear here." : "No matches.")
                    .foregroundStyle(.secondary)
                Spacer()
            } else {
                List(filtered) { entry in
                    HistoryRow(entry: entry)
                        .padding(.vertical, 4)
                }
            }
        }
        .confirmationDialog(
            "Delete all \(history.entries.count) dictations?",
            isPresented: $confirmClear
        ) {
            Button("Delete All", role: .destructive) { history.clear() }
        } message: {
            Text("This can't be undone.")
        }
    }
}

struct HistoryRow: View {
    let entry: HistoryEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(entry.finalText)
                .lineLimit(3)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 8) {
                Text(entry.date, format: .relative(presentation: .named))
                if let app = entry.appName {
                    Text("→ \(app)")
                }
                Text(outcomeLabel(entry.outcome))
                    .foregroundStyle(entry.outcome.hasPrefix("history-only") ? .orange : .secondary)
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(entry.finalText, forType: .string)
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .buttonStyle(.borderless)
                .help("Copy")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    private func outcomeLabel(_ outcome: String) -> String {
        switch outcome {
        case "ax": return "inserted"
        case "paste": return "pasted"
        case "applescript": return "typed"
        default: return "not inserted"
        }
    }
}

// MARK: - Scratchpad

struct ScratchpadSection: View {
    @ObservedObject var history: HistoryStore

    var body: some View {
        TextEditor(
            text: Binding(
                get: { history.scratchpad },
                set: { history.scratchpad = $0 }
            )
        )
        .font(.body)
        .padding(8)
    }
}

// MARK: - Settings

/// General + Cleanup stacked on one scrollable page; Dictionary and Snippets
/// have their own sidebar sections. The Cmd+, Settings scene keeps the
/// classic tabbed layout via `SettingsView`.
struct SettingsSection: View {
    @ObservedObject var controller: AppController

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text("General")
                    .font(.title3.bold())
                    .padding(.horizontal, 20)
                    .padding(.top, 16)
                GeneralSettings(controller: controller)
                Divider()
                    .padding(.horizontal, 20)
                Text("Cleanup")
                    .font(.title3.bold())
                    .padding(.horizontal, 20)
                    .padding(.top, 16)
                CleanupSettings()
                Divider()
                    .padding(.horizontal, 20)
                Text("Eye Control")
                    .font(.title3.bold())
                    .padding(.horizontal, 20)
                    .padding(.top, 16)
                GazeSettings(controller: controller)
            }
            .frame(maxWidth: 560, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
    }
}
