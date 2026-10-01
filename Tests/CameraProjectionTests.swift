import XCTest
import Metal
import simd
@testable import MusicPrayer

final class CameraProjectionTests: XCTestCase {
    func testActualGPUProjectionPreservesNeutralFramingAndDepthRange() throws {
        let points: [SIMD3<Float>] = [SIMD3(0, 0, 0), SIMD3(1, 1, 0), SIMD3(0, 0, 5.8), SIMD3(0, 0, -24)]
        let projected = try project(points, camera: CameraPose())
        XCTAssertEqual(projected[0].x, 0, accuracy: 0.00001)
        XCTAssertEqual(projected[0].y, 0, accuracy: 0.00001)
        XCTAssertEqual(projected[0].w, 6, accuracy: 0.00001)
        XCTAssertEqual(projected[1].x / projected[1].w, 2 / 1.6 / 6, accuracy: 0.00001)
        XCTAssertEqual(projected[1].y / projected[1].w, 2.142857 / 6, accuracy: 0.00001)
        XCTAssertEqual(projected[2].z / projected[2].w, 0, accuracy: 0.00001)
        XCTAssertEqual(projected[3].z / projected[3].w, 1, accuracy: 0.00001)
    }

    func testActualGPUProjectionCentersCameraTargetsAcrossAllMusicViews() throws {
        let scenes = [SectionScene(separation: 0.95, thickness: 0.1, water: 0.1),
                      SectionScene(separation: 0.1, thickness: 0.1, water: 0.95),
                      SectionScene(separation: 0.1, thickness: 0.95, water: 0.1)]
        var moment = MusicalMoment()
        moment.sectionProgress = 0.3
        moment.barPhase = 0.25
        for scene in scenes {
            let camera = AutomaticCamera.destination(moment: moment, scene: scene, analyzed: true)
            let forward = simd_normalize(camera.target - camera.eye)
            let right = simd_normalize(simd_cross(forward, SIMD3<Float>(0, 1, 0)))
            let up = simd_cross(right, forward)
            let points = [camera.target, camera.target + right, camera.target + up]
            let projected = try project(points, camera: camera)
            XCTAssertEqual(projected[0].x, 0, accuracy: 0.00001)
            XCTAssertEqual(projected[0].y, 0, accuracy: 0.00001)
            XCTAssertEqual(projected[0].w, simd_length(camera.target - camera.eye), accuracy: 0.00001)
            XCTAssertGreaterThan(projected[1].x, 0)
            XCTAssertEqual(projected[1].y, 0, accuracy: 0.00001)
            XCTAssertGreaterThan(projected[2].y, 0)
            XCTAssertEqual(projected[2].x, 0, accuracy: 0.00001)
            for point in projected {
                XCTAssertGreaterThan(point.w, 0)
                XCTAssertTrue((0...1).contains(point.z / point.w))
            }
        }
    }

    func testManualTrackTransitionKeepsCameraWithItsRetainedVisualSnapshot() {
        var outgoing = VisualFrame(), incoming = VisualFrame()
        outgoing.camera = AutomaticCamera.destination(moment: MusicalMoment(), scene: SectionScene(water: 1), analyzed: true)
        incoming.camera = AutomaticCamera.destination(moment: MusicalMoment(vocal: 1), scene: SectionScene(thickness: 1), analyzed: true)
        let transition = TrackVisualTransition(outgoing: outgoing, started: 100, wasPlaying: true)
        XCTAssertEqual(transition.frame(incoming: incoming, at: 100.2).camera, outgoing.camera)
        let handoff = transition.frame(incoming: incoming, at: 100.4)
        XCTAssertEqual(handoff.presence, 0, accuracy: 0.00001)
        XCTAssertEqual(handoff.camera, incoming.camera)
    }

    /// Exercise the production projection function itself, with GPU readback.
    /// The probe is appended only in this test; the app's shader is unmodified.
    private func project(_ points: [SIMD3<Float>], camera: CameraPose) throws -> [SIMD4<Float>] {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let shaderURL = try XCTUnwrap(Bundle.module.url(forResource: "Shaders", withExtension: "metal"))
        let shader = try String(contentsOf: shaderURL, encoding: .utf8)
        let probe = """
        kernel void cameraProjectionProbe(const device float4* points [[buffer(0)]],
                                          device float4* projected [[buffer(1)]],
                                          constant FrameUniforms& frame [[buffer(2)]],
                                          uint id [[thread_position_in_grid]]) {
            projected[id] = projectWorld(points[id].xyz, frame);
        }
        """
        let library = try device.makeLibrary(source: shader + "\n" + probe, options: nil)
        let function = try XCTUnwrap(library.makeFunction(name: "cameraProjectionProbe"))
        let pipeline = try device.makeComputePipelineState(function: function)
        let input = points.map { SIMD4<Float>($0, 1) }
        let inputBuffer = try XCTUnwrap(input.withUnsafeBytes {
            device.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: .storageModeShared)
        })
        let outputBuffer = try XCTUnwrap(device.makeBuffer(length: input.count * MemoryLayout<SIMD4<Float>>.stride, options: .storageModeShared))
        // The production FrameUniforms contract consists of twelve aligned float4 groups.
        var uniforms = [SIMD4<Float>](repeating: .zero, count: 12)
        uniforms[6] = SIMD4(1.6, 128, 80, camera.horizon)
        uniforms[10] = SIMD4(camera.eye, 0)
        uniforms[11] = SIMD4(camera.target, 0)
        let command = try XCTUnwrap(queue.makeCommandBuffer())
        let encoder = try XCTUnwrap(command.makeComputeCommandEncoder())
        encoder.setComputePipelineState(pipeline)
        encoder.setBuffer(inputBuffer, offset: 0, index: 0)
        encoder.setBuffer(outputBuffer, offset: 0, index: 1)
        uniforms.withUnsafeBytes { encoder.setBytes($0.baseAddress!, length: $0.count, index: 2) }
        encoder.dispatchThreads(MTLSize(width: input.count, height: 1, depth: 1),
                                threadsPerThreadgroup: MTLSize(width: min(input.count, pipeline.threadExecutionWidth), height: 1, depth: 1))
        encoder.endEncoding()
        command.commit()
        command.waitUntilCompleted()
        XCTAssertNil(command.error)
        return Array(UnsafeBufferPointer(start: outputBuffer.contents().assumingMemoryBound(to: SIMD4<Float>.self), count: input.count))
    }
}
