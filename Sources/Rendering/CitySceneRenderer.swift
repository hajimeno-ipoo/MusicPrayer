import MetalKit
import MetalPerformanceShaders
import simd

/// Owns a multipart city mesh, antialiased planar reflection and studio lighting.
final class CitySceneRenderer {
    private struct Uniforms {
        var viewProjection: simd_float4x4
        var lightViewProjection: simd_float4x4
        var eye: SIMD4<Float>
        var clockAudio: SIMD4<Float>
        var bandsBeat: SIMD4<Float>
        var instruments: SIMD4<Float>
        var rhythm: SIMD4<Float>
        var structure: SIMD4<Float>
        var layout: SIMD4<Float>
        var phasesPresence: SIMD4<Float>
        var colorViewport: SIMD4<Float>

        init(frame: VisualFrame, size: CGSize) {
            let aspect = Float(max(1, size.width) / max(1, size.height))
            let eye3 = SIMD3<Float>(-30, 21.4, 30.6)
            let target = SIMD3<Float>(0, 1.0, 0)
            let near: Float = 0.1, far: Float = 100
            let f: Float = 1 / tan(0.235 / 2)
            let projection = simd_float4x4(columns: (
                SIMD4(f / aspect, 0, 0, 0), SIMD4(0, f, 0, 0),
                SIMD4(0, -0.10, far / (near - far), -1), SIMD4(0, 0, near * far / (near - far), 0)))
            viewProjection = projection * Self.view(eye: eye3, target: target)
            let lightProjection = simd_float4x4(columns: (
                SIMD4(1 / 11, 0, 0, 0), SIMD4(0, 1 / 11, 0, 0),
                SIMD4(0, 0, 1 / (0.1 - 50), 0), SIMD4(0, 0, 0.1 / (0.1 - 50), 1)))
            lightViewProjection = lightProjection * Self.view(eye: SIMD3(-8, 14, -9), target: SIMD3(0, 1, 0))
            eye = SIMD4(eye3, 1)
            // Only the travelling gold light uses these live levels. A paused
            // track may retain analysed beats and FFT, but emits no gold light.
            clockAudio = SIMD4(frame.time, frame.isPlaying ? frame.rms : 0,
                               frame.isPlaying ? frame.peak : 0, frame.loudness)
            bandsBeat = SIMD4(frame.bass, frame.mid, frame.treble, frame.beat)
            instruments = SIMD4(frame.vocal, frame.drums, frame.bassInstrument, frame.other)
            rhythm = SIMD4(frame.tempo, frame.pace, frame.bar, frame.density)
            structure = SIMD4(frame.sectionProgress, frame.segmentProgress, frame.phraseProgress, frame.sectionTransition)
            layout = SIMD4(frame.sectionSeparation, frame.sectionThickness, frame.sectionDepth, frame.sectionGlow)
            phasesPresence = SIMD4(frame.beatPhase, frame.barPhase, frame.presence, frame.hasAnalysis)
            colorViewport = SIMD4(frame.hue, frame.modeBias, Float(size.width), Float(size.height))
        }

        private static func view(eye: SIMD3<Float>, target: SIMD3<Float>) -> simd_float4x4 {
            let z = simd_normalize(eye - target)
            let x = simd_normalize(simd_cross(SIMD3<Float>(0, 1, 0), z)), y = simd_cross(z, x)
            return simd_float4x4(columns: (
                SIMD4(x.x, y.x, z.x, 0), SIMD4(x.y, y.y, z.y, 0), SIMD4(x.z, y.z, z.z, 0),
                SIMD4(-simd_dot(x, eye), -simd_dot(y, eye), -simd_dot(z, eye), 1)))
        }
    }

    private let device: MTLDevice
    private let basePipeline: MTLRenderPipelineState
    private let buildingPipeline: MTLRenderPipelineState
    private let reflectionPipeline: MTLRenderPipelineState
    private let crystalPipeline: MTLRenderPipelineState
    private let crystalReflectionPipeline: MTLRenderPipelineState
    private let goldPipeline: MTLRenderPipelineState
    private let goldReflectionPipeline: MTLRenderPipelineState
    private let shadowPipeline: MTLRenderPipelineState
    private let brightPipeline: MTLRenderPipelineState
    private let compositePipeline: MTLRenderPipelineState
    private let depthState: MTLDepthStencilState
    private let lightDepthState: MTLDepthStencilState
    private let blur: MPSImageGaussianBlur
    private var reflectionBlur: MPSImageGaussianBlur
    private let environment: MTLTexture
    private let buildingVertices: MTLBuffer
    private let foundationVertices: MTLBuffer
    private let goldVertices: MTLBuffer
    private let goldRoute: MTLBuffer
    private let crystalOrder: MTLBuffer
    private let buildingVertexCount: Int
    private let foundationVertexCount: Int
    private let goldVertexCount: Int
    private let shadow: MTLTexture
    private var scene: MTLTexture?
    private var multisampleColor: MTLTexture?
    private var depth: MTLTexture?
    private var bright: MTLTexture?
    private var bloom: MTLTexture?
    private var reflectionMultisampleColor: MTLTexture?
    private var reflectionDepth: MTLTexture?
    private var reflection: MTLTexture?
    private var reflectionFiltered: MTLTexture?

    init(device: MTLDevice) throws {
        self.device = device
        guard let shaderURL = Bundle.module.url(forResource: "SpectrumCity", withExtension: "metal") else {
            throw RenderFailure.message("SpectrumCity.metalがアプリ内にありません。")
        }
        let library = try device.makeLibrary(source: String(contentsOf: shaderURL, encoding: .utf8), options: nil)
        func pipeline(_ vertex: String, _ fragment: String, format: MTLPixelFormat = .rgba16Float,
                      usesDepth: Bool = false, additive: Bool = false, transparent: Bool = false) throws -> MTLRenderPipelineState {
            guard let vertexFunction = library.makeFunction(name: vertex),
                  let fragmentFunction = library.makeFunction(name: fragment) else {
                throw RenderFailure.message("都市のMetal関数 \(vertex) / \(fragment) がありません。")
            }
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.label = fragment
            descriptor.rasterSampleCount = usesDepth ? 4 : 1
            descriptor.vertexFunction = vertexFunction
            descriptor.fragmentFunction = fragmentFunction
            descriptor.colorAttachments[0].pixelFormat = format
            if additive {
                descriptor.colorAttachments[0].isBlendingEnabled = true
                descriptor.colorAttachments[0].sourceRGBBlendFactor = .one
                descriptor.colorAttachments[0].destinationRGBBlendFactor = .one
                descriptor.colorAttachments[0].sourceAlphaBlendFactor = .zero
                descriptor.colorAttachments[0].destinationAlphaBlendFactor = .one
            }
            if transparent {
                descriptor.colorAttachments[0].isBlendingEnabled = true
                descriptor.colorAttachments[0].sourceRGBBlendFactor = .one
                descriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
                descriptor.colorAttachments[0].sourceAlphaBlendFactor = .one
                descriptor.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
            }
            if usesDepth { descriptor.depthAttachmentPixelFormat = .depth32Float }
            return try device.makeRenderPipelineState(descriptor: descriptor)
        }
        basePipeline = try pipeline("cityBaseVertex", "cityBaseFragment", usesDepth: true)
        buildingPipeline = try pipeline("cityBuildingVertex", "cityBuildingFragment", usesDepth: true)
        reflectionPipeline = try pipeline("cityReflectionVertex", "cityReflectionFragment", usesDepth: true)
        crystalPipeline = try pipeline("cityCrystalVertex", "cityCrystalFragment", usesDepth: true, transparent: true)
        crystalReflectionPipeline = try pipeline("cityCrystalReflectionVertex", "cityCrystalFragment", usesDepth: true, transparent: true)
        goldPipeline = try pipeline("cityGoldVertex", "cityGoldFragment", usesDepth: true, additive: true)
        goldReflectionPipeline = try pipeline("cityGoldReflectionVertex", "cityGoldFragment", usesDepth: true, additive: true)
        let shadowDescriptor = MTLRenderPipelineDescriptor()
        shadowDescriptor.label = "City geometry shadows"
        shadowDescriptor.vertexFunction = library.makeFunction(name: "cityShadowVertex")
        shadowDescriptor.depthAttachmentPixelFormat = .depth32Float
        shadowPipeline = try device.makeRenderPipelineState(descriptor: shadowDescriptor)
        brightPipeline = try pipeline("cityFullscreenVertex", "cityBrightFragment")
        compositePipeline = try pipeline("cityFullscreenVertex", "cityCompositeFragment", format: .bgra8Unorm_srgb)
        let descriptor = MTLDepthStencilDescriptor()
        descriptor.depthCompareFunction = .lessEqual
        descriptor.isDepthWriteEnabled = true
        guard let depthState = device.makeDepthStencilState(descriptor: descriptor) else {
            throw RenderFailure.message("都市のDepth stateを作成できません。")
        }
        self.depthState = depthState
        descriptor.isDepthWriteEnabled = false
        guard let lightDepthState = device.makeDepthStencilState(descriptor: descriptor) else {
            throw RenderFailure.message("都市の光束のDepth stateを作成できません。")
        }
        self.lightDepthState = lightDepthState
        blur = MPSImageGaussianBlur(device: device, sigma: 3.0)
        blur.edgeMode = .clamp
        reflectionBlur = MPSImageGaussianBlur(device: device, sigma: 1.6)
        reflectionBlur.edgeMode = .clamp
        guard let environmentURL = Bundle.module.url(forResource: "CityStudioEnvironment", withExtension: "png") else {
            throw RenderFailure.message("都市のスタジオ反射素材がアプリ内にありません。")
        }
        environment = try MTKTextureLoader(device: device).newTexture(URL: environmentURL,
            options: [.SRGB: true, .generateMipmaps: true, .origin: MTKTextureLoader.Origin.topLeft])
        let buildings = CityMesh.buildingVertices(), foundation = CityMesh.foundationVertices()
        let gold = CityMesh.goldLightVertices(), route = CityMesh.goldLightRoute()
        buildingVertexCount = buildings.count; foundationVertexCount = foundation.count
        goldVertexCount = gold.count
        guard let buildingsBuffer = device.makeBuffer(bytes: buildings, length: buildings.count * MemoryLayout<CityVertex>.stride),
              let foundationBuffer = device.makeBuffer(bytes: foundation, length: foundation.count * MemoryLayout<CityVertex>.stride),
              let goldBuffer = device.makeBuffer(bytes: gold, length: gold.count * MemoryLayout<CityVertex>.stride),
              let routeBuffer = device.makeBuffer(bytes: route, length: route.count * MemoryLayout<SIMD4<Float>>.stride) else {
            throw RenderFailure.message("都市の立体部品のbufferを作成できません。")
        }
        buildingVertices = buildingsBuffer; foundationVertices = foundationBuffer
        goldVertices = goldBuffer; goldRoute = routeBuffer
        let order = (0..<CityMesh.buildingCount).sorted {
            let a = CityMesh.gridCoordinate(for: $0), b = CityMesh.gridCoordinate(for: $1)
            let aDepth = Float(a.x) * 1.80 - Float(a.y) * 1.30
            let bDepth = Float(b.x) * 1.80 - Float(b.y) * 1.30
            return aDepth == bDepth ? $0 < $1 : aDepth > bDepth
        }.map(UInt32.init)
        guard let orderBuffer = device.makeBuffer(bytes: order, length: order.count * MemoryLayout<UInt32>.stride) else {
            throw RenderFailure.message("都市の透明な建物の描画順bufferを作成できません。")
        }
        crystalOrder = orderBuffer
        let shadowTexture = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .depth32Float, width: 1024,
                                                                     height: 1024, mipmapped: false)
        shadowTexture.storageMode = .private; shadowTexture.usage = [.renderTarget, .shaderRead]
        guard let shadow = device.makeTexture(descriptor: shadowTexture) else {
            throw RenderFailure.message("都市の影textureを作成できません。")
        }
        self.shadow = shadow
    }

    private func texture(width: Int, height: Int, format: MTLPixelFormat, label: String,
                         usage: MTLTextureUsage, samples: Int = 1) throws -> MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: width,
                                                                 height: height, mipmapped: false)
        descriptor.storageMode = .private
        if samples > 1 { descriptor.textureType = .type2DMultisample; descriptor.sampleCount = samples }
        descriptor.usage = usage
        guard let texture = device.makeTexture(descriptor: descriptor) else {
            throw RenderFailure.message("都市の\(label) textureを作成できません。")
        }
        texture.label = "Spectrum city \(label)"
        return texture
    }

    private func resize(width: Int, height: Int) throws {
        guard scene?.width != width || scene?.height != height else { return }
        let newScene = try texture(width: width, height: height, format: .rgba16Float, label: "HDR scene",
                                   usage: [.renderTarget, .shaderRead])
        let newMultisampleColor = try texture(width: width, height: height, format: .rgba16Float,
                                             label: "4x MSAA color", usage: .renderTarget, samples: 4)
        let newDepth = try texture(width: width, height: height, format: .depth32Float, label: "4x MSAA depth",
                                   usage: .renderTarget, samples: 4)
        let bloomWidth = max(1, width / 4), bloomHeight = max(1, height / 4)
        let newBright = try texture(width: bloomWidth, height: bloomHeight, format: .rgba16Float, label: "bright",
                                    usage: [.renderTarget, .shaderRead])
        let newBloom = try texture(width: bloomWidth, height: bloomHeight, format: .rgba16Float, label: "bloom",
                                   usage: [.shaderRead, .shaderWrite])
        let reflectionWidth = max(1, width / 2), reflectionHeight = max(1, height / 2)
        let newReflectionColor = try texture(width: reflectionWidth, height: reflectionHeight, format: .rgba16Float,
                                             label: "half size 4x MSAA mirror color", usage: .renderTarget, samples: 4)
        let newReflectionDepth = try texture(width: reflectionWidth, height: reflectionHeight, format: .depth32Float,
                                             label: "half size 4x MSAA mirror depth", usage: .renderTarget, samples: 4)
        let newReflection = try texture(width: reflectionWidth, height: reflectionHeight, format: .rgba16Float,
                                        label: "planar reflection", usage: [.renderTarget, .shaderRead])
        let newReflectionFiltered = try texture(width: reflectionWidth, height: reflectionHeight, format: .rgba16Float,
                                                label: "rough planar reflection", usage: [.shaderRead, .shaderWrite])
        scene = newScene; multisampleColor = newMultisampleColor; depth = newDepth; bright = newBright; bloom = newBloom
        reflection = newReflection; reflectionFiltered = newReflectionFiltered
        reflectionMultisampleColor = newReflectionColor; reflectionDepth = newReflectionDepth
        reflectionBlur = MPSImageGaussianBlur(device: device, sigma: max(0.3, Float(reflectionWidth) / 1920 * 1.6))
        reflectionBlur.edgeMode = .clamp
    }

    func encode(command: MTLCommandBuffer, descriptor: MTLRenderPassDescriptor, frame: VisualFrame, size: CGSize) throws {
        guard let target = descriptor.colorAttachments[0].texture else {
            throw RenderFailure.message("都市の表示先textureがありません。")
        }
        // The reference composition is 16:9. Fit it inside the existing player without stretching or cropping.
        let compositionWidth = max(1, min(target.width, Int(Double(target.height) * 16 / 9)))
        let compositionHeight = max(1, min(target.height, Int(Double(target.width) * 9 / 16)))
        try resize(width: compositionWidth, height: compositionHeight)
        guard let scene, let multisampleColor, let depth, let bright, let bloom, let reflection, let reflectionFiltered,
              let reflectionMultisampleColor, let reflectionDepth else {
            throw RenderFailure.message("都市の描画textureがありません。")
        }
        var uniforms = Uniforms(frame: frame, size: CGSize(width: compositionWidth, height: compositionHeight))
        // AudioFeatureAnalyzer supplies 0...1 for a fixed -80...0 dBFS range.
        let spectrum = CityMesh.displaySpectrum(frame.spectrum)
        func inputs(_ encoder: MTLRenderCommandEncoder) {
            encoder.setCullMode(.none)
            encoder.setDepthStencilState(depthState)
            encoder.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
            encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
            spectrum.withUnsafeBytes {
                encoder.setVertexBytes($0.baseAddress!, length: $0.count, index: 1)
                encoder.setFragmentBytes($0.baseAddress!, length: $0.count, index: 1)
            }
            encoder.setVertexBuffer(buildingVertices, offset: 0, index: 2)
            encoder.setVertexBuffer(goldRoute, offset: 0, index: 3)
            encoder.setVertexBuffer(crystalOrder, offset: 0, index: 4)
            encoder.setFragmentBuffer(goldRoute, offset: 0, index: 3)
            encoder.setFragmentTexture(environment, index: 2)
        }
        let shadowPass = MTLRenderPassDescriptor()
        shadowPass.depthAttachment.texture = shadow
        shadowPass.depthAttachment.loadAction = .clear; shadowPass.depthAttachment.storeAction = .store
        shadowPass.depthAttachment.clearDepth = 1
        guard let shadowEncoder = command.makeRenderCommandEncoder(descriptor: shadowPass) else {
            throw RenderFailure.message("都市の影encoderを作成できません。")
        }
        shadowEncoder.label = "Spectrum city geometry shadows"
        inputs(shadowEncoder)
        shadowEncoder.setRenderPipelineState(shadowPipeline)
        shadowEncoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: buildingVertexCount, instanceCount: CityMesh.buildingCount)
        shadowEncoder.endEncoding()

        let reflectionPass = MTLRenderPassDescriptor()
        reflectionPass.colorAttachments[0].texture = reflectionMultisampleColor
        reflectionPass.colorAttachments[0].resolveTexture = reflection
        reflectionPass.colorAttachments[0].loadAction = .clear; reflectionPass.colorAttachments[0].storeAction = .multisampleResolve
        reflectionPass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1)
        reflectionPass.depthAttachment.texture = reflectionDepth
        reflectionPass.depthAttachment.loadAction = .clear; reflectionPass.depthAttachment.storeAction = .dontCare
        reflectionPass.depthAttachment.clearDepth = 1
        guard let reflectionEncoder = command.makeRenderCommandEncoder(descriptor: reflectionPass) else {
            throw RenderFailure.message("都市の反射encoderを作成できません。")
        }
        reflectionEncoder.label = "Spectrum city half resolution 4x MSAA mirror"
        inputs(reflectionEncoder)
        var reflectedUniforms = uniforms
        reflectedUniforms.eye.y = -uniforms.eye.y
        reflectionEncoder.setFragmentBytes(&reflectedUniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
        reflectionEncoder.setRenderPipelineState(reflectionPipeline)
        reflectionEncoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: buildingVertexCount, instanceCount: CityMesh.buildingCount)
        reflectionEncoder.setCullMode(.front)
        reflectionEncoder.setRenderPipelineState(goldReflectionPipeline)
        reflectionEncoder.setVertexBuffer(goldVertices, offset: 0, index: 2)
        reflectionEncoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: goldVertexCount, instanceCount: 7)
        reflectionEncoder.setDepthStencilState(lightDepthState)
        reflectionEncoder.setVertexBuffer(buildingVertices, offset: 0, index: 2)
        reflectionEncoder.setCullMode(.none)
        reflectionEncoder.setRenderPipelineState(crystalReflectionPipeline)
        reflectionEncoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: buildingVertexCount, instanceCount: CityMesh.buildingCount)
        reflectionEncoder.setRenderPipelineState(goldReflectionPipeline)
        reflectionEncoder.setCullMode(.front)
        reflectionEncoder.setVertexBuffer(goldVertices, offset: 0, index: 2)
        reflectionEncoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: goldVertexCount, instanceCount: 7, baseInstance: 7)
        reflectionEncoder.endEncoding()
        reflectionBlur.encode(commandBuffer: command, sourceTexture: reflection, destinationTexture: reflectionFiltered)
        let scenePass = MTLRenderPassDescriptor()
        scenePass.colorAttachments[0].texture = multisampleColor
        scenePass.colorAttachments[0].resolveTexture = scene
        scenePass.colorAttachments[0].loadAction = .clear
        scenePass.colorAttachments[0].storeAction = .multisampleResolve
        scenePass.colorAttachments[0].clearColor = MTLClearColorMake(0.0005, 0.001, 0.003, 1)
        scenePass.depthAttachment.texture = depth
        scenePass.depthAttachment.loadAction = .clear
        scenePass.depthAttachment.storeAction = .dontCare
        scenePass.depthAttachment.clearDepth = 1
        guard let sceneEncoder = command.makeRenderCommandEncoder(descriptor: scenePass) else {
            throw RenderFailure.message("都市の描画encoderを作成できません。")
        }
        sceneEncoder.label = "Spectrum city multipart buildings and beveled foundation"
        inputs(sceneEncoder)
        sceneEncoder.setFragmentTexture(reflection, index: 0)
        sceneEncoder.setFragmentTexture(reflectionFiltered, index: 3)
        sceneEncoder.setFragmentTexture(shadow, index: 1)
        sceneEncoder.setRenderPipelineState(basePipeline)
        sceneEncoder.setVertexBuffer(foundationVertices, offset: 0, index: 2)
        sceneEncoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: foundationVertexCount)
        sceneEncoder.setRenderPipelineState(buildingPipeline)
        sceneEncoder.setVertexBuffer(buildingVertices, offset: 0, index: 2)
        sceneEncoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: buildingVertexCount, instanceCount: CityMesh.buildingCount)
        sceneEncoder.setCullMode(.back)
        sceneEncoder.setRenderPipelineState(goldPipeline)
        sceneEncoder.setVertexBuffer(goldVertices, offset: 0, index: 2)
        sceneEncoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: goldVertexCount, instanceCount: 7)
        sceneEncoder.setDepthStencilState(lightDepthState)
        sceneEncoder.setVertexBuffer(buildingVertices, offset: 0, index: 2)
        sceneEncoder.setCullMode(.none)
        sceneEncoder.setRenderPipelineState(crystalPipeline)
        sceneEncoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: buildingVertexCount, instanceCount: CityMesh.buildingCount)
        sceneEncoder.setRenderPipelineState(goldPipeline)
        sceneEncoder.setCullMode(.back)
        sceneEncoder.setVertexBuffer(goldVertices, offset: 0, index: 2)
        sceneEncoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: goldVertexCount, instanceCount: 7, baseInstance: 7)
        sceneEncoder.endEncoding()

        let brightPass = MTLRenderPassDescriptor()
        brightPass.colorAttachments[0].texture = bright
        brightPass.colorAttachments[0].loadAction = .dontCare
        brightPass.colorAttachments[0].storeAction = .store
        guard let brightEncoder = command.makeRenderCommandEncoder(descriptor: brightPass) else {
            throw RenderFailure.message("都市のBloom encoderを作成できません。")
        }
        brightEncoder.label = "Spectrum city quarter size bright extraction"
        brightEncoder.setRenderPipelineState(brightPipeline)
        brightEncoder.setFragmentTexture(scene, index: 0)
        brightEncoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        brightEncoder.endEncoding()
        blur.encode(commandBuffer: command, sourceTexture: bright, destinationTexture: bloom)

        descriptor.colorAttachments[0].loadAction = .clear
        descriptor.colorAttachments[0].clearColor = MTLClearColorMake(0.0005, 0.001, 0.003, 1)
        guard let compositeEncoder = command.makeRenderCommandEncoder(descriptor: descriptor) else {
            throw RenderFailure.message("都市の表示encoderを作成できません。")
        }
        compositeEncoder.label = "Spectrum city HDR and bloom composite"
        compositeEncoder.setViewport(MTLViewport(originX: Double(target.width - compositionWidth) / 2,
                                                 originY: Double(target.height - compositionHeight) / 2,
                                                 width: Double(compositionWidth), height: Double(compositionHeight),
                                                 znear: 0, zfar: 1))
        compositeEncoder.setRenderPipelineState(compositePipeline)
        compositeEncoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
        compositeEncoder.setFragmentTexture(scene, index: 0)
        compositeEncoder.setFragmentTexture(bloom, index: 1)
        compositeEncoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        compositeEncoder.endEncoding()
    }
}
