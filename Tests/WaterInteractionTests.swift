import XCTest
@testable import MusicPrayer

final class WaterInteractionTests: XCTestCase {
    func testInputFollowsCameraHorizonAndUsesWaterLocalCoordinates() {
        let input = WaterInteractions()
        input.horizon = 0.58
        XCTAssertFalse(input.enqueue(screenUV: SIMD2(0.5, 0.57)))
        XCTAssertTrue(input.enqueue(screenUV: SIMD2(0.25, 0.58)))
        XCTAssertTrue(input.enqueue(screenUV: SIMD2(0.75, 0.79)))
        XCTAssertTrue(input.enqueue(screenUV: SIMD2(1, 1)))
        let pulses = input.drain()
        XCTAssertEqual(pulses.count, 3)
        XCTAssertEqual(pulses[0].position, SIMD2(0.25, 0))
        XCTAssertEqual(pulses[1].position.x, 0.75)
        XCTAssertEqual(pulses[1].position.y, 0.5, accuracy: 0.00001)
        XCTAssertEqual(pulses[2].position, SIMD2(1, 1))
        XCTAssertTrue(input.drain().isEmpty)
    }

    func testInvalidAndOutsideInputDoNotProduceWaves() {
        let input = WaterInteractions()
        for point: SIMD2<Float> in [SIMD2(-0.1, 0.9), SIMD2(1.1, 0.9), SIMD2(0.5, 1.1),
                                   SIMD2(.nan, 0.8), SIMD2(0.5, .infinity)] {
            XCTAssertFalse(input.enqueue(screenUV: point))
        }
        XCTAssertFalse(input.enqueue(screenUV: SIMD2(0.5, 0.8), strength: 0))
        XCTAssertFalse(input.enqueue(screenUV: SIMD2(0.5, 0.8), radius: .nan))
        XCTAssertTrue(input.drain().isEmpty)
    }

    func testInputBacklogKeepsRecentDragAndDrainsOnce() {
        let input = WaterInteractions(capacity: 3)
        for x: Float in [0.1, 0.2, 0.3, 0.4, 0.5] {
            input.enqueue(screenUV: SIMD2(x, 0.8))
        }
        XCTAssertEqual(input.drain().map(\.position.x), [0.3, 0.4, 0.5])
        XCTAssertTrue(input.drain().isEmpty)
    }

    func testConcurrentUIInputAndRendererDrainingDoNotLoseImpulses() {
        let input = WaterInteractions(capacity: 1000)
        let lock = NSLock()
        var consumed = 0
        DispatchQueue.concurrentPerform(iterations: 1000) { index in
            if index.isMultiple(of: 4) {
                let count = input.drain().count
                lock.lock(); consumed += count; lock.unlock()
            } else {
                input.enqueue(screenUV: SIMD2(0.5, 0.8))
            }
        }
        XCTAssertEqual(consumed + input.drain().count, 750)
    }
}
