import XCTest
@testable import MusicPrayer

final class TrackVisualTransitionTests: XCTestCase {
    func testManualSwitchKeepsOldPaletteThenEmergesWithNewFrameInEightTenths() {
        var old = VisualFrame(); old.time = 25; old.hue = -0.03; old.presence = 1
        var next = VisualFrame(); next.time = 0.2; next.hue = 0.04; next.presence = 1
        let transition = TrackVisualTransition(outgoing: old, started: 100, wasPlaying: true)
        let fading = transition.frame(incoming: next, at: 100.2)
        XCTAssertEqual(fading.hue, old.hue)
        XCTAssertEqual(fading.time, 25.2, accuracy: 0.00001)
        XCTAssertEqual(fading.presence, 0.5, accuracy: 0.00001)
        let handoff = transition.frame(incoming: next, at: 100.4)
        XCTAssertEqual(handoff.presence, 0, accuracy: 0.00001)
        let emerging = transition.frame(incoming: next, at: 100.6)
        XCTAssertEqual(emerging.hue, next.hue)
        XCTAssertEqual(emerging.time, next.time)
        XCTAssertEqual(emerging.presence, 0.5, accuracy: 0.00001)
        XCTAssertTrue(transition.isFinished(at: 100.81))
        XCTAssertEqual(transition.frame(incoming: next, at: 101).presence, 1)
    }

    func testRepeatedSwitchStartsAtVisiblePresenceAndPausedOldFrameDoesNotMove() {
        var old = VisualFrame(); old.time = 20; old.presence = 0.3
        let transition = TrackVisualTransition(outgoing: old, started: 100, wasPlaying: false)
        let initial = transition.frame(incoming: VisualFrame(), at: 100)
        XCTAssertEqual(initial.presence, 0.3)
        let midway = transition.frame(incoming: VisualFrame(), at: 100.2)
        XCTAssertEqual(midway.presence, 0.15, accuracy: 0.00001)
        XCTAssertEqual(midway.time, 20)
    }

    func testAutomaticTransitionOnlyEmergesAndKeepsIncomingEndFade() {
        var next = VisualFrame(); next.presence = 0.7
        let transition = TrackVisualTransition(outgoing: nil, started: 100, wasPlaying: true)
        XCTAssertEqual(transition.duration, 0.4)
        XCTAssertEqual(transition.frame(incoming: next, at: 100).presence, 0)
        XCTAssertEqual(transition.frame(incoming: next, at: 100.2).presence, 0.35, accuracy: 0.00001)
        XCTAssertEqual(transition.frame(incoming: next, at: 100.41).presence, 0.7)
        XCTAssertFalse(transition.isFinished(at: 100.2))
        XCTAssertTrue(transition.isFinished(at: 100.41))
    }
}
