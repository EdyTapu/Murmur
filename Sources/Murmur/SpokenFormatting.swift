import Foundation

// Deterministic, on-device formatting of what was said. Every pattern here was
// written against real Parakeet output (see Tests), which already punctuates
// and writes numbers as digits: "Let's meet at 2, actually 3 on Friday."

private func regex(_ pattern: String) -> NSRegularExpression {
    // Patterns are compile-time constants; a bad one is a programmer error.
    try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
}

private func words(_ s: String) -> [Substring] { s.split(whereSeparator: \.isWhitespace) }

private func bare(_ word: Substring) -> String {
    word.lowercased().trimmingCharacters(in: .punctuationCharacters)
}

private func capitalizedFirst(_ s: String) -> String {
    guard let first = s.first, first.isLowercase else { return s }
    return first.uppercased() + s.dropFirst()
}

// MARK: - Backtrack

/// Keeps only the corrected version when the speaker changes their mind:
/// "at 2, actually 3" → "at 3"; "to John? No, wait, send it to Jane" → "send it to Jane".
enum Backtrack {
    // Parakeet writes spoken numbers as digits; number words are left out
    // because "one" is usually a pronoun ("a good one, actually one more thing").
    private static let number = #"\d[\d:.]*"#
    /// "actually" is usually not a correction ("that's actually good"), so it
    /// only counts between two numbers of the same sentence.
    private static let numberFix = regex(
        #"\b"# + number + #"(?:\s?[ap]\.?m\.?)?,?\s+actually,?\s+(?:make (?:it|that)\s+)?("# + number + #")"#)
    /// A correction is said after a pause, which Parakeet writes as punctuation.
    /// Without that requirement these are ordinary words: "is there no wait
    /// time", "don't scratch that itch".
    private static let marker = regex(
        #"\s*[,;.?!…-]+\s*(scratch that|no,? wait|wait,? no|or rather)\b[,;:.]?\s*"#)

    static func apply(_ text: String) -> String {
        var text = numberFix.stringByReplacingMatches(
            in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "$1")
        // Each pass resolves the first marker; a handful is plenty for one dictation.
        for _ in 0..<5 {
            guard let match = marker.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
                let whole = Range(match.range, in: text), let phrase = Range(match.range(at: 1), in: text)
            else { break }
            let before = String(text[..<whole.lowerBound])
            let after = String(text[whole.upperBound...])
            // Nothing to correct, or nothing to correct it with: leave the words alone.
            guard !before.isEmpty, !after.isEmpty else { break }

            // Only the sentence being corrected is in scope.
            let sentenceStart = before.range(of: #"[.!?]\s+"#, options: [.regularExpression, .backwards])?.upperBound
                ?? before.startIndex
            let kept = String(before[..<sentenceStart])
            let scope = words(String(before[sentenceStart...]))
            let correctionEnd = after.range(of: #"[.!?](\s|$)"#, options: .regularExpression)?.lowerBound ?? after.endIndex
            let correction = words(String(after[..<correctionEnd]))

            var keep = 0
            if !text[phrase].lowercased().hasPrefix("scratch"), let first = correction.first {
                // "send it to John, no wait, send it to Jane": restart where the
                // correction's first word was last said. Otherwise swap the same
                // number of trailing words: "Tuesday, no wait, Wednesday".
                keep = correction.count > 1
                    ? scope.lastIndex { bare($0) == bare(first) } ?? max(0, scope.count - correction.count)
                    : max(0, scope.count - 1)
            }
            let head = (kept + scope[..<keep].joined(separator: " ")).trimmingCharacters(in: .whitespaces)
            text = head.isEmpty ? capitalizedFirst(after) : head + " " + after
        }
        return text
    }
}

// MARK: - Spoken punctuation

/// "Hello comma? How are you question mark?" → "Hello, how are you?"
enum SpokenPunctuation {
    // Parakeet adds its own mark after a spoken one ("comma?"), so the pattern
    // swallows punctuation on both sides.
    private static let closers: [(NSRegularExpression, String)] = [
        ("question mark", "?"), ("exclamation (?:point|mark)", "!"), ("semicolon", ";"),
        ("close (?:parenthesis|paren)", ")"), ("(?:close|end) quote", "\u{201D}"),
    ].map { (regex(#"\s*[,.?!]?\s*\b"# + $0.0 + #"\b[,.?!]?"#), $0.1) }
    private static let openers: [(NSRegularExpression, String)] = [
        ("open (?:parenthesis|paren)", " ("), ("open quote", " \u{201C}"),
    ].map { (regex(#"\s*[,.?!]?\s*\b"# + $0.0 + #"\b[,.?!]?\s*"#), $0.1) }
    // "period", "colon" and "full stop" are deliberately absent: they end
    // ordinary sentences ("a difficult period.") and Parakeet already
    // punctuates sentence ends on its own.
    // shortcut: "comma" only counts when a pause follows, so "add a comma."
    // still loses the word; upgrade to an LLM pass if that bites.
    private static let ambiguous: [(NSRegularExpression, String)] = [
        ("comma", ","),
    ].map { (regex(#"\s*[,.?!]?\s*\b"# + $0.0 + #"\b(?:[,.?!]|\s*$)"#), $0.1) }
    private static let sentenceStart = regex(#"([.?!]\s+)(\p{Ll})"#)

    static func apply(_ text: String) -> String {
        var text = text
        for (pattern, mark) in closers + openers + ambiguous {
            text = pattern.stringByReplacingMatches(
                in: text, range: NSRange(text.startIndex..., in: text),
                withTemplate: NSRegularExpression.escapedTemplate(for: mark))
        }
        // A mark we just placed may have started a new sentence.
        for match in sentenceStart.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed() {
            guard let letter = Range(match.range(at: 2), in: text) else { continue }
            text.replaceSubrange(letter, with: text[letter].uppercased())
        }
        return text.trimmingCharacters(in: .whitespaces)
    }
}

// MARK: - Lists

/// "One, buy milk. Two, call mom." → a numbered list; "bullet point apples
/// bullet point bread" → a bulleted list.
enum ListFormatter {
    private static let numberWords = ["one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten"]
    private static let numberPattern = #"(\d{1,2}|"# + numberWords.joined(separator: "|") + ")"
    /// "number one, buy milk" anywhere, or "One, buy milk" opening a sentence.
    /// The pause after the number is what makes it a list marker: "my number
    /// one priority" and "one apple and two pears" are just words.
    private static let numbered = regex(
        #"(?:\bnumber\s+"# + numberPattern + #"[,.:]\s+|(?:^|(?<=[.!?:])\s+)"# + numberPattern + #"[,.:]\s+)"#)
    /// Not after a word that makes it a noun ("the first bullet point is…").
    private static let bullet = regex(
        #"\s*(?<!\b(?:the|a|an|this|that|each|every|first|second|third|last|next|one|another|my|your|our)\s)\bbullet(?:\s+point)?\b[,.:]?\s+"#)

    static func apply(_ text: String) -> String {
        let all = NSRange(text.startIndex..., in: text)
        let numberedMatches = numbered.matches(in: text, range: all)
        let values = numberedMatches.map { match -> Int in
            let group = match.range(at: 1).location != NSNotFound ? match.range(at: 1) : match.range(at: 2)
            let token = (text as NSString).substring(with: group).lowercased()
            return Int(token) ?? (numberWords.firstIndex(of: token) ?? -2) + 1
        }
        // Only a run that counts 1, 2, 3… is a list.
        if values.count >= 2, values == Array(1...values.count) {
            return build(text, markers: numberedMatches.map(\.range)) { "\($0 + 1). " }
        }
        let bullets = bullet.matches(in: text, range: all)
        if bullets.count >= 2 {
            return build(text, markers: bullets.map(\.range)) { _ in "- " }
        }
        return text
    }

    private static func build(_ text: String, markers: [NSRange], prefix: (Int) -> String) -> String {
        let ns = text as NSString
        var lines: [String] = []
        let intro = ns.substring(to: markers[0].location).trimmingCharacters(in: .whitespaces)
        if !intro.isEmpty { lines.append(intro.last?.isPunctuation == true ? intro : intro + ":") }
        for (index, marker) in markers.enumerated() {
            let end = index + 1 < markers.count ? markers[index + 1].location : ns.length
            let item = ns.substring(with: NSRange(location: NSMaxRange(marker), length: end - NSMaxRange(marker)))
                .trimmingCharacters(in: CharacterSet(charactersIn: " ,.;"))
            lines.append(prefix(index) + capitalizedFirst(item))
        }
        return lines.joined(separator: "\n")
    }
}

// MARK: - Code casing

/// Spoken casing commands: "snake case user id" → "user_id",
/// "camel case get user name" → "getUserName".
enum CodeCase {
    private static let command = regex(#"\b(snake|camel|pascal|kebab|constant)[ -]?case\b[,:]?\s+"#)
    /// Words that end the identifier: "snake case user id to 5" names `user_id`, not `user_id_to_5`.
    private static let stopWords: Set<String> = [
        "to", "is", "equals", "and", "or", "in", "for", "with", "from", "of", "as", "then", "the", "a",
    ]

    private static let token = regex(#"[\p{L}\p{N}]+"#)

    static func apply(_ text: String) -> String {
        var text = text
        // Right to left, so earlier ranges stay valid as later ones are rewritten.
        for match in command.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed() {
            guard let whole = Range(match.range, in: text), let style = Range(match.range(at: 1), in: text)
            else { continue }
            var parts: [String] = []
            var end = whole.upperBound
            for found in token.matches(in: text, range: NSRange(whole.upperBound..., in: text)) {
                guard parts.count < 4, let range = Range(found.range, in: text) else { break }
                // Punctuation between words ends the identifier.
                // "use snake case for the column names" talks about the style; it names nothing.
                guard text[end..<range.lowerBound].allSatisfy(\.isWhitespace),
                    !stopWords.contains(text[range].lowercased())
                else { break }
                parts.append(String(text[range]))
                end = range.upperBound
            }
            guard !parts.isEmpty else { continue }
            let identifier: String
            // Already cased by the recognizer ("camelcase getUsername"): keep it.
            if parts.count == 1, parts[0].range(of: #"\p{Ll}\p{Lu}"#, options: .regularExpression) != nil {
                identifier = parts[0]
            } else {
                let lower = parts.map { $0.lowercased() }
                switch text[style].lowercased() {
                case "snake": identifier = lower.joined(separator: "_")
                case "kebab": identifier = lower.joined(separator: "-")
                case "constant": identifier = lower.joined(separator: "_").uppercased()
                case "pascal": identifier = lower.map(\.capitalized).joined()
                default: identifier = lower[0] + lower.dropFirst().map(\.capitalized).joined()
                }
            }
            text.replaceSubrange(whole.lowerBound..<end, with: identifier)
        }
        return text
    }
}
