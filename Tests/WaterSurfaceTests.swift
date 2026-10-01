import Metal
import XCTest
@testable import MusicPrayer

final class WaterSurfaceTests: XCTestCase {
    private let width = 256
    private let height = 128

    func testClickCreatesLocalWaveThenPropagatesIntoUnexcitedWater() throws {
        let (device, queue) = try environment()
        let surface = try WaterSurface(device: device)
        try advance(surface, queue: queue, steps: 1,
                    pulses: [WaterPulse(position: SIMD2(0.5, 0.5), strength: 0.8, radius: 0.025)])
        let initial = try read(surface.texture, device: device, queue: queue)
        XCTAssertTrue(initial.allSatisfy(\.isFinite))
        XCTAssertGreaterThan(initial[(height / 2 * width + width / 2) * 2], 0.7)
        XCTAssertLessThan(farRingPeak(initial), 0.00001)

        try advance(surface, queue: queue, steps: 100)
        let propagated = try read(surface.texture, device: device, queue: queue)
        XCTAssertTrue(propagated.allSatisfy(\.isFinite))
        XCTAssertGreaterThan(farRingPeak(propagated), 0.005)
    }

    func testTwoWavesInterfereAsTheSumOfTheirIndividualFields() throws {
        let (device, queue) = try environment()
        let first = try WaterSurface(device: device)
        let second = try WaterSurface(device: device)
        let together = try WaterSurface(device: device)
        let a = WaterPulse(position: SIMD2(0.44, 0.5), strength: 0.45, radius: 0.018)
        let b = WaterPulse(position: SIMD2(0.56, 0.5), strength: 0.35, radius: 0.018)
        try advance(first, queue: queue, steps: 80, pulses: [a])
        try advance(second, queue: queue, steps: 80, pulses: [b])
        try advance(together, queue: queue, steps: 80, pulses: [a, b])
        let fieldA = try read(first.texture, device: device, queue: queue)
        let fieldB = try read(second.texture, device: device, queue: queue)
        let combined = try read(together.texture, device: device, queue: queue)
        var largestError: Float = 0
        var overlap = false
        for index in stride(from: 0, to: combined.count, by: 2) {
            largestError = max(largestError, abs(combined[index] - fieldA[index] - fieldB[index]))
            if abs(fieldA[index]) > 0.01, abs(fieldB[index]) > 0.01 { overlap = true }
        }
        XCTAssertTrue(overlap, "The two propagated waves must reach a shared area.")
        XCTAssertLessThan(largestError, 0.0001)
    }

    func testWaveRemainsFiniteAndDampsAfterSeveralSeconds() throws {
        let (device, queue) = try environment()
        let surface = try WaterSurface(device: device)
        try advance(surface, queue: queue, steps: 60,
                    pulses: [WaterPulse(position: SIMD2(0.5, 0.5), strength: 0.8, radius: 0.025)])
        let early = try read(surface.texture, device: device, queue: queue)
        try advance(surface, queue: queue, steps: 660)
        let late = try read(surface.texture, device: device, queue: queue)
        XCTAssertTrue(early.allSatisfy(\.isFinite))
        XCTAssertTrue(late.allSatisfy(\.isFinite))
        XCTAssertGreaterThan(heightEnergy(early), 0)
        XCTAssertLessThan(heightEnergy(late), heightEnergy(early) * 0.5)
    }

    func testActivityMeasuresFlatWaterClickAndPropagatingWave() throws {
        let (device, queue) = try environment()
        let surface = try WaterSurface(device: device)
        XCTAssertEqual(try activity(surface, device: device, queue: queue).max(), 0)
        try advance(surface, queue: queue, steps: 1)
        XCTAssertEqual(try activity(surface, device: device, queue: queue).max(), 0)

        try advance(surface, queue: queue, steps: 1,
                    pulses: [WaterPulse(position: SIMD2(0.5, 0.5), strength: 0.8, radius: 0.025)])
        let clicked = try activity(surface, device: device, queue: queue)
        XCTAssertGreaterThan(try XCTUnwrap(clicked.max()), 0.7)
        try advance(surface, queue: queue, steps: 100)
        let propagated = try activity(surface, device: device, queue: queue)
        let field = try read(surface.texture, device: device, queue: queue)
        XCTAssertTrue(propagated.allSatisfy(\.isFinite))
        XCTAssertEqual(try XCTUnwrap(propagated.max()), try XCTUnwrap(field.map { abs($0) }.max()))
        XCTAssertGreaterThan(try XCTUnwrap(propagated.max()), 0.00001)
    }

    func testActivityIncludesPreviousHeightAtTheLastCell() throws {
        let (device, queue) = try environment()
        let surface = try WaterSurface(device: device)
        try advance(surface, queue: queue, steps: 1)
        var state = Array(repeating: Float.zero, count: width * height * 2)
        state[0] = 0.3
        state[state.count - 1] = -0.75
        let buffer = try XCTUnwrap(state.withUnsafeBytes {
            device.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: .storageModeShared)
        })
        let command = try XCTUnwrap(queue.makeCommandBuffer())
        let blit = try XCTUnwrap(command.makeBlitCommandEncoder())
        let rowBytes = width * 2 * MemoryLayout<Float>.stride
        blit.copy(from: buffer, sourceOffset: 0, sourceBytesPerRow: rowBytes, sourceBytesPerImage: rowBytes * height,
                  sourceSize: MTLSize(width: width, height: height, depth: 1), to: surface.texture,
                  destinationSlice: 0, destinationLevel: 0, destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
        blit.endEncoding()
        command.commit()
        command.waitUntilCompleted()
        XCTAssertEqual(command.status, .completed, command.error?.localizedDescription ?? "Water state upload failed")
        let samples = try activity(surface, device: device, queue: queue)
        XCTAssertEqual(samples.first, 0.3)
        XCTAssertEqual(samples.last, 0.75)
        XCTAssertEqual(samples.max(), 0.75)
    }

    func testActivityFallsBelowIdleThresholdAfterLongDamping() throws {
        let (device, queue) = try environment()
        let surface = try WaterSurface(device: device)
        try advance(surface, queue: queue, steps: 1,
                    pulses: [WaterPulse(position: SIMD2(0.5, 0.5), strength: 0.8, radius: 0.025)])
        var peak = try XCTUnwrap(activity(surface, device: device, queue: queue).max())
        XCTAssertGreaterThan(peak, 0.00001)
        for _ in 0..<10 where peak > 0.00001 {
            try advance(surface, queue: queue, steps: 1200)
            peak = try XCTUnwrap(activity(surface, device: device, queue: queue).max())
        }
        XCTAssertTrue(peak.isFinite)
        XCTAssertLessThanOrEqual(peak, 0.00001)
    }

    private func environment() throws -> (MTLDevice, MTLCommandQueue) {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("Metal device unavailable") }
        return (device, try XCTUnwrap(device.makeCommandQueue()))
    }

    private func advance(_ surface: WaterSurface, queue: MTLCommandQueue, steps: Int,
                         pulses: [WaterPulse] = []) throws {
        var completedSteps = 0
        while completedSteps < steps {
            let command = try XCTUnwrap(queue.makeCommandBuffer())
            let batch = min(120, steps - completedSteps)
            for index in 0..<batch {
                try surface.encode(command: command, elapsed: 1.0 / 120,
                                   pulses: completedSteps == 0 && index == 0 ? pulses : [],
                                   frame: VisualFrame(), aspect: 1.4)
            }
            command.commit()
            command.waitUntilCompleted()
            XCTAssertEqual(command.status, .completed, command.error?.localizedDescription ?? "Water compute command failed")
            completedSteps += batch
        }
    }

    private func activity(_ surface: WaterSurface, device: MTLDevice, queue: MTLCommandQueue) throws -> [Float] {
        let count = WaterSurface.activitySampleCount
        let buffer = try XCTUnwrap(device.makeBuffer(length: count * MemoryLayout<Float>.stride, options: .storageModeShared))
        let command = try XCTUnwrap(queue.makeCommandBuffer())
        try surface.encodeActivityCheck(command: command, result: buffer)
        command.commit()
        command.waitUntilCompleted()
        XCTAssertEqual(command.status, .completed, command.error?.localizedDescription ?? "Water activity readback failed")
        return Array(UnsafeBufferPointer(start: buffer.contents().assumingMemoryBound(to: Float.self), count: count))
    }

    private func read(_ texture: MTLTexture, device: MTLDevice, queue: MTLCommandQueue) throws -> [Float] {
        let rowBytes = width * 2 * MemoryLayout<Float>.stride
        let buffer = try XCTUnwrap(device.makeBuffer(length: rowBytes * height, options: .storageModeShared))
        let command = try XCTUnwrap(queue.makeCommandBuffer())
        let blit = try XCTUnwrap(command.makeBlitCommandEncoder())
        blit.copy(from: texture, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                  sourceSize: MTLSize(width: width, height: height, depth: 1), to: buffer,
                  destinationOffset: 0, destinationBytesPerRow: rowBytes, destinationBytesPerImage: rowBytes * height)
        blit.endEncoding()
        command.commit()
        command.waitUntilCompleted()
        XCTAssertEqual(command.status, .completed, command.error?.localizedDescription ?? "Water readback failed")
        return Array(UnsafeBufferPointer(start: buffer.contents().assumingMemoryBound(to: Float.self), count: width * height * 2))
    }

    private func farRingPeak(_ state: [Float]) -> Float {
        var result: Float = 0
        for y in 0..<height where abs((Float(y) + 0.5) / Float(height) - 0.5) < 0.015 {
            for x in 0..<width {
                let distance = abs((Float(x) + 0.5) / Float(width) - 0.5)
                if distance > 0.07, distance < 0.12 { result = max(result, abs(state[(y * width + x) * 2])) }
            }
        }
        return result
    }

    private func heightEnergy(_ state: [Float]) -> Double {
        stride(from: 0, to: state.count, by: 2).reduce(0) { $0 + Double(state[$1]) * Double(state[$1]) }
    }
}
