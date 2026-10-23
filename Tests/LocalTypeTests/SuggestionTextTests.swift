import XCTest
@testable import LocalType

final class SuggestionTextTests: XCTestCase {
    // MARK: format

    func testMidWordNewWordKeepsLeadingSpace() {
        // "Hello" + " world": пробел обязан сохраниться, иначе будет склейка
        XCTAssertEqual(SuggestionText.format(" world", prompt: "Hello", maxWords: 4), " world")
    }

    func testMidWordCompletionHasNoLeadingSpace() {
        XCTAssertEqual(SuggestionText.format("lo there", prompt: "Hel", maxWords: 4), "lo there")
    }

    func testTrailingSpacePromptStripsLeadingSpace() {
        XCTAssertEqual(SuggestionText.format("  world", prompt: "Hello ", maxWords: 4), "world")
    }

    func testLimitsWords() {
        XCTAssertEqual(SuggestionText.format("a b c d e f", prompt: "x ", maxWords: 4), "a b c d")
    }

    func testStopsAtNewline() {
        XCTAssertEqual(SuggestionText.format("one\ntwo", prompt: "x ", maxWords: 4), "one")
    }

    func testEmptyAndWhitespaceReturnNil() {
        XCTAssertNil(SuggestionText.format("", prompt: "x ", maxWords: 4))
        XCTAssertNil(SuggestionText.format("   ", prompt: "x ", maxWords: 4))
    }

    func testNumericArtifactsFilteredInTextContext() {
        XCTAssertNil(SuggestionText.format("10", prompt: "привет ", maxWords: 4))
        XCTAssertNil(SuggestionText.format("10:25", prompt: "привет ", maxWords: 4))
        XCTAssertNil(SuggestionText.format("2022,", prompt: "привет ", maxWords: 4))
    }

    func testNumbersAllowedInNumericContext() {
        XCTAssertEqual(SuggestionText.format("25", prompt: "total 10 ", maxWords: 4), "25")
        XCTAssertEqual(SuggestionText.format("0", prompt: "x = 1", maxWords: 4), "0")
    }

    func testWordWithDigitsNotFiltered() {
        XCTAssertEqual(SuggestionText.format("mp3 player", prompt: "my ", maxWords: 4), "mp3 player")
    }

    // MARK: extractNextWord

    func testExtractNextWord() {
        let r = SuggestionText.extractNextWord(from: " hello big world")
        XCTAssertEqual(r?.word, "hello")
        XCTAssertEqual(r?.remainder, " big world")
    }

    func testExtractLastWord() {
        let r = SuggestionText.extractNextWord(from: "world")
        XCTAssertEqual(r?.word, "world")
        XCTAssertEqual(r?.remainder, "")
    }

    func testExtractFromEmpty() {
        XCTAssertNil(SuggestionText.extractNextWord(from: ""))
        XCTAssertNil(SuggestionText.extractNextWord(from: "  "))
    }

    func testTabSequenceReassemblesSuggestion() {
        var rest = "раз два три"
        var out = ""
        while let (w, r) = SuggestionText.extractNextWord(from: rest) {
            out += (out.isEmpty ? "" : " ") + w
            rest = r
        }
        XCTAssertEqual(out, "раз два три")
    }

    // MARK: needsLeadingSpace

    func testNeedsLeadingSpace() {
        XCTAssertFalse(SuggestionText.needsLeadingSpace(beforeCaret: "Hel", isCompletingWord: true))
        XCTAssertTrue(SuggestionText.needsLeadingSpace(beforeCaret: "Hello", isCompletingWord: false))
        XCTAssertFalse(SuggestionText.needsLeadingSpace(beforeCaret: "Hello ", isCompletingWord: false))
        XCTAssertFalse(SuggestionText.needsLeadingSpace(beforeCaret: "", isCompletingWord: false))
    }

    // MARK: trimPrompt

    func testTrimPromptShortUnchanged() {
        XCTAssertEqual(SuggestionText.trimPrompt("hello world", limit: 100), "hello world")
    }

    func testTrimPromptCutsAtWordBoundary() {
        let r = SuggestionText.trimPrompt("aaaa bbbb cccc", limit: 8) // suffix(8) = "bb cccc" -> "bbbb cccc"? (8 chars: "bbb cccc")
        XCTAssertFalse(r.hasPrefix("b "), "не должно начинаться с обломка слова")
        XCTAssertTrue(r.hasSuffix("cccc"))
    }
}
