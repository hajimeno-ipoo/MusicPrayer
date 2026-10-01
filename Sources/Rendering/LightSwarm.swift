import Foundation
import Metal
import simd

/// Particles and eight saved positions remain on the GPU. The render queue owns all updates.
final class LightSwarm {
    struct Particle {
        var position: SIMD4<Float>
        var velocity: SIMD4<Float>
        var appearance: SIMD4<Float>
    }
    private struct Uniforms {
        var clock: SIMD4<Float>
        var music: SIMD4<Float>
        var levels: SIMD4<Float>
        var eye: SIMD4<Float>
        var target: SIMD4<Float>
        var layout: SIMD4<Float>
    }
    static let historyCount = 8
    let particleCount: Int
    let particleBuffer: MTLBuffer
    let historyBuffer: MTLBuffer
    private let updatePipeline: MTLComputePipelineState
    private let renderPipeline: MTLRenderPipelineState
    private var renderUniforms: Uniforms
    private var previousAudioTime: Float?
    private var previousBeat: Float = 0

    init(device: MTLDevice, particleCount: Int = 1440) throws {
        self.particleCount = max(1, particleCount)
        guard let url = Bundle.module.url(forResource: "LightSwarm", withExtension: "metal") else {
            throw RenderFailure.message("LightSwarm.metalがアプリ内にありません。")
        }
        let library = try device.makeLibrary(source: String(contentsOf: url, encoding: .utf8), options: nil)
        guard let update = library.makeFunction(name: "updateLightSwarm"),
              let vertex = library.makeFunction(name: "lightSwarmVertex"),
              let fragment = library.makeFunction(name: "lightSwarmFragment") else {
            throw RenderFailure.message("光の群れのMetal関数がありません。")
        }
        updatePipeline = try device.makeComputePipelineState(function: update)
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertex
        descriptor.fragmentFunction = fragment
        let color = descriptor.colorAttachments[0]!
        color.pixelFormat = .rgba16Float
        color.isBlendingEnabled = true
        color.sourceRGBBlendFactor = .one
        color.destinationRGBBlendFactor = .one
        color.sourceAlphaBlendFactor = .one
        color.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        renderPipeline = try device.makeRenderPipelineState(descriptor: descriptor)
        guard let particles = device.makeBuffer(length: self.particleCount * MemoryLayout<Particle>.stride, options: .storageModeShared),
              let history = device.makeBuffer(length: self.particleCount * Self.historyCount * MemoryLayout<SIMD4<Float>>.stride, options: .storageModeShared) else {
            throw RenderFailure.message("光の群れのMetal bufferを作成できません。")
        }
        particleBuffer = particles
        historyBuffer = history
        // Fixed seeds make repeated plays and tests reproducible; simulation follows the actual signal.
        let states = particles.contents().assumingMemoryBound(to: Particle.self)
        let trail = history.contents().assumingMemoryBound(to: SIMD4<Float>.self)
        for index in 0..<self.particleCount {
            let seed = Float(index) + 1
            func random(_ scale: Float) -> Float {
                let value = sin(seed * scale) * 43758.5453
                return value - floor(value)
            }
            let position = SIMD4<Float>((random(12.9898) - 0.5) * 8.5,
                                        0.3 + (random(39.346) - 0.5) * 1.8,
                                        (random(73.156) - 0.5) * 2.8, 0)
            states[index] = Particle(position: position,
                                     velocity: SIMD4((random(8.25) - 0.5) * 0.16, 0, 0, random(3.72)),
                                     appearance: SIMD4(0, random(51.13), random(19.19), 0))
            for sample in 0..<Self.historyCount { trail[index * Self.historyCount + sample] = position }
        }
        renderUniforms = Uniforms(clock: .zero, music: .zero, levels: .zero,
                                  eye: SIMD4(0, 0.2, 6, 0), target: SIMD4(0, 0.2, 0, 0),
                                  layout: SIMD4(1, Float(self.particleCount), 0, 0))
    }

    func encodeUpdate(command: MTLCommandBuffer, frame: VisualFrame, deltaTime: Float,
                      aspect: Float, cameraEye: SIMD3<Float>, cameraTarget: SIMD3<Float>) throws {
        let audioDelta = previousAudioTime.map { frame.time - $0 }
        let advanced = audioDelta.map { abs($0) > 0.00001 } ?? true
        // Audio snapshots arrive at 60 Hz even on a 120 Hz display. Integrate the audio delta once.
        // Seeking changes the flow's musical time, but never simulates the skipped minutes.
        let elapsed = audioDelta.flatMap { $0 > 0 && $0 < 0.2 ? $0 : nil } ?? deltaTime
        let dt = advanced ? min(1.0 / 30.0, max(0, elapsed)) : 0
        let burst = advanced ? max(0, frame.beat - previousBeat) * frame.drums : 0
        previousAudioTime = frame.time
        previousBeat = frame.beat
        renderUniforms = Uniforms(clock: SIMD4(frame.time, dt, burst, frame.presence),
                                  music: SIMD4(frame.vocal, frame.bassInstrument, frame.drums, frame.bass),
                                  levels: SIMD4(frame.rms, frame.treble, frame.pace, frame.hue),
                                  eye: SIMD4(cameraEye, 0), target: SIMD4(cameraTarget, 0),
                                  layout: SIMD4(max(0.1, aspect), Float(particleCount), 0, 0))
        guard let encoder = command.makeComputeCommandEncoder() else {
            throw RenderFailure.message("光の群れの更新を準備できません。")
        }
        encoder.label = "GPU light flow · vocal attraction · drum burst · trail history"
        encoder.setComputePipelineState(updatePipeline)
        encoder.setBuffer(particleBuffer, offset: 0, index: 0)
        encoder.setBuffer(historyBuffer, offset: 0, index: 1)
        encoder.setBytes(&renderUniforms, length: MemoryLayout<Uniforms>.stride, index: 2)
        let width = min(updatePipeline.maxTotalThreadsPerThreadgroup, updatePipeline.threadExecutionWidth)
        encoder.dispatchThreads(MTLSize(width: particleCount, height: 1, depth: 1),
                                threadsPerThreadgroup: MTLSize(width: width, height: 1, depth: 1))
        encoder.endEncoding()
    }

    func encodeRender(command: MTLCommandBuffer, target: MTLTexture, ribbonDepths: MTLTexture) throws {
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .load
        pass.colorAttachments[0].storeAction = .store
        guard let encoder = command.makeRenderCommandEncoder(descriptor: pass) else {
            throw RenderFailure.message("光の群れの描画を準備できません。")
        }
        encoder.label = "Additive lights and eight-position trails"
        encoder.setRenderPipelineState(renderPipeline)
        encoder.setCullMode(.none)
        encoder.setVertexBuffer(particleBuffer, offset: 0, index: 0)
        encoder.setVertexBuffer(historyBuffer, offset: 0, index: 1)
        encoder.setVertexBytes(&renderUniforms, length: MemoryLayout<Uniforms>.stride, index: 2)
        encoder.setFragmentTexture(ribbonDepths, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6,
                               instanceCount: particleCount * Self.historyCount)
        encoder.endEncoding()
    }
}
