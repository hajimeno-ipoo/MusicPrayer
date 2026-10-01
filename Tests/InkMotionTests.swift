import XCTest
@testable import MusicPrayer

final class InkMotionTests: XCTestCase {
    func testEachMusicalFamilySelectsADifferentGesture() {
        for kind in InkMotionKind.allCases {
            var frame = VisualFrame()
            frame.hasAnalysis = 1
            frame.rms = 0.8
            switch kind {
            case .suction: frame.mid = 1; frame.other = 1
            case .eruption: frame.vocal = 1; frame.peak = 1
            case .collision: frame.drums = 1; frame.beat = 1
            case .breathing: frame.bass = 1; frame.bassInstrument = 1
            case .sinking: frame.rms = 0
            case .split: frame.treble = 1
            }
            var controller = InkMotionController()
            let state = controller.update(frame: frame)
            XCTAssertEqual(controller.selected, kind)
            XCTAssertEqual(sum(state), 1, accuracy: 0.00001)
        }
    }

    func testPhraseChangesBlendForcesAndPauseHoldsThem() {
        var controller = InkMotionController()
        var frame = VisualFrame()
        frame.hasAnalysis = 1; frame.vocal = 1; frame.rms = 0.8
        _ = controller.update(frame: frame)
        frame.time = 0.1; frame.phraseProgress = 0.95
        let singing = controller.update(frame: frame)
        frame.drums = 1; frame.vocal = 0; frame.phraseProgress = 0.01; frame.time = 0.15
        let crossing = controller.update(frame: frame)
        XCTAssertEqual(controller.selected, .collision)
        XCTAssertGreaterThan(crossing.weightsA.y, 0.8, "A phrase boundary must not pop from one field to another.")
        XCTAssertGreaterThan(crossing.weightsA.z, singing.weightsA.z)
        for _ in 0..<20 {
            let paused = controller.update(frame: frame)
            XCTAssertEqual(paused.weightsA, crossing.weightsA)
            XCTAssertEqual(paused.weightsB, crossing.weightsB)
        }
        for i in 1...30 { frame.time = 0.15 + Float(i) / 30; _ = controller.update(frame: frame) }
        let settled = controller.update(frame: frame)
        XCTAssertGreaterThan(settled.weightsA.z, 0.75)
        XCTAssertEqual(sum(settled), 1, accuracy: 0.00001)
    }

    func testSeekAndTrackChangesDiscardThePreviousGesture() {
        var controller = InkMotionController()
        var frame = VisualFrame()
        frame.trackID = UUID(); frame.hasAnalysis = 1; frame.vocal = 1; frame.rms = 0.8
        _ = controller.update(frame: frame)
        frame.time = 20; frame.vocal = 0; frame.bass = 1
        let sought = controller.update(frame: frame)
        XCTAssertEqual(sought.weightsA.w, 1)
        frame.trackID = UUID(); frame.bass = 0; frame.treble = 1
        let newTrack = controller.update(frame: frame)
        XCTAssertEqual(newTrack.weightsB.y, 1)
        XCTAssertEqual(newTrack.weightsA.w, 0)
    }

    func testShortSectionChangesSelectAGestureEvenBeforeTheOldAccentFades() {
        var controller = InkMotionController()
        var frame = VisualFrame()
        frame.hasAnalysis = 1; frame.rms = 0.8; frame.mid = 1
        frame.sectionTransition = 1
        _ = controller.update(frame: frame)
        for i in 1...12 {
            frame.time = Float(i) / 30
            frame.sectionProgress = Float(i) / 13
            frame.sectionTransition = 1 - frame.time / 1.5
            _ = controller.update(frame: frame)
        }
        frame.time = 13.0 / 30; frame.mid = 0; frame.vocal = 1
        frame.sectionProgress = 0; frame.sectionTransition = 1
        _ = controller.update(frame: frame)
        XCTAssertEqual(controller.selected, .eruption,
                       "A short section must not wait for the previous section's accent to fully decay.")
    }

    func testAnalysisValuesCannotChooseGesturesWhenAnalysisIsAbsent() {
        var a = InkMotionController(), b = InkMotionController()
        var plain = VisualFrame(), unavailable = VisualFrame()
        plain.rms = 0.4; plain.mid = 0.3; plain.bass = 0.2
        unavailable = plain
        unavailable.vocal = 1; unavailable.drums = 1; unavailable.other = 1
        unavailable.bassInstrument = 1; unavailable.density = 1; unavailable.pace = 1
        unavailable.phraseProgress = 0.95; unavailable.sectionTransition = 1
        for i in 0...40 {
            plain.time = Float(i) / 60; unavailable.time = plain.time
            if i == 20 { unavailable.phraseProgress = 0 }
            let left = a.update(frame: plain), right = b.update(frame: unavailable)
            XCTAssertEqual(left.weightsA, right.weightsA)
            XCTAssertEqual(left.weightsB, right.weightsB)
        }
    }

    func testRealtimeOnlyMusicAndSpectrumRemainFinite() {
        var controller = InkMotionController()
        var frame = VisualFrame()
        _ = controller.update(frame: frame)
        frame.bass = 1
        for i in 1...30 { frame.time = Float(i) / 30; _ = controller.update(frame: frame) }
        let live = controller.update(frame: frame)
        XCTAssertGreaterThan(live.weightsA.w, 0.3)
        XCTAssertEqual(sum(live), 1, accuracy: 0.00001)
        let values = InkSpectrum.values([.nan, .infinity, -2, 2, 0.5])
        XCTAssertEqual(values.count, 64)
        XCTAssertEqual(Array(values.prefix(6)), [0, 0, 0, 1, 0.5, 0])
        XCTAssertEqual(InkSpectrum.values(Array(repeating: 0.5, count: 80)).count, 64)
    }

    private func sum(_ state: InkMotionState) -> Float {
        state.weightsA.x + state.weightsA.y + state.weightsA.z + state.weightsA.w
            + state.weightsB.x + state.weightsB.y
    }
}
