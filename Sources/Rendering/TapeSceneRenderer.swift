import AppKit
import MetalKit
import simd

/// Owns only the cassette scene. The existing frame composer supplies all musical signals.
final class TapeSceneRenderer {
    private struct Uniforms {
        var viewProjection: simd_float4x4
        var eye: SIMD4<Float>
        var clockAudio: SIMD4<Float>
        var bandsBeat: SIMD4<Float>
        var rhythm: SIMD4<Float>
        var instruments: SIMD4<Float>
        var structure: SIMD4<Float>
        var layout: SIMD4<Float>
        var viewportProgress: SIMD4<Float>
        var phasesPresence: SIMD4<Float>
        init(frame: VisualFrame, size: CGSize) {
            let breathing = sin(frame.phraseProgress * .pi * 2)
            let barBreathing = (1 - cos(frame.barPhase * .pi * 2)) * 0.008
            let distance: Float = 1 - frame.vocal * 0.055 + frame.sectionDepth * 0.05 + breathing * 0.012 + barBreathing
            let sway = sin(frame.time * 0.035 * frame.tempo) * 0.10
            let eye3 = SIMD3<Float>((4.5 + sway) * distance, 7.3 * distance,
                                   (8.0 + frame.sectionProgress * 0.12 + frame.bar * 0.04) * distance)
            eye = SIMD4(eye3, 1)
            let target = SIMD3<Float>(0, 0.1, -0.05)
            let z = simd_normalize(eye3 - target)
            let x = simd_normalize(simd_cross(SIMD3<Float>(0, 1, 0), z))
            let y = simd_cross(z, x)
            let view = simd_float4x4(columns: (SIMD4(x.x, y.x, z.x, 0), SIMD4(x.y, y.y, z.y, 0),
                                             SIMD4(x.z, y.z, z.z, 0), SIMD4(-simd_dot(x, eye3), -simd_dot(y, eye3), -simd_dot(z, eye3), 1)))
            let aspect = Float(size.width / max(1, size.height)), near: Float = 0.1, far: Float = 80
            let f: Float = 1 / tan(0.66 / 2)
            let projection = simd_float4x4(columns: (SIMD4(f / aspect, 0, 0, 0), SIMD4(0, f, 0, 0),
                                                   SIMD4(0, 0, far / (near - far), -1), SIMD4(0, 0, near * far / (near - far), 0)))
            viewProjection = projection * view
            clockAudio = SIMD4(frame.time, frame.rms, frame.peak, frame.bass)
            bandsBeat = SIMD4(frame.mid, frame.treble, frame.beat, frame.bar)
            rhythm = SIMD4(frame.tempo, frame.pace, frame.vocal, frame.drums)
            instruments = SIMD4(frame.bassInstrument, frame.other, frame.loudness, frame.density)
            structure = SIMD4(frame.sectionProgress, frame.segmentProgress, frame.phraseProgress, frame.sectionTransition)
            layout = SIMD4(frame.sectionSeparation, frame.sectionThickness, frame.sectionDepth, frame.sectionGlow)
            viewportProgress = SIMD4(Float(size.width), Float(size.height),
                                     frame.duration > 0 ? min(1, frame.time / Float(frame.duration)) : 0,
                                     frame.hasAnalysis > 0 ? frame.hue + frame.modeBias * 0.035 : 0.48)
            phasesPresence = SIMD4(frame.beatPhase, frame.barPhase, frame.presence, frame.hasAnalysis)
        }
    }
    private let device: MTLDevice
    private let meshPipeline: MTLRenderPipelineState
    private let floorPipeline: MTLRenderPipelineState
    private let spectrumPipeline: MTLRenderPipelineState
    private let timePipeline: MTLRenderPipelineState
    private let presentationPipeline: MTLRenderPipelineState
    private let depthState: MTLDepthStencilState
    private let vertices: MTLBuffer
    private let vertexCount: Int
    private var depth: MTLTexture?
    private var artworkTexture: MTLTexture
    private var titleTexture: MTLTexture
    private var lowerTexture: MTLTexture
    private var timeTexture: MTLTexture
    private var trackID: UUID?
    private var trackTitle = ""
    private var trackArtist = ""
    private var trackArtwork: Data?
    private var elapsedSecond = -1
    private var durationSecond = -1
    private var currentUniforms: Uniforms?

    init(device: MTLDevice) throws {
        self.device = device
        guard let shaderURL = Bundle.module.url(forResource: "TapeScene", withExtension: "metal") else {
            throw RenderFailure.message("TapeScene.metalがアプリ内にありません。")
        }
        let library = try device.makeLibrary(source: String(contentsOf: shaderURL, encoding: .utf8), options: nil)
        func pipeline(_ vertex: String, _ fragment: String, format: MTLPixelFormat = .rgba16Float,
                      usesDepth: Bool = true, blend: Bool = false) throws -> MTLRenderPipelineState {
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.label = fragment
            descriptor.vertexFunction = library.makeFunction(name: vertex)
            descriptor.fragmentFunction = library.makeFunction(name: fragment)
            descriptor.colorAttachments[0].pixelFormat = format
            if usesDepth { descriptor.depthAttachmentPixelFormat = .depth32Float }
            if blend {
                let attachment = descriptor.colorAttachments[0]!
                attachment.isBlendingEnabled = true
                attachment.sourceRGBBlendFactor = .sourceAlpha
                attachment.destinationRGBBlendFactor = .oneMinusSourceAlpha
                attachment.sourceAlphaBlendFactor = .one
                attachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha
            }
            return try device.makeRenderPipelineState(descriptor: descriptor)
        }
        meshPipeline = try pipeline("tapeMeshVertex", "tapeMeshFragment", blend: true)
        floorPipeline = try pipeline("tapeFloorVertex", "tapeFloorFragment")
        spectrumPipeline = try pipeline("tapeSpectrumVertex", "tapeSpectrumFragment", blend: true)
        timePipeline = try pipeline("tapeTimeVertex", "tapeTimeFragment", blend: true)
        presentationPipeline = try pipeline("tapeFullscreenVertex", "tapeCompositeFragment", format: .bgra8Unorm_srgb, usesDepth: false)
        let descriptor = MTLDepthStencilDescriptor()
        descriptor.depthCompareFunction = .lessEqual
        descriptor.isDepthWriteEnabled = true
        guard let state = device.makeDepthStencilState(descriptor: descriptor) else {
            throw RenderFailure.message("カセットのDepth stateを作成できません。")
        }
        depthState = state
        let mesh = TapeMesh.makeVertices()
        guard let buffer = mesh.withUnsafeBytes({ device.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: .storageModeShared) }) else {
            throw RenderFailure.message("カセットの頂点bufferを作成できません。")
        }
        vertices = buffer; vertexCount = mesh.count
        artworkTexture = try Self.texture(device: device, width: 1024, height: 640) { context in
            Self.drawDefaultArtwork(context, width: 1024, height: 640)
        }
        titleTexture = try Self.label(device: device, title: "MUSIC PRAYER", artist: "AUDIO VISUALIZER")
        lowerTexture = try Self.label(device: device, title: "STEREO  •  SIDE A", artist: "")
        timeTexture = try Self.times(device: device, elapsed: 0, remaining: 0)
    }

    private static func texture(device: MTLDevice, width: Int, height: Int,
                                drawing: (CGContext) -> Void) throws -> MTLTexture {
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        try pixels.withUnsafeMutableBytes { bytes in
            guard let context = CGContext(data: bytes.baseAddress, width: width, height: height,
                                          bitsPerComponent: 8, bytesPerRow: width * 4,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
                throw RenderFailure.message("カセットのラベル画像を作成できません。")
            }
            drawing(context)
        }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm_srgb,
                                                                  width: width, height: height, mipmapped: false)
        descriptor.usage = .shaderRead
        guard let texture = device.makeTexture(descriptor: descriptor) else {
            throw RenderFailure.message("カセットのラベルtextureを作成できません。")
        }
        pixels.withUnsafeBytes { texture.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0,
                                                 withBytes: $0.baseAddress!, bytesPerRow: width * 4) }
        return texture
    }

    private static func drawDefaultArtwork(_ context: CGContext, width: Int, height: Int) {
        let colors = [NSColor(calibratedRed: 0.05, green: 0.20, blue: 0.29, alpha: 1).cgColor,
                      NSColor(calibratedRed: 0.04, green: 0.65, blue: 0.69, alpha: 1).cgColor,
                      NSColor(calibratedRed: 0.40, green: 0.10, blue: 0.32, alpha: 1).cgColor]
        if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors as CFArray, locations: [0, 0.6, 1]) {
            context.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: width, y: height), options: [])
        }
        context.setLineWidth(3)
        for index in 0..<24 {
            context.setStrokeColor(NSColor(white: 1, alpha: 0.035 + CGFloat(index % 3) * 0.018).cgColor)
            context.strokeEllipse(in: CGRect(x: -180 + index * 34, y: -130 + index * 12, width: 820, height: 500))
        }
    }

    private static func drawText(_ text: String, context: CGContext, rect: CGRect,
                                 font: NSFont, color: NSColor, centered: Bool = false) {
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        paragraph.alignment = centered ? .center : .left
        (text as NSString).draw(in: rect, withAttributes: [.font: font, .foregroundColor: color,
                                                         .paragraphStyle: paragraph])
        NSGraphicsContext.restoreGraphicsState()
    }

    private static func label(device: MTLDevice, title: String, artist: String) throws -> MTLTexture {
        try texture(device: device, width: 1536, height: 256) { context in
            context.setFillColor(NSColor(calibratedRed: 0.84, green: 0.93, blue: 0.94, alpha: 1).cgColor)
            context.fill(CGRect(x: 0, y: 0, width: 1536, height: 256))
            drawText(title, context: context, rect: CGRect(x: 60, y: artist.isEmpty ? 65 : 132, width: 1416, height: 90),
                     font: .systemFont(ofSize: 64, weight: .semibold), color: NSColor(calibratedRed: 0.10, green: 0.23, blue: 0.25, alpha: 1), centered: true)
            if !artist.isEmpty {
                drawText(artist, context: context, rect: CGRect(x: 60, y: 38, width: 1416, height: 66),
                         font: .systemFont(ofSize: 40, weight: .regular), color: NSColor(calibratedRed: 0.24, green: 0.40, blue: 0.42, alpha: 1), centered: true)
            }
        }
    }

    private static func times(device: MTLDevice, elapsed: Int, remaining: Int) throws -> MTLTexture {
        func clock(_ seconds: Int) -> String {
            let seconds = max(0, seconds)
            return String(format: "%02d:%02d:%02d", seconds / 3600, (seconds / 60) % 60, seconds % 60)
        }
        return try texture(device: device, width: 1024, height: 512) { context in
            for (index, pair) in [("ELAPSED", clock(elapsed)), ("REMAINING", clock(remaining))].enumerated() {
                let origin = CGFloat(index * 256)
                drawText(pair.0, context: context, rect: CGRect(x: 10, y: origin + 158, width: 1004, height: 65),
                         font: .systemFont(ofSize: 33, weight: .semibold), color: NSColor(white: 0.83, alpha: 1), centered: true)
                drawText(pair.1, context: context, rect: CGRect(x: 10, y: origin + 20, width: 1004, height: 135),
                         font: .monospacedDigitSystemFont(ofSize: 117, weight: .bold), color: NSColor(white: 0.87, alpha: 1), centered: true)
            }
        }
    }

    private func updateLabels(_ frame: VisualFrame) throws {
        if trackID != frame.trackID || trackTitle != frame.title || trackArtist != frame.artist || trackArtwork != frame.artwork {
            trackID = frame.trackID; trackTitle = frame.title; trackArtist = frame.artist; trackArtwork = frame.artwork
            titleTexture = try Self.label(device: device, title: frame.title.isEmpty ? "MUSIC PRAYER" : frame.title,
                                          artist: frame.artist.isEmpty ? "AUDIO VISUALIZER" : frame.artist)
            artworkTexture = try Self.texture(device: device, width: 1024, height: 640) { context in
                if let data = frame.artwork, let image = NSImage(data: data),
                   let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                    let factor = max(1024 / CGFloat(cg.width), 640 / CGFloat(cg.height))
                    let w = CGFloat(cg.width) * factor, h = CGFloat(cg.height) * factor
                    context.draw(cg, in: CGRect(x: (1024 - w) / 2, y: (640 - h) / 2, width: w, height: h))
                } else { Self.drawDefaultArtwork(context, width: 1024, height: 640) }
            }
        }
        let elapsed = Int(max(0, frame.time)), duration = Int(max(0, frame.duration))
        if elapsed != elapsedSecond || duration != durationSecond {
            elapsedSecond = elapsed; durationSecond = duration
            timeTexture = try Self.times(device: device, elapsed: elapsed, remaining: max(0, duration - elapsed))
        }
    }

    func encode(command: MTLCommandBuffer, target: MTLTexture, frame: VisualFrame, size: CGSize) throws {
        try updateLabels(frame)
        if depth?.width != target.width || depth?.height != target.height {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .depth32Float, width: target.width, height: target.height, mipmapped: false)
            descriptor.storageMode = .private; descriptor.usage = [.renderTarget, .shaderRead]
            depth = device.makeTexture(descriptor: descriptor)
        }
        guard let depth else { throw RenderFailure.message("カセットの深度textureを作成できません。") }
        var uniforms = Uniforms(frame: frame, size: size)
        currentUniforms = uniforms
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear; pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColorMake(0.24, 0.27, 0.32, 1)
        pass.depthAttachment.texture = depth
        pass.depthAttachment.loadAction = .clear; pass.depthAttachment.storeAction = .store; pass.depthAttachment.clearDepth = 1
        guard let encoder = command.makeRenderCommandEncoder(descriptor: pass) else {
            throw RenderFailure.message("カセットの描画encoderを作成できません。")
        }
        encoder.label = "Cassette mesh, grain floor, shadow, spectrum and time"
        encoder.setCullMode(.none)
        encoder.setDepthStencilState(depthState)
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
        var spectrum = Array(frame.spectrum.prefix(64))
        spectrum += Array(repeating: 0, count: max(0, 64 - spectrum.count))
        spectrum.withUnsafeBytes { encoder.setVertexBytes($0.baseAddress!, length: $0.count, index: 2) }
        encoder.setRenderPipelineState(floorPipeline)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
        encoder.setRenderPipelineState(meshPipeline)
        encoder.setVertexBuffer(vertices, offset: 0, index: 1)
        encoder.setFragmentTexture(artworkTexture, index: 0)
        encoder.setFragmentTexture(titleTexture, index: 1)
        encoder.setFragmentTexture(lowerTexture, index: 2)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: vertexCount)
        encoder.setRenderPipelineState(spectrumPipeline)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 36, instanceCount: 64)
        encoder.setRenderPipelineState(timePipeline)
        encoder.setFragmentTexture(timeTexture, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: 2)
        encoder.endEncoding()
    }

    func encodePresentation(command: MTLCommandBuffer, descriptor: MTLRenderPassDescriptor, scene: MTLTexture) throws {
        guard let depth, var uniforms = currentUniforms,
              let encoder = command.makeRenderCommandEncoder(descriptor: descriptor) else {
            throw RenderFailure.message("カセットの表示encoderを作成できません。")
        }
        encoder.setRenderPipelineState(presentationPipeline)
        encoder.setFragmentTexture(scene, index: 0)
        encoder.setFragmentTexture(depth, index: 1)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
    }
}
