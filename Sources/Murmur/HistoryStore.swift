import Foundation
import os

struct HistoryEntry: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var date: Date = Date()
    var rawText: String
    var finalText: String
    var appName: String?
    var appBundleID: String?
    /// "ax", "paste", "applescript", or "history-only:<reason>"
    var outcome: String
}

/// Every dictation is saved here, whether or not insertion succeeded -
/// the Wispr-style "nothing is ever lost" guarantee.
@MainActor
final class HistoryStore: ObservableObject {
    private let log = Logger(subsystem: "com.alessio.murmur", category: "history")
    private static let cap = 1000

    @Published private(set) var entries: [HistoryEntry] = []
    @Published var scratchpad: String = "" {
        didSet { saveScratchpadDebounced() }
    }

    private let fileURL: URL
    private let scratchpadURL: URL
    private var scratchpadTask: Task<Void, Never>?

    init(directory: URL = AppSupport.directory) {
        fileURL = directory.appendingPathComponent("history.json")
        scratchpadURL = directory.appendingPathComponent("scratchpad.txt")
        load()
    }

    func add(_ entry: HistoryEntry) {
        entries.insert(entry, at: 0)
        if entries.count > Self.cap {
            entries.removeLast(entries.count - Self.cap)
        }
        save()
    }

    func clear() {
        entries.removeAll()
        save()
    }

    private func load() {
        if let data = try? Data(contentsOf: fileURL),
            let decoded = try? JSONDecoder().decode([HistoryEntry].self, from: data) {
            entries = decoded
        }
        scratchpad = (try? String(contentsOf: scratchpadURL, encoding: .utf8)) ?? ""
    }

    private func save() {
        do {
            let data = try JSONEncoder().encode(entries)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            log.error("Failed to save history: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func saveScratchpadDebounced() {
        scratchpadTask?.cancel()
        let text = scratchpad
        let url = scratchpadURL
        scratchpadTask = Task {
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            try? text.write(to: url, atomically: true, encoding: .utf8)
        }
    }
}
