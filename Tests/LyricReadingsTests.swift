import Foundation
import XCTest
@testable import MusicPrayer

final class LyricReadingsTests: XCTestCase {
    func testBundledDictionarySelectsUnambiguousReadingsAndCharacterOffsets() async throws {
        let lines = ["来ない", "来る", "来ます", "行った", "止めた", "一回り", "😀来ない", "方が", "哀く"]
        let source = lines.joined(separator: "\n")
        let plan = try await LyricReadingResolver().prepare(sourceText: source, lines: lines)

        XCTAssertEqual(plan.readings(for: "来ない"), [LyricReading(start: 0, count: 1, salt: 5)])
        XCTAssertEqual(plan.readings(for: "来る"), [LyricReading(start: 0, count: 1, salt: 3)])
        XCTAssertEqual(plan.readings(for: "来ます"), [])
        XCTAssertEqual(plan.readings(for: "行った"), [])
        XCTAssertEqual(plan.readings(for: "止めた"), [])
        XCTAssertEqual(plan.readings(for: "一回り"), [LyricReading(start: 0, count: 2, salt: 2)])
        XCTAssertEqual(plan.readings(for: "😀来ない"), [LyricReading(start: 1, count: 1, salt: 5)])
        XCTAssertEqual(plan.readings(for: "方が"), [LyricReading(start: 0, count: 1, salt: 7)])
        XCTAssertEqual(plan.readings(for: "哀く"), [LyricReading(start: 0, count: 1, salt: 5)])
        XCTAssertTrue(plan.isCurrent(sourceText: source))
    }

    func testReportedLyricPhrasesSelectTheirRequestedReadings() async throws {
        let lines = ["暗闇走り抜ける", "1つの街と人が", "2人でいても離れていても", "車道で踊るあの娘", "想い出を"]
        let source = lines.joined(separator: "\n")
        let plan = try await LyricReadingResolver().prepare(sourceText: source, lines: lines)

        // The consecutive Han run is handled by the bundled font dictionary.
        XCTAssertEqual(plan.readings(for: lines[0]), [])
        XCTAssertEqual(plan.readings(for: lines[1]), [LyricReading(start: 0, count: 1, salt: 1),
                                                    LyricReading(start: 5, count: 1, salt: 3)])
        XCTAssertEqual(plan.readings(for: lines[2]), [LyricReading(start: 0, count: 1, salt: 1),
                                                    LyricReading(start: 1, count: 1, salt: 5)])
        XCTAssertEqual(plan.readings(for: lines[3]), [LyricReading(start: 7, count: 1, salt: 2)])
        XCTAssertEqual(plan.readings(for: lines[4]), [LyricReading(start: 0, count: 1, salt: 3),
                                                    LyricReading(start: 2, count: 1, salt: 3)])
        XCTAssertTrue(plan.isCurrent(sourceText: source))
    }

    func testContextReadingsPreserveOrdinaryDaughterAndApplyToEveryMatch() async throws {
        let lines = ["娘", "娘が", "あの娘", "あの娘が", "😀あの娘とあの娘"]
        let plan = try await LyricReadingResolver().prepare(sourceText: lines.joined(separator: "\n"), lines: lines)

        XCTAssertEqual(plan.readings(for: "娘"), [])
        XCTAssertEqual(plan.readings(for: "娘が"), [])
        XCTAssertEqual(plan.readings(for: "あの娘"), [LyricReading(start: 2, count: 1, salt: 2)])
        XCTAssertEqual(plan.readings(for: "あの娘が"), [LyricReading(start: 2, count: 1, salt: 2)])
        XCTAssertEqual(plan.readings(for: "😀あの娘とあの娘"), [LyricReading(start: 3, count: 1, salt: 2),
                                                              LyricReading(start: 7, count: 1, salt: 2)])
    }

    func testNumberContextReadingsRespectNumberBoundariesAndOverrideOkurigana() async throws {
        let lines = ["1つ", "１つ", "2人", "２人", "12人", "１２人", "２2人", "2２人", "11つ", "１１つ", "１1つ", "1１つ",
                     "😀2人と１つ", "2人が", "２人が"]
        let plan = try await LyricReadingResolver().prepare(sourceText: lines.joined(separator: "\n"), lines: lines)

        for text in ["1つ", "１つ"] {
            XCTAssertEqual(plan.readings(for: text), [LyricReading(start: 0, count: 1, salt: 1)], text)
        }
        for text in ["2人", "２人", "2人が", "２人が"] {
            XCTAssertEqual(plan.readings(for: text), [LyricReading(start: 0, count: 1, salt: 1),
                                                      LyricReading(start: 1, count: 1, salt: 5)], text)
        }
        for text in ["12人", "１２人", "２2人", "2２人", "11つ", "１１つ", "１1つ", "1１つ"] {
            XCTAssertEqual(plan.readings(for: text), [], text)
        }
        XCTAssertEqual(plan.readings(for: "😀2人と１つ"), [LyricReading(start: 1, count: 1, salt: 1),
                                                        LyricReading(start: 2, count: 1, salt: 5),
                                                        LyricReading(start: 4, count: 1, salt: 1)])
    }

    func testAdditionalReportedPhrasesSelectTheirRequestedReadings() async throws {
        let lines = ["2つの国と", "２つの国と", "不満の声", "あなたの声聞きたくて", "金のハンドルで街を飛びまわれ",
                     "胸の鼓動焼きつけろ", "あの時感じた", "AH AHいくつかの場面"]
        let source = lines.joined(separator: "\n")
        let plan = try await LyricReadingResolver().prepare(sourceText: source, lines: lines)

        for text in ["2つの国と", "２つの国と"] {
            XCTAssertEqual(plan.readings(for: text), [LyricReading(start: 0, count: 1, salt: 1)], text)
        }
        XCTAssertEqual(plan.readings(for: "不満の声"), [LyricReading(start: 3, count: 1, salt: 2)])
        XCTAssertEqual(plan.readings(for: "あなたの声聞きたくて"), [])
        XCTAssertEqual(plan.readings(for: "金のハンドルで街を飛びまわれ"), [LyricReading(start: 0, count: 1, salt: 1)])
        // These consecutive Han runs and English words are handled by the font dictionary.
        for text in ["胸の鼓動焼きつけろ", "あの時感じた", "AH AHいくつかの場面"] {
            XCTAssertEqual(plan.readings(for: text), [], text)
        }
        XCTAssertTrue(plan.isCurrent(sourceText: source))
    }

    func testAdditionalContextsPreserveLongerNumbersAndOrdinaryGoldAndUnselectedReadings() async throws {
        let lines = ["12つ", "１２つ", "1２つ", "１2つ", "金の貸し借り", "金", "声聞", "声聞の教え"]
        let plan = try await LyricReadingResolver().prepare(sourceText: lines.joined(separator: "\n"), lines: lines)
        for text in lines {
            XCTAssertEqual(plan.readings(for: text), [], text)
        }
    }

    func testDayAndAdditionalLyricPhrasesUseRequestedReadings() async throws {
        let lines = ["そんな1日でもいいでしょう", "そんな１日でもいいでしょう", "Oh 人生楽ありゃ苦あり",
                     "大きな声で 自由に歌っているの", "もっと楽に生きていきたい",
                     "今朝もミニのスカートで 人ゴミの中走ってく", "ゴミの中走っていく", "走っていく", "candy pretty doll"]
        let source = lines.joined(separator: "\n")
        let plan = try await LyricReadingResolver().prepare(sourceText: source, lines: lines)

        for text in ["そんな1日でもいいでしょう", "そんな１日でもいいでしょう"] {
            XCTAssertEqual(plan.readings(for: text), [LyricReading(start: 3, count: 1, salt: 2),
                                                      LyricReading(start: 4, count: 1, salt: 1)], text)
        }
        XCTAssertEqual(plan.readings(for: "Oh 人生楽ありゃ苦あり"), [LyricReading(start: 3, count: 3, salt: 2),
                                                                  LyricReading(start: 9, count: 1, salt: 1)])
        XCTAssertEqual(plan.readings(for: "大きな声で 自由に歌っているの"), [LyricReading(start: 3, count: 1, salt: 2)])
        XCTAssertEqual(plan.readings(for: "もっと楽に生きていきたい"), [LyricReading(start: 3, count: 1, salt: 2),
                                                                   LyricReading(start: 5, count: 1, salt: 3)])
        let crowdLine = "今朝もミニのスカートで 人ゴミの中走ってく"
        XCTAssertEqual(plan.readings(for: crowdLine), [LyricReading(start: 12, count: 1, salt: 3)],
                       "人ゴミの人にひとを指定し、中走のなかはしは同梱フォントの規則へ任せること")
        for text in ["ゴミの中走っていく", "走っていく", "candy pretty doll"] {
            XCTAssertEqual(plan.readings(for: text), [], text)
        }
        XCTAssertTrue(plan.isCurrent(sourceText: source))
    }

    func testDayContextsExcludeLongerNumbersAndRecomputePreviousVersion() async throws {
        let lines = ["11日", "１１日", "１1日", "1１日", "1つ", "１つ"]
        let resolver = LyricReadingResolver()
        let plan = try await resolver.prepare(sourceText: lines.joined(separator: "\n"), lines: lines)
        for text in ["11日", "１１日", "１1日", "1１日"] {
            XCTAssertEqual(plan.readings(for: text), [], text)
        }
        for text in ["1つ", "１つ"] {
            XCTAssertEqual(plan.readings(for: text), [LyricReading(start: 0, count: 1, salt: 1)], text)
        }
        let source = "そんな1日でもいいでしょう"
        let stale = LyricReadings(version: "rubifont-0.6.18-1", sourceTextHash: LyricHash.text(source), lines: [source: []])
        let refreshed = try await resolver.prepare(sourceText: source, lines: [source], existing: stale)
        XCTAssertEqual(refreshed.version, "rubifont-0.6.19-1")
        XCTAssertEqual(refreshed.readings(for: source), [LyricReading(start: 3, count: 1, salt: 2),
                                                        LyricReading(start: 4, count: 1, salt: 1)])
        XCTAssertTrue(refreshed.isCurrent(sourceText: source))
    }

    func testPreviousDictionaryVersionRecomputesContextReadingsWithoutChangingText() async throws {
        let source = "😀あの娘と2人で想い出を"
        let stale = LyricReadings(version: "rubifont-0.6.18-1", sourceTextHash: LyricHash.text(source), lines: [source: []])
        XCTAssertFalse(stale.isCurrent(sourceText: source))
        let refreshed = try await LyricReadingResolver().prepare(sourceText: source, lines: [source], existing: stale)

        XCTAssertEqual(refreshed.version, "rubifont-0.6.19-1")
        XCTAssertEqual(refreshed.readings(for: source), [LyricReading(start: 3, count: 1, salt: 2),
                                                        LyricReading(start: 5, count: 1, salt: 1),
                                                        LyricReading(start: 6, count: 1, salt: 5),
                                                        LyricReading(start: 8, count: 1, salt: 3),
                                                        LyricReading(start: 10, count: 1, salt: 3)])
        XCTAssertEqual(refreshed.sourceTextHash, LyricHash.text(source))
        XCTAssertTrue(refreshed.isCurrent(sourceText: source))

        let voiceSource = "あなたの声聞きたくて"
        let oldVoicePlan = LyricReadings(version: "rubifont-0.6.16-1", sourceTextHash: LyricHash.text(voiceSource),
                                        lines: [voiceSource: [LyricReading(start: 4, count: 2, salt: 2)]])
        let voiceRefreshed = try await LyricReadingResolver().prepare(sourceText: voiceSource, lines: [voiceSource],
                                                                     existing: oldVoicePlan)
        XCTAssertEqual(voiceRefreshed.version, "rubifont-0.6.19-1")
        XCTAssertEqual(voiceRefreshed.readings(for: voiceSource), [], "旧辞書の声聞salt2指定を新辞書へ持ち越さないこと")
        XCTAssertTrue(voiceRefreshed.isCurrent(sourceText: voiceSource))

        let crowdSource = "今朝もミニのスカートで 人ゴミの中走ってく"
        let oldCrowdPlan = LyricReadings(version: "rubifont-0.6.18-1", sourceTextHash: LyricHash.text(crowdSource),
                                        lines: [crowdSource: []])
        let crowdRefreshed = try await LyricReadingResolver().prepare(sourceText: crowdSource, lines: [crowdSource],
                                                                     existing: oldCrowdPlan)
        XCTAssertEqual(crowdRefreshed.version, "rubifont-0.6.19-1")
        XCTAssertEqual(crowdRefreshed.readings(for: crowdSource), [LyricReading(start: 12, count: 1, salt: 3)])
        XCTAssertTrue(crowdRefreshed.isCurrent(sourceText: crowdSource))
    }

    func testPreparedReadingsAreReusedAndStaleOrIncompletePlansArePreparedAgain() async throws {
        let resolver = LyricReadingResolver()
        let source = "来ない\n来ます"
        let lines = ["来ない", "来ます"]
        let current = try await resolver.prepare(sourceText: source, lines: lines)
        let reused = try await resolver.prepare(sourceText: source, lines: lines, existing: current)
        XCTAssertEqual(reused, current)

        var stale = current
        stale.version = "old-reading-data"
        stale.lines["来ない"] = []
        let refreshed = try await resolver.prepare(sourceText: source, lines: lines, existing: stale)
        XCTAssertEqual(refreshed, current)

        var incomplete = current
        incomplete.lines.removeValue(forKey: "来ます")
        let completed = try await resolver.prepare(sourceText: source, lines: lines, existing: incomplete)
        XCTAssertEqual(completed, current)

        let editedSource = "来る\n来ます"
        let edited = try await resolver.prepare(sourceText: editedSource, lines: ["来る", "来ます"], existing: current)
        XCTAssertFalse(current.isCurrent(sourceText: editedSource))
        XCTAssertTrue(edited.isCurrent(sourceText: editedSource))
        XCTAssertEqual(edited.readings(for: "来る"), [LyricReading(start: 0, count: 1, salt: 3)])
        XCTAssertEqual(edited.readings(for: "来ます"), [])
    }

    func testReadingsPersistAlongsideUnchangedTimingsAndCanBeAddedToOldLyrics() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MusicPrayerReadings-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let audio = root.appendingPathComponent("audio.bin")
        try Data((0..<140_000).map { UInt8($0 % 251) }).write(to: audio)
        let directory = root.appendingPathComponent("Lyrics")
        let store = LyricStore(directory: directory)
        let source = "来ない\n来ます"
        let fingerprint = try await store.saveText(url: audio, text: source, request: 1)
        let timeline = makeTimeline(fingerprint: fingerprint, source: source)
        let resolver = LyricReadingResolver()
        let plan = try await resolver.prepare(sourceText: source, lines: timeline.lines.map(\.text))
        try await store.saveTimeline(timeline, request: 1, readings: plan)
        let saved = try await store.load(fingerprint: fingerprint)
        XCTAssertEqual(saved?.readings, plan)
        XCTAssertEqual(saved?.readings?.readings(for: "来ます"), [])
        XCTAssertEqual(saved?.sourceText, source)
        XCTAssertEqual(saved?.timeline, timeline)

        let file = directory.appendingPathComponent("\(fingerprint).json")
        var oldEnvelope = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        oldEnvelope.removeValue(forKey: "readings")
        try JSONSerialization.data(withJSONObject: oldEnvelope).write(to: file, options: .atomic)
        let old = try await store.load(fingerprint: fingerprint)
        XCTAssertNil(old?.readings)
        XCTAssertEqual(old?.timeline, timeline)
        let completed = try await resolver.prepare(sourceText: source, lines: timeline.lines.map(\.text), existing: old?.readings)
        try await store.saveTimeline(timeline, request: 1, readings: completed)
        let restored = try await store.load(fingerprint: fingerprint)
        XCTAssertEqual(restored?.readings, plan)
        XCTAssertEqual(restored?.timeline, timeline)
    }

    private func makeTimeline(fingerprint: String, source: String) -> LyricTimeline {
        let hash = LyricHash.text(source)
        let lines = LyricParser.parse(source).map { line in
            TimedLyricLine(id: LyricHash.lineID(audioFingerprint: fingerprint, version: LyricVersions.alignment,
                                              sourceTextHash: hash, ordinal: line.ordinal),
                           ordinal: line.ordinal, text: line.text,
                           start: Double(line.ordinal) * 2 + 1, end: Double(line.ordinal) * 2 + 2,
                           textWeight: line.textWeight, confidence: 0.5,
                           characterTimings: line.text.map { _ in
                               LyricCharacterTiming(start: Double(line.ordinal) * 2 + 1,
                                                    end: Double(line.ordinal) * 2 + 2)
                           })
        }
        return LyricTimeline(version: LyricVersions.alignment, analysisVersion: MusicAnalyzer.cacheVersion,
                             analysisFingerprint: fingerprint, analysisDigest: String(repeating: "d", count: 64),
                             sourceText: source, sourceTextHash: hash, mode: .speechRecognition,
                             lines: lines, confidence: 0.5,
                             frames: [LyricStructureFrame(start: 0, end: Double(lines.count) * 2 + 1,
                                 section: 0, segment: 0, lineOrdinals: lines.map(\.ordinal),
                                 support: LyricFrameSupport())])
    }
}
