import XCTest
@testable import MusicPrayer

final class AnalysisTests: XCTestCase {
    func testUnanalyzedAndOutsideSongHaveNoInventedMusic() {
        XCTAssertNil(TimelineSampler.sample(nil, at: 2).bpm)
        var analysis = MusicAnalysis(duration: 10)
        analysis.bpm = 120
        analysis.pace = [PaceSpan(range: TimeSpan(start: 0, duration: 10), value: 112)]
        for time in [-1.0, 10.0, 12.0, .nan, .infinity] {
            let sample = TimelineSampler.sample(analysis, at: time)
            XCTAssertNil(sample.bpm)
            XCTAssertNil(sample.pace)
            XCTAssertEqual(sample.beat, 0)
        }
        let incomplete = TimelineSampler.sample(MusicAnalysis(duration: 10), at: 2)
        XCTAssertNil(incomplete.vocal)
        XCTAssertNil(incomplete.key)
        XCTAssertNil(incomplete.momentary)
    }

    func testSectionBoundaryIsOwnedByFollowingSectionAndSeekIsStateless() {
        var analysis = MusicAnalysis(duration: 30)
        analysis.sections = [TimeSpan(start: 0, duration: 10), TimeSpan(start: 10, duration: 20)]
        analysis.phrases = [TimeSpan(start: 10, duration: 4)]
        XCTAssertEqual(TimelineSampler.sample(analysis, at: 9.999).section, 1)
        let boundary = TimelineSampler.sample(analysis, at: 10)
        XCTAssertEqual(boundary.section, 2)
        XCTAssertEqual(boundary.sectionProgress, 0)
        XCTAssertEqual(boundary.sectionTransition, 1)
        _ = TimelineSampler.sample(analysis, at: 26)
        let seekBack = TimelineSampler.sample(analysis, at: 12)
        XCTAssertEqual(seekBack.section, 2)
        XCTAssertEqual(seekBack.sectionProgress, 0.1, accuracy: 0.0001)
        XCTAssertEqual(seekBack.phraseProgress, 0.5, accuracy: 0.0001)
        XCTAssertEqual(seekBack.sectionTransition, 0)
    }

    func testRangeGapsAndTimeSeriesEndsStayAbsent() {
        var analysis = MusicAnalysis(duration: 20)
        analysis.pace = [PaceSpan(range: TimeSpan(start: 2, duration: 2), value: 80),
                         PaceSpan(range: TimeSpan(start: 8, duration: 3), value: 110)]
        analysis.vocal = [TimeValue(time: 2, value: 0.2), TimeValue(time: 4, value: 0.8)]
        XCTAssertNil(TimelineSampler.sample(analysis, at: 1).vocal)
        XCTAssertEqual(TimelineSampler.sample(analysis, at: 3).vocal!, 0.5, accuracy: 0.0001)
        XCTAssertEqual(TimelineSampler.sample(analysis, at: 4).vocal, 0.8)
        XCTAssertNil(TimelineSampler.sample(analysis, at: 4).pace)
        XCTAssertNil(TimelineSampler.sample(analysis, at: 5).vocal)
        XCTAssertNil(TimelineSampler.sample(analysis, at: 7).pace)
        XCTAssertEqual(TimelineSampler.sample(analysis, at: 8).pace, 110)
    }

    func testBeatPhaseUsesRealIntervalsAndPeakIsOnlyAtItsTimestamp() {
        var analysis = MusicAnalysis(duration: 20)
        analysis.beats = [2, 2.5, 3.25]
        analysis.bars = [2, 4]
        analysis.peak = TimeValue(time: 7, value: -0.8)
        XCTAssertEqual(TimelineSampler.sample(analysis, at: 1.99).beat, 0)
        XCTAssertEqual(TimelineSampler.sample(analysis, at: 2).beat, 1)
        XCTAssertEqual(TimelineSampler.sample(analysis, at: 2.25).beatPhase, 0.5, accuracy: 0.0001)
        XCTAssertEqual(TimelineSampler.sample(analysis, at: 2.875).beatPhase, 0.5, accuracy: 0.0001)
        XCTAssertEqual(TimelineSampler.sample(analysis, at: 3.25).beatPhase, 0)
        XCTAssertEqual(TimelineSampler.sample(analysis, at: 6.99).peak, 0)
        XCTAssertEqual(TimelineSampler.sample(analysis, at: 7).peak, 1)
        XCTAssertGreaterThan(TimelineSampler.sample(analysis, at: 7.05).peak, 0)
        XCTAssertEqual(TimelineSampler.sample(analysis, at: 8).peak, 0)
    }

    func testCacheModelRoundTripsMissingAndPresentResults() throws {
        var analysis = MusicAnalysis(fingerprint: "source-sha256", duration: 12)
        analysis.keys = [KeySpan(range: TimeSpan(start: 0, duration: 12), label: "A minor", hue: 0.021, minor: true)]
        analysis.momentary = [TimeValue(time: 0, value: -20), TimeValue(time: 10, value: -12)]
        let restored = try JSONDecoder().decode(MusicAnalysis.self, from: JSONEncoder().encode(analysis))
        XCTAssertEqual(restored.fingerprint, "source-sha256")
        XCTAssertEqual(restored.version, MusicAnalyzer.cacheVersion)
        let moment = TimelineSampler.sample(restored, at: 5)
        XCTAssertEqual(moment.key, "A minor")
        XCTAssertEqual(moment.modeBias, -1)
        XCTAssertEqual(moment.momentary!, -16, accuracy: 0.0001)
        XCTAssertNil(moment.bpm)
        XCTAssertNil(moment.shortTerm)
    }
}
