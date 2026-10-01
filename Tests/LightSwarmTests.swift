import XCTest
import Metal
import simd
@testable import MusicPrayer

final class LightSwarmTests: XCTestCase {
    private let eye = SIMD3<Float>(0, 0.2, 6)
    private let target = SIMD3<Float>(0, 0.2, 0)

    func testGPUDrumImpulseAndSavedTrailPositions() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let quiet = try LightSwarm(device: device, particleCount: 64)
        let drums = try LightSwarm(device: device, particleCount: 64)
        var frame = VisualFrame()
        frame.rms = 0.6
        frame.drums = 1
        frame.beat = 0
        try update(quiet, queue: queue, frame: frame)
        frame.beat = 1
        try update(drums, queue: queue, frame: frame)
        let calm = states(quiet), burst = states(drums)
        let calmSpeed = calm.reduce(Float(0)) { $0 + simd_length(SIMD3($1.velocity.x, $1.velocity.y, $1.velocity.z)) } / 64
        let burstSpeed = burst.reduce(Float(0)) { $0 + simd_length(SIMD3($1.velocity.x, $1.velocity.y, $1.velocity.z)) } / 64
        XCTAssertGreaterThan(burstSpeed, calmSpeed + 0.4, "The drum beat must inject an actual GPU velocity impulse.")
        for step in 1...12 {
            frame.time = Float(step) / 60
            frame.beat = 0
            try update(drums, queue: queue, frame: frame)
        }
        let trail = drums.historyBuffer.contents().assumingMemoryBound(to: SIMD4<Float>.self)
        let displacement = (0..<64).reduce(Float(0)) { sum, index in
            sum + simd_length(trail[index * 8] - trail[index * 8 + 7])
        }
        XCTAssertGreaterThan(displacement, 1, "Trails must contain different saved positions, rather than a static graphic.")
        let before = Data(bytes: drums.particleBuffer.contents(), count: drums.particleBuffer.length)
        try update(drums, queue: queue, frame: frame)
        let paused = Data(bytes: drums.particleBuffer.contents(), count: drums.particleBuffer.length)
        XCTAssertEqual(before, paused, "An unchanged playback clock must hold the particle simulation.")
    }

    func testGPUVocalAndBassChangeSpatialFlow() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let calm = try LightSwarm(device: device, particleCount: 64)
        let musical = try LightSwarm(device: device, particleCount: 64)
        var a = VisualFrame(), b = VisualFrame()
        b.vocal = 1
        b.bassInstrument = 1
        for step in 0..<60 {
            a.time = Float(step) / 60
            b.time = a.time
            try update(calm, queue: queue, frame: a)
            try update(musical, queue: queue, frame: b)
        }
        let plain = states(calm), active = states(musical)
        let displacement = zip(plain, active).reduce(Float(0)) { $0 + simd_length($1.0.position - $1.1.position) }
        let meanZ = active.reduce(Float(0)) { $0 + $1.position.z } / 64
        let plainZ = plain.reduce(Float(0)) { $0 + $1.position.z } / 64
        XCTAssertGreaterThan(displacement, 5)
        XCTAssertGreaterThan(meanZ, plainZ + 0.02, "Vocal attraction must move the swarm toward the foreground.")
    }

    func testDuplicateDisplayFramesDoNotSlowTheMusicSimulation() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let sixty = try LightSwarm(device: device, particleCount: 32)
        let oneTwenty = try LightSwarm(device: device, particleCount: 32)
        var frame = VisualFrame()
        frame.rms = 0.6
        frame.vocal = 0.8
        frame.bassInstrument = 0.7
        for step in 0..<60 {
            frame.time = Float(step) / 60
            let command = try XCTUnwrap(queue.makeCommandBuffer())
            try sixty.encodeUpdate(command: command, frame: frame, deltaTime: 1 / 60,
                                   aspect: 1.6, cameraEye: eye, cameraTarget: target)
            // The initial frame uses the caller's elapsed time; subsequent frames use audio deltas.
            let displayDelta: Float = step == 0 ? 1 / 60 : 1 / 120
            try oneTwenty.encodeUpdate(command: command, frame: frame, deltaTime: displayDelta,
                                       aspect: 1.6, cameraEye: eye, cameraTarget: target)
            try oneTwenty.encodeUpdate(command: command, frame: frame, deltaTime: 1 / 120,
                                       aspect: 1.6, cameraEye: eye, cameraTarget: target)
            command.commit()
            command.waitUntilCompleted()
            XCTAssertNil(command.error)
        }
        let a = states(sixty), b = states(oneTwenty)
        for index in 0..<32 {
            XCTAssertLessThan(simd_length(a[index].position - b[index].position), 0.00001)
        }
    }

    func testGPUConfinementReflectsOutwardVelocityInsteadOfAccumulatingAtEdges() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let swarm = try LightSwarm(device: device, particleCount: 4)
        let particle = swarm.particleBuffer.contents().assumingMemoryBound(to: LightSwarm.Particle.self)
        particle[0].position = SIMD4(0, 1.699, 0, 0)
        particle[0].velocity = SIMD4(0, 2, 0, 0.5)
        particle[1].position = SIMD4(0, -0.849, 0, 0)
        particle[1].velocity = SIMD4(0, -2, 0, 0.5)
        particle[2].position = SIMD4(0, 0.35, 1.799, 0)
        particle[2].velocity = SIMD4(0, 0, 2, 0.5)
        particle[3].position = SIMD4(0, 0.35, -1.499, 0)
        particle[3].velocity = SIMD4(0, 0, -2, 0.5)
        try update(swarm, queue: queue, frame: VisualFrame())
        let reflected = states(swarm)
        XCTAssertLessThan(reflected[0].velocity.y, 0)
        XCTAssertGreaterThan(reflected[1].velocity.y, 0)
        XCTAssertLessThan(reflected[2].velocity.z, 0)
        XCTAssertGreaterThan(reflected[3].velocity.z, 0)
        for value in reflected {
            XCTAssertTrue(value.position.y.isFinite && value.position.z.isFinite)
            XCTAssertTrue((-0.85...1.7).contains(value.position.y))
            XCTAssertTrue((-1.5...1.8).contains(value.position.z))
        }
        // Continue the actual GPU flow to catch repeated edge sticking after the initial bounce.
        var frame = VisualFrame()
        frame.bassInstrument = 1
        for step in 1...120 {
            frame.time = Float(step) / 60
            try update(swarm, queue: queue, frame: frame)
        }
        for value in states(swarm) {
            XCTAssertTrue(value.position.y.isFinite && value.position.z.isFinite)
            XCTAssertTrue((-0.85...1.7).contains(value.position.y))
            XCTAssertTrue((-1.5...1.8).contains(value.position.z))
        }
    }

    func testZeroTrackPresenceDrawsNoLights() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let swarm = try LightSwarm(device: device, particleCount: 128)
        let textureDescriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: 128, height: 128, mipmapped: false)
        textureDescriptor.storageMode = .shared
        textureDescriptor.usage = [.renderTarget]
        let image = try XCTUnwrap(device.makeTexture(descriptor: textureDescriptor))
        let depthDescriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .depth32Float, width: 128, height: 128, mipmapped: false)
        depthDescriptor.textureType = .type2DArray
        depthDescriptor.arrayLength = 4
        depthDescriptor.storageMode = .private
        depthDescriptor.usage = [.renderTarget, .shaderRead]
        let depth = try XCTUnwrap(device.makeTexture(descriptor: depthDescriptor))
        var frame = VisualFrame()
        frame.rms = 1
        for step in 0..<30 {
            frame.time = Float(step) / 60
            try update(swarm, queue: queue, frame: frame)
        }
        func render(presence: Float, clothDepth: Double = 1) throws -> Float {
            frame.presence = presence
            let command = try XCTUnwrap(queue.makeCommandBuffer())
            try swarm.encodeUpdate(command: command, frame: frame, deltaTime: 1 / 60,
                                   aspect: 1, cameraEye: eye, cameraTarget: target)
            for layer in 0..<4 {
                let pass = MTLRenderPassDescriptor()
                pass.depthAttachment.texture = depth
                pass.depthAttachment.slice = layer
                pass.depthAttachment.loadAction = .clear
                pass.depthAttachment.storeAction = .store
                pass.depthAttachment.clearDepth = clothDepth
                let encoder = try XCTUnwrap(command.makeRenderCommandEncoder(descriptor: pass))
                encoder.endEncoding()
            }
            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = image
            pass.colorAttachments[0].loadAction = .clear
            pass.colorAttachments[0].storeAction = .store
            pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0)
            let clear = try XCTUnwrap(command.makeRenderCommandEncoder(descriptor: pass))
            clear.endEncoding()
            try swarm.encodeRender(command: command, target: image, ribbonDepths: depth)
            command.commit()
            command.waitUntilCompleted()
            XCTAssertNil(command.error)
            var pixels = [UInt16](repeating: 0, count: 128 * 128 * 4)
            pixels.withUnsafeMutableBytes { image.getBytes($0.baseAddress!, bytesPerRow: 128 * 8,
                                                         from: MTLRegionMake2D(0, 0, 128, 128), mipmapLevel: 0) }
            return pixels.reduce(Float(0)) { $0 + Float(Float16(bitPattern: $1)) }
        }
        let unobscured = try render(presence: 1)
        XCTAssertGreaterThan(unobscured, 1, "The active control image must actually contain GPU lights.")
        let behindCloth = try render(presence: 1, clothDepth: 0)
        XCTAssertEqual(behindCloth / unobscured, 0.4, accuracy: 0.01, "Lights behind a ribbon must attenuate according to its actual depth layer.")
        XCTAssertEqual(try render(presence: 0), 0, accuracy: 0.00001, "Track fade-out must remove both lights and trails.")
    }

    private func update(_ swarm: LightSwarm, queue: MTLCommandQueue, frame: VisualFrame) throws {
        let command = try XCTUnwrap(queue.makeCommandBuffer())
        try swarm.encodeUpdate(command: command, frame: frame, deltaTime: 1 / 60,
                               aspect: 1.6, cameraEye: eye, cameraTarget: target)
        command.commit()
        command.waitUntilCompleted()
        XCTAssertNil(command.error)
    }

    private func states(_ swarm: LightSwarm) -> [LightSwarm.Particle] {
        Array(UnsafeBufferPointer(start: swarm.particleBuffer.contents().assumingMemoryBound(to: LightSwarm.Particle.self), count: swarm.particleCount))
    }
}
