import Metal
import XCTest
import simd
@testable import MusicPrayer

final class WaterReflectionTests: XCTestCase {
    private let width = 256
    private let height = 192
    private let horizon: Float = 0.60

    func testUniformReflectionFadesSmoothlyWithoutHorizontalBrightnessBands() throws {
        let fixture = try Fixture(width: width, height: height)
        let scene = try fixture.texture { _, _ in SIMD4(0.35, 0.18, 0.45, 1) }
        let water = try fixture.texture { _, _ in .zero }
        let pixels = try fixture.render(scene: scene, water: water, horizon: horizon)
        XCTAssertTrue(pixels.allSatisfy(\.isFinite))

        // A flat-colored reflected object has no stripes of its own. The water should
        // gradually darken toward the viewer, without repeatedly becoming brighter.
        let firstRow = Int(Float(height) * (horizon + (1 - horizon) * 0.10))
        let lastRow = Int(Float(height) * (horizon + (1 - horizon) * 0.85))
        let profile = (firstRow...lastRow).map { y -> Float in
            (112..<144).reduce(Float(0)) { total, x in
                let i = (y * width + x) * 4
                return total + pixels[i] * 0.2126 + pixels[i + 1] * 0.7152 + pixels[i + 2] * 0.0722
            } / 32
        }
        XCTAssertGreaterThan(profile.first! - profile.last!, 0.08,
                             "The fixture must still contain a visibly fading reflection.")
        let largestUpwardStep = zip(profile.dropFirst(), profile).map { $0 - $1 }.max()!
        XCTAssertLessThan(largestUpwardStep, 0.0005,
                          "A uniform reflection must not acquire repeated horizontal light/dark bands.")
    }

    func testLocalWaterWaveChangesNearbyReflectionAndLeavesDistantWaterAndSkyIntact() throws {
        let fixture = try Fixture(width: width, height: height)
        let scene = try fixture.texture { x, y in SIMD4(0.10 + x * 0.8, 0.08 + y * y * 0.9, 0.8 - x * 0.65, 1) }
        let calm = try fixture.texture { _, _ in .zero }
        let disturbed = try fixture.texture { x, y in
            let offset = (SIMD2(x, y) - SIMD2<Float>(0.50, 0.45)) / SIMD2<Float>(0.10, 0.13)
            return SIMD4(0.5 * exp(-simd_length_squared(offset) * 2), 0, 0, 0)
        }
        let plain = try fixture.render(scene: scene, water: calm, horizon: horizon)
        let wave = try fixture.render(scene: scene, water: disturbed, horizon: horizon)
        XCTAssertTrue(wave.allSatisfy(\.isFinite))
        var nearbyDifference: Float = 0
        var nearbyCount: Float = 0
        var distantDifference: Float = 0
        var skyDifference: Float = 0
        for y in 0..<height { for x in 0..<width {
            let u = (Float(x) + 0.5) / Float(width)
            let v = (Float(y) + 0.5) / Float(height)
            let depth = (v - horizon) / (1 - horizon)
            let i = (y * width + x) * 4
            let difference = simd_length(SIMD3(wave[i] - plain[i], wave[i + 1] - plain[i + 1], wave[i + 2] - plain[i + 2]))
            if v < horizon { skyDifference = max(skyDifference, difference) }
            if (0.40...0.60).contains(u), (0.30...0.60).contains(depth) {
                nearbyDifference += difference
                nearbyCount += 1
            }
            if v > horizon, u < 0.20 || u > 0.80 { distantDifference = max(distantDifference, difference) }
        } }
        XCTAssertGreaterThan(nearbyDifference / nearbyCount, 0.001,
                             "A local wave must visibly bend or light the nearby colored reflection.")
        XCTAssertLessThan(distantDifference, 0.0001, "A local wave must not produce a screen-wide horizontal band.")
        XCTAssertEqual(skyDifference, 0, "Water interaction must leave the scene above the water unchanged.")
    }

    func testStrongMusicAndLocalWaveKeepThinReflectionStraightAndItsWidthStable() throws {
        let fixture = try Fixture(width: width, height: height)
        let center: Float = 0.5
        let scene = try fixture.texture { x, _ in
            let line = exp(-pow((x - center) / 0.009, 2))
            return SIMD4(line * 0.75, 0, line * 0.50, 1)
        }
        let emptyScene = try fixture.texture { _, _ in SIMD4(0, 0, 0, 1) }
        let calm = try fixture.texture { _, _ in .zero }
        // A steep local wave deliberately stresses the slope displacement limit.
        let disturbed = try fixture.texture { x, y in
            let offset = (SIMD2(x, y) - SIMD2<Float>(0.5, 0.48)) / SIMD2<Float>(0.022, 0.13)
            return SIMD4(4 * exp(-simd_length_squared(offset) * 2), 0, 0, 0)
        }
        let reference = try fixture.render(scene: scene, water: calm, horizon: horizon)
        let referenceBackground = try fixture.render(scene: emptyScene, water: calm, horizon: horizon)
        let firstRow = Int(Float(height) * (horizon + (1 - horizon) * 0.10))
        let lastRow = Int(Float(height) * (horizon + (1 - horizon) * 0.85))

        func lineProfile(_ pixels: [Float], _ background: [Float], row: Int) -> (center: Float, width: Float) {
            // Subtract the identical dark-scene render to isolate the reflected line
            // from the background and the local water's independently added light.
            let signal = (0..<width).map { x in max(0, pixels[(row * width + x) * 4] - background[(row * width + x) * 4]) }
            let total = signal.reduce(0, +)
            XCTAssertGreaterThan(total, 0.05, "The reflection must remain measurable even at the dim near edge.")
            let centroid = signal.enumerated().reduce(Float(0)) { $0 + (Float($1.offset) + 0.5) / Float(width) * $1.element } / max(total, 0.0001)
            let threshold = signal.max()! * 0.5
            let core = signal.indices.filter { signal[$0] >= threshold }
            return (centroid, Float(core.last! - core.first! + 1) / Float(width))
        }

        for time: Float in [0, 3.7, 9.1, 17.4] {
            let pixels = try fixture.render(scene: scene, water: disturbed, horizon: horizon,
                                            time: time, bass: 1, waterLevel: 1, bar: 1, analysis: 1)
            let background = try fixture.render(scene: emptyScene, water: disturbed, horizon: horizon,
                                                time: time, bass: 1, waterLevel: 1, bar: 1, analysis: 1)
            XCTAssertTrue(pixels.allSatisfy(\.isFinite))
            for row in firstRow...lastRow {
                let actual = lineProfile(pixels, background, row: row)
                let original = lineProfile(reference, referenceBackground, row: row)
                // At 256 px, 1% means under 2.6 px of sideways motion. This allows
                // small ripples while rejecting the former multi-percent pinches.
                XCTAssertLessThan(abs(actual.center - center), 0.01,
                                  "The line bent too far sideways at time \(time), row \(row).")
                XCTAssertLessThan(abs(actual.width - original.width), 0.01,
                                  "The line acquired a visible pinch or widening at time \(time), row \(row).")
            }
        }
    }

    private struct Fixture {
        let device: MTLDevice
        let queue: MTLCommandQueue
        let pipeline: MTLRenderPipelineState
        let width: Int
        let height: Int

        init(width: Int, height: Int) throws {
            guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("Metal device unavailable") }
            self.device = device
            self.queue = try XCTUnwrap(device.makeCommandQueue())
            self.width = width
            self.height = height
            let url = try XCTUnwrap(Bundle.module.url(forResource: "Shaders", withExtension: "metal"))
            let library = try device.makeLibrary(source: String(contentsOf: url, encoding: .utf8), options: nil)
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = try XCTUnwrap(library.makeFunction(name: "fullscreenVertex"))
            descriptor.fragmentFunction = try XCTUnwrap(library.makeFunction(name: "compositeFragment"))
            descriptor.colorAttachments[0].pixelFormat = .rgba16Float
            pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
        }

        func texture(_ value: (Float, Float) -> SIMD4<Float>) throws -> MTLTexture {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba32Float, width: width, height: height, mipmapped: false)
            descriptor.storageMode = .shared
            descriptor.usage = [.shaderRead]
            let texture = try XCTUnwrap(device.makeTexture(descriptor: descriptor))
            var values = [SIMD4<Float>]()
            values.reserveCapacity(width * height)
            for y in 0..<height { for x in 0..<width {
                values.append(value((Float(x) + 0.5) / Float(width), (Float(y) + 0.5) / Float(height)))
            } }
            values.withUnsafeBytes { texture.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0,
                                                      withBytes: $0.baseAddress!, bytesPerRow: width * 16) }
            return texture
        }

        func render(scene: MTLTexture, water: MTLTexture, horizon: Float,
                    time: Float = 3.7, bass: Float = 0, waterLevel: Float = 0.5,
                    bar: Float = 0, analysis: Float = 0) throws -> [Float] {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: width, height: height, mipmapped: false)
            descriptor.storageMode = .shared
            descriptor.usage = [.renderTarget]
            let target = try XCTUnwrap(device.makeTexture(descriptor: descriptor))
            let bloom = try texture { _, _ in .zero }
            // Match the twelve float4 groups in the renderer's Swift/Metal uniform ABI.
            var uniforms: [SIMD4<Float>] = [
                SIMD4(time, 0, 0, bass), SIMD4(0, 0, 0, bar), .zero, .zero, .zero,
                SIMD4(0, analysis, 1, 0), SIMD4(Float(width) / Float(height), Float(width), Float(height), horizon),
                .zero, SIMD4(repeating: 0.5), SIMD4(waterLevel, 0, 0, 0), .zero, .zero
            ]
            let command = try XCTUnwrap(queue.makeCommandBuffer())
            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = target
            pass.colorAttachments[0].loadAction = .dontCare
            pass.colorAttachments[0].storeAction = .store
            let encoder = try XCTUnwrap(command.makeRenderCommandEncoder(descriptor: pass))
            encoder.setRenderPipelineState(pipeline)
            encoder.setFragmentTexture(scene, index: 0)
            encoder.setFragmentTexture(bloom, index: 1)
            encoder.setFragmentTexture(water, index: 2)
            uniforms.withUnsafeMutableBytes { encoder.setFragmentBytes($0.baseAddress!, length: $0.count, index: 0) }
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            encoder.endEncoding()
            command.commit()
            command.waitUntilCompleted()
            XCTAssertEqual(command.status, .completed, command.error?.localizedDescription ?? "Water composite failed")
            var pixels = [Float16](repeating: 0, count: width * height * 4)
            target.getBytes(&pixels, bytesPerRow: width * 8, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
            return pixels.map(Float.init)
        }
    }
}
