import XCTest
@testable import MusicPrayer

final class LyricMusicContextTests: XCTestCase {
    private func analysis() -> MusicAnalysis {
        let range = TimeSpan(start: 0, duration: 100)
        return MusicAnalysis(fingerprint: String(repeating: "a", count: 64), duration: 100,
                             sections: [range], segments: [range], phrases: [range])
    }

    private func token(_ text: String, _ start: Double, _ end: Double) -> RecognizedLyricToken {
        .init(text: text, start: start, end: end, confidence: 0.9)
    }

    func testLongLeadingPauseAffectsOnlyColourAndNeedsLoudnessSupport() throws {
        var music = analysis()
        music.bpm = 100
        music.vocal = [.init(time: 10, value: 0.7), .init(time: 11, value: 0.2),
                       .init(time: 12, value: 0.8), .init(time: 12.5, value: 0.9)]
        music.momentary = [.init(time: 10, value: -15), .init(time: 11.9, value: -25),
                          .init(time: 12.2, value: -15), .init(time: 12.8, value: -14)]
        let speech = [token("朝", 10, 13), token("日", 13, 13.4), token("光", 14, 14.4)]
        let result = try LyricAligner.align(sourceText: "朝日光", analysis: music, transcription: speech)
        XCTAssertEqual(result.lines[0].start, 10)
        XCTAssertEqual(result.lines[0].end, 14.4)
        XCTAssertEqual(result.lines[0].characterTimings, [.init(start: 12, end: 13),
            .init(start: 13, end: 13.4), .init(start: 14, end: 14.4)])
        XCTAssertEqual(LyricMotion.emphasis(time: 11.99, timing: result.lines[0].characterTimings[0]), 0)
        music.momentary = [.init(time: 10, value: -15), .init(time: 11.9, value: -16),
                          .init(time: 12.2, value: -20), .init(time: 12.8, value: -22)]
        let unsupported = try LyricAligner.align(sourceText: "朝日光", analysis: music, transcription: speech)
        XCTAssertEqual(unsupported.lines[0].characterTimings[0].start, 10)
        let short = try LyricAligner.align(sourceText: "朝日光", analysis: music,
            transcription: [token("朝", 11.8, 12.3), token("日", 13, 13.4), token("光", 14, 14.4)])
        XCTAssertEqual(short.lines[0].characterTimings[0].start, 11.8)
    }

    func testSeveralRowsShareOneFrameWithoutSharingTheirWordTimes() throws {
        let timeline = try LyricAligner.align(sourceText: "Alpha\nBravo\nCharlie", analysis: analysis(),
            transcription: [token("Alpha", 10, 12), token("Bravo", 12, 14), token("Charlie", 14, 17)])
        XCTAssertEqual(timeline.frames.count, 1)
        XCTAssertEqual(timeline.frames[0].lineOrdinals, [0, 1, 2])
        XCTAssertEqual(timeline.lines.map(\.start), [10, 12, 14])
        XCTAssertEqual(timeline.lines.map(\.end), [12, 14, 17])
        XCTAssertEqual(LyricMotion.visibleLines(timeline, at: 13).map(\.ordinal), [1])
        XCTAssertEqual(LyricMotion.visibleLines(timeline, at: 15).map(\.ordinal), [2])
    }

    func testRowKeepsItsIDAndTimeAcrossAllIntersectingFramesIncludingShortFringe() throws {
        var music = analysis()
        music.phrases = [TimeSpan(start: 0, duration: 10), TimeSpan(start: 10, duration: 90)]
        let timeline = try LyricAligner.align(sourceText: "Alpha", analysis: music,
                                              transcription: [token("Alpha", 9.951, 12)])
        XCTAssertEqual(timeline.frames.map(\.lineOrdinals), [[0], [0]])
        XCTAssertEqual(timeline.lines[0].start, 9.951)
        for time in [9.8, 9.999, 10.0, 10.001, 11.9, 12.2] {
            XCTAssertEqual(LyricMotion.visibleLines(timeline, at: time).map(\.id), [timeline.lines[0].id])
        }
    }

    func testVoiceWithoutMatchingTextDoesNotPopulateIntroOrOutroFrames() throws {
        var music = analysis()
        music.phrases = [TimeSpan(start: 0, duration: 20), TimeSpan(start: 20, duration: 10),
                         TimeSpan(start: 30, duration: 70)]
        music.vocal = [TimeValue(time: 0, value: 1), TimeValue(time: 20, value: 0.8), TimeValue(time: 40, value: 1)]
        music.instrumentRanges.vocal = [TimeSpan(start: 0, duration: 100)]
        let timeline = try LyricAligner.align(sourceText: "Alpha", analysis: music,
            transcription: [token("Unlisted", 0, 2), token("Alpha", 20.88, 24), token("Extra", 40, 42)])
        XCTAssertEqual(timeline.frames.map(\.lineOrdinals), [[], [0], []])
        XCTAssertEqual(timeline.lines[0].start, 20.88)
        XCTAssertTrue(LyricMotion.visibleLines(timeline, at: 10).isEmpty)
        XCTAssertTrue(LyricMotion.visibleLines(timeline, at: 40).isEmpty)
    }

    func testAllSixAnalysisTypesSupportTheSameFrameWithoutMovingWords() throws {
        var music = analysis()
        music.phrases = [TimeSpan(start: 0, duration: 10), TimeSpan(start: 10, duration: 10),
                         TimeSpan(start: 20, duration: 80)]
        music.beats = [9, 10, 12, 18, 20]; music.bars = [10, 20]; music.bpm = 96
        music.pace = [PaceSpan(range: TimeSpan(start: 0, duration: 100), value: 12)]
        music.keys = [KeySpan(range: TimeSpan(start: 0, duration: 100), label: "C major", hue: 0, minor: false)]
        music.vocal = [TimeValue(time: 12, value: 0.4), TimeValue(time: 18, value: 0.8)]
        music.drums = [TimeValue(time: 12, value: 0.2)]
        music.bass = [TimeValue(time: 12, value: 0.3)]
        music.other = [TimeValue(time: 12, value: 0.6)]
        music.instrumentRanges = InstrumentRanges(vocal: [TimeSpan(start: 10, duration: 10)],
            drums: [TimeSpan(start: 0, duration: 5)], bass: [TimeSpan(start: 12, duration: 1)],
            other: [TimeSpan(start: 0, duration: 100)])
        music.momentary = [TimeValue(time: 12, value: -18), TimeValue(time: 18, value: -12)]
        music.shortTerm = [TimeValue(time: 15, value: -16)]
        music.integrated = -14; music.peak = TimeValue(time: 50, value: -0.5)
        let timeline = try LyricAligner.align(sourceText: "Alpha", analysis: music,
                                              transcription: [token("Alpha", 11.5, 18.5)])
        let frame = timeline.frames[1]
        XCTAssertEqual(frame.section, 0); XCTAssertEqual(frame.segment, 0)
        XCTAssertEqual(frame.support.instrumentPresence, ["vocal": true, "drums": false, "bass": true, "other": true])
        XCTAssertEqual(frame.support.activity["vocal"]!, 0.6, accuracy: 1e-6)
        XCTAssertEqual(Set(frame.support.activity.keys), Set(["vocal", "drums", "bass", "other"]))
        XCTAssertEqual(frame.support.beats, 3); XCTAssertEqual(frame.support.bars, 1)
        XCTAssertEqual(frame.support.bpm, 96); XCTAssertEqual(frame.support.pace, [12])
        XCTAssertEqual(frame.support.keys, ["C major"])
        XCTAssertEqual(frame.support.momentary, -15); XCTAssertEqual(frame.support.shortTerm, -16)
        XCTAssertEqual(frame.support.integrated, -14); XCTAssertEqual(frame.support.peak, music.peak)
        XCTAssertEqual(timeline.lines[0].start, 11.5); XCTAssertEqual(timeline.lines[0].end, 18.5)
        try LyricAligner.validate(timeline, analysis: music)
        var damaged = timeline; damaged.frames[1].support.activity["vocal"] = 0
        XCTAssertThrowsError(try LyricAligner.validate(damaged, analysis: music))
    }

    func testStructureCannotChooseBetweenIdenticalTextCorrespondences() {
        var music = analysis()
        music.sections = [TimeSpan(start: 0, duration: 40), TimeSpan(start: 40, duration: 60)]
        music.segments = music.sections; music.phrases = music.sections
        XCTAssertThrowsError(try LyricAligner.align(sourceText: "Alpha\n\nBravo", analysis: music,
            transcription: [token("Alpha", 10, 12), token("Bravo", 20, 22), token("Bravo", 40, 42)])) {
            XCTAssertEqual($0 as? LyricAlignmentError, .ambiguousMatch)
        }
    }

    func testMissingStructureAndRealCoverageGapsDoNotInventFrames() {
        var missing = analysis(); missing.phrases = []
        XCTAssertThrowsError(try LyricAligner.align(sourceText: "Alpha", analysis: missing,
            transcription: [token("Alpha", 10, 12)])) {
            XCTAssertEqual($0 as? LyricAlignmentError, .analysisUnavailable)
        }
        var gap = analysis()
        gap.phrases = [TimeSpan(start: 0, duration: 10), TimeSpan(start: 11, duration: 89)]
        XCTAssertThrowsError(try LyricAligner.align(sourceText: "Alpha", analysis: gap,
            transcription: [token("Alpha", 9, 12)])) {
            XCTAssertEqual($0 as? LyricAlignmentError, .invalidFinalBoundaries)
        }
    }
}
