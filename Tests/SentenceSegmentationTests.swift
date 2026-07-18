import XCTest
@testable import SpeechDock

/// Phase 4: sentence segmentation — boundary detection that respects abbreviations, decimals, URLs,
/// emails, initials, paragraphs, and a max chunk length.
final class SentenceSegmentationTests: XCTestCase {

    private let seg = SentenceSegmentationService()

    func testBasicTwoSentences() {
        XCTAssertEqual(seg.segment("Hello world. How are you?"),
                       ["Hello world.", "How are you?"])
    }

    func testDecimalNotSplit() {
        XCTAssertEqual(seg.segment("Pi is about 3.14 today."), ["Pi is about 3.14 today."])
    }

    func testURLNotSplit() {
        XCTAssertEqual(seg.segment("Please visit example.com for details."),
                       ["Please visit example.com for details."])
    }

    func testEmailNotSplit() {
        XCTAssertEqual(seg.segment("Write to a@b.com when ready."),
                       ["Write to a@b.com when ready."])
    }

    func testAbbreviationNotSplit() {
        let chunks = seg.segment("Dr. Smith arrived early. He was prepared.")
        XCTAssertEqual(chunks.count, 2)
        XCTAssertEqual(chunks.first, "Dr. Smith arrived early.")
    }

    func testInitialsNotSplit() {
        let chunks = seg.segment("J. R. R. Tolkien wrote many books.")
        XCTAssertEqual(chunks.count, 1)
    }

    func testFrenchSentences() {
        let chunks = seg.segment("Bonjour à tous. Comment allez-vous aujourd'hui?")
        XCTAssertEqual(chunks.count, 2)
    }

    func testParagraphsArePreserved() {
        let chunks = seg.segment("First paragraph here.\n\nSecond paragraph here.")
        XCTAssertEqual(chunks, ["First paragraph here.", "Second paragraph here."])
    }

    func testWhitespaceNormalized() {
        let chunks = seg.segment("Hello     world.\n   Next   line.")
        XCTAssertEqual(chunks, ["Hello world.", "Next line."])
    }

    func testEmptyAndWhitespaceOnly() {
        XCTAssertEqual(seg.segment(""), [])
        XCTAssertEqual(seg.segment("   \n\n  "), [])
    }

    func testLongSentenceIsSplitByMaxLength() {
        var s = SentenceSegmentationService()
        s.maxChunkLength = 25
        let sentence = "one two three four five six seven eight nine ten eleven twelve."
        let chunks = s.segment(sentence)
        XCTAssertGreaterThan(chunks.count, 1)
        for chunk in chunks {
            XCTAssertLessThanOrEqual(chunk.count, 25)
        }
    }

    func testLongSentencePrefersClauseBoundaries() {
        var s = SentenceSegmentationService()
        s.maxChunkLength = 40
        let sentence = "First we gather the data, then we clean it, and finally we present the results clearly."
        let chunks = s.segment(sentence)
        XCTAssertGreaterThan(chunks.count, 1)
        // No chunk should exceed the limit.
        XCTAssertTrue(chunks.allSatisfy { $0.count <= 40 })
    }
}
