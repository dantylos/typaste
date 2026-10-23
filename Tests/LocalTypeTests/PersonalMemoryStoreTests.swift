import Foundation
import XCTest
@testable import LocalType

@MainActor
final class PersonalMemoryStoreTests: XCTestCase {

    private func makeTempStore() -> PersonalMemoryStore {
        let tempURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("localtype_test_\(UUID().uuidString).sqlite3")
        return PersonalMemoryStore(databaseURL: tempURL)
    }

    func testRecordAndMatchPrefixContinuationInRussianAndEnglish() {
        let store = makeTempStore()
        defer {
            store.close()
            try? FileManager.default.removeItem(at: store.databaseURL)
        }

        store.recordPhrase("Добрый день, подскажите пожалуйста по проекту", bundleID: "ru.keepcoder.Telegram", weight: 2)
        store.recordPhrase("Thank you for the quick code review today", bundleID: "com.apple.mail", weight: 2)
        XCTAssertEqual(store.phraseCount(), 2)

        // 1. Mid-word Russian prefix match ("Добрый ден" -> "ь, подскажите пожалуйста по")
        let ruMidWord = store.matchPrefixContinuation(for: "Добрый ден", bundleID: "ru.keepcoder.Telegram", maxWords: 4)
        XCTAssertEqual(ruMidWord, "ь, подскажите пожалуйста по")

        // 2. Trailing-space Russian prefix match ("Добрый день, " -> "подскажите пожалуйста по проекту")
        let ruTrailingSpace = store.matchPrefixContinuation(for: "Добрый день, ", bundleID: "ru.keepcoder.Telegram", maxWords: 4)
        XCTAssertEqual(ruTrailingSpace, "подскажите пожалуйста по проекту")

        // 3. English prefix match after completed sentence
        let enMatch = store.matchPrefixContinuation(
            for: "Hi Alex! Thank you for the",
            bundleID: "com.apple.mail",
            maxWords: 4
        )
        XCTAssertEqual(enMatch, " quick code review today")
    }

    func testLanguageDetectionAndAppPrioritizedStyleExamples() {
        let store = makeTempStore()
        defer {
            store.close()
            try? FileManager.default.removeItem(at: store.databaseURL)
        }

        store.recordPhrase("Привет, сейчас посмотрю пулл реквест", bundleID: "com.tinyspeck.slackmacgap", weight: 1)
        store.recordPhrase("Давай созвонимся через десять минут", bundleID: "ru.keepcoder.Telegram", weight: 3)
        store.recordPhrase("Let us schedule a meeting tomorrow", bundleID: "com.apple.mail", weight: 5)

        XCTAssertEqual(PersonalMemoryStore.detectLanguage("Привет как"), "ru")
        XCTAssertEqual(PersonalMemoryStore.detectLanguage("Hello world"), "en")

        // Query in Russian for Telegram should return only Russian phrases with Telegram first
        let ruExamples = store.relevantStyleExamples(for: "Привет, давай", bundleID: "ru.keepcoder.Telegram", limit: 4)
        XCTAssertEqual(ruExamples.count, 2)
        XCTAssertEqual(ruExamples.first, "Давай созвонимся через десять минут")

        // Query in English should return only English phrases
        let enExamples = store.relevantStyleExamples(for: "Let us ", bundleID: "com.apple.mail", limit: 4)
        XCTAssertEqual(enExamples, ["Let us schedule a meeting tomorrow"])
    }

    func testExtractCompletedSentenceAndIgnoreShortOrTokenStrings() {
        let store = makeTempStore()
        defer {
            store.close()
            try? FileManager.default.removeItem(at: store.databaseURL)
        }

        // Single word or too short should be ignored
        store.recordPhrase("Привет", bundleID: "global")
        store.recordPhrase("Hi", bundleID: "global")
        // Long token/password without spaces (> 32 chars) should be ignored
        store.recordPhrase("Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9abcdef", bundleID: "global")
        XCTAssertEqual(store.phraseCount(), 0)

        // Completed sentence extraction
        XCTAssertNil(PersonalMemoryStore.extractCompletedSentence(from: "Я еще печатаю это предлож"))
        XCTAssertEqual(
            PersonalMemoryStore.extractCompletedSentence(from: "Первое предложение. Отправил отчет на почту! "),
            "Отправил отчет на почту!"
        )
    }

    func testBuildInstructInputDisablesThinkAndIncludesExamples() {
        let input = SuggestionText.buildInstructInput(
            prompt: "Привет, давай ",
            styleExamples: ["Давай созвонимся через 15 минут"]
        )
        XCTAssertTrue(input.contains("<think>\n\n</think>"))
        XCTAssertTrue(input.contains("Давай созвонимся через 15 минут"))
        XCTAssertTrue(input.hasSuffix("Привет, давай "))
    }
}
