import XCTest

final class DictionaryGuardTests: XCTestCase {

    func testEmptyDictionaryChangesNothing() {
        XCTAssertEqual(
            DictionaryGuard.restore(original: "I use iOS", corrected: "I use IOS", dictionary: []),
            "I use IOS"
        )
    }

    func testRestoresAWordTheModelRecased() {
        let result = DictionaryGuard.restore(
            original: "I use iOS daily",
            corrected: "I use IOS daily",
            dictionary: ["iOS"]
        )
        XCTAssertEqual(result, "I use iOS daily")
    }

    func testRestoresAWordTheModelMisspelled() {
        let result = DictionaryGuard.restore(
            original: "Ask Zed about it",
            corrected: "Ask Zeb about it",
            dictionary: ["Zed"]
        )
        XCTAssertEqual(result, "Ask Zed about it")
    }

    func testKeepsPunctuationTheModelAddedAroundARestoredWord() {
        let result = DictionaryGuard.restore(
            original: "Try iOS now",
            corrected: "Try IOS, now",
            dictionary: ["iOS"]
        )
        XCTAssertEqual(result, "Try iOS, now")
    }

    func testLeavesLegitimateCorrectionsElsewhereAlone() {
        let result = DictionaryGuard.restore(
            original: "teh iOS app",
            corrected: "the iOS app",
            dictionary: ["iOS"]
        )
        XCTAssertEqual(result, "the iOS app")
    }

    func testAddingPunctuationAroundAProtectedWordIsNotAViolation() {
        let result = DictionaryGuard.restore(
            original: "I like Zed",
            corrected: "I like Zed.",
            dictionary: ["Zed"]
        )
        XCTAssertEqual(result, "I like Zed.")
    }

    func testBringsBackAProtectedWordTheModelDeleted() {
        let result = DictionaryGuard.restore(
            original: "Use Foo bar",
            corrected: "Use bar",
            dictionary: ["Foo"]
        )
        XCTAssertEqual(result, "Use Foo bar")
    }

    func testRestoresMultiWordPhraseCasing() {
        let result = DictionaryGuard.restore(
            original: "I read the New York Times",
            corrected: "I read the new york times",
            dictionary: ["New York Times"]
        )
        XCTAssertEqual(result, "I read the New York Times")
    }

    func testIgnoresTermsThatNeverAppearedInTheOriginal() {
        // "Apple" isn't in what the user typed, so nothing should be forced in.
        let result = DictionaryGuard.restore(
            original: "I ate an apple",
            corrected: "I ate an apple.",
            dictionary: ["Zed"]
        )
        XCTAssertEqual(result, "I ate an apple.")
    }

    // MARK: Sentence-start capitalization

    func testLowercaseTermIsCapitalizedAtStartOfText() {
        let result = DictionaryGuard.restore(
            original: "wanna go home",
            corrected: "Wanna go home",
            dictionary: ["wanna"]
        )
        XCTAssertEqual(result, "Wanna go home")
    }

    func testLowercaseTermIsCapitalizedEvenIfModelLeftItLowercase() {
        let result = DictionaryGuard.restore(
            original: "wanna go home",
            corrected: "wanna go home.",
            dictionary: ["wanna"]
        )
        XCTAssertEqual(result, "Wanna go home.")
    }

    func testLowercaseTermStaysLowercaseMidSentence() {
        let result = DictionaryGuard.restore(
            original: "i really wanna go",
            corrected: "I really Wanna go",
            dictionary: ["wanna"]
        )
        XCTAssertEqual(result, "I really wanna go")
    }

    func testLowercaseTermIsCapitalizedAfterSentenceEnd() {
        let result = DictionaryGuard.restore(
            original: "It is late. wanna leave? i wanna leave",
            corrected: "It is late. Wanna leave? I Wanna leave",
            dictionary: ["wanna"]
        )
        XCTAssertEqual(result, "It is late. Wanna leave? I wanna leave")
    }

    func testLowercaseTermIsCapitalizedAfterLineBreakAndQuote() {
        let result = DictionaryGuard.restore(
            original: "Hi\nwanna go? He said \"wanna go\"",
            corrected: "Hi\nwanna go? He said \"wanna go\"",
            dictionary: ["wanna"]
        )
        XCTAssertEqual(result, "Hi\nWanna go? He said \"wanna go\"")
    }

    func testCamelCaseTermsAreNeverCapitalized() {
        let result = DictionaryGuard.restore(
            original: "iOS is great",
            corrected: "IOS is great",
            dictionary: ["iOS"]
        )
        XCTAssertEqual(result, "iOS is great")
    }

    func testSplitSeparatesEdgePunctuation() {
        let parts = DictionaryGuard.split("(Zed),")
        XCTAssertEqual(parts.lead, "(")
        XCTAssertEqual(parts.core, "Zed")
        XCTAssertEqual(parts.trail, "),")
        XCTAssertEqual(DictionaryGuard.core(of: "C++"), "C++")
    }
}

final class TextComparisonTests: XCTestCase {

    func testWhitespaceOnlyDifferencesAreUnchanged() {
        XCTAssertTrue(TextComparison.isUnchanged("hello   world\n", from: "hello world"))
    }

    func testCaseChangeIsARealChange() {
        XCTAssertFalse(TextComparison.isUnchanged("I like it", from: "i like it"))
    }

    func testPunctuationChangeIsARealChange() {
        XCTAssertFalse(TextComparison.isUnchanged("Hello, world", from: "Hello world"))
    }
}
