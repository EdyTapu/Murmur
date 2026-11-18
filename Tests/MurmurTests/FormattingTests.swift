import Foundation
import Testing

@testable import Murmur

// Inputs are real Parakeet transcripts of the spoken phrases.
@Suite struct BacktrackTests {
    @Test func keepsOnlyTheCorrection() {
        #expect(Backtrack.apply("Let's meet at 2, actually 3 on Friday.") == "Let's meet at 3 on Friday.")
        #expect(Backtrack.apply("Send it to John? No, wait, send it to Jane") == "Send it to Jane")
        #expect(Backtrack.apply("I'll bring the red one, or rather the blue one.") == "I'll bring the blue one.")
        #expect(Backtrack.apply("Let's meet Tuesday, no wait, Wednesday") == "Let's meet Wednesday")
    }

    @Test func scratchThatDropsOnlyTheLastSentence() {
        #expect(
            Backtrack.apply("Hi Sam. Send the report tomorrow. Scratch that. Send it on Friday")
                == "Hi Sam. Send it on Friday")
    }

    @Test func leavesOrdinarySpeechAlone() {
        for text in [
            "That's actually a good idea.", "No wait", "I actually have 3 dogs and 2 cats.",
            "That's not what I meant. Let's try again.", "Sorry, I meant to call you yesterday.",
            "But actually no one came to the party.", "Is there no wait time at the restaurant?",
            "That was a good one. Actually, one more thing.", "Don't scratch that itch again please folks.",
        ] {
            #expect(Backtrack.apply(text) == text)
        }
    }
}

@Suite struct SpokenPunctuationTests {
    @Test func replacesSpokenMarks() {
        #expect(
            SpokenPunctuation.apply("Hello comma? How are you question mark? I am fine.")
                == "Hello, How are you? I am fine.")
        #expect(
            SpokenPunctuation.apply("He said open quote hello there close quote and left exclamation point.")
                == "He said \u{201C}hello there\u{201D} and left!")
        #expect(
            SpokenPunctuation.apply("Open parenthesis, maybe close parenthesis semicolon done.") == "(maybe); done.")
    }

    @Test func leavesTheWordsAloneInProse() {
        for prose in [
            "The Victorian period was long and the colon is an organ.", "It was a difficult period.",
            "The car came to a full stop.",
        ] {
            #expect(SpokenPunctuation.apply(prose) == prose)
        }
    }
}

@Suite struct ListFormatterTests {
    @Test func numberedLists() {
        #expect(
            ListFormatter.apply("I need three things. One, buy milk. Two, call mom. Three, email Sam.")
                == "I need three things.\n1. Buy milk\n2. Call mom\n3. Email Sam")
        #expect(
            ListFormatter.apply("My to-do list is number one, buy milk number two, call mom number three, email Sam.")
                == "My to-do list is:\n1. Buy milk\n2. Call mom\n3. Email Sam")
    }

    @Test func bulletLists() {
        #expect(
            ListFormatter.apply("Shopping list bullet point apples bullet point bananas bullet point bread")
                == "Shopping list:\n- Apples\n- Bananas\n- Bread")
    }

    @Test func numbersInProseAreNotLists() {
        for text in [
            "I have one apple and two pears.", "One, I never said that.", "Chapter two, verse one.",
            "My number one priority is shipping and my number two priority is hiring.",
            "The first bullet point is short and the second bullet point is long.",
        ] {
            #expect(ListFormatter.apply(text) == text)
        }
    }
}

@Suite struct CodeCaseTests {
    @Test func casingCommands() {
        #expect(CodeCase.apply("Set Snake Case User ID to 5.") == "Set user_id to 5.")
        #expect(CodeCase.apply("call camel case get user name, then stop") == "call getUserName, then stop")
        #expect(CodeCase.apply("The function is called camelcase getUsername") == "The function is called getUsername")
        #expect(CodeCase.apply("constant case max retries") == "MAX_RETRIES")
        for prose in [
            "a suitcase for the trip", "Please use snake case for the column names.",
            "We should use camel case for variables.",
        ] {
            #expect(CodeCase.apply(prose) == prose)
        }
    }
}

@Suite struct CleanupPipelineTests {
    @Test func fullPassOnRealTranscripts() {
        let list = RulesCleaner.clean(
            "Um, I need three things. One, buy milk. Two, call mom. Three, email Sam.", removeFillers: true)
        #expect(list.text == "I need three things.\n1. Buy milk\n2. Call mom\n3. Email Sam")
        let fix = RulesCleaner.clean("Send the report tomorrow. Scratch that. Send it on Friday", removeFillers: true)
        #expect(fix.text == "Send it on Friday")
        #expect(!fix.cancelled)
    }
}

@Suite struct MicChoiceTests {
    private let builtIn = AudioInputDevice(uid: "builtin", name: "MacBook Pro Microphone", transport: .builtIn)
    private let headset = AudioInputDevice(uid: "xm5", name: "WH-1000XM5", transport: .bluetooth)
    private let usb = AudioInputDevice(uid: "usb", name: "USB Mic", transport: .other)

    @Test func neverPicksAnUnrankedBluetoothHeadset() {
        // macOS made the headphones the default input; the built-in mic is used instead.
        #expect(AudioDevices.chooseInput(ranked: [], connected: [headset, usb, builtIn], systemDefaultUID: "xm5") == "builtin")
        #expect(AudioDevices.chooseInput(ranked: [], connected: [headset, usb], systemDefaultUID: "xm5") == "usb")
        // No other microphone exists: follow the system default.
        #expect(AudioDevices.chooseInput(ranked: [], connected: [headset], systemDefaultUID: "xm5") == nil)
        // A virtual device records silence, so it is no substitute either.
        let zoom = AudioInputDevice(uid: "zoom", name: "ZoomAudioDevice", transport: .virtual)
        #expect(AudioDevices.chooseInput(ranked: [], connected: [headset, zoom], systemDefaultUID: "xm5") == nil)
    }

    @Test func rankedListWinsAndSkipsDisconnectedMics() {
        #expect(AudioDevices.chooseInput(ranked: ["gone", "usb"], connected: [builtIn, usb], systemDefaultUID: "builtin") == "usb")
        // Ranking the headset is the explicit opt-in to use its microphone.
        #expect(AudioDevices.chooseInput(ranked: ["xm5"], connected: [builtIn, headset], systemDefaultUID: "builtin") == "xm5")
        #expect(AudioDevices.chooseInput(ranked: ["gone"], connected: [builtIn], systemDefaultUID: "builtin") == nil)
    }
}

@Suite struct ContextVocabularyTests {
    private let common: Set<String> = ["the", "meeting", "with", "about", "function", "returns", "paris", "notes", "hello"]
    private func terms(_ context: String) -> [String] {
        ContextVocabulary.terms(in: context, isKnownWord: { common.contains($0) })
    }

    @Test func collectsNamesAndIdentifiersOnly() {
        let found = terms("Notes. The meeting with Caitlin about getUserName and user_id on edytapu.dev. Hello Paris")
        #expect(found == ["Caitlin", "getUserName", "user_id", "edytapu.dev"])
    }

    @Test func spellsTheTranscriptLikeTheScreen() {
        let screen = ["Caitlin", "getUserName", "user_id", "edytapu.dev", "Rojo"]
        let knownNames: Set<String> = ["Maria", "Katherine"]
        func apply(_ text: String, _ terms: [String]) -> String {
            ContextVocabulary.apply(text, terms: terms, isKnownWord: { knownNames.contains($0) })
        }
        #expect(
            apply("Ask Kaitlyn if get user name returns the user ID.", screen)
                == "Ask Caitlin if getUserName returns the user_id.")
        #expect(apply("Open rojo, then stop", screen) == "Open Rojo, then stop")
        // Unrelated words, names that are not close, and real names are left alone.
        let prose = "Katherine said the meeting is about usernames."
        #expect(apply(prose, screen) == prose)
        #expect(apply("Ask Maria about it", ["Mario"]) == "Ask Maria about it")
    }
}

@Suite struct WebSearchTests {
    @Test func recognisesSearchCommands() {
        #expect(WebSearch.url(forCommand: "Search for Swift actors.", selection: nil)?.absoluteString
            == "https://www.google.com/search?q=Swift%20actors")
        #expect(WebSearch.url(forCommand: "Look up this", selection: " Parakeet TDT ")?.absoluteString
            == "https://www.google.com/search?q=Parakeet%20TDT")
        #expect(WebSearch.url(forCommand: "Make this more formal", selection: "hey") == nil)
        #expect(WebSearch.url(forCommand: "Research the topic", selection: nil) == nil)
    }
}

@Suite struct StatsStoreTests {
    private func tempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @MainActor @Test func backfillsFromHistoryThenPersists() {
        let dir = tempDir()
        let yesterday = Date().addingTimeInterval(-86_400)
        let old = [
            HistoryEntry(date: yesterday, rawText: "a", finalText: "one two three", appName: "Notes", outcome: "paste"),
            HistoryEntry(rawText: "b", finalText: "four five", appName: "Mail", outcome: "paste", duration: 1.0),
        ]
        let store = StatsStore(directory: dir, backfill: old)
        #expect(store.totalWords == 5)
        #expect(store.dayStreak() == 2)
        #expect(store.wordsPerMinute == nil)  // under 10 s of timed speech

        store.record(text: Array(repeating: "word", count: 30).joined(separator: " "), seconds: 12, app: "Notes")
        store.recordFixes(2)
        #expect(store.wordsPerMinute == 148)  // (2 + 30) words in 13 s
        #expect(store.topApps.first?.name == "Notes")
        #expect(store.lastDays(2).map(\.words) == [3, 32])

        // A second launch reads the file and ignores the backfill.
        let reopened = StatsStore(directory: dir, backfill: old)
        #expect(reopened.totalWords == 35)
        #expect(reopened.wordsLearned == 2)
    }
}

@Suite struct SyncFolderTests {
    @MainActor @Test func relocatingMergesAndPicksUpAnotherMacsEdit() throws {
        let fm = FileManager.default
        let local = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let shared = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        for dir in [local, shared] { try fm.createDirectory(at: dir, withIntermediateDirectories: true) }

        let otherMac = DictionaryStore(directory: shared)
        otherMac.learn(heard: "row joe", corrected: "Rojo")

        let thisMac = DictionaryStore(directory: local)
        thisMac.learn(heard: "loo ow", corrected: "Luau")
        thisMac.learn(heard: "roho", corrected: "Rojo")
        thisMac.relocate(to: shared)
        #expect(Set(thisMac.terms.map(\.canonical)) == ["Rojo", "Luau"])
        #expect(thisMac.terms.first { $0.canonical == "Rojo" }?.aliases == ["row joe", "roho"])

        // The other Mac sees the merged file the next time it looks.
        otherMac.reloadIfChanged()
        #expect(Set(otherMac.terms.map(\.canonical)) == ["Rojo", "Luau"])
        #expect(otherMac.transforms.map(\.name) == ["Polish", "Prompt Engineer"])
    }
}

@Suite struct ScratchpadTests {
    @Test func noonTasksAreTheNoteLinesWithoutListMarkers() {
        let note = "- email Smith by Friday\n\n2. call the dentist at 3pm\n[ ] buy milk\n   \nplain line"
        #expect(Noon.tasks(in: note) == ["email Smith by Friday", "call the dentist at 3pm", "buy milk", "plain line"])
    }

    @MainActor @Test func migratesTheOldSinglePadAndKeepsOneNoteOpen() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try "old pad text\nsecond line".write(to: dir.appendingPathComponent("scratchpad.txt"), atomically: true, encoding: .utf8)
        let store = ScratchpadStore(directory: dir)
        #expect(store.notes.map(\.title) == ["old pad text"])
        store.add()
        #expect(store.notes.count == 2)
        store.close(store.notes[1].id)
        store.close(store.notes[0].id)
        #expect(store.notes.map(\.text) == [""])
        #expect(store.selected == store.notes[0].id)
    }
}

@Suite struct SyncSafetyTests {
    @MainActor @Test func aDamagedSharedFileIsNeverOverwritten() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("dictionary.json")
        try "half-synced {".write(to: file, atomically: true, encoding: .utf8)

        let store = DictionaryStore(directory: dir)
        store.learn(heard: "row joe", corrected: "Rojo")
        #expect(try String(contentsOf: file, encoding: .utf8) == "half-synced {")
    }
}

@Suite struct ContextReadingTests {
    /// Reading our own interface from a background thread froze the app.
    @Test func neverReadsItsOwnProcess() async {
        let text = await Task.detached { ContextVocabulary.visibleText(pid: ProcessInfo.processInfo.processIdentifier) }.value
        #expect(text.isEmpty)
    }
}
