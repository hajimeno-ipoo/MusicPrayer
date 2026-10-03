import Foundation
import XCTest
@testable import MusicPrayer

final class LyricParserTests: XCTestCase {
    func testMixedLineEndingsPreserveNonemptyRowsAndParagraphHints() {
        let text = "\r\n  君の声  \r\n\t\r\n\r遠い夜の向こうから\n君の声\r\n"
        let lines = LyricParser.parse(text)
        XCTAssertEqual(lines.map(\.text), ["  君の声  ", "遠い夜の向こうから", "君の声"])
        XCTAssertEqual(lines.map(\.ordinal), [0, 1, 2])
        XCTAssertEqual(lines.map(\.paragraphStart), [false, true, false])
        XCTAssertEqual(lines.map(\.textWeight), [3, 9, 3])
    }

    func testUnicodeWeightsUseCharactersWithoutRemovingOriginalScalars() {
        let composed = "e\u{301}"
        let family = "👨‍👩‍👧‍👦"
        let source = "\(composed) \(family)、君！"
        let line = LyricParser.parse(source).first!
        XCTAssertEqual(Array(line.text.utf8), Array(source.utf8))
        XCTAssertEqual(line.textWeight, 3)
        XCTAssertEqual(LyricParser.characterWeight(Character(composed)), 1)
        XCTAssertEqual(LyricParser.characterWeight(Character(family)), 1)
    }

    func testPunctuationAndFormatOnlyRowsRemainAsZeroWeightLines() {
        let source = "！？、。\n\u{200B}\n \t\nA"
        let lines = LyricParser.parse(source)
        XCTAssertEqual(lines.map(\.text), ["！？、。", "\u{200B}", "A"])
        XCTAssertEqual(lines.map(\.textWeight), [0, 0, 1])
        XCTAssertEqual(lines.map(\.paragraphStart), [false, false, true])
        for character in [Character(" "), Character("\t"), Character("\u{0}"), Character("\u{200B}"), Character("_")] {
            XCTAssertEqual(LyricParser.characterWeight(character), 0)
        }
    }

    func testRepeatedRowsHaveTheirOwnOrdinals() {
        let lines = LyricParser.parse("同じ\n同じ\n\n\n同じ")
        XCTAssertEqual(lines.map(\.ordinal), [0, 1, 2])
        XCTAssertEqual(lines.map(\.text), ["同じ", "同じ", "同じ"])
        XCTAssertEqual(lines.map(\.paragraphStart), [false, false, true])
    }

    func testWhitespaceOnlySourceHasNoDisplayLines() {
        XCTAssertTrue(LyricParser.parse(" \t\r\n\u{3000}\n\r").isEmpty)
        XCTAssertTrue(LyricParser.parse("").isEmpty)
    }

    func testHashUsesExactUTF8AndLineIDsAreReproducibleAndDistinct() {
        XCTAssertEqual(LyricHash.text(""), "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        XCTAssertNotEqual(LyricHash.text("君\n声"), LyricHash.text("君\r\n声"))
        XCTAssertNotEqual(LyricHash.text("é"), LyricHash.text("e\u{301}"))
        let sourceHash = LyricHash.text("同じ\n同じ")
        let first = LyricHash.lineID(audioFingerprint: "audio", version: 1, sourceTextHash: sourceHash, ordinal: 0)
        XCTAssertEqual(first.count, 64)
        XCTAssertEqual(first, LyricHash.lineID(audioFingerprint: "audio", version: 1, sourceTextHash: sourceHash, ordinal: 0))
        XCTAssertNotEqual(first, LyricHash.lineID(audioFingerprint: "audio", version: 1, sourceTextHash: sourceHash, ordinal: 1))
        XCTAssertNotEqual(first, LyricHash.lineID(audioFingerprint: "other", version: 1, sourceTextHash: sourceHash, ordinal: 0))
        XCTAssertNotEqual(first, LyricHash.lineID(audioFingerprint: "audio", version: 2, sourceTextHash: sourceHash, ordinal: 0))
        XCTAssertNotEqual(LyricHash.lineID(audioFingerprint: "ab", version: 1, sourceTextHash: "c", ordinal: 0),
                          LyricHash.lineID(audioFingerprint: "a", version: 1, sourceTextHash: "bc", ordinal: 0))
    }
}
