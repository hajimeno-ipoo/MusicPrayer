import Foundation
import MetalKit
import MetalPerformanceShaders
import simd

enum RenderFailure: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
}

/// Twelve float4 groups keep the Swift/Metal ABI explicit, including alignment.
private struct RenderUniforms {
    var clockAudio: SIMD4<Float>
    var bandsBeat: SIMD4<Float>
    var rhythmInstruments: SIMD4<Float>
    var instrumentsStructure: SIMD4<Float>
    var structureColor: SIMD4<Float>
    var lightState: SIMD4<Float>
    var viewport: SIMD4<Float>
    var tempoPhase: SIMD4<Float>
    var sceneLayout: SIMD4<Float>
    var sceneWater: SIMD4<Float>
    var cameraEye: SIMD4<Float>
    var cameraTarget: SIMD4<Float>
    init(frame: VisualFrame, size: CGSize) {
        clockAudio = SIMD4(frame.time, frame.rms, frame.peak, frame.bass)
        bandsBeat = SIMD4(frame.mid, frame.treble, frame.beat, frame.bar)
        rhythmInstruments = SIMD4(frame.pace, frame.vocal, frame.drums, frame.bassInstrument)
        instrumentsStructure = SIMD4(frame.other, frame.sectionProgress, frame.segmentProgress, frame.phraseProgress)
        structureColor = SIMD4(frame.sectionTransition, frame.hue, frame.modeBias, frame.loudness)
        lightState = SIMD4(frame.density, frame.hasAnalysis, frame.presence, 0)
        viewport = SIMD4(Float(size.width / max(1, size.height)), Float(size.width), Float(size.height), frame.camera.horizon)
        tempoPhase = SIMD4(frame.tempo, frame.beatPhase, frame.barPhase, 0)
        sceneLayout = SIMD4(frame.sectionSeparation, frame.sectionThickness, frame.sectionDepth, frame.sectionGlow)
        sceneWater = SIMD4(frame.sectionWater, 0, 0, 0)
        cameraEye = SIMD4(frame.camera.eye.x, frame.camera.eye.y, frame.camera.eye.z, 0)
        cameraTarget = SIMD4(frame.camera.target.x, frame.camera.target.y, frame.camera.target.z, 0)
    }

    var groups: [SIMD4<Float>] {
        [clockAudio, bandsBeat, rhythmInstruments, instrumentsStructure, structureColor, lightState,
         viewport, tempoPhase, sceneLayout, sceneWater, cameraEye, cameraTarget]
    }
}

/// Compare with the last presented inputs, so small changes still accumulate.
/// The tolerance only suppresses the subvisible tail of exponential smoothing.
struct RenderInputs {
    private let frame: VisualFrame
    private let size: CGSize
    private let groups: [SIMD4<Float>]

    init(frame: VisualFrame, size: CGSize) {
        self.frame = frame
        self.size = size
        groups = RenderUniforms(frame: frame, size: size).groups
    }

    func matches(_ other: RenderInputs) -> Bool {
        guard size == other.size, frame.time == other.frame.time,
              frame.trackID == other.frame.trackID, frame.visualizerStyle == other.frame.visualizerStyle,
              frame.spectrum.count == other.frame.spectrum.count else { return false }
        let tolerance: Float = 0.00001
        return zip(groups, other.groups).allSatisfy { a, b in
            (0..<4).allSatisfy { abs(a[$0] - b[$0]) <= tolerance }
        } && zip(frame.spectrum, other.frame.spectrum).allSatisfy { abs($0 - $1) <= tolerance }
    }
}

/// GPU completion runs off the render thread. Pending frames must finish before
/// deciding that a static view needs another water frame.
final class WaterRenderActivity {
    enum State { case pending, active, idle }
    private let lock = NSLock()
    private var pending = 0
    private var completedFrame = -1
    private var active = true

    var state: State {
        lock.lock(); defer { lock.unlock() }
        return pending > 0 ? .pending : (active ? .active : .idle)
    }

    func submitted() {
        lock.lock(); defer { lock.unlock() }
        pending += 1
    }

    func completed(frame: Int, maximumHeight: Float) {
        lock.lock(); defer { lock.unlock() }
        pending -= 1
        if frame > completedFrame {
            completedFrame = frame
            active = !maximumHeight.isFinite || maximumHeight > 0.00001
        }
    }
}

final class MetalRenderer: NSObject, MTKViewDelegate {
    var onError: ((String) -> Void)?
    private let device: MTLDevice
    private let source: VisualFrameSource
    private let queue: MTLCommandQueue
    private let ribbonPipeline: MTLRenderPipelineState
    private let resolvePipeline: MTLRenderPipelineState
    private let brightPipeline: MTLRenderPipelineState
    private let compositePipeline: MTLRenderPipelineState
    private let depthState: MTLDepthStencilState
    private let blur: MPSImageGaussianBlur
    private let water: WaterSurface
    private let lightSwarm: LightSwarm
    private let inkFluid: InkFluid
    private let inkRenderer: InkRenderer
    private var previousRenderTime: Double?
    private let indexBuffer: MTLBuffer
    private let indexCount: Int
    private let uniforms: [MTLBuffer]
    private let spectra: [MTLBuffer]
    private let waterActivityBuffers: [MTLBuffer]
    private let waterActivity = WaterRenderActivity()
    private var lastRenderedInputs: RenderInputs?
    private let slots = (0..<3).map { _ in DispatchSemaphore(value: 1) }
    private(set) var submittedFrameCount = 0
    private var scene: MTLTexture?
    private var inkScene: MTLTexture?
    private var ribbonColors: MTLTexture?
    private var ribbonDepths: MTLTexture?
    private var bright: MTLTexture?
    private var bloom: MTLTexture?
    private var textureSize = CGSize.zero
    private var hasReportedError = false

    init(device: MTLDevice, source: VisualFrameSource) throws {
        self.device = device; self.source = source
        guard let queue = device.makeCommandQueue() else { throw RenderFailure.message("Metal command queueを作成できません。") }
        self.queue = queue
        water = try WaterSurface(device: device)
        lightSwarm = try LightSwarm(device: device)
        inkFluid = try InkFluid(device: device)
        inkRenderer = try InkRenderer(device: device)
        guard let shaderURL = Bundle.module.url(forResource: "Shaders", withExtension: "metal") else {
            throw RenderFailure.message("Shaders.metalがアプリ内にありません。")
        }
        let library = try device.makeLibrary(source: String(contentsOf: shaderURL, encoding: .utf8), options: nil)
        func pipeline(vertex: String, fragment: String, format: MTLPixelFormat, ribbons: Bool = false) throws -> MTLRenderPipelineState {
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.label = fragment
            guard let vertexFunction = library.makeFunction(name: vertex), let fragmentFunction = library.makeFunction(name: fragment) else {
                throw RenderFailure.message("Metal関数 \(vertex) / \(fragment) がありません。")
            }
            descriptor.vertexFunction = vertexFunction
            descriptor.fragmentFunction = fragmentFunction
            let attachment = descriptor.colorAttachments[0]!
            attachment.pixelFormat = format
            if ribbons {
                descriptor.depthAttachmentPixelFormat = .depth32Float
            }
            return try device.makeRenderPipelineState(descriptor: descriptor)
        }
        ribbonPipeline = try pipeline(vertex: "ribbonVertex", fragment: "ribbonFragment", format: .rgba16Float, ribbons: true)
        resolvePipeline = try pipeline(vertex: "fullscreenVertex", fragment: "resolveRibbonsFragment", format: .rgba16Float)
        brightPipeline = try pipeline(vertex: "fullscreenVertex", fragment: "brightFragment", format: .rgba16Float)
        compositePipeline = try pipeline(vertex: "fullscreenVertex", fragment: "compositeFragment", format: .bgra8Unorm_srgb)
        let depthDescriptor = MTLDepthStencilDescriptor()
        depthDescriptor.depthCompareFunction = .lessEqual
        // Each cloth has its own depth layer. Cross-cloth transparency is resolved per pixel afterward.
        depthDescriptor.isDepthWriteEnabled = true
        guard let depthState = device.makeDepthStencilState(descriptor: depthDescriptor) else { throw RenderFailure.message("Depth stateを作成できません。") }
        self.depthState = depthState
        blur = MPSImageGaussianBlur(device: device, sigma: 9)
        blur.edgeMode = .clamp
        let columns = 384, rows = 32
        var indices: [UInt32] = []
        indices.reserveCapacity((columns - 1) * (rows - 1) * 6)
        for row in 0..<(rows - 1) {
            for column in 0..<(columns - 1) {
                let a = UInt32(row * columns + column), b = a + UInt32(columns)
                indices.append(contentsOf: [a, b, a + 1, a + 1, b, b + 1])
            }
        }
        guard let indexBuffer = indices.withUnsafeBytes({ device.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: .storageModeShared) }) else {
            throw RenderFailure.message("Ribbon index bufferを作成できません。")
        }
        self.indexBuffer = indexBuffer; indexCount = indices.count
        var uniforms: [MTLBuffer] = [], spectra: [MTLBuffer] = [], waterActivityBuffers: [MTLBuffer] = []
        for _ in 0..<3 {
            guard let uniform = device.makeBuffer(length: MemoryLayout<RenderUniforms>.stride, options: .storageModeShared),
                  let spectrum = device.makeBuffer(length: 64 * MemoryLayout<Float>.stride, options: .storageModeShared),
                  let waterActivity = device.makeBuffer(length: WaterSurface.activitySampleCount * MemoryLayout<Float>.stride,
                                                        options: .storageModeShared) else {
                throw RenderFailure.message("フレーム用Metal bufferを作成できません。")
            }
            uniforms.append(uniform); spectra.append(spectrum); waterActivityBuffers.append(waterActivity)
        }
        self.uniforms = uniforms; self.spectra = spectra
        self.waterActivityBuffers = waterActivityBuffers
        super.init()
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        lastRenderedInputs = nil
        previousRenderTime = nil
        if !hasReportedError { view.isPaused = false }
    }

    func resumeIfNeeded(in view: MTKView) {
        guard view.isPaused, !hasReportedError else { return }
        let inputs = RenderInputs(frame: source.snapshot(), size: view.drawableSize)
        if (lastRenderedInputs.map({ !inputs.matches($0) }) ?? true) || source.waterInteractions.hasPendingPulses {
            previousRenderTime = nil
            view.isPaused = false
        }
    }

    private func makeTexture(width: Int, height: Int, format: MTLPixelFormat, label: String, layers: Int = 1) throws -> MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: width, height: height, mipmapped: false)
        descriptor.storageMode = .private
        descriptor.usage = format == .depth32Float ? [.renderTarget, .shaderRead] : [.renderTarget, .shaderRead, .shaderWrite]
        if layers > 1 {
            descriptor.textureType = .type2DArray
            descriptor.arrayLength = layers
        }
        guard let texture = device.makeTexture(descriptor: descriptor) else { throw RenderFailure.message("\(label) textureを作成できません。") }
        texture.label = label
        return texture
    }

    private func resize(_ size: CGSize) throws {
        guard size != textureSize else { return }
        let width = max(1, Int(size.width)), height = max(1, Int(size.height))
        scene = try makeTexture(width: width, height: height, format: .rgba16Float, label: "HDR ribbons")
        inkScene = try makeTexture(width: max(1, width / 2), height: max(1, height / 2), format: .rgba16Float, label: "HDR volumetric ink")
        ribbonColors = try makeTexture(width: width, height: height, format: .rgba16Float, label: "Four ribbon color layers", layers: 4)
        ribbonDepths = try makeTexture(width: width, height: height, format: .depth32Float, label: "Four ribbon depth layers", layers: 4)
        bright = try makeTexture(width: max(1, width / 2), height: max(1, height / 2), format: .rgba16Float, label: "Bright extraction")
        bloom = try makeTexture(width: max(1, width / 2), height: max(1, height / 2), format: .rgba16Float, label: "Gaussian bloom")
        textureSize = size
    }

    private func report(_ error: Error) {
        guard !hasReportedError else { return }
        hasReportedError = true
        NSLog("MetalRenderer: %@", error.localizedDescription)
        onError?(error.localizedDescription)
    }

    func draw(in view: MTKView) {
        guard !hasReportedError, view.drawableSize.width > 0, view.drawableSize.height > 0 else { return }
        let snapshot = source.snapshot()
        let inputs = RenderInputs(frame: snapshot, size: view.drawableSize)
        if let previous = lastRenderedInputs, inputs.matches(previous), !source.waterInteractions.hasPendingPulses {
            switch waterActivity.state {
            case .idle:
                // No drawable acquisition, simulation, ray marching, bloom, or GPU submission.
                previousRenderTime = nil
                view.isPaused = true
                return
            case .pending:
                // Preserve elapsed time while the existing wave calculation finishes.
                return
            case .active:
                break
            }
        }
        // Never overwrite a slot until its GPU command has completed.
        let slot = submittedFrameCount % 3
        let semaphore = slots[slot]
        guard semaphore.wait(timeout: .now()) == .success else { return }
        var committed = false
        defer { if !committed { semaphore.signal() } }
        do { try resize(view.drawableSize) } catch { report(error); return }
        guard let scene, let inkScene, let ribbonColors, let ribbonDepths, let bright, let bloom,
              let command = queue.makeCommandBuffer() else { report(RenderFailure.message("Metalフレームを準備できません。")); return }
        // Do not advance persistent simulations unless this command will be presented.
        guard let drawable = view.currentDrawable, let finalPass = view.currentRenderPassDescriptor else { return }
        let renderTime = ProcessInfo.processInfo.systemUptime
        let elapsed = previousRenderTime.map { max(0, renderTime - $0) } ?? (1.0 / 60)
        previousRenderTime = renderTime
        let aspect = Float(view.drawableSize.width / view.drawableSize.height)
        var waterFrame = snapshot
        if snapshot.visualizerStyle == .ink { waterFrame.camera.horizon = InkRenderer.waterHorizon(aspect: aspect) }
        source.waterInteractions.horizon = waterFrame.camera.horizon
        do {
            try water.encode(command: command, elapsed: elapsed, pulses: source.waterInteractions.drain(), frame: waterFrame, aspect: aspect)
            try water.encodeActivityCheck(command: command, result: waterActivityBuffers[slot])
            if snapshot.visualizerStyle == .ink {
                try inkFluid.encode(command: command, frame: snapshot, elapsed: elapsed)
            } else {
                try lightSwarm.encodeUpdate(command: command, frame: snapshot, deltaTime: Float(elapsed),
                                            aspect: aspect, cameraEye: snapshot.camera.eye, cameraTarget: snapshot.camera.target)
            }
        } catch { report(error); return }
        var uniform = RenderUniforms(frame: snapshot, size: view.drawableSize)
        withUnsafeBytes(of: &uniform) { uniforms[slot].contents().copyMemory(from: $0.baseAddress!, byteCount: $0.count) }
        let spectrumPointer = spectra[slot].contents().assumingMemoryBound(to: Float.self)
        for index in 0..<64 { spectrumPointer[index] = index < snapshot.spectrum.count ? snapshot.spectrum[index] : 0 }
        let activeScene = snapshot.visualizerStyle == .ink ? inkScene : scene
        if snapshot.visualizerStyle == .ink {
            command.label = "3D ink fluid · Volume lighting · Reflection · Bloom"
            do { try inkRenderer.encode(command: command, target: inkScene, density: inkFluid.densityTexture,
                                        frame: snapshot, water: water.texture, aspect: aspect) }
            catch { report(error); return }
        } else {
            command.label = "Ribbon layers · Depth resolve · Bloom · Water"
            for ribbon in 0..<4 {
                let layerPass = MTLRenderPassDescriptor()
                layerPass.colorAttachments[0].texture = ribbonColors
                layerPass.colorAttachments[0].slice = ribbon
                layerPass.colorAttachments[0].loadAction = .clear
                layerPass.colorAttachments[0].storeAction = .store
                layerPass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0)
                layerPass.depthAttachment.texture = ribbonDepths
                layerPass.depthAttachment.slice = ribbon
                layerPass.depthAttachment.loadAction = .clear
                layerPass.depthAttachment.storeAction = .store
                layerPass.depthAttachment.clearDepth = 1
                guard let ribbonEncoder = command.makeRenderCommandEncoder(descriptor: layerPass) else { report(RenderFailure.message("Ribbon encoderを作成できません。")); return }
                ribbonEncoder.label = "Cloth layer \(ribbon)"
                ribbonEncoder.setRenderPipelineState(ribbonPipeline)
                ribbonEncoder.setDepthStencilState(depthState)
                ribbonEncoder.setCullMode(.none)
                ribbonEncoder.setVertexBuffer(uniforms[slot], offset: 0, index: 0)
                ribbonEncoder.setVertexBuffer(spectra[slot], offset: 0, index: 1)
                ribbonEncoder.setFragmentBuffer(uniforms[slot], offset: 0, index: 0)
                ribbonEncoder.drawIndexedPrimitives(type: .triangle, indexCount: indexCount, indexType: .uint32, indexBuffer: indexBuffer, indexBufferOffset: 0, instanceCount: 1, baseVertex: 0, baseInstance: ribbon)
                ribbonEncoder.endEncoding()
            }
            let scenePass = MTLRenderPassDescriptor()
            scenePass.colorAttachments[0].texture = scene
            scenePass.colorAttachments[0].loadAction = .dontCare
            scenePass.colorAttachments[0].storeAction = .store
            guard let resolveEncoder = command.makeRenderCommandEncoder(descriptor: scenePass) else { report(RenderFailure.message("Ribbon depth resolve encoderを作成できません。")); return }
            resolveEncoder.label = "Per-pixel depth-sorted transparent ribbons"
            resolveEncoder.setRenderPipelineState(resolvePipeline)
            resolveEncoder.setFragmentTexture(ribbonColors, index: 0)
            resolveEncoder.setFragmentTexture(ribbonDepths, index: 1)
            resolveEncoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            resolveEncoder.endEncoding()
            do { try lightSwarm.encodeRender(command: command, target: scene, ribbonDepths: ribbonDepths) }
            catch { report(error); return }
        }

        let brightPass = MTLRenderPassDescriptor()
        brightPass.colorAttachments[0].texture = bright
        brightPass.colorAttachments[0].loadAction = .dontCare
        brightPass.colorAttachments[0].storeAction = .store
        guard let brightEncoder = command.makeRenderCommandEncoder(descriptor: brightPass) else { report(RenderFailure.message("Bloom encoderを作成できません。")); return }
        brightEncoder.setRenderPipelineState(brightPipeline)
        brightEncoder.setFragmentTexture(activeScene, index: 0)
        brightEncoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        brightEncoder.endEncoding()
        blur.encode(commandBuffer: command, sourceTexture: bright, destinationTexture: bloom)

        if snapshot.visualizerStyle == .ink {
            do { try inkRenderer.encodeComposite(command: command, pass: finalPass, scene: inkScene, bloom: bloom) }
            catch { report(error); return }
        } else {
            guard let compositeEncoder = command.makeRenderCommandEncoder(descriptor: finalPass) else { report(RenderFailure.message("Composite encoderを作成できません。")); return }
            compositeEncoder.setRenderPipelineState(compositePipeline)
            compositeEncoder.setFragmentTexture(scene, index: 0)
            compositeEncoder.setFragmentTexture(bloom, index: 1)
            compositeEncoder.setFragmentTexture(water.texture, index: 2)
            compositeEncoder.setFragmentBuffer(uniforms[slot], offset: 0, index: 0)
            compositeEncoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            compositeEncoder.endEncoding()
        }
        command.present(drawable)
        let activity = waterActivity
        let activityBuffer = waterActivityBuffers[slot]
        let submittedFrame = submittedFrameCount
        activity.submitted()
        command.addCompletedHandler { [weak self] completed in
            let samples = UnsafeBufferPointer(start: activityBuffer.contents().assumingMemoryBound(to: Float.self),
                                              count: WaterSurface.activitySampleCount)
            activity.completed(frame: submittedFrame, maximumHeight: samples.max() ?? .infinity)
            semaphore.signal()
            if let error = completed.error { DispatchQueue.main.async { self?.report(error) } }
        }
        lastRenderedInputs = inputs
        submittedFrameCount += 1
        committed = true
        command.commit()
    }
}
