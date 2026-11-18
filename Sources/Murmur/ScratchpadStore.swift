import Foundation

struct ScratchNote: Codable, Identifiable, Equatable {
    var id = UUID()
    var text = ""

    /// Tab label: the note's first line.
    var title: String {
        let line = text.split(whereSeparator: \.isNewline).first.map(String.init)?
            .trimmingCharacters(in: .whitespaces) ?? ""
        return line.isEmpty ? "New note" : String(line.prefix(24))
    }
}

/// The scratchpad's notes, one per tab, persisted as JSON in Application Support.
@MainActor
final class ScratchpadStore: ObservableObject {
    @Published var notes: [ScratchNote] {
        didSet { saveDebounced() }
    }
    @Published var selected: UUID

    private let fileURL: URL
    private var saveTask: Task<Void, Never>?

    init(directory: URL = AppSupport.directory) {
        fileURL = directory.appendingPathComponent("scratchpad.json")
        let loaded: [ScratchNote]
        if let data = try? Data(contentsOf: fileURL),
            let saved = try? JSONDecoder().decode([ScratchNote].self, from: data), !saved.isEmpty {
            loaded = saved
        } else {
            // The single plain-text scratchpad this replaced becomes the first note.
            let legacy = try? String(contentsOf: directory.appendingPathComponent("scratchpad.txt"), encoding: .utf8)
            loaded = [ScratchNote(text: legacy ?? "")]
        }
        notes = loaded
        selected = loaded[0].id
    }

    func add() {
        let note = ScratchNote()
        notes.append(note)
        selected = note.id
    }

    func close(_ id: UUID) {
        notes.removeAll { $0.id == id }
        if notes.isEmpty { notes = [ScratchNote()] }
        if !notes.contains(where: { $0.id == selected }) { selected = notes[notes.count - 1].id }
    }

    private func saveDebounced() {
        saveTask?.cancel()
        let snapshot = notes
        let url = fileURL
        saveTask = Task {
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            try? JSONEncoder().encode(snapshot).write(to: url, options: .atomic)
        }
    }
}

/// Hands scratchpad lines to the Noon day planner through its CLI.
enum Noon {
    static let executable: URL? = [
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/noon").path,
        "/opt/homebrew/bin/noon", "/usr/local/bin/noon",
    ].first(where: FileManager.default.isExecutableFile(atPath:)).map(URL.init(fileURLWithPath:))

    /// One to-do per non-empty line, without list markers ("- ", "1. ", "[ ] ").
    static func tasks(in text: String) -> [String] {
        text.split(whereSeparator: \.isNewline).compactMap { line in
            let task = line.replacingOccurrences(
                of: #"^\s*(?:[-*•]\s+|\d+[.)]\s+)?(?:\[[ xX]?\]\s*)?"#, with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespaces)
            return task.isEmpty ? nil : task
        }
    }

    /// Adds each task with `noon task`; returns how many Noon accepted.
    static func send(_ tasks: [String]) async -> Int {
        guard let executable else { return 0 }
        return await Task.detached {
            tasks.filter { task in
                let process = Process()
                process.executableURL = executable
                // Passed as an argument, never through a shell.
                process.arguments = ["task", task]
                process.standardOutput = FileHandle.nullDevice
                process.standardError = FileHandle.nullDevice
                guard (try? process.run()) != nil else { return false }
                process.waitUntilExit()
                return process.terminationStatus == 0
            }.count
        }.value
    }
}
