import Metal
import XCTest
import simd
@testable import MusicPrayer

final class RibbonGlassCoverageTests: XCTestCase {
    func testSoftClothMaterialKeepsSolidGeometryCoverageAndEmptyBackground() throws {
        let fixture = try Fixture()
        let image = try fixture.render(activeLayers: 1, presence: 1)
        let center = fixture.centerIndex
        let material = image.layers[0][center]

        XCTAssertGreaterThan(material.w, 0.1, "The fixture must exercise a visible cloth material.")
        XCTAssertLessThan(material.w, 0.5, "The production cloth must retain its internal transparency.")
        XCTAssertEqual(image.resolved[center].w, 1, accuracy: 0.001,
                       "Desktop transparency must use the cloth footprint, not its material alpha.")
        for channel in 0..<3 {
            XCTAssertEqual(image.resolved[center][channel], material[channel], accuracy: 0.001,
                           "Separating coverage must not brighten or recolor the cloth.")
        }
        XCTAssertEqual(image.resolved[0], .zero, "Pixels outside the geometry must remain transparent.")
        let softEdge = image.resolved.filter { $0.w > 0.01 && $0.w < 0.99 }
        XCTAssertGreaterThan(softEdge.count, 20,
                             "The actual fragment edge fade must survive; a binary depth mask is insufficient.")
        XCTAssertTrue(image.resolved.allSatisfy { pixel in
            (0..<4).allSatisfy { pixel[$0].isFinite } && (0...1).contains(pixel.w)
        })
    }

    func testTrackPresenceFadesGeometryWithoutLeavingAnOpaqueClothSilhouette() throws {
        let fixture = try Fixture()
        let visible = try fixture.render(activeLayers: 1, presence: 1)
        let fading = try fixture.render(activeLayers: 1, presence: 0.5)
        let absent = try fixture.render(activeLayers: 1, presence: 0)
        let center = fixture.centerIndex

        XCTAssertEqual(fading.resolved[center].w, 0.5, accuracy: 1 / 255 + 0.001)
        XCTAssertEqual(fading.layers[0][center].w, visible.layers[0][center].w * 0.5, accuracy: 0.001)
        for channel in 0..<3 {
            XCTAssertEqual(fading.resolved[center][channel], visible.resolved[center][channel] * 0.5,
                           accuracy: 0.001)
        }
        XCTAssertTrue(absent.resolved.allSatisfy { $0 == .zero },
                      "Zero track presence must remove both the cloth RGB and its coverage.")
    }

    func testCoverageDoesNotChangePerPixelDepthSortedClothColorMixing() throws {
        let fixture = try Fixture()
        let image = try fixture.render(activeLayers: 4, presence: 1)
        let center = fixture.centerIndex
        // The deliberately scrambled depths are 0.2, 0.8, 0.4, 0.6.
        // Source material RGBA comes from the production fragment, not a copy of its shader formula.
        let ordered = [1, 3, 2, 0].map { image.layers[$0][center] }
        let materialComposite = ordered.reduce(SIMD4<Float>.zero) { result, layer in
            layer + result * (1 - layer.w)
        }
        let unsorted = image.layers.reduce(SIMD4<Float>.zero) { result, layer in
            layer[center] + result * (1 - layer[center].w)
        }
        XCTAssertGreaterThan(simd_length(SIMD3(materialComposite.x - unsorted.x,
                                             materialComposite.y - unsorted.y,
                                             materialComposite.z - unsorted.z)), 0.02,
                             "The control colors must make an incorrect depth order detectable.")
        for channel in 0..<3 {
            XCTAssertEqual(image.resolved[center][channel], materialComposite[channel], accuracy: 0.002)
        }
        XCTAssertLessThan(materialComposite.w, 0.95)
        XCTAssertEqual(image.resolved[center].w, 1, accuracy: 0.001,
                       "Resolved geometry coverage must be independent of the material composite alpha.")
    }

    private struct Image {
        let resolved: [SIMD4<Float>]
        let layers: [[SIMD4<Float>]]
    }

    private struct Fixture {
        let device: MTLDevice
        let queue: MTLCommandQueue
        let clothPipeline: MTLRenderPipelineState
        let resolvePipeline: MTLRenderPipelineState
        let depthState: MTLDepthStencilState
        let width = 256
        let height = 128

        var centerIndex: Int { height / 2 * width + width / 2 }

        init() throws {
            guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("Metal device unavailable") }
            self.device = device
            queue = try XCTUnwrap(device.makeCommandQueue())
            let url = try XCTUnwrap(Bundle.module.url(forResource: "Shaders", withExtension: "metal"))
            let shader = try String(contentsOf: url, encoding: .utf8)
            // A flat quad supplies predictable geometry and UVs to the actual production fragment.
            // Both the cloth pass and depth resolve below use the production functions unchanged.
            let probe = """
            vertex RibbonOut glassCoverageFixtureVertex(uint id [[vertex_id]],
                                                        constant float4* values [[buffer(1)]]) {
                const float2 corners[6] = { float2(0, 0), float2(1, 0), float2(0, 1),
                                            float2(0, 1), float2(1, 0), float2(1, 1) };
                float2 uv = corners[id];
                float2 position = mix(values[0].xy, values[0].zw, uv);
                RibbonOut out;
                out.position = float4(position, values[2].x, 1);
                out.world = float3(position, 0);
                out.uv = uv;
                out.color = values[1].xyz;
                out.activity = 0.4;
                out.glow = 0.2;
                out.opacity = values[1].w;
                return out;
            }
            """
            let library = try device.makeLibrary(source: shader + "\n" + probe, options: nil)
            let cloth = MTLRenderPipelineDescriptor()
            cloth.vertexFunction = try XCTUnwrap(library.makeFunction(name: "glassCoverageFixtureVertex"))
            cloth.fragmentFunction = try XCTUnwrap(library.makeFunction(name: "ribbonFragment"))
            cloth.colorAttachments[0].pixelFormat = .rgba16Float
            cloth.colorAttachments[1].pixelFormat = .r8Unorm
            cloth.depthAttachmentPixelFormat = .depth32Float
            clothPipeline = try device.makeRenderPipelineState(descriptor: cloth)
            let resolve = MTLRenderPipelineDescriptor()
            resolve.vertexFunction = try XCTUnwrap(library.makeFunction(name: "fullscreenVertex"))
            resolve.fragmentFunction = try XCTUnwrap(library.makeFunction(name: "resolveRibbonsFragment"))
            resolve.colorAttachments[0].pixelFormat = .rgba16Float
            resolvePipeline = try device.makeRenderPipelineState(descriptor: resolve)
            let depth = MTLDepthStencilDescriptor()
            depth.depthCompareFunction = .lessEqual
            depth.isDepthWriteEnabled = true
            depthState = try XCTUnwrap(device.makeDepthStencilState(descriptor: depth))
        }

        func render(activeLayers: Int, presence: Float) throws -> Image {
            let colors = try texture(format: .rgba16Float, layers: 4)
            let coverage = try texture(format: .r8Unorm, layers: 4)
            let depths = try texture(format: .depth32Float, layers: 4)
            let scene = try texture(format: .rgba16Float)
            var uniforms = [SIMD4<Float>](repeating: .zero, count: 12)
            uniforms[5] = SIMD4(0.5, 0, presence, 0)
            uniforms[10] = SIMD4(0, 0, 6, 0)
            let palette: [SIMD4<Float>] = [SIMD4(0.03, 0.05, 0.8, 0.58),
                                         SIMD4(0.02, 0.8, 0.4, 1),
                                         SIMD4(0.8, 0.01, 0.5, 1),
                                         SIMD4(0.7, 0.4, 0.03, 0.68)]
            let depthValues: [Float] = [0.2, 0.8, 0.4, 0.6]
            let command = try XCTUnwrap(queue.makeCommandBuffer())
            for layer in 0..<4 {
                let pass = MTLRenderPassDescriptor()
                for attachment in 0..<2 {
                    pass.colorAttachments[attachment].texture = attachment == 0 ? colors : coverage
                    pass.colorAttachments[attachment].slice = layer
                    pass.colorAttachments[attachment].loadAction = .clear
                    pass.colorAttachments[attachment].storeAction = .store
                    pass.colorAttachments[attachment].clearColor = MTLClearColorMake(0, 0, 0, 0)
                }
                pass.depthAttachment.texture = depths
                pass.depthAttachment.slice = layer
                pass.depthAttachment.loadAction = .clear
                pass.depthAttachment.storeAction = .store
                pass.depthAttachment.clearDepth = 1
                let encoder = try XCTUnwrap(command.makeRenderCommandEncoder(descriptor: pass))
                encoder.setRenderPipelineState(clothPipeline)
                encoder.setDepthStencilState(depthState)
                encoder.setCullMode(.none)
                let values = [SIMD4<Float>(-0.8, -0.6, 0.8, 0.6), palette[layer],
                              SIMD4(depthValues[layer], 0, 0, 0)]
                values.withUnsafeBytes { encoder.setVertexBytes($0.baseAddress!, length: $0.count, index: 1) }
                uniforms.withUnsafeBytes { encoder.setFragmentBytes($0.baseAddress!, length: $0.count, index: 0) }
                if layer < activeLayers { encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6) }
                encoder.endEncoding()
            }
            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = scene
            pass.colorAttachments[0].loadAction = .dontCare
            pass.colorAttachments[0].storeAction = .store
            let encoder = try XCTUnwrap(command.makeRenderCommandEncoder(descriptor: pass))
            encoder.setRenderPipelineState(resolvePipeline)
            encoder.setFragmentTexture(colors, index: 0)
            encoder.setFragmentTexture(depths, index: 1)
            encoder.setFragmentTexture(coverage, index: 2)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            encoder.endEncoding()
            command.commit()
            command.waitUntilCompleted()
            XCTAssertNil(command.error)
            return Image(resolved: read(scene), layers: (0..<4).map { read(colors, slice: $0) })
        }

        private func texture(format: MTLPixelFormat, layers: Int = 1) throws -> MTLTexture {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format,
                                                                     width: width, height: height, mipmapped: false)
            descriptor.storageMode = format == .depth32Float ? .private : .shared
            descriptor.usage = [.renderTarget, .shaderRead]
            if layers > 1 {
                descriptor.textureType = .type2DArray
                descriptor.arrayLength = layers
            }
            return try XCTUnwrap(device.makeTexture(descriptor: descriptor))
        }

        private func read(_ texture: MTLTexture, slice: Int = 0) -> [SIMD4<Float>] {
            var values = [UInt16](repeating: 0, count: width * height * 4)
            values.withUnsafeMutableBytes {
                texture.getBytes($0.baseAddress!, bytesPerRow: width * 8, bytesPerImage: width * height * 8,
                                 from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0, slice: slice)
            }
            return stride(from: 0, to: values.count, by: 4).map { index in
                SIMD4(Float(Float16(bitPattern: values[index])), Float(Float16(bitPattern: values[index + 1])),
                      Float(Float16(bitPattern: values[index + 2])), Float(Float16(bitPattern: values[index + 3])))
            }
        }
    }
}
