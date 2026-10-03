import XCTest
@testable import MusicPrayer

final class LyricAlignerTests: XCTestCase {
    private func analysis(duration: Double = 100) -> MusicAnalysis {
        MusicAnalysis(fingerprint: String(repeating: "a", count: 64), duration: duration,
                      sections: [TimeSpan(start: 0, duration: duration)],
                      segments: [TimeSpan(start: 0, duration: duration)],
                      phrases: [TimeSpan(start: 0, duration: duration)])
    }

    private func tokens(_ text: String, start: Double, step: Double = 0.4,
                        confidence: Double = 0.9) -> [RecognizedLyricToken] {
        text.enumerated().map { index, character in
            let time = start + Double(index) * step
            return RecognizedLyricToken(text: String(character), start: time,
                                        end: time + step, confidence: confidence)
        }
    }

    private func assertFailure(_ expected: LyricAlignmentError, source: String,
                               transcription: [RecognizedLyricToken],
                               analysis: MusicAnalysis? = nil,
                               file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try LyricAligner.align(sourceText: source,
                                                  analysis: analysis ?? self.analysis(),
                                                  transcription: transcription), file: file, line: line) {
            XCTAssertEqual($0 as? LyricAlignmentError, expected, file: file, line: line)
        }
    }

    func testUnmatchedIntroAndOutroDoNotShiftNativeWordTimes() throws {
        let speech = tokens("声だけ", start: 0) +
            tokens("朝日が差し込む窓の向こう", start: 20.88, step: 0.3) +
            tokens("余分な声", start: 60)
        let result = try LyricAligner.align(sourceText: "朝日が差し込む 窓の向こう",
                                           analysis: analysis(), transcription: speech)
        XCTAssertEqual(result.mode, .speechRecognition)
        XCTAssertEqual(result.lines[0].start, 20.88)
        XCTAssertEqual(result.lines[0].end, 24.48, accuracy: 1e-9)
        XCTAssertEqual(result.lines[0].confidence, 1)
        XCTAssertEqual(result.lines[0].text, "朝日が差し込む 窓の向こう")
    }

    func testExtraVoiceBetweenLinesIsSkippedAndDoesNotExpandEitherLine() throws {
        let speech = tokens("朝の光", start: 20) + tokens("知らない声", start: 30) +
            tokens("夜の星", start: 40)
        let result = try LyricAligner.align(sourceText: "朝の光\n夜の星",
                                           analysis: analysis(), transcription: speech)
        XCTAssertEqual(result.lines.map(\.start), [20, 40])
        XCTAssertEqual(result.lines[0].end, 21.2, accuracy: 1e-9)
        XCTAssertEqual(result.lines[1].end, 41.2, accuracy: 1e-9)
    }

    func testRepeatedLinesKeepGlobalOrderWithoutReusingRecognition() throws {
        let speech = tokens("ありがとう", start: 10) + tokens("君に届ける", start: 20) +
            tokens("ありがとう", start: 30)
        let result = try LyricAligner.align(sourceText: "ありがとう\n君に届ける\nありがとう",
                                           analysis: analysis(), transcription: speech)
        XCTAssertEqual(result.lines.map(\.start), [10, 20, 30])
        XCTAssertEqual(result.lines.map(\.ordinal), [0, 1, 2])
        XCTAssertEqual(Set(result.lines.map(\.id)).count, 3)
    }

    func testEqualMatchesAtDifferentTimesAreRejectedAsAmbiguous() {
        assertFailure(.ambiguousMatch, source: "ありがとう",
                      transcription: tokens("ありがとう", start: 10) + tokens("ありがとう", start: 40))
    }

    func testJapaneseReadingResolvesEqualSpellingScoresForAnOmittedKanjiBoundary() throws {
        let result = try LyricAligner.align(sourceText: "ひとつひとつの瞬間が", analysis: analysis(),
                                           transcription: tokens("一つひとつの瞬間が", start: 45.42, step: 0.24))
        XCTAssertEqual(result.lines[0].start, 45.42)
        XCTAssertEqual(result.lines[0].end, 47.58, accuracy: 1e-9)
        XCTAssertLessThan(result.confidence, 1)
    }

    func testIdenticalJapaneseReadingsAtDifferentTimesRemainAmbiguous() {
        assertFailure(.ambiguousMatch, source: "ひとつひとつの瞬間が",
                      transcription: tokens("一つひとつの瞬間が", start: 10) +
                        tokens("一つひとつの瞬間が", start: 40))
    }

    func testReadingNeverOverridesBetterOriginalSpellingAgreement() throws {
        let result = try LyricAligner.align(sourceText: "ひとつひとつの瞬間が", analysis: analysis(),
                                           transcription: tokens("ひとつひとつの瞬間が", start: 10) +
                                            tokens("一つひとつの瞬間が", start: 40))
        XCTAssertEqual(result.lines[0].start, 10)
        XCTAssertEqual(result.confidence, 1)
    }

    func testReadingAloneCannotReplaceRequiredSpellingEvidence() {
        assertFailure(.unmatchedLine(0), source: "ひとつ", transcription: tokens("一つ", start: 20))
    }

    func testSpellingErrorsAndMissingCharactersRetainRecognizedBoundaryTimes() throws {
        let input = "当たり前じゃない 今日を生きる"
        let recognized = "当たり前じゃない教生る"
        let result = try LyricAligner.align(sourceText: input, analysis: analysis(),
                                           transcription: tokens(recognized, start: 34.86))
        XCTAssertEqual(result.lines[0].start, 34.86)
        XCTAssertEqual(result.lines[0].end, 34.86 + Double(recognized.count) * 0.4, accuracy: 1e-9)
        XCTAssertGreaterThanOrEqual(result.confidence, 0.6)
        XCTAssertLessThan(result.confidence, 1)
        XCTAssertEqual(result.sourceText, input)
    }

    func testWidthKanaCaseAndPunctuationAreNormalizedOnlyForMatching() throws {
        let input = "  ＡＢＣ、ひかり！\r\n\r\n空。 "
        let speech = [RecognizedLyricToken(text: "abc ヒカリ。", start: 20, end: 23, confidence: 0.9),
                      RecognizedLyricToken(text: "空", start: 30, end: 31, confidence: 0.9)]
        let result = try LyricAligner.align(sourceText: input, analysis: analysis(), transcription: speech)
        XCTAssertEqual(result.sourceText, input)
        XCTAssertEqual(result.lines.map(\.text), ["  ＡＢＣ、ひかり！", "空。 "])
        XCTAssertEqual(result.lines.map(\.start), [20, 30])
        XCTAssertEqual(result.lines.map(\.end), [23, 31])
        XCTAssertEqual(result.confidence, 1)
    }

    func testTextAgreementDoesNotClaimRecognizerConfidence() throws {
        let result = try LyricAligner.align(sourceText: "朝の光", analysis: analysis(),
                                           transcription: tokens("朝の光", start: 20, confidence: 0.1))
        XCTAssertEqual(result.confidence, 1)
    }

    func testColourPreservesMultiCharacterTokensAndTheirSilentGap() throws {
        let result = try LyricAligner.align(sourceText: "朝日 空", analysis: analysis(), transcription: [
            RecognizedLyricToken(text: "朝日", start: 10, end: 11, confidence: 1),
            RecognizedLyricToken(text: "空", start: 13, end: 14, confidence: 1)])
        let timings = result.lines[0].characterTimings
        XCTAssertEqual(timings, [.init(start: 10, end: 11), .init(start: 10, end: 11),
                                .init(start: 11, end: 11), .init(start: 13, end: 14)])
        XCTAssertEqual(LyricMotion.emphasis(time: 12, timing: timings[3]), 0)
        XCTAssertEqual(result.lines[0].start, 10)
        XCTAssertEqual(result.lines[0].end, 14)
        var corrupt = result
        corrupt.lines[0].characterTimings.swapAt(0, 3)
        XCTAssertThrowsError(try LyricAligner.validate(corrupt, analysis: analysis()))
    }

    func testColourKeepsOriginalUnicodeAndGroupsMissingSpelling() throws {
        let source = "  ＡＢＣ、ひかり！"
        let grouped = try LyricAligner.align(sourceText: source, analysis: analysis(),
            transcription: [.init(text: "abc ヒカリ", start: 20, end: 23, confidence: 1)])
        XCTAssertEqual(grouped.lines[0].text, source)
        XCTAssertEqual(grouped.lines[0].characterTimings.count, source.count)
        XCTAssertTrue(grouped.lines[0].hasValidCharacterTimings)
        XCTAssertEqual(grouped.lines[0].characterTimings[2], .init(start: 20, end: 23))
        XCTAssertEqual(grouped.lines[0].characterTimings[7], .init(start: 20, end: 23))
        let missing = try LyricAligner.align(sourceText: "朝日の光", analysis: analysis(),
            transcription: tokens("朝の光", start: 10))
        XCTAssertTrue(missing.lines[0].hasValidCharacterTimings)
        XCTAssertEqual(missing.lines[0].characterTimings[1], missing.lines[0].characterTimings[2])
    }

    func testNoRecognizedWordsAndUnsupportedRowsFailWithoutSignalFallback() {
        var music = analysis()
        music.vocal = [TimeValue(time: 0, value: 1), TimeValue(time: 90, value: 1)]
        music.phrases = [TimeSpan(start: 0, duration: 90)]
        assertFailure(.noRecognizedWords, source: "朝の光", transcription: [], analysis: music)
        assertFailure(.noRecognizedWords, source: "朝の光", transcription: tokens("。！？", start: 1))
        assertFailure(.unmatchedLine(0), source: "。！？", transcription: tokens("朝の光", start: 20))
    }

    func testOneUnmatchedLineRejectsTheEntireTimeline() {
        assertFailure(.unmatchedLine(1), source: "朝の光\n魚は泳ぐ\n夜の星",
                      transcription: tokens("朝の光", start: 10) + tokens("夜の星", start: 30))
    }

    func testOutOfOrderMatchesCannotBeReturnedAsACompleteTimeline() {
        assertFailure(.unmatchedLine(1), source: "朝の光\n夜の星",
                      transcription: tokens("夜の星", start: 10) + tokens("朝の光", start: 30))
    }

    func testOneTimedTokenCannotBeSplitIntoInventedLineTimes() throws {
        let speech = [RecognizedLyricToken(text: "朝の光夜の星", start: 20, end: 26, confidence: 0.9)]
        assertFailure(.unmatchedLine(0), source: "朝の光\n夜の星", transcription: speech)
        let whole = try LyricAligner.align(sourceText: "朝の光 夜の星", analysis: analysis(), transcription: speech)
        XCTAssertEqual(whole.lines[0].start, 20)
        XCTAssertEqual(whole.lines[0].end, 26)
    }

    func testInvalidRecognitionRangesAndConfidenceAreRejected() {
        let invalid: [RecognizedLyricToken] = [
            .init(text: "朝の光", start: .nan, end: 25, confidence: 0.9),
            .init(text: "朝の光", start: -1, end: 25, confidence: 0.9),
            .init(text: "朝の光", start: 25, end: 25, confidence: 0.9),
            .init(text: "朝の光", start: 20, end: 101, confidence: 0.9),
            .init(text: "朝の光", start: 20, end: 25, confidence: .infinity),
            .init(text: "朝の光", start: 20, end: 25, confidence: 1.1)
        ]
        for token in invalid {
            assertFailure(.invalidFinalBoundaries, source: "朝の光", transcription: [token])
        }
        assertFailure(.invalidFinalBoundaries, source: "朝の光", transcription: [
            .init(text: "朝の", start: 20, end: 23, confidence: 0.9),
            .init(text: "光", start: 22, end: 24, confidence: 0.9)
        ])
        assertFailure(.invalidDuration, source: "朝の光", transcription: tokens("朝の光", start: 20),
                      analysis: analysis(duration: .nan))
    }

    func testDigestTracksAudioIdentityDurationAndUsedMusicFeatures() throws {
        var music = analysis()
        let digest = try LyricAligner.analysisDigest(music)
        music.vocal = [TimeValue(time: 0, value: 1)]
        music.phrases = [TimeSpan(start: 0, duration: 30)]
        music.bpm = 120
        XCTAssertNotEqual(try LyricAligner.analysisDigest(music), digest)
        music.vocal = []
        music.phrases = [TimeSpan(start: 0, duration: 100)]
        music.bpm = nil
        XCTAssertEqual(try LyricAligner.analysisDigest(music), digest)
        music.duration = 101
        XCTAssertNotEqual(try LyricAligner.analysisDigest(music), digest)
        music.duration = 100
        music.version += 1
        XCTAssertNotEqual(try LyricAligner.analysisDigest(music), digest)
        music.version -= 1
        music.fingerprint = String(repeating: "b", count: 64)
        XCTAssertNotEqual(try LyricAligner.analysisDigest(music), digest)
    }

    func testEveryAuxiliaryAnalysisChangeInvalidatesSavedFrameContext() throws {
        let original = analysis()
        let digest = try LyricAligner.analysisDigest(original)
        let changes: [(inout MusicAnalysis) -> Void] = [
            { $0.beats = [20] }, { $0.bars = [20] }, { $0.bpm = 96 },
            { $0.drums = [TimeValue(time: 20, value: 0.5)] },
            { $0.bass = [TimeValue(time: 20, value: 0.5)] },
            { $0.other = [TimeValue(time: 20, value: 0.5)] },
            { $0.instrumentRanges.vocal = [TimeSpan(start: 20, duration: 5)] },
            { $0.instrumentRanges.drums = [TimeSpan(start: 20, duration: 5)] },
            { $0.instrumentRanges.bass = [TimeSpan(start: 20, duration: 5)] },
            { $0.instrumentRanges.other = [TimeSpan(start: 20, duration: 5)] },
            { $0.pace = [PaceSpan(range: TimeSpan(start: 0, duration: 100), value: 12)] },
            { $0.keys = [KeySpan(range: TimeSpan(start: 0, duration: 100), label: "C major", hue: 0, minor: false)] },
            { $0.momentary = [TimeValue(time: 20, value: -16)] },
            { $0.shortTerm = [TimeValue(time: 20, value: -16)] },
            { $0.integrated = -14 }, { $0.peak = TimeValue(time: 20, value: -1) }
        ]
        for change in changes {
            var updated = original; change(&updated)
            XCTAssertNotEqual(try LyricAligner.analysisDigest(updated), digest)
        }
    }

    func testCachedTimelineRejectsTamperingAndInvalidIntervals() throws {
        let music = analysis()
        let original = try LyricAligner.align(sourceText: "朝の光\n夜の星", analysis: music,
                                             transcription: tokens("朝の光", start: 20) + tokens("夜の星", start: 40))
        try LyricAligner.validate(original, analysis: music)
        var variants: [LyricTimeline] = []
        var bad = original; bad.version -= 1; variants.append(bad)
        bad = original; bad.analysisVersion += 1; variants.append(bad)
        bad = original; bad.analysisFingerprint = String(repeating: "b", count: 64); variants.append(bad)
        bad = original; bad.analysisDigest = String(repeating: "b", count: 64); variants.append(bad)
        bad = original; bad.sourceTextHash = String(repeating: "b", count: 64); variants.append(bad)
        bad = original; bad.lines.removeLast(); variants.append(bad)
        bad = original; bad.lines[0].id = "modified"; variants.append(bad)
        bad = original; bad.lines[0].ordinal = 1; variants.append(bad)
        bad = original; bad.lines[0].text = "changed"; variants.append(bad)
        bad = original; bad.lines[0].textWeight += 1; variants.append(bad)
        bad = original; bad.lines[0].start = -.infinity; variants.append(bad)
        bad = original; bad.lines[0].end = bad.lines[0].start + 0.29; variants.append(bad)
        bad = original; bad.lines[1].start = bad.lines[0].end - 0.1; variants.append(bad)
        bad = original; bad.lines[1].end = music.duration + 1; variants.append(bad)
        bad = original; bad.lines[0].confidence = 0.5; variants.append(bad)
        bad = original; bad.confidence = 0.9; variants.append(bad)
        bad = original; bad.frames.removeAll(); variants.append(bad)
        bad = original; bad.frames[0].lineOrdinals.removeLast(); variants.append(bad)
        for variant in variants {
            XCTAssertThrowsError(try LyricAligner.validate(variant, analysis: music)) {
                XCTAssertEqual($0 as? LyricAlignmentError, .inconsistentSavedData)
            }
        }
    }

    func testStableResultsUseSourceSpecificIDsWithoutChangingInput() throws {
        let speech = tokens("朝の光", start: 20)
        let first = try LyricAligner.align(sourceText: "朝の光", analysis: analysis(), transcription: speech)
        let second = try LyricAligner.align(sourceText: "朝の光", analysis: analysis(), transcription: speech)
        let punctuated = try LyricAligner.align(sourceText: "朝の光。", analysis: analysis(), transcription: speech)
        XCTAssertEqual(first, second)
        XCTAssertEqual(first.lines[0].start, punctuated.lines[0].start)
        XCTAssertNotEqual(first.lines[0].id, punctuated.lines[0].id)
        XCTAssertNotEqual(first.sourceTextHash, punctuated.sourceTextHash)
    }
}
