import ApplicationServices
import Foundation
import Testing

@testable import Murmur

@Suite struct RulesCleanerTests {
    @Test func removesFillers() {
        let out = RulesCleaner.clean("Um, let's meet at, uh, 3pm.", removeFillers: true)
        #expect(out.text == "Let's meet at, 3pm." || out.text == "Let's meet at 3pm.")
        #expect(!out.cancelled)
    }

    @Test func keepsFillersWhenDisabled() {
        let out = RulesCleaner.clean("Um, hello there.", removeFillers: false)
        #expect(out.text.lowercased().contains("um"))
    }

    @Test func doesNotEatWordsContainingFillerLetters() {
        let out = RulesCleaner.clean("The umbrella and the hummingbird hummed.", removeFillers: true)
        #expect(out.text.contains("umbrella"))
        #expect(out.text.contains("hummingbird"))
    }

    @Test func scratchThatCancels() {
        #expect(RulesCleaner.clean("Scratch that.", removeFillers: true).cancelled)
        #expect(RulesCleaner.clean("send the report tomorrow scratch that", removeFillers: true).cancelled)
        #expect(!RulesCleaner.clean("Don't scratch that itch again please folks.", removeFillers: true).cancelled)
    }

    @Test func trailingNewLineCommand() {
        let out = RulesCleaner.clean("Here is the first item new line", removeFillers: true)
        #expect(out.text == "Here is the first item")
        #expect(out.trailingNewlines == 1)

        let para = RulesCleaner.clean("Done with this thought. New paragraph", removeFillers: true)
        #expect(para.trailingNewlines == 2)
    }

    @Test func capitalizesFirstLetter() {
        let out = RulesCleaner.clean("hello world.", removeFillers: true)
        #expect(out.text == "Hello world.")
    }

    @Test func emptyInput() {
        let out = RulesCleaner.clean("   ", removeFillers: true)
        #expect(out.text.isEmpty)
        #expect(!out.cancelled)
    }

    @Test func repairsPunctuationGaps() {
        #expect(RulesCleaner.repairWhitespace("hello , world  .") == "Hello, world.")
    }
}

@Suite struct DictionaryTests {
    @Test func replacesAliases() {
        let terms = [
            DictionaryTerm(canonical: "Rojo", aliases: ["row joe", "roho"]),
            DictionaryTerm(canonical: "Luau", aliases: ["loo out"]),
        ]
        let result = DictionaryStore.apply(
            "I synced row joe and wrote some loo out code.", terms: terms, snippets: [])
        #expect(result == "I synced Rojo and wrote some Luau code.")
    }

    @Test func aliasMatchIsWholeWord() {
        let terms = [DictionaryTerm(canonical: "Git", aliases: ["get"])]
        let result = DictionaryStore.apply(
            "Together we get things done.", terms: terms, snippets: [])
        #expect(result.contains("Together"))
        #expect(!result.contains("ToGither"))
    }

    @Test func snippetTriggersOnWholeUtterance() {
        let snippets = [Snippet(trigger: "insert my email", expansion: "alessio@example.com")]
        let hit = DictionaryStore.apply("Insert my email.", terms: [], snippets: snippets)
        #expect(hit == "alessio@example.com")
        let miss = DictionaryStore.apply(
            "Please insert my email into the doc.", terms: [], snippets: snippets)
        #expect(miss != "alessio@example.com")
    }
}

@Suite struct LLMSanityTests {
    @Test func rejectsBallooningOutput() {
        let input = "Send the report by Friday."
        let ballooned = Array(repeating: "word", count: 60).joined(separator: " ")
        #expect(!LLMCleaner.sane(input: input, output: ballooned))
    }

    @Test func acceptsNormalCleanup() {
        #expect(LLMCleaner.sane(input: "um send the uh report by friday", output: "Send the report by Friday."))
    }

    @Test func rejectsEmptyOutput() {
        #expect(!LLMCleaner.sane(input: "hello", output: ""))
    }
}

@Suite struct AppCategoryTests {
    @Test func categorizesKnownApps() {
        #expect(AppCategory.categorize(bundleID: "com.tinyspeck.slackmacgap") == .workMessaging)
        #expect(AppCategory.categorize(bundleID: "com.apple.mail") == .email)
        #expect(AppCategory.categorize(bundleID: "com.apple.MobileSMS") == .personalMessaging)
        #expect(AppCategory.categorize(bundleID: "com.apple.dt.Xcode") == .other)
        #expect(AppCategory.categorize(bundleID: nil) == .other)
    }
}

@Suite struct HistoryStoreTests {
    @Test @MainActor func roundTrips() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("murmur-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = HistoryStore(directory: dir)
        store.add(HistoryEntry(rawText: "raw", finalText: "final", appName: "Notes", appBundleID: "com.apple.Notes", outcome: "paste"))
        #expect(store.entries.count == 1)

        let reloaded = HistoryStore(directory: dir)
        #expect(reloaded.entries.count == 1)
        #expect(reloaded.entries[0].finalText == "final")
    }
}

@Suite struct CorrectionLearnerTests {
    private let known: Set<String> = [
        "push", "it", "to", "their", "there", "the", "meeting", "tonight", "tomorrow", "row", "joe", "see", "you", "whisper", "flow", "and", "more",
    ]
    private func fixes(_ inserted: String, before: String? = nil, after: String) -> [CorrectionLearner.Correction] {
        CorrectionLearner.corrections(
            inserted: inserted, baseline: before ?? inserted, current: after,
            isKnownWord: { known.contains($0.lowercased().trimmingCharacters(in: .punctuationCharacters)) })
    }

    @Test func learnsARetypedName() {
        #expect(
            fixes("Push it to edwardtapu.dev.", after: "Push it to edytapu.dev.")
                == [.init(heard: "edwardtapu.dev", corrected: "edytapu.dev")])
    }

    @Test func learnsInsideALargerFieldAndSeveralFixesAtOnce() {
        let out = fixes(
            "row joe and whisper flow", before: "Notes: row joe and whisper flow\nmore",
            after: "Notes: Rojo and Wispr Flow\nmore, typed later")
        #expect(out == [.init(heard: "row joe", corrected: "Rojo"), .init(heard: "whisper flow", corrected: "Wispr Flow")])
    }

    @Test func ignoresRewritesOrdinaryWordsAndUnrelatedEdits() {
        #expect(fixes("See you tonight", after: "See you tomorrow").isEmpty)
        #expect(fixes("Push it to their", after: "Push it to there").isEmpty)
        #expect(fixes("the meeting", after: "Zoomcall").isEmpty)
        // Fixing text that was never dictated teaches nothing.
        #expect(fixes("See you tonight", before: "edwardtapu.dev See you tonight", after: "edytapu.dev See you tonight").isEmpty)
        // Sending the message empties the field.
        #expect(fixes("Push it to edwardtapu.dev.", after: "").isEmpty)
        #expect(fixes("Push it to edwardtapu.dev.", after: "Push it to edwardtapu.dev. And more").isEmpty)
    }
}

@Suite struct DictionaryLearnTests {
    @MainActor @Test func learnedFixIsAppliedAndReplacesAnOlderOne() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = DictionaryStore(directory: dir)
        store.learn(heard: "edwardtapu.dev", corrected: "edytapoo.dev")
        store.learn(heard: "edwardtapu.dev", corrected: "edytapu.dev")
        store.learn(heard: "Edward Tapu.dev", corrected: "edytapu.dev")
        #expect(
            DictionaryStore.apply("Put it on edwardtapu.dev now", terms: store.terms, snippets: [])
                == "Put it on edytapu.dev now")
        #expect(store.terms.last?.aliases == ["edwardtapu.dev", "Edward Tapu.dev"])
    }
}

@Suite struct CorrectionWatcherTests {
    /// Drives the real polling loop against a fake text field.
    @MainActor private func watch(_ field: @escaping () -> String, _ learned: @escaping ([CorrectionLearner.Correction]) -> Void)
        -> CorrectionWatcher {
        let watcher = CorrectionWatcher()
        watcher.onLearn = learned
        watcher.watch(
            inserted: "Push it to edwardtapu.dev.", in: AXUIElementCreateSystemWide(), read: { _ in field() })
        return watcher
    }

    @MainActor @Test func learnsASettledFixWhenTheMessageIsSent() async throws {
        var field = "Push it to edwardtapu.dev."
        var learned: [CorrectionLearner.Correction] = []
        let watcher = watch({ field }, { learned += $0 })

        field = "Push it to edytapu.dev."
        try await Task.sleep(for: .milliseconds(1100))
        field = ""  // message sent
        try await Task.sleep(for: .milliseconds(500))
        #expect(learned == [.init(heard: "edwardtapu.dev", corrected: "edytapu.dev")])
        watcher.stop()
    }

    @MainActor @Test func neverLearnsAHalfTypedWord() async throws {
        var field = "Push it to edwardtapu.dev."
        var learned: [CorrectionLearner.Correction] = []
        let watcher = watch({ field }, { learned += $0 })

        // Still typing: each state lasts less than the settle time.
        for partial in ["edwardtapu.de", "edwardtapu.d", "edytapu.d"] {
            field = "Push it to \(partial)"
            try await Task.sleep(for: .milliseconds(300))
        }
        field = ""
        try await Task.sleep(for: .milliseconds(500))
        #expect(learned.isEmpty)
        watcher.stop()
    }
}
