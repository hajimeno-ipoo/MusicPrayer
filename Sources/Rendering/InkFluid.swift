import Foundation
import Metal
import simd

/// A coarse, incompressible 3D dye flow. Velocity and three dye concentrations stay on the GPU.
/// Bounded MacCormack dye transport preserves folds; the velocity uses a finite Jacobi pressure solve.
final class InkFluid {
    static let domainMinimum = SIMD3<Float>(-4.8, 0, -1.8)
    static let domainMaximum = SIMD3<Float>(4.8, 5.5, 1.8)
    private struct Uniforms {
        var minimum: SIMD4<Float>
        var extent: SIMD4<Float>
        var clock: SIMD4<Float>
        var levels: SIMD4<Float>
        var music: SIMD4<Float>
        var rhythm: SIMD4<Float>
        var structure: SIMD4<Float>
        var layout: SIMD4<Float>
        var expression: SIMD4<Float>
        var motionA: SIMD4<Float>
        var motionB: SIMD4<Float>
    }
    private let seed: MTLComputePipelineState
    private let advection: MTLComputePipelineState
    private let divergence: MTLComputePipelineState
    private let pressureSolve: MTLComputePipelineState
    private let projection: MTLComputePipelineState
    private let dyePrediction: MTLComputePipelineState
    private let dyeAdvection: MTLComputePipelineState
    private let resolution: SIMD3<Int>
    private var dye: [MTLTexture]
    private var velocity: [MTLTexture]
    private let predictedDye: MTLTexture
    private let divergenceField: MTLTexture
    private let pressure: [MTLTexture]
    private var current = 0
    private var previousTime: Float?
    private var previousBeat: Float = 0
    private var previousPresence: Float = 1
    private var previousTrackID: UUID?
    private var accumulator: Double = 0
    private var pendingBurst: Float = 0
    private var simulationTime: Float = 0
    private var motionController = InkMotionController()
    private(set) var motionState = InkMotionState()

    /// RGB store blue / violet / pink dye concentration; alpha is the sum of the three.
    var densityTexture: MTLTexture { dye[current] }
    /// Exposed internally for GPU verification; rendering uses densityTexture only.
    var velocityTexture: MTLTexture { velocity[current] }

    init(device: MTLDevice, resolution: SIMD3<Int> = SIMD3(144, 96, 64)) throws {
        let dimensions = SIMD3(max(8, resolution.x), max(8, resolution.y), max(8, resolution.z))
        self.resolution = dimensions
        guard let url = Bundle.module.url(forResource: "InkFluid", withExtension: "metal") else {
            throw RenderFailure.message("InkFluid.metalがアプリ内にありません。")
        }
        let library = try device.makeLibrary(source: String(contentsOf: url, encoding: .utf8), options: nil)
        func pipeline(_ name: String) throws -> MTLComputePipelineState {
            guard let function = library.makeFunction(name: name) else {
                throw RenderFailure.message("インクのMetal関数 \(name) がありません。")
            }
            return try device.makeComputePipelineState(function: function)
        }
        seed = try pipeline("seedInk")
        advection = try pipeline("advectInkVelocity")
        divergence = try pipeline("inkDivergence")
        pressureSolve = try pipeline("solveInkPressure")
        projection = try pipeline("projectInkVelocity")
        dyePrediction = try pipeline("predictInkDensity")
        dyeAdvection = try pipeline("advectInkDensity")
        func texture(_ name: String, _ format: MTLPixelFormat) throws -> MTLTexture {
            let descriptor = MTLTextureDescriptor()
            descriptor.textureType = .type3D
            descriptor.pixelFormat = format
            descriptor.width = dimensions.x
            descriptor.height = dimensions.y
            descriptor.depth = dimensions.z
            descriptor.storageMode = .private
            descriptor.usage = [.shaderRead, .shaderWrite]
            guard let result = device.makeTexture(descriptor: descriptor) else {
                throw RenderFailure.message("インクの3Dテクスチャを作成できません。")
            }
            result.label = name
            return result
        }
        dye = try (0..<2).map { try texture("3D blue / violet / pink ink \($0)", .rgba16Float) }
        velocity = try (0..<2).map { try texture("3D projected ink velocity \($0)", .rgba16Float) }
        predictedDye = try texture("Ink MacCormack dye prediction", .rgba16Float)
        divergenceField = try texture("Ink velocity divergence", .r16Float)
        pressure = try (0..<2).map { try texture("Ink pressure \($0)", .r16Float) }
    }

    func encode(command: MTLCommandBuffer, frame: VisualFrame, elapsed: Double, motion: InkMotionState? = nil) throws {
        // Wall-clock rendering time never advances a paused musical simulation.
        guard frame.time.isFinite else { return }
        motionState = motion ?? motionController.update(frame: frame)
        let spectrum = InkSpectrum.values(frame.spectrum)
        let delta = previousTime.map { frame.time - $0 }
        let reset = previousTime == nil || delta.map { $0 < -0.00001 || $0 >= 0.2 } == true
            || previousTrackID != frame.trackID
            || (previousPresence <= 0.01 && frame.presence > 0.01)
        if reset {
            current = 0
            simulationTime = frame.time
            accumulator = 0
            pendingBurst = 0
            var uniforms = makeUniforms(frame: frame, dt: 0, burst: 0)
            try dispatch(command, pipeline: seed, textures: [dye[current], velocity[current]], uniforms: &uniforms, spectrum: spectrum)
        } else if let delta, delta > 0.00001 {
            accumulator += Double(delta)
            pendingBurst = max(pendingBurst, max(0, bounded(frame.beat) - previousBeat) * bounded(frame.drums))
            let fixedStep = 1.0 / 30.0
            let steps = min(6, Int((accumulator + 0.000001) / fixedStep))
            if steps > 0 {
                accumulator = max(0, accumulator - Double(steps) * fixedStep)
                for step in 0..<steps {
                    simulationTime += Float(fixedStep)
                    var uniforms = makeUniforms(frame: frame, dt: Float(fixedStep), burst: step == 0 ? pendingBurst : 0)
                    let next = 1 - current
                    try dispatch(command, pipeline: advection,
                                 textures: [velocity[current], dye[current], velocity[next]], uniforms: &uniforms, spectrum: spectrum)
                    // The divergence pass also clears the initial pressure field each step.
                    try dispatch(command, pipeline: divergence,
                                 textures: [velocity[next], divergenceField, pressure[0]], uniforms: &uniforms, spectrum: spectrum)
                    var pressureIndex = 0
                    for _ in 0..<10 {
                        try dispatch(command, pipeline: pressureSolve,
                                     textures: [pressure[pressureIndex], divergenceField, pressure[1 - pressureIndex]], uniforms: &uniforms, spectrum: spectrum)
                        pressureIndex = 1 - pressureIndex
                    }
                    try dispatch(command, pipeline: projection,
                                 textures: [velocity[next], pressure[pressureIndex], velocity[current]], uniforms: &uniforms, spectrum: spectrum)
                    try dispatch(command, pipeline: dyePrediction,
                                 textures: [dye[current], velocity[current], predictedDye], uniforms: &uniforms, spectrum: spectrum)
                    try dispatch(command, pipeline: dyeAdvection,
                                 textures: [dye[current], velocity[current], dye[next], predictedDye], uniforms: &uniforms, spectrum: spectrum)
                    // Projection wrote the old slot; swapping references aligns it with the new dye.
                    velocity.swapAt(current, next)
                    current = next
                }
                pendingBurst = 0
            }
        }
        previousTime = frame.time
        previousBeat = bounded(frame.beat)
        previousPresence = bounded(frame.presence)
        previousTrackID = frame.trackID
    }

    private func bounded(_ value: Float) -> Float { value.isFinite ? min(1, max(0, value)) : 0 }

    private func makeUniforms(frame: VisualFrame, dt: Float, burst: Float) -> Uniforms {
        Uniforms(minimum: SIMD4(Self.domainMinimum, 0),
                 extent: SIMD4(Self.domainMaximum - Self.domainMinimum, 0),
                 clock: SIMD4(simulationTime, dt, burst, bounded(frame.presence)),
                 levels: SIMD4(bounded(frame.rms), bounded(frame.bass), bounded(frame.mid), bounded(frame.treble)),
                 music: SIMD4(bounded(frame.vocal), bounded(frame.drums), bounded(frame.bassInstrument), bounded(frame.other)),
                 rhythm: SIMD4(bounded(frame.beatPhase), bounded(frame.barPhase), bounded(frame.bar),
                               frame.tempo.isFinite ? min(2, max(0.4, frame.tempo)) : 1),
                 structure: SIMD4(bounded(frame.pace), bounded(frame.phraseProgress), bounded(frame.segmentProgress), bounded(frame.sectionProgress)),
                 layout: SIMD4(bounded(frame.sectionSeparation), bounded(frame.sectionThickness), bounded(frame.sectionDepth), bounded(frame.sectionTransition)),
                 expression: SIMD4(bounded(frame.density), frame.modeBias.isFinite ? min(1, max(-1, frame.modeBias)) : 0,
                                   frame.hue.isFinite ? min(0.033, max(-0.033, frame.hue)) : 0, bounded(frame.hasAnalysis)),
                 motionA: motionState.weightsA, motionB: motionState.weightsB)
    }

    private func dispatch(_ command: MTLCommandBuffer, pipeline: MTLComputePipelineState,
                          textures: [MTLTexture], uniforms: inout Uniforms, spectrum: [Float]) throws {
        guard let encoder = command.makeComputeCommandEncoder() else {
            throw RenderFailure.message("3Dインクの流れを計算できません。")
        }
        encoder.label = pipeline.label ?? "3D ink advection / pressure projection"
        encoder.setComputePipelineState(pipeline)
        for (index, texture) in textures.enumerated() { encoder.setTexture(texture, index: index) }
        encoder.setBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
        spectrum.withUnsafeBytes { encoder.setBytes($0.baseAddress!, length: $0.count, index: 1) }
        encoder.dispatchThreads(MTLSize(width: resolution.x, height: resolution.y, depth: resolution.z),
                                threadsPerThreadgroup: MTLSize(width: 8, height: 4, depth: 4))
        encoder.endEncoding()
    }
}
