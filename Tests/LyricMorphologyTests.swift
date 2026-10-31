import Foundation
import XCTest
@testable import MusicPrayer

final class LyricMorphologyTests: XCTestCase {
    func testStandardDictionarySplitsAdjacentWordsAndUsesCharacterOffsets() throws {
        let text = "😀砂遥か越えて行く"
        let tokens = try LyricMorphology.tokens(in: text)
        XCTAssertEqual(tokens.prefix(2).map(\.text), ["砂", "遥か"])
        XCTAssertEqual(tokens.prefix(2).map(\.reading), ["すな", "はるか"])
        XCTAssertEqual(tokens.prefix(2).map(\.start), [1, 2], "UTF-16 offsets must not displace selections after emoji")
        let characters = Array(text)
        for token in tokens {
            XCTAssertEqual(String(characters[token.start..<(token.start + token.text.count)]), token.text)
        }
        XCTAssertEqual(try LyricMorphology.tokens(in: "抱き上げる").map(\.reading), ["だきあげる"])
        XCTAssertEqual(try LyricMorphology.tokens(in: "English 123 😀"), [])
    }

    func testWholeSourceAndBareLinesKeepTheSameDefaultReadings() async throws {
        let lines = ["金", "明日", "灯火"]
        let source = lines.joined(separator: "\n")
        let plan = try await LyricReadingResolver().prepare(sourceText: source, lines: [source] + lines)
        for text in [source] + lines { XCTAssertEqual(plan.readings(for: text), [], text) }
    }

    func testAlignmentRequiresCompleteUniqueCandidateMatch() {
        let parts: [LyricReadingAlignment.Part] = [
            .init(start: 2, count: 1, choices: [("いだ", 1), ("だ", 3)]),
            .init(start: 3, count: 1, choices: [("き", 0)]),
            .init(start: 4, count: 1, choices: [("あ", 2), ("うえ", 4)]),
            .init(start: 5, count: 1, choices: [("げ", 0)]),
            .init(start: 6, count: 1, choices: [("る", 0)])
        ]
        XCTAssertEqual(LyricReadingAlignment.match(reading: "だきあげる", parts: parts), [
            LyricReading(start: 2, count: 1, salt: 3), LyricReading(start: 4, count: 1, salt: 2)
        ])
        XCTAssertNil(LyricReadingAlignment.match(reading: "だきあげ", parts: parts))
        XCTAssertNil(LyricReadingAlignment.match(reading: "だきあげるよ", parts: parts))
        XCTAssertNil(LyricReadingAlignment.match(reading: "かきあげる", parts: parts))
        let ambiguous: [LyricReadingAlignment.Part] = [
            .init(start: 0, count: 1, choices: [("あ", 1), ("あい", 2)]),
            .init(start: 1, count: 1, choices: [("いう", 1), ("う", 2)])
        ]
        XCTAssertNil(LyricReadingAlignment.match(reading: "あいう", parts: ambiguous), "Do not guess a split when multiple candidates fit")
    }

    func testMorphologySupplementsUnregisteredPhrasesAndPreservesExplicitLyrics() async throws {
        let lines = ["傍で歌う", "静かな声", "抱き寄せた", "語り継がれる", "入る", "行った", "😀傍で歌う",
                     "あの娘が笑う", "金のハンドル", "来ぬ人", "明日", "灯火", "11日", "12人", "花咲く"]
        let source = lines.joined(separator: "\n")
        let resolver = LyricReadingResolver()
        let old = LyricReadings(version: "rubifont-0.6.23-1", sourceTextHash: LyricHash.text(source),
            lines: Dictionary(uniqueKeysWithValues: lines.map { ($0, []) }))
        let plan = try await resolver.prepare(sourceText: source, lines: lines, existing: old)
        XCTAssertEqual(plan.readings(for: "傍で歌う"), [LyricReading(start: 0, count: 1, salt: 3)])
        XCTAssertEqual(plan.readings(for: "静かな声"), [LyricReading(start: 3, count: 1, salt: 2)])
        XCTAssertEqual(plan.readings(for: "抱き寄せた"), [LyricReading(start: 0, count: 1, salt: 3)])
        XCTAssertEqual(plan.readings(for: "語り継がれる"), [LyricReading(start: 0, count: 1, salt: 4)])
        XCTAssertEqual(plan.readings(for: "入る"), [LyricReading(start: 0, count: 1, salt: 3)])
        XCTAssertEqual(plan.readings(for: "行った"), [LyricReading(start: 0, count: 1, salt: 3)])
        XCTAssertEqual(plan.readings(for: "😀傍で歌う"), [LyricReading(start: 1, count: 1, salt: 3)])
        XCTAssertEqual(plan.readings(for: "あの娘が笑う"), [LyricReading(start: 2, count: 1, salt: 2)], "Explicit こ must win over the OS むすめ")
        XCTAssertEqual(plan.readings(for: "金のハンドル"), [LyricReading(start: 0, count: 1, salt: 1)], "Explicit きん must win over the OS かね")
        XCTAssertEqual(plan.readings(for: "来ぬ人"), [LyricReading(start: 0, count: 1, salt: 5), LyricReading(start: 2, count: 1, salt: 3)], "The こぬ pair must win over the OS きぬ")
        for text in ["明日", "灯火", "11日", "12人", "花咲く"] {
            XCTAssertEqual(plan.readings(for: text), [], "Preserve bare defaults, number rules and unsupported adjacent Han: \(text)")
        }
        XCTAssertEqual(plan.version, LyricReadings.currentVersion)
        XCTAssertTrue(plan.isCurrent(sourceText: source))
        let restored = try JSONDecoder().decode(LyricReadings.self, from: JSONEncoder().encode(plan))
        let reused = try await resolver.prepare(sourceText: source, lines: lines, existing: restored)
        XCTAssertEqual(reused, restored)
    }
}
