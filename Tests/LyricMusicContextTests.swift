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

    func testMissingPrefixUsesEntranceGapWithoutMovingRecognizedFollowingCharacters() throws {
        var music = analysis()
        music.bars = [10]
        music.instrumentRanges.vocal = [TimeSpan(start: 10.1, duration: 10)]
        let timeline = try LyricAligner.align(sourceText: "ああ　星の海", analysis: music,
            transcription: [token("星", 10.7, 11), token("の", 11, 11.3), token("海", 11.3, 12)])
        let row = timeline.lines[0]
        XCTAssertEqual(row.unrecognizedLeadingCharacters, 2)
        XCTAssertEqual(row.start, 10.7)
        XCTAssertEqual(row.characterTimings[0], row.characterTimings[3])
        let colours = LyricMotion.colourTimings(for: row,
            displayStart: LyricMotion.displayStarts(timeline, analysis: music)[0])
        XCTAssertGreaterThan(LyricMotion.emphasis(time: 10.4, timing: colours[0]), 0)
        XCTAssertEqual(LyricMotion.emphasis(time: 10.4, timing: colours[3]), 0)
        XCTAssertEqual(colours[0], colours[1], "認識されていない文字間を等分した時刻を作らないこと")
        XCTAssertEqual(colours[0].end, row.start)
        XCTAssertEqual(Array(colours[3...]), Array(row.characterTimings[3...]))
        try LyricAligner.validate(timeline, analysis: music)
        XCTAssertEqual(try JSONDecoder().decode(LyricTimeline.self, from: JSONEncoder().encode(timeline)), timeline)
    }

    func testRecognizedLeadingWordKeepsSharedTokenAndFollowingIntervals() throws {
        var music = analysis()
        music.bars = [10]
        music.instrumentRanges.vocal = [TimeSpan(start: 10.1, duration: 10)]
        let timeline = try LyricAligner.align(sourceText: "Alpha beta", analysis: music,
            transcription: [token("Alpha", 10.7, 11), token("beta", 11, 12)])
        let row = timeline.lines[0]
        XCTAssertEqual(row.unrecognizedLeadingCharacters, 0)
        let colours = LyricMotion.colourTimings(for: row,
            displayStart: LyricMotion.displayStarts(timeline, analysis: music)[0])
        XCTAssertGreaterThan(LyricMotion.emphasis(time: 10.4, timing: colours[0]), 0)
        XCTAssertTrue(colours.prefix(5).allSatisfy { $0 == colours[0] })
        XCTAssertEqual(colours[0].end, 11)
        XCTAssertEqual(Array(colours[5...]), Array(row.characterTimings[5...]))
        XCTAssertEqual(LyricMotion.colourTimings(for: row, displayStart: nil), row.characterTimings)
        var legacy = row; legacy.unrecognizedLeadingCharacters = nil
        XCTAssertEqual(LyricMotion.colourTimings(for: legacy, displayStart: 10.1), row.characterTimings)
        var corrupt = row; corrupt.unrecognizedLeadingCharacters = 9
        XCTAssertFalse(corrupt.hasValidCharacterTimings)
        XCTAssertEqual(LyricMotion.colourTimings(for: corrupt, displayStart: 10.1), row.characterTimings)
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
        XCTAssertEqual(LyricMotion.colourTimings(for: result.lines[0], displayStart: 9),
                       result.lines[0].characterTimings, "長い認識区間に含まれる歌唱前の休止を青くしないこと")
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

    func testMusicalEntranceKeepsContinuousRowsAndStaysWithinCurrentBar() throws {
        var music = analysis()
        music.phrases = [TimeSpan(start: 0, duration: 10), TimeSpan(start: 10, duration: 10),
                         TimeSpan(start: 20, duration: 80)]
        music.bars = [8, 12, 16, 20]
        music.instrumentRanges.vocal = [TimeSpan(start: 10.5, duration: 9.5)]
        let timeline = try LyricAligner.align(sourceText: "Alpha\nBravo\nCharlie", analysis: music,
            transcription: [token("Alpha", 12.4, 14), token("Bravo", 14, 16), token("Charlie", 17.5, 19)])
        let starts = LyricMotion.displayStarts(timeline, analysis: music)
        XCTAssertEqual(starts[0], 12, "大きな表示枠でも直前の小節より前へ出さないこと")
        XCTAssertEqual(starts[1], 14, "連続する行を前行の認識区間へ動かさないこと")
        XCTAssertEqual(starts[2], 16)
        XCTAssertEqual(LyricMotion.visibleLines(timeline, at: 12.1, displayStarts: starts).map(\.ordinal), [0])
        XCTAssertEqual(LyricMotion.visibleLines(timeline, at: 14.1, displayStarts: starts).map(\.ordinal), [0, 1])
        XCTAssertTrue(LyricMotion.visibleLines(timeline, at: 9, displayStarts: starts).isEmpty)
        XCTAssertTrue(LyricMotion.visibleLines(timeline, at: 40, displayStarts: starts).isEmpty)
        XCTAssertEqual(timeline.lines.map(\.start), [12.4, 14, 17.5])
        XCTAssertEqual(LyricMotion.emphasis(time: 12.1, timing: timeline.lines[0].characterTimings[0]), 0)
        _ = LyricMotion.visibleLines(timeline, at: 18, displayStarts: starts)
        XCTAssertEqual(LyricMotion.visibleLines(timeline, at: 12.1, displayStarts: starts).map(\.ordinal), [0])
    }

    func testMusicalEntranceRequiresMatchingAnalysisAndAllThreeObservations() throws {
        var music = analysis()
        music.phrases = [TimeSpan(start: 0, duration: 20), TimeSpan(start: 20, duration: 10),
                         TimeSpan(start: 30, duration: 70)]
        music.bars = [10, 20, 30]
        music.instrumentRanges.vocal = [TimeSpan(start: 0, duration: 4), TimeSpan(start: 20.2, duration: 6),
                                        TimeSpan(start: 40, duration: 4)]
        let timeline = try LyricAligner.align(sourceText: "Alpha", analysis: music,
            transcription: [token("Unlisted", 0, 2), token("Alpha", 20.88, 24), token("Extra", 40, 42)])
        XCTAssertEqual(LyricMotion.displayStarts(timeline, analysis: music)[0], 20.2)
        XCTAssertTrue(LyricMotion.visibleLines(timeline, at: 10,
            displayStarts: LyricMotion.displayStarts(timeline, analysis: music)).isEmpty)
        XCTAssertTrue(LyricMotion.displayStarts(timeline, analysis: nil).isEmpty)
        var missing = music; missing.bars = []
        XCTAssertTrue(LyricMotion.displayStarts(timeline, analysis: missing).isEmpty)
        missing = music; missing.instrumentRanges.vocal = [TimeSpan(start: 0, duration: 4)]
        XCTAssertTrue(LyricMotion.displayStarts(timeline, analysis: missing).isEmpty)
        missing = music; missing.fingerprint = String(repeating: "b", count: 64)
        XCTAssertTrue(LyricMotion.displayStarts(timeline, analysis: missing).isEmpty)
        var wrongFrame = timeline; wrongFrame.frames[1].lineOrdinals = []
        XCTAssertTrue(LyricMotion.displayStarts(wrongFrame, analysis: music).isEmpty)
        XCTAssertTrue(LyricMotion.visibleLines(timeline, at: 20,
            displayStarts: LyricMotion.displayStarts(timeline, analysis: missing)).isEmpty)
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
