import AppKit
import ApplicationServices
import Foundation

/// Learns dictionary entries from the user's own fixes: after a dictation is
/// inserted, the text field is watched, and a misheard word the user retypes
/// becomes an alias → canonical dictionary term.
enum CorrectionLearner {
    struct Correction: Equatable {
        var heard: String
        var corrected: String
    }

    /// The spelling fixes that turned `baseline` (the field right after the
    /// dictation landed) into `current`, limited to words of `inserted`.
    /// Rewrites, ordinary-word swaps and edits elsewhere in the field are ignored.
    static func corrections(
        inserted: String, baseline: String, current: String, isKnownWord: (String) -> Bool
    ) -> [Correction] {
        let old = Array(baseline), new = Array(current)
        var prefix = 0
        while prefix < min(old.count, new.count), old[prefix] == new[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < min(old.count, new.count) - prefix,
            old[old.count - 1 - suffix] == new[new.count - 1 - suffix] { suffix += 1 }
        // Grow the changed span to whole words.
        while prefix > 0, !old[prefix - 1].isWhitespace { prefix -= 1 }
        while suffix > 0, !old[old.count - suffix].isWhitespace { suffix -= 1 }

        let oldWords = String(old[prefix..<old.count - suffix]).split(whereSeparator: \.isWhitespace)
        let newWords = String(new[prefix..<new.count - suffix]).split(whereSeparator: \.isWhitespace)
        // A span this large is a rewrite (or a cleared field), not a spelling fix.
        guard oldWords.count <= 40, newWords.count <= 40 else { return [] }

        var removed = Set<Int>(), added = Set<Int>()
        // Punctuation typed next to a word is not a change to the word.
        let bare = { (word: Substring) in word.trimmingCharacters(in: .punctuationCharacters) }
        for change in newWords.difference(from: oldWords, by: { bare($0) == bare($1) }) {
            switch change {
            case .remove(let offset, _, _): removed.insert(offset)
            case .insert(let offset, _, _): added.insert(offset)
            }
        }

        let dictated = inserted.lowercased()
        var found: [Correction] = []
        var i = 0, j = 0
        while i < oldWords.count || j < newWords.count {
            var heardWords: [Substring] = [], correctedWords: [Substring] = []
            while removed.contains(i) { heardWords.append(oldWords[i]); i += 1 }
            while added.contains(j) { correctedWords.append(newWords[j]); j += 1 }
            if heardWords.isEmpty, correctedWords.isEmpty {
                i += 1
                j += 1
                continue
            }
            guard (1...3).contains(heardWords.count), (1...3).contains(correctedWords.count) else { continue }
            let heard = heardWords.joined(separator: " ").trimmingCharacters(in: .punctuationCharacters)
            let corrected = correctedWords.joined(separator: " ").trimmingCharacters(in: .punctuationCharacters)
            guard !heard.isEmpty, !corrected.isEmpty, heard != corrected,
                dictated.contains(heard.lowercased()),
                // Only names and jargon are worth remembering, and a plain word
                // must never become an alias: "their" → "there" would then
                // rewrite every "their".
                !correctedWords.allSatisfy({ isKnownWord(String($0)) }),
                !(heardWords.count == 1 && isKnownWord(heard)),
                soundsAlike(heard, corrected)
            else { continue }
            found.append(Correction(heard: heard, corrected: corrected))
        }
        return found
    }

    /// A misrecognition resembles what was said; a reworded phrase does not.
    static func soundsAlike(_ a: String, _ b: String) -> Bool {
        let x = Array(a.lowercased().filter { $0.isLetter || $0.isNumber })
        let y = Array(b.lowercased().filter { $0.isLetter || $0.isNumber })
        guard !x.isEmpty, !y.isEmpty else { return false }
        return distance(x, y) * 2 <= max(x.count, y.count)
    }

    /// Levenshtein distance, two rows.
    static func distance(_ x: [Character], _ y: [Character]) -> Int {
        var previous = Array(0...y.count)
        for (r, cx) in x.enumerated() {
            var row = [r + 1]
            for (c, cy) in y.enumerated() {
                row.append(min(previous[c] + (cx == cy ? 0 : 1), previous[c + 1] + 1, row[c] + 1))
            }
            previous = row
        }
        return previous[y.count]
    }
}

/// Polls the text field a dictation was inserted into and reports the
/// corrections the user made there. Works wherever the field's value is
/// readable over Accessibility; elsewhere (terminals) it silently does nothing.
@MainActor
final class CorrectionWatcher {
    var onLearn: (([CorrectionLearner.Correction]) -> Void)?
    private var task: Task<Void, Never>?

    /// Start watching the focused field. Call right after a successful insertion.
    func watch(inserted: String, in element: AXUIElement?, read: @escaping (AXUIElement) -> String?) {
        stop()
        let target = inserted.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let element, !target.isEmpty, let baseline = read(element),
            baseline.utf16.count < 200_000, baseline.contains(target)
        else { return }

        // A hung app must not stall Murmur's main thread on every poll.
        AXUIElementSetMessagingTimeout(element, 0.2)

        task = Task { [weak self] in
            var candidate: [CorrectionLearner.Correction] = []
            var reported: [CorrectionLearner.Correction] = []
            var stablePolls = 0
            // 60 s is enough to fix a word; watching longer risks reading unrelated edits.
            for _ in 0..<240 {
                try? await Task.sleep(for: .milliseconds(250))
                guard !Task.isCancelled, let current = read(element) else { break }
                // An emptied field means the message was sent; what was there last stands.
                if current.allSatisfy(\.isWhitespace) { break }
                let found = CorrectionLearner.corrections(
                    inserted: target, baseline: baseline, current: current,
                    isKnownWord: { NSSpellChecker.shared.checkSpelling(of: $0, startingAt: 0).location == NSNotFound })
                // A half-typed word ("Robl" on the way to "Roblox") never settles, so it is never learned.
                stablePolls = found == candidate ? stablePolls + 1 : 0
                candidate = found
                if stablePolls >= 6, candidate != reported {
                    self?.onLearn?(candidate.filter { !reported.contains($0) })
                    reported = candidate
                }
            }
            // Sent or superseded: a fix that had settled for half a second counts.
            if stablePolls >= 2, candidate != reported {
                self?.onLearn?(candidate.filter { !reported.contains($0) })
            }
        }
    }

    /// End the current watch; a fix that had settled is still reported.
    func stop() {
        task?.cancel()
        task = nil
    }
}
