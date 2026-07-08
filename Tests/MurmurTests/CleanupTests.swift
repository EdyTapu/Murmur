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
