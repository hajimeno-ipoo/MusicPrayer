import Foundation
import Metal

/// Two textures retain waves between frames; clicks and musical impulses share the same simulation.
final class WaterSurface {
    static let activitySampleCount = 512
    private let pipeline: MTLComputePipelineState
    private let activityPipeline: MTLComputePipelineState
    private var states: [MTLTexture]
    private var current = 0
    private var initialized = false
    private var accumulator: Double = 0
    private var pending: [WaterPulse] = []
    private var lastMusicTime: Float?
    private var lastBeat: Float = 0
    private var lastBass: Float = 0
    private var lastBassPulse: Float = -1
    var texture: MTLTexture { states[current] }

    init(device: MTLDevice) throws {
        guard let url = Bundle.module.url(forResource: "WaterSurface", withExtension: "metal") else {
            throw RenderFailure.message("WaterSurface.metalがアプリ内にありません。")
        }
        let library = try device.makeLibrary(source: String(contentsOf: url, encoding: .utf8), options: nil)
        guard let function = library.makeFunction(name: "advanceWater") else { throw RenderFailure.message("水面のMetal関数がありません。") }
        pipeline = try device.makeComputePipelineState(function: function)
        guard let activityFunction = library.makeFunction(name: "measureWaterActivity") else { throw RenderFailure.message("水面の静止判定用Metal関数がありません。") }
        activityPipeline = try device.makeComputePipelineState(function: activityFunction)
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rg32Float, width: 256, height: 128, mipmapped: false)
        descriptor.storageMode = .private
        descriptor.usage = [.shaderRead, .shaderWrite]
        states = try (0..<2).map { index in
            guard let texture = device.makeTexture(descriptor: descriptor) else { throw RenderFailure.message("水面の状態を作成できません。") }
            texture.label = "Wave height / previous height \(index)"
            return texture
        }
    }

    func encode(command: MTLCommandBuffer, elapsed: Double, pulses: [WaterPulse], frame: VisualFrame, aspect: Float) throws {
        pending.append(contentsOf: pulses)
        // One impulse per onset, rather than injecting the same beat every display frame.
        if let lastMusicTime, frame.time > lastMusicTime, frame.time - lastMusicTime < 0.2 {
            if frame.hasAnalysis > 0, frame.beat > 0.6, lastBeat <= 0.6, frame.drums > 0.08 {
                let x: Float = 0.5 + 0.22 * sin(frame.time * 0.73)
                pending.append(WaterPulse(position: SIMD2(x, 0.24), strength: 0.06 + frame.drums * 0.16 + frame.bar * 0.05, radius: 0.012))
            }
            if frame.bass > 0.55, lastBass <= 0.55, frame.time - lastBassPulse > 0.35 {
                pending.append(WaterPulse(position: SIMD2(0.38, 0.5), strength: frame.bass * 0.09, radius: 0.025))
                lastBassPulse = frame.time
            }
        } else if lastMusicTime.map({ abs(frame.time - $0) >= 0.2 }) ?? false { lastBassPulse = frame.time - 1 }
        lastMusicTime = frame.time; lastBeat = frame.beat; lastBass = frame.bass
        if pending.count > 32 { pending.removeFirst(pending.count - 32) }
        accumulator += min(1.0 / 15, max(0, elapsed))
        let step = 1.0 / 120
        var steps = min(8, Int(accumulator / step))
        if !initialized || !pending.isEmpty { steps = max(1, steps) }
        guard steps > 0 else { return }
        accumulator = max(0, accumulator - Double(steps) * step)
        let horizon = frame.camera.horizon
        let dx = max(0.1, aspect) / 256, dy = max(0.05, 1 - horizon) / 128
        let ratio = min(4, max(0.02, (dy * dy) / (dx * dx)))
        for index in 0..<steps {
            guard let encoder = command.makeComputeCommandEncoder() else { throw RenderFailure.message("水面の計算を準備できません。") }
            var uniforms = SIMD8<Float>(aspect, horizon, ratio, 0.45 / (1 + ratio), Float(index == 0 ? pending.count : 0), initialized ? 0 : 1, 0, 0)
            let destination = 1 - current
            encoder.label = "Propagate interactive water waves"
            encoder.setComputePipelineState(pipeline)
            encoder.setTexture(states[current], index: 0)
            encoder.setTexture(states[destination], index: 1)
            encoder.setBytes(&uniforms, length: MemoryLayout<SIMD8<Float>>.stride, index: 0)
            let vectors = pending.isEmpty ? [SIMD4<Float>.zero] : pending.map { SIMD4($0.position.x, $0.position.y, $0.strength, $0.radius) }
            vectors.withUnsafeBytes { encoder.setBytes($0.baseAddress!, length: $0.count, index: 1) }
            encoder.dispatchThreads(MTLSize(width: 256, height: 128, depth: 1), threadsPerThreadgroup: MTLSize(width: 16, height: 8, depth: 1))
            encoder.endEncoding()
            current = destination; initialized = true
        }
        pending.removeAll(keepingCapacity: true)
    }

    /// Read results only after this command completes; each sample includes both wave heights.
    func encodeActivityCheck(command: MTLCommandBuffer, result: MTLBuffer) throws {
        guard result.length >= Self.activitySampleCount * MemoryLayout<Float>.stride else {
            throw RenderFailure.message("水面の静止判定用bufferが小さすぎます。")
        }
        guard let encoder = command.makeComputeCommandEncoder() else {
            throw RenderFailure.message("水面の静止判定を準備できません。")
        }
        var layout = SIMD2<UInt32>(UInt32(Self.activitySampleCount), initialized ? 1 : 0)
        encoder.label = "Measure remaining water wave activity"
        encoder.setComputePipelineState(activityPipeline)
        encoder.setTexture(texture, index: 0)
        encoder.setBuffer(result, offset: 0, index: 0)
        encoder.setBytes(&layout, length: MemoryLayout<SIMD2<UInt32>>.stride, index: 1)
        let width = min(activityPipeline.maxTotalThreadsPerThreadgroup, activityPipeline.threadExecutionWidth)
        encoder.dispatchThreads(MTLSize(width: Self.activitySampleCount, height: 1, depth: 1),
                                threadsPerThreadgroup: MTLSize(width: width, height: 1, depth: 1))
        encoder.endEncoding()
    }
}
