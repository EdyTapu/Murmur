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

    private struct FileModel: Codable {
        var terms: [DictionaryTerm]
        var snippets: [Snippet]
    }

    private let fileURL: URL

    init(directory: URL = AppSupport.directory) {
        fileURL = directory.appendingPathComponent("dictionary.json")
        load()
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
            let model = try? JSONDecoder().decode(FileModel.self, from: data)
        else { return }
        terms = model.terms
        snippets = model.snippets
    }

    private func save() {
        let model = FileModel(terms: terms, snippets: snippets)
        do {
            let data = try JSONEncoder().encode(model)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            log.error("Failed to save dictionary: \(error.localizedDescription, privacy: .public)")
        }
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
