import Foundation
import Metal
import simd

/// A real, absorbing 3D ink volume and its reflected image share one HDR pass.
final class InkRenderer {
    private struct Uniforms {
        var viewport: SIMD4<Float>
        var audio: SIMD4<Float>
        var rhythm: SIMD4<Float>
        var timing: SIMD4<Float>
        var structure: SIMD4<Float>
        var scene: SIMD4<Float>
        var material: SIMD4<Float>
        var music: SIMD4<Float>
        var instruments: SIMD4<Float>
        var domainMinimum: SIMD4<Float>
        var domainExtent: SIMD4<Float>
        var sampling: SIMD4<Float>
        var offset: SIMD4<Float>
        var eye: SIMD4<Float>
        var target: SIMD4<Float>
        var layout: SIMD4<Float>
    }

    private let volumePipeline: MTLRenderPipelineState
    private let compositePipeline: MTLRenderPipelineState
    // Keep the ink's water reflection above the existing lower player controls.
    private static let cameraEye = SIMD3<Float>(0, 1.45, 6.8)
    private static let cameraTarget = SIMD3<Float>(0, 1.05, 0)
    private static let cameraFocal: Float = 1.75

    static func waterHorizon(aspect: Float) -> Float {
        // The same camera basis and projection are used in InkRendering.metal.
        let eye = cameraEye
        let forward = simd_normalize(cameraTarget - eye)
        let right = simd_normalize(simd_cross(forward, SIMD3<Float>(0, 1, 0)))
        let up = simd_normalize(simd_cross(right, forward))
        let floor = -eye
        return 0.5 - simd_dot(floor, up) / simd_dot(floor, forward) * cameraFocal * 0.5
    }

    init(device: MTLDevice) throws {
        guard let url = Bundle.module.url(forResource: "InkRendering", withExtension: "metal") else {
            throw RenderFailure.message("InkRendering.metalがアプリ内にありません。")
        }
        let library = try device.makeLibrary(source: String(contentsOf: url, encoding: .utf8), options: nil)
        func pipeline(fragment: String, format: MTLPixelFormat) throws -> MTLRenderPipelineState {
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.label = fragment
            descriptor.vertexFunction = library.makeFunction(name: "inkFullscreenVertex")
            descriptor.fragmentFunction = library.makeFunction(name: fragment)
            descriptor.colorAttachments[0].pixelFormat = format
            return try device.makeRenderPipelineState(descriptor: descriptor)
        }
        volumePipeline = try pipeline(fragment: "inkVolumeFragment", format: .rgba16Float)
        compositePipeline = try pipeline(fragment: "inkCompositeFragment", format: .bgra8Unorm_srgb)
    }

    func encode(command: MTLCommandBuffer, target: MTLTexture, density: MTLTexture,
                frame: VisualFrame, water: MTLTexture, aspect: Float) throws {
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .dontCare
        pass.colorAttachments[0].storeAction = .store
        guard let encoder = command.makeRenderCommandEncoder(descriptor: pass) else {
            throw RenderFailure.message("インクの立体描画を開始できません。")
        }
        func level(_ value: Float) -> Float { value.isFinite ? min(1, max(0, value)) : 0 }
        let phrase = sin(level(frame.phraseProgress) * .pi) * level(frame.hasAnalysis)
        let tempo = min(2, max(0.4, frame.tempo))
        let detailPhase = frame.time * 0.55 + sin(level(frame.beatPhase) * .pi * 2) * tempo * 0.12
        let curlTravel = frame.time * 0.18 + sin(frame.time * 0.9) * level(frame.pace) * 0.70
        let thickness = 0.86 + level(frame.sectionThickness) * 0.28 + level(frame.density) * 0.12
                      + max(level(frame.bass), level(frame.bassInstrument)) * 0.08
        var uniforms = Uniforms(
            viewport: SIMD4(max(0.1, aspect), frame.time, frame.presence, frame.rms),
            audio: SIMD4(frame.bass, frame.vocal, frame.drums, frame.treble),
            rhythm: SIMD4(frame.beat, frame.bar, frame.sectionTransition, frame.loudness),
            timing: SIMD4(level(frame.beatPhase), level(frame.barPhase), tempo, level(frame.pace)),
            structure: SIMD4(level(frame.sectionProgress), level(frame.segmentProgress), level(frame.phraseProgress), level(frame.hasAnalysis)),
            scene: SIMD4(level(frame.sectionSeparation), level(frame.sectionThickness), level(frame.sectionDepth), level(frame.sectionGlow)),
            material: SIMD4(level(frame.density), level(frame.peak), level(frame.sectionWater), level(frame.mid)),
            music: SIMD4(frame.hue.isFinite ? min(0.033, max(-0.033, frame.hue)) : 0,
                         frame.modeBias.isFinite ? min(1, max(-1, frame.modeBias)) : 0, detailPhase, curlTravel),
            instruments: SIMD4(level(frame.vocal), level(frame.drums), level(frame.bassInstrument), level(frame.other)),
            domainMinimum: SIMD4(InkFluid.domainMinimum, 0),
            domainExtent: SIMD4(InkFluid.domainMaximum - InkFluid.domainMinimum, 0),
            sampling: SIMD4((level(frame.sectionSeparation) - 0.5) * 0.68, 1 / thickness,
                            1 / (0.80 + level(frame.sectionDepth) * 0.40), phrase),
            offset: SIMD4(sin(level(frame.sectionProgress) * .pi * 2) * level(frame.hasAnalysis) * 0.12,
                          sin(level(frame.segmentProgress) * .pi) * level(frame.hasAnalysis) * 0.12,
                          phrase * 0.14 + level(frame.vocal) * 0.30, 0),
            eye: SIMD4(Self.cameraEye, Self.cameraFocal),
            target: SIMD4(Self.cameraTarget, 0),
            layout: SIMD4(max(1, aspect / 1.25), Self.waterHorizon(aspect: aspect), 0, 0))
        encoder.label = "Absorbing ink volume · Soft scattering · Reflected water"
        encoder.setRenderPipelineState(volumePipeline)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
        let spectrum = InkSpectrum.values(frame.spectrum)
        spectrum.withUnsafeBytes { bytes in
            encoder.setFragmentBytes(bytes.baseAddress!, length: bytes.count, index: 1)
        }
        encoder.setFragmentTexture(density, index: 0)
        encoder.setFragmentTexture(water, index: 1)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
    }

    func encodeComposite(command: MTLCommandBuffer, pass: MTLRenderPassDescriptor,
                         scene: MTLTexture, bloom: MTLTexture) throws {
        guard let encoder = command.makeRenderCommandEncoder(descriptor: pass) else {
            throw RenderFailure.message("インクの画面合成を開始できません。")
        }
        encoder.label = "Ink HDR · Bloom · Display tone mapping"
        encoder.setRenderPipelineState(compositePipeline)
        encoder.setFragmentTexture(scene, index: 0)
        encoder.setFragmentTexture(bloom, index: 1)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
    }
}
