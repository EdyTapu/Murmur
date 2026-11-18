import Foundation
import os

struct DictionaryTerm: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    /// The correct spelling to produce (e.g. "Rojo", "OPT(ML)", "Luau").
    var canonical: String
    /// Misrecognitions to replace, e.g. ["row joe", "roho"]. Matched whole-word, case-insensitive.
    var aliases: [String] = []
}

struct Snippet: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    /// Spoken trigger phrase, matched against the whole utterance (e.g. "insert my email").
    var trigger: String
    var expansion: String
}

/// A reusable rewrite of the selected text, run from the Transforms shortcut.
struct Transform: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var name: String
    var prompt: String

    static let builtIn = [
        Transform(name: "Polish", prompt: "Fix grammar, spelling and punctuation and make it read cleanly. Keep the meaning, tone and length."),
        Transform(name: "Prompt Engineer", prompt: "Rewrite this as a clear, specific prompt for an AI assistant: state the goal, the context and the expected output."),
    ]
}

/// Personal dictionary + snippets, persisted as JSON in Application Support.
@MainActor
final class DictionaryStore: ObservableObject {
    private let log = Logger(subsystem: "com.alessio.murmur", category: "dictionary")

    @Published var terms: [DictionaryTerm] = [] {
        didSet { save() }
    }
    @Published var snippets: [Snippet] = [] {
        didSet { save() }
    }

    @Published var transforms: [Transform] = Transform.builtIn {
        didSet { save() }
    }

    private struct FileModel: Codable {
        var terms: [DictionaryTerm]
        var snippets: [Snippet]
        /// Absent in files written before transforms existed.
        var transforms: [Transform]?
    }

    private var fileURL: URL
    /// Modification date of the file as last read or written, to spot another Mac's edit.
    private var syncedAt: Date?
    private var loading = false
    /// False while the file exists but could not be read (not downloaded from
    /// iCloud yet, or damaged). Saving then would replace it with less.
    private var readable = true

    init(directory: URL = Prefs.syncFolder ?? AppSupport.directory) {
        fileURL = directory.appendingPathComponent("dictionary.json")
        load()
    }

    /// Move the dictionary to `directory` (nil = back to this Mac only).
    /// Entries already in the destination are kept and local ones are added to them.
    func relocate(to directory: URL?) {
        let local = (terms, snippets, transforms)
        fileURL = (directory ?? AppSupport.directory).appendingPathComponent("dictionary.json")
        syncedAt = nil
        load()
        loading = true
        for mine in local.0 {
            if let index = terms.firstIndex(where: { $0.canonical == mine.canonical }) {
                terms[index].aliases += mine.aliases.filter { !terms[index].aliases.contains($0) }
            } else {
                terms.append(mine)
            }
        }
        snippets += local.1.filter { mine in !snippets.contains { $0.trigger == mine.trigger } }
        transforms += local.2.filter { mine in !transforms.contains { $0.name == mine.name } }
        loading = false
        save()
    }

    /// Pick up edits made on another Mac. Cheap enough to call before every dictation.
    func reloadIfChanged() {
        if !readable || modificationDate() != syncedAt { load() }
    }

    private func modificationDate() -> Date? {
        // Not URL.resourceValues: a URL caches them, which would hide another Mac's edit.
        (try? FileManager.default.attributesOfItem(atPath: fileURL.path))?[.modificationDate] as? Date
    }

    private func load() {
        // An iCloud file that is not downloaded blocks the reader until it
        // arrives; ask for it and read it on a later call instead.
        var fresh = fileURL
        fresh.removeAllCachedResourceValues()
        let status = (try? fresh.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey]))?
            .ubiquitousItemDownloadingStatus
        if status == .notDownloaded {
            try? FileManager.default.startDownloadingUbiquitousItem(at: fileURL)
            readable = false
            return
        }
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            readable = true  // nothing there to lose
            return
        }
        guard let data = try? Data(contentsOf: fileURL),
            let model = try? JSONDecoder().decode(FileModel.self, from: data)
        else {
            readable = false
            log.error("Dictionary file could not be read; not overwriting it")
            return
        }
        readable = true
        loading = true
        terms = model.terms
        snippets = model.snippets
        transforms = model.transforms ?? Transform.builtIn
        loading = false
        syncedAt = modificationDate()
    }

    private func save() {
        // Loading must not write back: two Macs would rewrite the file at each other forever.
        guard !loading else { return }
        guard readable else {
            // Try again; once the file can be read its entries are merged on the next relocate/reload.
            log.warning("Dictionary change not saved: the file is not readable yet")
            return
        }
        let model = FileModel(terms: terms, snippets: snippets, transforms: transforms)
        do {
            let data = try JSONEncoder().encode(model)
            try data.write(to: fileURL, options: .atomic)
            syncedAt = modificationDate()
        } catch {
            log.error("Failed to save dictionary: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Record a fix the user made by hand: `heard` now always becomes `corrected`.
    func learn(heard: String, corrected: String) {
        reloadIfChanged()
        var updated = terms
        for i in updated.indices {
            updated[i].aliases.removeAll { $0.caseInsensitiveCompare(heard) == .orderedSame }
        }
        if let i = updated.firstIndex(where: { $0.canonical == corrected }) {
            updated[i].aliases.append(heard)
        } else {
            updated.append(DictionaryTerm(canonical: corrected, aliases: [heard]))
        }
        terms = updated
    }

    // MARK: - Application

    /// Apply snippets (whole-utterance trigger match) and dictionary substitutions.
    nonisolated static func apply(
        _ text: String, terms: [DictionaryTerm], snippets: [Snippet]
    ) -> String {
        let normalized = RulesCleaner.normalizedPhrase(text)
        for snippet in snippets {
            if normalized == RulesCleaner.normalizedPhrase(snippet.trigger) {
                return snippet.expansion
            }
        }
        var result = text
        for term in terms {
            for alias in term.aliases where !alias.isEmpty {
                let pattern = "(?i)\\b" + NSRegularExpression.escapedPattern(for: alias) + "\\b"
                result = result.replacingOccurrences(
                    of: pattern, with: term.canonical, options: .regularExpression)
            }
        }
        return result
    }
}

enum AppSupport {
    static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first!
            .appendingPathComponent("Murmur", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }
}
