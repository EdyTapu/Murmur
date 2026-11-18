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
    /// Seconds of audio; absent on entries from before it was recorded.
    var duration: Double?
}

/// Every dictation is saved here, whether or not insertion succeeded -
/// the Wispr-style "nothing is ever lost" guarantee.
@MainActor
final class HistoryStore: ObservableObject {
    private let log = Logger(subsystem: "com.alessio.murmur", category: "history")
    private static let cap = 1000

    @Published private(set) var entries: [HistoryEntry] = []

    private let fileURL: URL

    init(directory: URL = AppSupport.directory) {
        fileURL = directory.appendingPathComponent("history.json")
        load()
    }

    func add(_ entry: HistoryEntry) {
        guard Prefs.historyRetention != .never else { return }
        entries.insert(entry, at: 0)
        prune()
        if entries.count > Self.cap {
            entries.removeLast(entries.count - Self.cap)
        }
        save()
    }

    /// Apply the retention setting to what is already stored.
    func prune() {
        let before = entries.count
        switch Prefs.historyRetention {
        case .forever: break
        case .day: entries.removeAll { $0.date < Date().addingTimeInterval(-86_400) }
        case .never: break  // stops new entries; what is already there stays until cleared
        }
        if entries.count != before { save() }
    }

    func clear() {
        entries.removeAll()
        save()
    }

    private func load() {
        if let data = try? Data(contentsOf: fileURL),
            let decoded = try? JSONDecoder().decode([HistoryEntry].self, from: data) {
            entries = decoded
            prune()
        }
    }

    private func save() {
        do {
            let data = try JSONEncoder().encode(entries)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            log.error("Failed to save history: \(error.localizedDescription, privacy: .public)")
        }
    }
}
