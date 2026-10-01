import XCTest
@testable import MusicPrayer

final class SectionSceneTests: XCTestCase {
    func testEqualSectionMeansHaveEqualScenesRegardlessOfNumber() {
        var analysis = MusicAnalysis(duration: 20)
        analysis.sections = [TimeSpan(start: 0, duration: 10), TimeSpan(start: 10, duration: 10)]
        analysis.pace = [PaceSpan(range: TimeSpan(start: 0, duration: 20), value: 120)]
        analysis.vocal = constant(0.7, end: 20)
        analysis.drums = constant(0.4, end: 20)
        analysis.bass = constant(0.8, end: 20)
        analysis.other = constant(0.6, end: 20)
        analysis.momentary = constant(-16, end: 20)
        analysis.shortTerm = constant(-19, end: 20)
        let scenes = SectionScenes.make(analysis)
        assertEqual(scenes[0], scenes[1])
    }

    func testHigherMeasuredActivityAndLoudnessChangeSceneInExpectedDirection() {
        var low = MusicAnalysis(duration: 10)
        low.sections = [TimeSpan(start: 0, duration: 10)]
        low.pace = [PaceSpan(range: low.sections[0], value: 25)]
        low.vocal = constant(0.1, end: 10)
        low.drums = constant(0.1, end: 10)
        low.bass = constant(0.1, end: 10)
        low.other = constant(0.1, end: 10)
        low.momentary = constant(-28, end: 10)
        low.shortTerm = constant(-28, end: 10)
        var high = low
        high.pace[0].value = 155
        high.vocal = constant(0.9, end: 10)
        high.drums = constant(0.9, end: 10)
        high.bass = constant(0.9, end: 10)
        high.other = constant(0.9, end: 10)
        high.momentary = constant(-8, end: 10)
        high.shortTerm = constant(-8, end: 10)
        let a = SectionScenes.make(low)[0], b = SectionScenes.make(high)[0]
        XCTAssertGreaterThan(b.separation, a.separation)
        XCTAssertGreaterThan(b.thickness, a.thickness)
        XCTAssertGreaterThan(b.depth, a.depth)
        XCTAssertGreaterThan(b.glow, a.glow)
        XCTAssertGreaterThan(b.water, a.water)
        for value in [a.separation, a.thickness, a.depth, a.glow, a.water,
                      b.separation, b.thickness, b.depth, b.glow, b.water] {
            XCTAssertTrue((0...1).contains(value))
        }
    }

    func testAbsentAndOutOfCoverageMeasurementsUseNeutralVisualScene() {
        var analysis = MusicAnalysis(duration: 30)
        analysis.sections = [TimeSpan(start: 0, duration: 5), TimeSpan(start: 20, duration: 5)]
        XCTAssertTrue(SectionScenes.make(MusicAnalysis()).isEmpty)
        for scene in SectionScenes.make(analysis) { assertEqual(scene, SectionScene()) }
        analysis.pace = [PaceSpan(range: TimeSpan(start: 10, duration: 5), value: 170)]
        analysis.vocal = [TimeValue(time: 10, value: 0.9), TimeValue(time: 15, value: 0.9)]
        analysis.momentary = [TimeValue(time: 10, value: -6), TimeValue(time: 15, value: -6)]
        for scene in SectionScenes.make(analysis) { assertEqual(scene, SectionScene()) }
    }

    func testRangeOverlapDurationWeightsMeasurementsAndExcludesGaps() {
        var analysis = MusicAnalysis(duration: 10)
        analysis.sections = [TimeSpan(start: 2, duration: 6)]
        // The section overlaps value 0 for one second and 180 for three seconds.
        // The two-second gap is absent data, so the observed mean is 135.
        analysis.pace = [PaceSpan(range: TimeSpan(start: 0, duration: 3), value: 0),
                         PaceSpan(range: TimeSpan(start: 5, duration: 5), value: 180)]
        var equivalent = analysis
        equivalent.pace = [PaceSpan(range: analysis.sections[0], value: 135)]
        assertEqual(SectionScenes.make(analysis)[0], SectionScenes.make(equivalent)[0])
    }

    func testIrregularTimeSamplesUseIntegratedMeanInsteadOfSampleCount() {
        var analysis = MusicAnalysis(duration: 10)
        analysis.sections = [TimeSpan(start: 0, duration: 10)]
        // Linear interpolation: areas 0.5 over 0...1 and 9 over 1...10 => mean 0.95.
        analysis.bass = [TimeValue(time: 0, value: 0), TimeValue(time: 1, value: 1), TimeValue(time: 10, value: 1)]
        var equivalent = analysis
        equivalent.bass = constant(0.95, end: 10)
        assertEqual(SectionScenes.make(analysis)[0], SectionScenes.make(equivalent)[0])
        // A clipped section inside a ramp also needs interpolated values at both edges.
        analysis.sections = [TimeSpan(start: 2, duration: 4)]
        analysis.bass = [TimeValue(time: 0, value: 0), TimeValue(time: 10, value: 1)]
        equivalent = analysis
        equivalent.bass = constant(0.4, end: 10)
        assertEqual(SectionScenes.make(analysis)[0], SectionScenes.make(equivalent)[0])
    }

    private func constant(_ value: Float, end: Double) -> [TimeValue] {
        [TimeValue(time: 0, value: value), TimeValue(time: end, value: value)]
    }

    private func assertEqual(_ a: SectionScene, _ b: SectionScene,
                             file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(a.separation, b.separation, accuracy: 0.00001, file: file, line: line)
        XCTAssertEqual(a.thickness, b.thickness, accuracy: 0.00001, file: file, line: line)
        XCTAssertEqual(a.depth, b.depth, accuracy: 0.00001, file: file, line: line)
        XCTAssertEqual(a.glow, b.glow, accuracy: 0.00001, file: file, line: line)
        XCTAssertEqual(a.water, b.water, accuracy: 0.00001, file: file, line: line)
    }
}
