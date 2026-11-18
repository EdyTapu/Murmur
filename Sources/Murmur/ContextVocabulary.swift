import ApplicationServices
import Foundation

/// Context awareness: names and identifiers visible in the app being dictated
/// into are used to spell the transcript the same way ("user id" → `userId`,
/// "Kaitlyn" → "Caitlin"). Read locally for one dictation and never stored.
enum ContextVocabulary {
    private static let token = try! NSRegularExpression(pattern: #"[\p{L}\p{N}_]+(?:\.[\p{L}\p{N}_]+)*"#)

    /// The words in `context` worth matching: identifiers (camelCase,
    /// snake_case, dotted) and proper nouns.
    static func terms(in context: String, isKnownWord: (String) -> Bool) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for match in token.matches(in: context, range: NSRange(context.startIndex..., in: context)) {
            guard result.count < 150, let range = Range(match.range, in: context) else { break }
            let word = String(context[range])
            guard word.count >= 3, word.contains(where: \.isLetter), !seen.contains(word) else { continue }
            let codeLike = word.contains("_") || word.contains(".")
                || word.range(of: #"\p{Ll}\p{Lu}"#, options: .regularExpression) != nil
            // A capitalized word that is not a word in lowercase is a name;
            // that also drops ordinary words that merely start a sentence.
            let name = word.first?.isUppercase == true && !isKnownWord(word.lowercased())
            if codeLike || name {
                seen.insert(word)
                result.append(word)
            }
        }
        return result
    }

    private static func key(_ s: some StringProtocol) -> String {
        s.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    /// Rewrite transcript words that are a context term said aloud.
    static func apply(_ text: String, terms: [String], isKnownWord: (String) -> Bool) -> String {
        guard !terms.isEmpty else { return text }
        var byKey: [String: String] = [:]
        for term in terms where key(term).count >= 4 { byKey[key(term)] = byKey[key(term)] ?? term }
        let names = terms.filter { $0.first?.isUppercase == true && $0.allSatisfy(\.isLetter) }

        var words = text.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        var index = 0
        while index < words.count {
            // Longest run first: "get user name" is `getUserName`, not `get` + `userName`.
            for length in stride(from: min(4, words.count - index), through: 1, by: -1) {
                let run = words[index..<index + length]
                let core = run.joined(separator: " ").trimmingCharacters(in: .punctuationCharacters)
                // A name the spell checker knows is already a real name ("Maria" is not a misheard "Mario").
                guard let term = byKey[key(core)]
                        ?? (length == 1 && !isKnownWord(core) ? nearName(core, in: names) : nil),
                    term != core, !core.isEmpty
                else { continue }
                let joined = run.joined(separator: " ")
                words.replaceSubrange(index..<index + length, with: [joined.replacingOccurrences(of: core, with: term)])
                break
            }
            index += 1
        }
        return words.joined(separator: " ")
    }

    /// A transcribed name within a couple of letters of a name on screen.
    private static func nearName(_ word: String, in names: [String]) -> String? {
        guard word.count >= 5, word.first?.isUppercase == true, word.allSatisfy(\.isLetter) else { return nil }
        let w = Array(word.lowercased())
        return names.first { name in
            let n = Array(name.lowercased())
            guard abs(n.count - w.count) <= 1, n != w else { return false }
            let distance = CorrectionLearner.distance(w, n)
            return distance <= 2 && distance * 10 <= max(w.count, n.count) * 3
        }
    }

    // MARK: - Reading the screen

    /// Text the user can see in the frontmost app: the focused field around
    /// the cursor, the window title and nearby labels. Bounded in size and
    /// time, and safe to call off the main thread.
    static func visibleText(pid: pid_t) -> String {
        // Never our own windows: Accessibility calls to one's own process run
        // in-process on the calling thread, so this would touch SwiftUI off
        // the main thread. That threw inside AppKit and left SwiftUI's lock
        // held, freezing the app at its next interface update.
        guard pid != ProcessInfo.processInfo.processIdentifier else { return "" }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.2)
        func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
            var value: CFTypeRef?
            return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
        }
        var parts: [String] = []
        if let focused = attribute(app, kAXFocusedUIElementAttribute), CFGetTypeID(focused) == AXUIElementGetTypeID(),
            let value = attribute(focused as! AXUIElement, kAXValueAttribute) as? String {
            // Only the stretch around the cursor matters in a long document.
            var location = value.utf16.count
            if let range = attribute(focused as! AXUIElement, kAXSelectedTextRangeAttribute),
                CFGetTypeID(range) == AXValueGetTypeID() {
                var cfRange = CFRange()
                if AXValueGetValue(range as! AXValue, .cfRange, &cfRange) { location = cfRange.location }
            }
            let units = Array(value.utf16)
            let lower = max(0, min(location, units.count) - 2000)
            parts.append(String(decoding: units[lower..<min(units.count, lower + 4000)], as: UTF16.self))
        }
        guard let window = attribute(app, kAXFocusedWindowAttribute), CFGetTypeID(window) == AXUIElementGetTypeID()
        else { return parts.joined(separator: "\n") }
        if let title = attribute(window as! AXUIElement, kAXTitleAttribute) as? String { parts.append(title) }

        // Breadth-first over the window for readable text (chat messages, labels).
        let deadline = Date().addingTimeInterval(0.25)
        var queue = [window as! AXUIElement]
        var visited = 0
        var collected = 0
        while !queue.isEmpty, visited < 400, collected < 6000, Date() < deadline {
            let element = queue.removeFirst()
            visited += 1
            if let role = attribute(element, kAXRoleAttribute) as? String,
                [kAXStaticTextRole, kAXTextAreaRole, kAXTextFieldRole, "AXHeading", "AXLink"].contains(role),
                let text = (attribute(element, kAXValueAttribute) as? String) ?? (attribute(element, kAXTitleAttribute) as? String),
                !text.isEmpty {
                let clipped = String(text.prefix(1000))
                parts.append(clipped)
                collected += clipped.count
            }
            if let children = attribute(element, kAXChildrenAttribute) as? [AXUIElement] { queue.append(contentsOf: children) }
        }
        return parts.joined(separator: "\n")
    }
}
