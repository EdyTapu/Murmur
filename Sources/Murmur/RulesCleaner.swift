import Foundation

/// Deterministic, zero-latency cleanup applied to every transcript:
/// filler-word removal, trailing spoken commands, whitespace repair.
/// Pure functions so this layer is unit-testable.
enum RulesCleaner {

    struct Output: Equatable {
        var text: String
        /// True when the utterance was a "scratch that" style cancel.
        var cancelled: Bool = false
        /// True when the user asked for a trailing newline ("new line" at the end).
        var trailingNewlines: Int = 0
    }

    private static let fillerPattern = #"(?i)(?<![\w'])(?:um+|uh+|uhm+|erm+|mmm+|hmm+)(?![\w'])[,.]?"#

    /// Whole-utterance commands that cancel the dictation.
    private static let cancelPhrases: Set<String> = [
        "scratch that", "cancel", "cancel that", "never mind", "nevermind",
    ]

    static func clean(_ raw: String, removeFillers: Bool) -> Output {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return Output(text: "") }

        // Whole-utterance cancel ("scratch that", possibly with punctuation).
        if cancelPhrases.contains(normalizedPhrase(text)) {
            return Output(text: "", cancelled: true)
        }

        // Utterance ending in "scratch that" cancels the whole dictation
        // (Wispr collapses to the correction; without word-level edit tracking,
        // dropping the dictation is the honest deterministic behavior).
        if normalizedPhrase(text).hasSuffix(" scratch that") {
            return Output(text: "", cancelled: true)
        }

        if removeFillers {
            text = text.replacingOccurrences(
                of: fillerPattern, with: "", options: .regularExpression)
        }

        // Trailing "new line" / "new paragraph" commands.
        var trailingNewlines = 0
        while true {
            let norm = normalizedPhrase(text)
            if norm.hasSuffix(" new paragraph") || norm == "new paragraph" {
                text = stripSuffixPhrase(text, wordCount: 2)
                trailingNewlines = max(trailingNewlines, 2)
            } else if norm.hasSuffix(" new line") || norm == "new line" {
                text = stripSuffixPhrase(text, wordCount: 2)
                trailingNewlines = max(trailingNewlines, 1)
            } else {
                break
            }
        }

        text = repairWhitespace(text)
        return Output(text: text, cancelled: false, trailingNewlines: trailingNewlines)
    }

    /// Lowercase, strip punctuation, collapse whitespace - for phrase matching.
    static func normalizedPhrase(_ s: String) -> String {
        let lowered = s.lowercased()
        let stripped = lowered.unicodeScalars.map { scalar -> Character in
            if CharacterSet.punctuationCharacters.contains(scalar) { return " " }
            return Character(scalar)
        }
        return String(stripped)
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    /// Remove the last `wordCount` words (plus trailing punctuation) from the text.
    private static func stripSuffixPhrase(_ s: String, wordCount: Int) -> String {
        var words = s.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }
        words.removeLast(min(wordCount, words.count))
        return words.joined(separator: " ")
    }

    /// Collapse doubled spaces / stray punctuation gaps left by removals,
    /// and capitalize the first letter.
    static func repairWhitespace(_ s: String) -> String {
        var text = s
        text = text.replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)
        text = text.replacingOccurrences(of: #"\s+([,.!?;:])"#, with: "$1", options: .regularExpression)
        text = text.replacingOccurrences(of: #"^[\s,.;:]+"#, with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: #"([,.!?;:]){2,}"#, with: "$1", options: .regularExpression)
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let first = text.first, first.isLowercase {
            text = first.uppercased() + text.dropFirst()
        }
        return text
    }
}
