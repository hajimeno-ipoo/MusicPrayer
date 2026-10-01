import XCTest
@testable import MusicPrayer

final class AutomaticCameraTests: XCTestCase {
    func testMeasuredSectionPropertiesSelectDistinctPhysicalViews() {
        let moment = MusicalMoment()
        let wide = AutomaticCamera.destination(moment: moment, scene: SectionScene(separation: 0.95, thickness: 0.1, water: 0.1), analyzed: true)
        let water = AutomaticCamera.destination(moment: moment, scene: SectionScene(separation: 0.1, thickness: 0.1, water: 0.95), analyzed: true)
        let ribbon = AutomaticCamera.destination(moment: moment, scene: SectionScene(separation: 0.1, thickness: 0.95, water: 0.1), analyzed: true)
        XCTAssertEqual(wide.shot, .wide)
        XCTAssertEqual(water.shot, .water)
        XCTAssertEqual(ribbon.shot, .ribbon)
        XCTAssertGreaterThan(wide.eye.z, water.eye.z + 0.7)
        XCTAssertGreaterThan(wide.eye.z, ribbon.eye.z + 0.7)
        XCTAssertLessThan(water.eye.y, -0.2)
        XCTAssertGreaterThan(ribbon.eye.y, 0.3)
        XCTAssertLessThan(water.horizon, ribbon.horizon - 0.08)
    }

    func testVoiceApproachesCenterRibbonAndReducesLateralExcursion() {
        var moment = MusicalMoment()
        moment.sectionProgress = 0.25
        moment.barPhase = 0.25
        let quiet = AutomaticCamera.destination(moment: moment, scene: SectionScene(), analyzed: true)
        moment.vocal = 1
        let singing = AutomaticCamera.destination(moment: moment, scene: SectionScene(), analyzed: true)
        XCTAssertLessThan(singing.eye.z, quiet.eye.z)
        XCTAssertLessThan(abs(singing.eye.x), abs(quiet.eye.x))
        XCTAssertEqual(singing.shot, .ribbon)
    }

    func testBarPathWrapsContinuouslyAndMovesBetweenItsEndpoints() {
        var moment = MusicalMoment()
        moment.sectionProgress = 0.3
        let first = AutomaticCamera.destination(moment: moment, scene: SectionScene(), analyzed: true)
        moment.barPhase = 0.25
        let quarter = AutomaticCamera.destination(moment: moment, scene: SectionScene(), analyzed: true)
        moment.barPhase = 1
        let end = AutomaticCamera.destination(moment: moment, scene: SectionScene(), analyzed: true)
        XCTAssertEqual(first.eye.x, end.eye.x, accuracy: 0.00001)
        XCTAssertEqual(first.eye.z, end.eye.z, accuracy: 0.00001)
        XCTAssertEqual(first.horizon, end.horizon, accuracy: 0.00001)
        XCTAssertGreaterThan(abs(quarter.eye.x - first.eye.x), 0.03)
    }

    func testSettlingUsesElapsedTimeRatherThanFrameCountAndPauseHoldsPose() {
        let scene = SectionScene(separation: 0.1, thickness: 0.1, water: 0.95)
        var slow = AutomaticCamera(), fast = AutomaticCamera()
        var a = CameraPose(), b = CameraPose()
        for step in 1...120 { a = slow.update(time: Double(step) / 30, moment: MusicalMoment(), scene: scene, analyzed: true, dt: 1 / 30) }
        for step in 1...480 { b = fast.update(time: Double(step) / 120, moment: MusicalMoment(), scene: scene, analyzed: true, dt: 1 / 120) }
        XCTAssertEqual(a.eye.y, b.eye.y, accuracy: 0.00001)
        XCTAssertEqual(a.eye.z, b.eye.z, accuracy: 0.00001)
        XCTAssertEqual(a.horizon, b.horizon, accuracy: 0.00001)
        for _ in 0..<100 {
            let paused = fast.update(time: 4, moment: MusicalMoment(vocal: 1), scene: SectionScene(), analyzed: true, dt: 1 / 60)
            XCTAssertEqual(paused, b)
        }
    }

    func testSeekGlidesToDestinationAndAbsentAnalysisUsesNeutralView() {
        var camera = AutomaticCamera()
        let before = camera.update(time: 1, moment: MusicalMoment(), scene: SectionScene(), analyzed: true, dt: 1 / 60)
        var moment = MusicalMoment()
        moment.vocal = 1
        moment.sectionProgress = 0.75
        let after = camera.update(time: 120, moment: moment, scene: SectionScene(thickness: 1), analyzed: true, dt: 1 / 60)
        XCTAssertLessThan(abs(after.eye.z - before.eye.z), 0.02)
        XCTAssertLessThan(abs(after.eye.x - before.eye.x), 0.02)
        XCTAssertEqual(AutomaticCamera.destination(moment: moment, scene: SectionScene(water: 1), analyzed: false), CameraPose())
        for phase in stride(from: Float(0), through: 1, by: 0.02) {
            moment.barPhase = phase
            let destination = AutomaticCamera.destination(moment: moment, scene: SectionScene(), analyzed: true)
            XCTAssertGreaterThanOrEqual(destination.eye.z, 5.4)
            XCTAssertTrue((0.58...0.69).contains(destination.horizon))
        }
    }
}
