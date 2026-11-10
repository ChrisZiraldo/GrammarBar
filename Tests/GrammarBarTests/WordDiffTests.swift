import XCTest

final class WordDiffTests: XCTestCase {

    // MARK: Helpers

    private func changes(_ segments: [DiffSegment]) -> [DiffChange] {
        segments.compactMap { segment in
            if case .change(let change) = segment.content { return change }
            return nil
        }
    }

    // MARK: Detecting changes

    func testIdenticalTextHasNoChanges() {
        let segments = WordDiff.segments(original: "Hello there world", corrected: "Hello there world")
        XCTAssertTrue(changes(segments).isEmpty)
    }

    func testCapitalizationChangeIsAnEdit() {
        let result = changes(WordDiff.segments(original: "i like it", corrected: "I like it"))
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first?.original, "i")
        XCTAssertEqual(result.first?.corrected, "I")
    }

    func testSmallEditIsBrokenIntoCharacterPieces() throws {
        let result = changes(WordDiff.segments(original: "its fine", corrected: "it's fine"))
        let change = try XCTUnwrap(result.first)

        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(change.pieces.map(\.text), ["it", "'", "s"])
        XCTAssertEqual(change.pieces.map(\.kind), [.same, .added, .same])
        // The pieces belong to one word, so no spaces between them.
        XCTAssertEqual(change.pieces.map(\.spaceBefore), [true, false, false])
    }

    func testUnrelatedWordsStayWholeWordReplacements() throws {
        let result = changes(WordDiff.segments(original: "teh cat", corrected: "the cat"))
        let change = try XCTUnwrap(result.first)

        XCTAssertEqual(change.pieces.map(\.kind), [.removed, .added])
        XCTAssertEqual(change.pieces.map(\.text), ["teh", "the"])
    }

    func testInsertionAndDeletion() {
        let inserted = changes(WordDiff.segments(original: "I went home", corrected: "I really went home"))
        XCTAssertEqual(inserted.count, 1)
        XCTAssertNil(inserted.first?.original)
        XCTAssertEqual(inserted.first?.corrected, "really")

        let deleted = changes(WordDiff.segments(original: "I really went home", corrected: "I went home"))
        XCTAssertEqual(deleted.count, 1)
        XCTAssertEqual(deleted.first?.original, "really")
        XCTAssertNil(deleted.first?.corrected)
    }

    func testChangeIdsAreSequential() {
        let result = changes(WordDiff.segments(
            original: "i has two cat",
            corrected: "I have two cats"
        ))
        XCTAssertEqual(result.map(\.id), Array(0..<result.count))
        XCTAssertGreaterThanOrEqual(result.count, 3)
    }

    // MARK: Composing

    func testComposeWithNothingRejectedGivesCorrectedWords() {
        let segments = WordDiff.segments(original: "i like it", corrected: "I like it")
        XCTAssertEqual(WordDiff.compose(segments, rejected: []), "I like it")
    }

    func testRejectingAChangeRestoresTheOriginalWord() {
        let segments = WordDiff.segments(original: "i like it", corrected: "I like it")
        XCTAssertEqual(WordDiff.compose(segments, rejected: [0]), "i like it")
    }

    func testRejectingOneOfSeveralChanges() {
        let segments = WordDiff.segments(original: "teh cat sat on teh mat", corrected: "the cat sat on the mat")
        XCTAssertEqual(WordDiff.compose(segments, rejected: [1]), "the cat sat on teh mat")
    }

    func testRejectingAnInsertionDropsTheWord() {
        let segments = WordDiff.segments(original: "I went home", corrected: "I really went home")
        XCTAssertEqual(WordDiff.compose(segments, rejected: [0]), "I went home")
    }

    func testRejectingADeletionKeepsTheWord() {
        let segments = WordDiff.segments(original: "I really went home", corrected: "I went home")
        XCTAssertEqual(WordDiff.compose(segments, rejected: [0]), "I really went home")
    }

    // MARK: Line breaks

    func testParagraphBreaksSurviveComposing() {
        let original = "Hello wrld\n\nSecond paragraph"
        let corrected = "Hello world\n\nSecond paragraph"
        let segments = WordDiff.segments(original: original, corrected: corrected)

        XCTAssertEqual(changes(segments).count, 1)
        XCTAssertEqual(WordDiff.compose(segments, rejected: []), corrected)
        XCTAssertEqual(WordDiff.compose(segments, rejected: [0]), original)
    }

    func testLineBreaksNeverCountAsEdits() {
        let result = changes(WordDiff.segments(
            original: "one two\nthree",
            corrected: "one two\n\nthree"
        ))
        XCTAssertTrue(result.isEmpty)
    }

    func testWordsTokenizerSeparatesBreaksFromWords() {
        XCTAssertEqual(WordDiff.words("a  b\n\nc"), ["a", "b", "\n\n", "c"])
        XCTAssertEqual(WordDiff.words("  "), [])
        XCTAssertEqual(WordDiff.words("a \n b"), ["a", "\n", "b"])
    }

    func testJoinPutsNoSpacesAroundBreaks() {
        XCTAssertEqual(WordDiff.join(["a", "b", "\n\n", "c"]), "a b\n\nc")
    }
}
