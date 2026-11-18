import AppKit
import SwiftUI

/// Murmur's identity colours: the blue-to-violet of the waveform mark.
enum Brand {
    static let blue = Color(red: 0.353, green: 0.635, blue: 1.0)
    static let violet = Color(red: 0.627, green: 0.4, blue: 1.0)
    static let gradient = LinearGradient(colors: [blue, violet], startPoint: .top, endPoint: .bottom)
    static let sweep = LinearGradient(colors: [blue, violet], startPoint: .leading, endPoint: .trailing)
}

/// The dashboard: a sidebar (Home, History, Scratchpad / Personalize /
/// System) beside the selected page.
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
                    ForEach([MainSection.dictionary, .snippets, .transforms]) { section in
                        Label(section.label, systemImage: section.icon).tag(section)
                    }
                }
                Section("System") {
                    ForEach([MainSection.headControl, .settings]) { section in
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
            ScratchpadSection(store: controller.scratchpad)
        case .dictionary:
            DictionarySettings(store: controller.dictionary)
        case .snippets:
            SnippetSettings(store: controller.dictionary)
        case .transforms:
            TransformSettings(store: controller.dictionary)
        case .headControl:
            HeadControlSection(controller: controller)
        case .settings:
            SettingsSection(controller: controller)
        }
    }
}

// MARK: - Home

struct HomeSection: View {
    @ObservedObject var controller: AppController
    @ObservedObject var history: HistoryStore
    @ObservedObject var stats: StatsStore

    init(controller: AppController, history: HistoryStore) {
        self.controller = controller
        self.history = history
        self.stats = controller.stats
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                hero
                statTiles
                insights
                recent
            }
            .padding(24)
            .frame(maxWidth: 720, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
    }

    // MARK: Status

    private var isRecording: Bool {
        if case .recording = controller.state { return true }
        return false
    }

    /// Short headline plus the detail line under it.
    private var status: (title: String, detail: String) {
        switch controller.asrState {
        case .notLoaded, .loading:
            return ("Loading the speech model…", "Dictation is ready in a few seconds.")
        case .downloading(let fraction):
            return ("Downloading the speech model… \(Int(fraction * 100))%", "This happens once.")
        case .failed(let message):
            return ("The speech model failed to load", message)
        case .ready:
            if !controller.micGranted { return ("Microphone access needed", "Grant it in System Settings → Privacy & Security.") }
            if !controller.axTrusted { return ("Accessibility access needed", "Grant it in System Settings → Privacy & Security.") }
            if isRecording { return ("Listening…", "Speak, then release the key or go quiet.") }
            return ("Ready", "Hold \(Prefs.hotkey.label) to dictate, quick-tap for hands-free. Everything stays on this Mac.")
        }
    }

    private var hero: some View {
        HStack(spacing: 14) {
            Image(systemName: isRecording ? "waveform.badge.mic" : "waveform")
                .font(.system(size: 26, weight: .semibold))
                .foregroundStyle(controller.isReady || isRecording ? AnyShapeStyle(Brand.gradient) : AnyShapeStyle(.orange))
                .frame(width: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text(status.title)
                    .font(.title3.weight(.semibold))
                Text(status.detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            // Drawn by hand: a tinted system button loses its label when disabled.
            Button {
                controller.toggleHandsFree()
            } label: {
                Text(isRecording ? "Stop" : "Start hands-free")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.black)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .background(.white, in: Capsule())
            }
            .buttonStyle(.plain)
            .disabled(!controller.isReady && !isRecording)
            .opacity(controller.isReady || isRecording ? 1 : 0.4)
        }
        .padding(18)
        .background(
            LinearGradient(
                colors: [Brand.blue.opacity(0.18), Brand.violet.opacity(0.18)],
                startPoint: .topLeading, endPoint: .bottomTrailing),
            in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Brand.violet.opacity(0.3)))
    }

    // MARK: Stats

    private var statTiles: some View {
        HStack(spacing: 10) {
            StatTile(value: stats.wordsThisWeek().formatted(), label: "Words this week")
            StatTile(value: stats.wordsPerMinute.map { "\($0)" } ?? "-", label: "Words per minute")
            StatTile(value: "\(stats.dayStreak())", label: "Day streak")
            StatTile(value: "\(stats.wordsLearned)", label: "Words learned")
        }
    }

    private var insights: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                SectionLabel("Last 26 weeks")
                Spacer()
                Text("\(stats.totalWords.formatted()) words in \(stats.totalDictations.formatted()) dictations")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack(alignment: .top, spacing: 24) {
                ActivityHeatmap(days: stats.lastDays(182))
                if !stats.topApps.isEmpty {
                    let most = max(1, stats.topApps.first?.words ?? 1)
                    VStack(alignment: .leading, spacing: 7) {
                        ForEach(stats.topApps, id: \.name) { app in
                            VStack(alignment: .leading, spacing: 3) {
                                HStack {
                                    Text(app.name).lineLimit(1)
                                    Spacer()
                                    Text(app.words.formatted())
                                        .foregroundStyle(.secondary)
                                        .monospacedDigit()
                                }
                                GeometryReader { geometry in
                                    Capsule()
                                        .fill(Brand.sweep)
                                        .frame(width: max(4, geometry.size.width * CGFloat(app.words) / CGFloat(most)))
                                }
                                .frame(height: 4)
                            }
                            .font(.caption)
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
            }
        }
        .padding(16)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 14))
    }

    // MARK: Recent

    private var recent: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel("Recent dictations")
            if history.entries.isEmpty {
                Text("Nothing yet - click into any text field, hold \(Prefs.hotkey.label), and speak.")
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 12)
            } else {
                VStack(spacing: 0) {
                    ForEach(history.entries.prefix(6)) { entry in
                        HStack(alignment: .firstTextBaseline, spacing: 12) {
                            Text(entry.date, format: .dateTime.hour().minute())
                                .font(.caption)
                                .monospacedDigit()
                                .foregroundStyle(.tertiary)
                                .frame(width: 58, alignment: .leading)
                            Text(entry.finalText)
                                .lineLimit(1)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            if let app = entry.appName {
                                Text(app)
                                    .font(.caption)
                                    .lineLimit(1)
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 2)
                                    .background(.quaternary, in: Capsule())
                            }
                        }
                        .padding(.vertical, 9)
                        if entry.id != history.entries.prefix(6).last?.id {
                            Divider()
                        }
                    }
                }
                .padding(.horizontal, 16)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 14))
            }
        }
    }
}

/// Small uppercase heading above a group.
struct SectionLabel: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text.uppercased())
            .font(.caption.weight(.semibold))
            .kerning(0.6)
            .foregroundStyle(.secondary)
    }
}

/// One square per day, a column per week, oldest on the left.
struct ActivityHeatmap: View {
    let days: [(date: Date, words: Int)]

    var body: some View {
        let most = max(1, days.map(\.words).max() ?? 1)
        LazyHGrid(rows: Array(repeating: GridItem(.fixed(11), spacing: 3), count: 7), spacing: 3) {
            ForEach(days, id: \.date) { day in
                RoundedRectangle(cornerRadius: 2.5)
                    .fill(day.words == 0
                        ? AnyShapeStyle(.quaternary)
                        : AnyShapeStyle(Brand.violet.opacity(0.3 + 0.7 * Double(day.words) / Double(most))))
                    .frame(width: 11, height: 11)
                    .help("\(day.date.formatted(date: .abbreviated, time: .omitted)): \(day.words) words")
            }
        }
        .frame(height: 7 * 11 + 6 * 3, alignment: .leading)
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
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 14))
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
    /// Shows what was actually said instead of the cleaned-up text.
    @State private var showOriginal = false

    private var shownText: String { showOriginal ? entry.rawText : entry.finalText }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(shownText)
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
                if entry.rawText != entry.finalText {
                    Button {
                        showOriginal.toggle()
                    } label: {
                        Image(systemName: showOriginal ? "wand.and.stars" : "arrow.uturn.backward")
                    }
                    .buttonStyle(.borderless)
                    .help(showOriginal ? "Show the cleaned-up text" : "Undo cleanup: show what was said")
                }
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(shownText, forType: .string)
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
    @ObservedObject var store: ScratchpadStore
    @State private var noonStatus: String?

    /// Looked up by id on every access: a binding into `notes[index]` can
    /// outlive the tab it pointed at.
    private var text: Binding<String> {
        Binding(
            get: { store.notes.first { $0.id == store.selected }?.text ?? "" },
            set: { new in
                if let index = store.notes.firstIndex(where: { $0.id == store.selected }) {
                    store.notes[index].text = new
                }
            })
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(store.notes) { note in
                        HStack(spacing: 4) {
                            Text(note.title)
                                .lineLimit(1)
                            Button {
                                store.close(note.id)
                            } label: {
                                Image(systemName: "xmark")
                                    .font(.caption2)
                            }
                            .buttonStyle(.borderless)
                            .help("Close note")
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(
                            note.id == store.selected ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear),
                            in: RoundedRectangle(cornerRadius: 7))
                        .contentShape(Rectangle())
                        .onTapGesture { store.selected = note.id }
                    }
                    Button {
                        store.add()
                    } label: {
                        Image(systemName: "plus")
                    }
                    .buttonStyle(.borderless)
                    .help("New note")
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
            }

            Divider()

            TextEditor(text: text)
                .font(.body)
                .padding(8)

            Divider()

            HStack(spacing: 10) {
                if let noonStatus {
                    Text(noonStatus)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if Noon.executable != nil {
                    Button("Send to Noon") {
                        let tasks = Noon.tasks(in: text.wrappedValue)
                        noonStatus = "Sending…"
                        Task {
                            let sent = await Noon.send(tasks)
                            noonStatus = sent == tasks.count
                                ? "Added \(sent) to Noon" : "Noon accepted \(sent) of \(tasks.count)"
                        }
                    }
                    .disabled(Noon.tasks(in: text.wrappedValue).isEmpty)
                    .help("Adds each line of this note to Noon as a to-do")
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
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
            }
            .frame(maxWidth: 560, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
    }
}

// MARK: - Head control

struct HeadControlSection: View {
    @ObservedObject var controller: AppController

    var body: some View {
        ScrollView {
            GazeSettings(controller: controller)
                .frame(maxWidth: 560, alignment: .leading)
                .frame(maxWidth: .infinity)
        }
    }
}
