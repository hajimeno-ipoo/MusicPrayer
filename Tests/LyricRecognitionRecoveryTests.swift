import XCTest
@testable import MusicPrayer

final class LyricRecognitionRecoveryTests: XCTestCase {
    private let fingerprint = String(repeating: "a", count: 64)
    private func token(_ text: String, _ start: Double, _ end: Double) -> RecognizedLyricToken {
        .init(text: text, start: start, end: end, confidence: 0.9)
    }
    private func analysis() -> MusicAnalysis {
        MusicAnalysis(fingerprint: fingerprint, duration: 60,
            sections: [.init(start: 0, duration: 60)], segments: [.init(start: 0, duration: 60)],
            phrases: [.init(start: 0, duration: 60)])
    }

    func testForeignPrefixUsesSurroundingNativeEdges() throws {
        let speech = [token("고요한밤이와요", 10, 12), token("썸머문라이트", 18, 20),
                      token("반짝이는별빛", 20, 23), token("아침이밝아와요", 30, 32)]
        let windows = try LyricRecognitionRecovery.plan(
            sourceText: "고요한밤이와요\nSummer moonlight 반짝이는별빛\n아침이밝아와요",
            primaryLanguage: "ko", transcription: speech, duration: 60)
        XCTAssertEqual(windows, [.init(start: 12, end: 20, sourceText: "Summer moonlight", language: "en")])
    }

    func testForeignPhraseInsideARowUsesItsOwnAdjacentFragments() throws {
        let speech = [token("고요한밤", 5, 7), token("별빛아래", 10, 12), token("썸머문라이트", 14, 15),
                      token("마음이빛나요", 16, 18), token("새벽이와요", 20, 22)]
        let windows = try LyricRecognitionRecovery.plan(
            sourceText: "고요한밤\n별빛아래 summer moonlight 마음이빛나요\n새벽이와요",
            primaryLanguage: "ko", transcription: speech, duration: 60)
        XCTAssertEqual(windows.map(\.start), [12])
        XCTAssertEqual(windows.map(\.end), [16])
    }

    func testAdjacentForeignRowsShareOneRecognitionWindow() throws {
        let windows = try LyricRecognitionRecovery.plan(
            sourceText: "고요한밤\nSummer moonlight\nGentle morning\n새벽이와요",
            primaryLanguage: "ko", transcription: [token("고요한밤", 5, 7), token("새벽이와요", 20, 22)], duration: 60)
        XCTAssertEqual(windows.count, 1)
        XCTAssertEqual(windows[0].sourceText, "Summer moonlight\nGentle morning")
        XCTAssertEqual(windows[0].start, 7)
        XCTAssertEqual(windows[0].end, 20)
    }

    func testShortAbbreviationInsideEstablishedForeignWindowIsKept() throws {
        let windows = try LyricRecognitionRecovery.plan(
            sourceText: "고요한밤\nSummer moonlight\nAI\nGentle morning\n새벽이와요",
            primaryLanguage: "ko", transcription: [token("고요한밤", 5, 7),
                token("AI", 13, 14), token("새벽이와요", 20, 22)], duration: 60)
        XCTAssertEqual(windows.count, 1)
        XCTAssertEqual(windows[0].sourceText, "Summer moonlight\nAI\nGentle morning")
        let recognized = [token("Summer moonlight", 10, 12), token("AI", 13, 14), token("Gentle morning", 15, 17)]
        let selected = try LyricRecognitionRecovery.select(window: windows[0], analysis: analysis(), alternatives: [recognized])
        XCTAssertEqual(selected, recognized)
    }

    func testMissingLeadingSpellingUsesTheFirstMatchedNativeTokenAsAnchor() throws {
        let windows = try LyricRecognitionRecovery.plan(
            sourceText: "고요한밤\nSummer moonlight 찬란한별빛\n새벽이와요",
            primaryLanguage: "ko", transcription: [token("고요한밤", 0, 2), token("나", 12, 13),
                token("란한별빛", 13, 15), token("새벽이와요", 20, 22)], duration: 60)
        XCTAssertEqual(windows[0].end, 13)
    }

    func testDifferentSingingOccurrencesCannotBecomeAnAnchor() {
        XCTAssertThrowsError(try LyricRecognitionRecovery.plan(sourceText: "밤이와요\nSummer moonlight",
            primaryLanguage: "ko", transcription: [token("밤이와요", 1, 3), token("밤이와요", 10, 12)], duration: 60)) {
                XCTAssertEqual($0 as? LyricAlignmentError, .ambiguousMatch)
        }
    }

    func testShortAbbreviationsAndOneLanguageDoNotRequestRecovery() throws {
        for (source, language) in [("AI의마음", "ko"), ("Summer moonlight", "en"), ("고요한밤", "ko")] {
            XCTAssertTrue(try LyricRecognitionRecovery.plan(sourceText: source, primaryLanguage: language,
                transcription: [token(source, 1, 3)], duration: 60).isEmpty)
        }
    }

    func testSelectionUsesRecognizedTextAgreementAndRejectsUnrelatedOrOutsideTokens() throws {
        let window = LyricRecognitionRecovery.Window(start: 10, end: 20, sourceText: "Summer moonlight", language: "en")
        let exact = [token("Summer", 12, 14), token("moonlight", 15, 18)]
        let result = try LyricRecognitionRecovery.select(window: window, analysis: analysis(), alternatives: [
            [token("winter morning", 10, 20)], exact, [token("Summer moonlight", 0, 4)]])
        XCTAssertEqual(result, exact)
        XCTAssertThrowsError(try LyricRecognitionRecovery.select(window: window, analysis: analysis(),
            alternatives: [[token("the dogs bark", 11, 18)], [token("Summer moonlight", 0, 4)]]))
    }

    func testEqualAgreementAtDifferentSingingPositionsIsAmbiguous() {
        let window = LyricRecognitionRecovery.Window(start: 10, end: 20, sourceText: "Summer moonlight", language: "en")
        XCTAssertThrowsError(try LyricRecognitionRecovery.select(window: window, analysis: analysis(), alternatives: [
            [token("Summer moonlight", 10, 12)], [token("Summer moonlight", 16, 18)]])) {
                XCTAssertEqual($0 as? LyricAlignmentError, .ambiguousMatch)
        }
    }

    func testSameOccurrenceWithDifferentNativeBoundariesKeepsFirstResult() throws {
        let window = LyricRecognitionRecovery.Window(start: 10, end: 20, sourceText: "Summer moonlight", language: "en")
        let first = [token("Summer moonlight", 12, 16)]
        for second in [token("Summer moonlight", 12, 17), token("Summer moonlight", 12.2, 15.8)] {
            XCTAssertEqual(try LyricRecognitionRecovery.select(window: window, analysis: analysis(),
                alternatives: [first, [second]]), first)
        }
    }

    func testClipFrameConversionRemovesOnlyNumericalNoise() {
        XCTAssertEqual(AppleLyricTranscriber.clipFrame(time: 1.0000000000000002, sampleRate: 48_000, isStart: true), 48_000)
        XCTAssertEqual(AppleLyricTranscriber.clipFrame(time: 0.9999999999999998, sampleRate: 48_000, isStart: false), 48_000)
        let fractional = 48_000.4 / 48_000
        XCTAssertEqual(AppleLyricTranscriber.clipFrame(time: fractional, sampleRate: 48_000, isStart: true), 48_001)
        XCTAssertEqual(AppleLyricTranscriber.clipFrame(time: fractional, sampleRate: 48_000, isStart: false), 48_000)
    }

    func testMergeKeepsOutsideNativeRangesAndCannotCutAStraddlingToken() throws {
        let window = LyricRecognitionRecovery.Window(start: 10, end: 20, sourceText: "Summer moonlight", language: "en")
        let before = token("밤이와요", 5, 10), after = token("반짝이는별빛", 20, 25)
        let replacement = [token("Summer moonlight", 12, 19)]
        XCTAssertEqual(try LyricRecognitionRecovery.merge([before, token("썸머", 10, 20), after],
            windows: [window], replacements: [replacement]), [before] + replacement + [after])
        XCTAssertThrowsError(try LyricRecognitionRecovery.merge([token("연결된말", 9, 12), after],
            windows: [window], replacements: [replacement]))
    }
}
