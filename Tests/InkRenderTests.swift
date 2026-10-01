import Metal
import XCTest
import simd
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import MusicPrayer

final class InkRenderTests: XCTestCase {
    private let width = 192
    private let height = 128

    func testForegroundVolumeAbsorbsTheInkBehindIt() throws {
        let (device, queue) = try environment()
        let renderer = try InkRenderer(device: device)
        let water = try makeWater(device: device)
        func slab(_ p: SIMD3<Float>, front: Bool, back: Bool) -> SIMD3<Float> {
            guard abs(p.x) < 2.2, (1.0...4.6).contains(p.y) else { return .zero }
            if front, (0.7...1.6).contains(p.z) { return SIMD3(0, 3.5, 0) }
            if back, (-1.6 ... -0.8).contains(p.z) { return SIMD3(0, 0, 1.2) }
            return .zero
        }
        let front = try makeDensity(device: device) { slab($0, front: true, back: false) }
        let back = try makeDensity(device: device) { slab($0, front: false, back: true) }
        let both = try makeDensity(device: device) { slab($0, front: true, back: true) }
        let a = try render(renderer, queue: queue, device: device, density: front, water: water)
        let b = try render(renderer, queue: queue, device: device, density: back, water: water)
        let c = try render(renderer, queue: queue, device: device, density: both, water: water)
        let index = (Int(Float(height) * 0.4) * width + width / 2) * 4
        let frontDifference = distance(a, c, index: index)
        let backDifference = distance(b, c, index: index)
        XCTAssertGreaterThan(backDifference, 0.03, "The opaque purple foreground must look different from the pink background.")
        XCTAssertLessThan(frontDifference, backDifference * 0.35, "Foreground extinction must obscure the rear volume, rather than add both colors together.")
        XCTAssertTrue(c.allSatisfy(\.isFinite))
    }

    func testDiluteMixedForegroundKeepsTheRearBlueVolumeVisible() throws {
        let (device, queue) = try environment()
        let renderer = try InkRenderer(device: device)
        let water = try makeWater(device: device)
        func slab(_ p: SIMD3<Float>, front: Bool, back: Bool) -> SIMD3<Float> {
            guard abs(p.x) < 3.2, (1.0...5.2).contains(p.y) else { return .zero }
            if front, (0.0...1.6).contains(p.z) { return SIMD3(0, 0.08, 0.12) }
            if back, (-1.6 ... -0.8).contains(p.z) { return SIMD3(2.4, 0, 0) }
            return .zero
        }
        let empty = try makeDensity(device: device) { _ in .zero }
        let front = try makeDensity(device: device) { slab($0, front: true, back: false) }
        let back = try makeDensity(device: device) { slab($0, front: false, back: true) }
        let both = try makeDensity(device: device) { slab($0, front: true, back: true) }
        let plain = try render(renderer, queue: queue, device: device, density: empty, water: water)
        let foreground = try render(renderer, queue: queue, device: device, density: front, water: water)
        let rear = try render(renderer, queue: queue, device: device, density: back, water: water)
        let layered = try render(renderer, queue: queue, device: device, density: both, water: water)
        var referenceEnergy: Float = 0
        var retainedEnergy: Float = 0
        // This upper central band intersects both slabs, and cannot contain water reflection.
        // Project each observed change onto the rear-only blue color direction. Subtracting
        // the foreground-only image prevents its own emission from counting as visible blue.
        for y in 35..<54 { for x in 82..<110 {
            let i = (y * width + x) * 4
            let rearChange = SIMD3(rear[i]-plain[i], rear[i+1]-plain[i+1], rear[i+2]-plain[i+2])
            let layeredChange = SIMD3(layered[i]-foreground[i], layered[i+1]-foreground[i+1], layered[i+2]-foreground[i+2])
            let energy = simd_length(rearChange)
            referenceEnergy += energy
            retainedEnergy += simd_dot(layeredChange, rearChange / max(energy, 0.0001))
        } }
        XCTAssertGreaterThan(referenceEnergy, 1, "The rear blue fixture must visibly illuminate the measured primary-volume pixels.")
        // A=.2 through 1.6 world units gives about 83% Beer transmittance with the dilute
        // material response, versus 42% with linear extinction. Allow lighting and ray angle
        // variation while requiring the actual rear color to remain visible through the veil.
        XCTAssertGreaterThan(retainedEnergy / referenceEnergy, 0.75,
                             "Dilute mixed ink must transmit the rear blue body rather than form an opaque pastel curtain.")
    }

    func testThreePigmentsAndAudioLightingProduceDifferentHDRImages() throws {
        let (device, queue) = try environment()
        let renderer = try InkRenderer(device: device)
        let water = try makeWater(device: device)
        func cloud(_ p: SIMD3<Float>) -> Float {
            let d = (p - SIMD3<Float>(0, 2.8, 0)) / SIMD3<Float>(1.7, 1.8, 1.2)
            return exp(-simd_length_squared(d) * 2.0) * 1.5
        }
        let blue = try makeDensity(device: device) { SIMD3(cloud($0), 0, 0) }
        let violet = try makeDensity(device: device) { SIMD3(0, cloud($0), 0) }
        let pink = try makeDensity(device: device) { SIMD3(0, 0, cloud($0)) }
        let a = try render(renderer, queue: queue, device: device, density: blue, water: water)
        let b = try render(renderer, queue: queue, device: device, density: violet, water: water)
        let c = try render(renderer, queue: queue, device: device, density: pink, water: water)
        let center = (Int(Float(height) * 0.4) * width + width / 2) * 4
        XCTAssertGreaterThan(b[center], a[center] * 2.0)
        XCTAssertGreaterThan(c[center], b[center] * 1.5)
        XCTAssertGreaterThan(a[center + 2], a[center] * 2.0)
        var loud = VisualFrame()
        loud.rms = 1
        loud.loudness = 1
        let lit = try render(renderer, queue: queue, device: device, density: pink, water: water, frame: loud)
        XCTAssertGreaterThan(lit[center], c[center] * 1.15, "Actual audio energy must increase the ink illumination.")
    }

    func testWaterReflectsTheVolumeAndZeroPresenceRemovesIt() throws {
        let (device, queue) = try environment()
        let renderer = try InkRenderer(device: device)
        let water = try makeWater(device: device)
        let density = try makeDensity(device: device) { p in
            let d = (p - SIMD3<Float>(0, 2.2, 0)) / SIMD3<Float>(2.0, 2.6, 1.2)
            return SIMD3(0, 0, exp(-simd_length_squared(d) * 1.2) * 1.8)
        }
        let empty = try makeDensity(device: device) { _ in .zero }
        let visible = try render(renderer, queue: queue, device: device, density: density, water: water)
        let plain = try render(renderer, queue: queue, device: device, density: empty, water: water)
        var absent = VisualFrame()
        absent.presence = 0
        let hidden = try render(renderer, queue: queue, device: device, density: density, water: water, frame: absent)
        let hiddenEmpty = try render(renderer, queue: queue, device: device, density: empty, water: water, frame: absent)
        XCTAssertEqual(hidden, hiddenEmpty, "A removed track must leave no cached volume or water reflection.")
        var reflectedEnergy: Float = 0
        // Even the front edge (z=1.8) projects above this band, so its primary rays
        // miss the entire density box. These pixels measure reflection, not direct ink.
        for y in Int(Float(height) * 0.72)..<Int(Float(height) * 0.80) {
            for x in (width / 4)..<(width * 3 / 4) {
                let i = (y * width + x) * 4
                reflectedEnergy += max(0, visible[i] - plain[i])
            }
        }
        XCTAssertGreaterThan(reflectedEnergy, 5, "The unobstructed water band must contain real reflected ink pixels above the player controls.")
        XCTAssertTrue((0.62...0.65).contains(InkRenderer.waterHorizon(aspect: 1.5)))
    }

    func testCompositeUpscalesHDRIntoTheDisplayFormat() throws {
        let (device, queue) = try environment()
        let renderer = try InkRenderer(device: device)
        let density = try makeDensity(device: device) { p in
            SIMD3(0.2, 0.35, 0.15) * exp(-simd_length_squared(p - SIMD3(0, 2.5, 0)) * 0.5)
        }
        let water = try makeWater(device: device)
        let scene = try makeTarget(device: device)
        let bloom = try makeTarget(device: device)
        let displayDescriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm_srgb,
                                                                        width: width * 2, height: height * 2, mipmapped: false)
        displayDescriptor.storageMode = .shared
        displayDescriptor.usage = [.renderTarget]
        let display = try XCTUnwrap(device.makeTexture(descriptor: displayDescriptor))
        let command = try XCTUnwrap(queue.makeCommandBuffer())
        try renderer.encode(command: command, target: scene, density: density, frame: VisualFrame(), water: water, aspect: 1.5)
        let clear = MTLRenderPassDescriptor()
        clear.colorAttachments[0].texture = bloom
        clear.colorAttachments[0].loadAction = .clear
        clear.colorAttachments[0].storeAction = .store
        let clearEncoder = try XCTUnwrap(command.makeRenderCommandEncoder(descriptor: clear))
        clearEncoder.endEncoding()
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = display
        pass.colorAttachments[0].loadAction = .dontCare
        pass.colorAttachments[0].storeAction = .store
        try renderer.encodeComposite(command: command, pass: pass, scene: scene, bloom: bloom)
        command.commit()
        command.waitUntilCompleted()
        XCTAssertEqual(command.status, .completed, command.error?.localizedDescription ?? "Ink composite failed")
        var bytes = [UInt8](repeating: 0, count: width * height * 16)
        display.getBytes(&bytes, bytesPerRow: width * 8, from: MTLRegionMake2D(0,0,width * 2,height * 2), mipmapLevel: 0)
        XCTAssertGreaterThan(bytes.enumerated().filter { $0.offset % 4 != 3 }.reduce(0) { $0 + Int($1.element) }, 1000)
        XCTAssertTrue(stride(from: 3, to: bytes.count, by: 4).allSatisfy { bytes[$0] == 255 })
    }

    func testRhythmCannotDrawAnIndependentWaterBandWithoutReflectedInk() throws {
        let (device, queue) = try environment()
        let renderer = try InkRenderer(device: device)
        let empty = try makeDensity(device: device) { _ in .zero }
        var base = VisualFrame()
        base.time = 2.4
        base.hasAnalysis = 1
        base.beatPhase = 0.3
        base.barPhase = 0.6
        for wave in [false, true] {
            let water = try makeWater(device: device, localWave: wave)
            let reference = try render(renderer, queue: queue, device: device, density: empty, water: water, frame: base)
            for accent in [SIMD2<Float>(1, 0), SIMD2<Float>(0, 1)] {
                var active = base
                active.beat = accent.x
                active.bar = accent.y
                let pixels = try render(renderer, queue: queue, device: device, density: empty, water: water, frame: active)
                XCTAssertEqual(pixels, reference,
                               "Beat and bar may brighten reflected ink at wave crests, but must not add a colored band on empty water; localWave=\(wave).")
                XCTAssertTrue(pixels.allSatisfy(\.isFinite))
            }
        }
    }

    func testAllSixAnalysisFamiliesChangeTheVolumeAtTheSameMusicTime() throws {
        let (device, queue) = try environment()
        let renderer = try InkRenderer(device: device)
        let water = try makeWater(device: device)
        let density = try makeDensity(device: device) { p in
            let left = exp(-simd_length_squared((p-SIMD3(-0.8,2.5,0.3))/SIMD3(1.1,1.7,0.8)) * 2.0)
            let right = exp(-simd_length_squared((p-SIMD3(1.0,1.6,-0.5))/SIMD3(0.9,1.2,0.8)) * 2.0)
            return SIMD3(left * 0.20, left * 0.60, right * 0.75)
        }
        var base = VisualFrame()
        base.time = 2.4
        base.hasAnalysis = 1
        let reference = try render(renderer, queue: queue, device: device, density: density, water: water, frame: base)
        func difference(_ other: VisualFrame, rows: Range<Int> = 0..<128,
                        columns: Range<Int> = 0..<192) throws -> Float {
            let pixels = try render(renderer, queue: queue, device: device, density: density, water: water, frame: other)
            var sum: Float = 0
            for y in rows { for x in columns {
                let index = (y * width + x) * 4
                sum += distance(reference,pixels,index: index)
            } }
            return sum / Float(rows.count * columns.count)
        }
        var rhythm = base
        rhythm.beat = 1; rhythm.bar = 1; rhythm.beatPhase = 0.3; rhythm.barPhase = 0.6; rhythm.tempo = 1.7
        // Measure the actual upper cloud, excluding empty sky and every floor ray.
        // The former whole-frame average also counted the removed independent water beam.
        XCTAssertGreaterThan(try difference(rhythm, rows: 24..<72, columns: 48..<144), 0.006,
                             "Rhythm must visibly light the primary volume, independently of fluid motion or water accents.")
        // Keep time, phase and tempo identical while comparing accents. This excludes
        // reflection-direction changes driven by phase from the measured light response.
        var waterBase = base
        waterBase.beatPhase = rhythm.beatPhase
        waterBase.barPhase = rhythm.barPhase
        waterBase.tempo = rhythm.tempo
        let reflectionDensity = try makeDensity(device: device) { p in
            let d = (p - SIMD3<Float>(0, 2.2, 0)) / SIMD3<Float>(2.0, 2.6, 1.2)
            return SIMD3(0, 0, exp(-simd_length_squared(d) * 1.2) * 1.8)
        }
        let empty = try makeDensity(device: device) { _ in .zero }
        let waveWater = try makeWater(device: device, localWave: true)
        func reflectedGain(_ surface: MTLTexture) throws -> (gain: Float, alignment: Float) {
            let plain = try render(renderer, queue: queue, device: device, density: empty, water: surface, frame: waterBase)
            let quiet = try render(renderer, queue: queue, device: device, density: reflectionDensity, water: surface, frame: waterBase)
            let active = try render(renderer, queue: queue, device: device, density: reflectionDensity, water: surface, frame: rhythm)
            var referenceEnergy: Float = 0, addedAlongReflection: Float = 0, changeEnergy: Float = 0
            // No direct volume intersects these rays. The region covers the local wave
            // and the pink cloud's actual reflection, rather than unrelated floor pixels.
            for y in 92..<103 { for x in 72..<120 {
                let i = (y * width + x) * 4
                let reflected = SIMD3(quiet[i] - plain[i], quiet[i + 1] - plain[i + 1], quiet[i + 2] - plain[i + 2])
                let change = SIMD3(active[i] - quiet[i], active[i + 1] - quiet[i + 1], active[i + 2] - quiet[i + 2])
                let energy = simd_length(reflected)
                referenceEnergy += energy
                addedAlongReflection += simd_dot(change, reflected / max(energy, 0.000001))
                changeEnergy += simd_length(change)
            } }
            XCTAssertGreaterThan(referenceEnergy, 1, "The fixture must contain visible reflected pink ink.")
            return (addedAlongReflection / referenceEnergy,
                    addedAlongReflection / max(changeEnergy, 0.000001))
        }
        let flatGain = try reflectedGain(water)
        let crestGain = try reflectedGain(waveWater)
        XCTAssertGreaterThan(crestGain.gain, 0, "Beat and bar must positively brighten the reflected ink at a wave.")
        XCTAssertGreaterThan(crestGain.gain, flatGain.gain,
                             "The local wave must add a crest accent beyond the same-time illumination reflected by flat water.")
        XCTAssertGreaterThan(crestGain.alignment, 0.98,
                             "The accent must follow the reflected pink color, rather than add an unrelated blue beam.")
        var structure = base
        structure.sectionProgress = 0.25; structure.segmentProgress = 0.6; structure.phraseProgress = 0.5
        structure.sectionTransition = 1; structure.sectionSeparation = 0.9
        structure.sectionThickness = 0.9; structure.sectionDepth = 0.85
        structure.sectionGlow = 0.9; structure.sectionWater = 1
        XCTAssertGreaterThan(try difference(structure), 0.012, "Actual structure statistics must reshape and relight the cloud.")
        var pace = base
        pace.pace = 1
        XCTAssertGreaterThan(try difference(pace), 0.003, "Musical activity must change real 3D fine curls at the same time.")
        var instruments = base
        instruments.vocal = 1; instruments.drums = 1; instruments.bassInstrument = 1; instruments.other = 1
        XCTAssertGreaterThan(try difference(instruments), 0.008, "Singing, drums, bass and other instruments must affect the cloud independently of RMS.")
        var loudness = base
        loudness.loudness = 1; loudness.density = 1; loudness.peak = 1
        XCTAssertGreaterThan(try difference(loudness), 0.012, "Momentary loudness, short term body and peak highlights must affect real pixels.")
        var key = base
        key.hue = 0.033; key.modeBias = 1
        XCTAssertGreaterThan(try difference(key), 0.001, "The key's subtle palette rotation must be visible without replacing the instrument palette.")
    }

    func testQuietPurpleAndBlueKeepVisibleBodiesAndDarkShadows() throws {
        let (device, queue) = try environment()
        let renderer = try InkRenderer(device: device)
        let water = try makeWater(device: device)
        let density = try makeDensity(device: device) { p in
            let cloud = exp(-simd_length_squared((p-SIMD3(0,2.5,0))/SIMD3(1.6,1.9,0.9)) * 1.7) * 3
            return SIMD3(cloud * 0.4, cloud * 0.6, 0)
        }
        let pixels = try render(renderer, queue: queue, device: device, density: density, water: water)
        var body: [Float] = []
        for y in 24..<65 { for x in 64..<128 {
            let i = (y * width + x) * 4
            body.append(pixels[i] * 0.2126 + pixels[i+1] * 0.7152 + pixels[i+2] * 0.0722)
        } }
        XCTAssertGreaterThan(body.reduce(0,+) / Float(body.count), 0.022, "Quiet ink must retain visible purple and blue forms before bloom.")
        XCTAssertLessThan(body.min()!, body.max()! * 0.35, "Increasing the light must retain dimensional dark folds.")
        XCTAssertLessThan(body.max()!, 0.8, "Quiet ink must not become a flat white wash.")
    }

    func testStrongSingingAndBeatKeepPinkCoreShadows() throws {
        let (device, queue) = try environment()
        let renderer = try InkRenderer(device: device)
        let water = try makeWater(device: device)
        let density = try makeDensity(device: device) { p in
            let cloud = exp(-simd_length_squared((p-SIMD3(0,2.5,0))/SIMD3(1.8,1.8,1.0)) * 1.7) * 4
            return SIMD3(0, cloud * 0.12, cloud * 0.88)
        }
        var frame = VisualFrame()
        frame.rms = 1; frame.loudness = 1; frame.density = 1; frame.peak = 1
        frame.vocal = 1; frame.drums = 1; frame.beat = 1; frame.bar = 1
        frame.beatPhase = 0.4; frame.sectionGlow = 1
        for spectralLevel: Float in [0,1] {
            frame.spectrum = Array(repeating: spectralLevel, count: 64)
            let pixels = try render(renderer, queue: queue, device: device, density: density, water: water, frame: frame)
            var luminance: [Float] = []
            for y in 25..<65 { for x in 68..<124 {
                let i = (y * width + x) * 4
                luminance.append(pixels[i] * 0.2126 + pixels[i+1] * 0.7152 + pixels[i+2] * 0.0722)
            } }
            luminance.sort()
            let shadow = luminance[luminance.count / 5]
            let litFold = luminance[luminance.count * 4 / 5]
            XCTAssertGreaterThan(litFold, 0.05, "Strong singing must retain bright pink folds, spectrum=\(spectralLevel).")
            XCTAssertLessThan(shadow, litFold * 0.65, "Strong singing, loudness, beat and all spectral bands must keep darker cores, spectrum=\(spectralLevel).")
            XCTAssertLessThan(luminance.reduce(0,+) / Float(luminance.count), 0.65, "The active cloud must retain color below white saturation before bloom, spectrum=\(spectralLevel).")
        }
    }

    func testEveryRealtimeSpectrumBinReachesDistinctSpatialInkPixels() throws {
        let (device, queue) = try environment()
        let renderer = try InkRenderer(device: device)
        let water = try makeWater(device: device)
        // Broad, translucent dye exposes the whole 64-band spatial range. The texture and
        // music time stay fixed so this measures actual spectral rendering, not solver motion.
        let density = try makeDensity(device: device) { p in
            let body = 0.42 * (0.85 + 0.15 * cos(p.y * 1.2))
            return SIMD3(body * 0.35, body * 0.50, body * 0.15)
        }
        var frame = VisualFrame()
        frame.time = 1.3
        let reference = try render(renderer, queue: queue, device: device, density: density, water: water, frame: frame)
        var centers = [Float]()
        for bin in 0..<64 {
            frame.spectrum = Array(repeating: 0, count: 64)
            frame.spectrum[bin] = 1
            let active = try render(renderer, queue: queue, device: device, density: density, water: water, frame: frame)
            var energy: Float = 0, weightedX: Float = 0, maximum: Float = 0
            for y in 0..<height { for x in 0..<width {
                let amount = distance(reference,active,index: (y * width + x) * 4)
                energy += amount; weightedX += Float(x) * amount; maximum = max(maximum,amount)
            } }
            XCTAssertTrue(active.allSatisfy(\.isFinite))
            XCTAssertGreaterThan(energy, 0.02, "Spectrum bin \(bin) must reach real HDR pixels, rather than disappear into a few averaged bands.")
            XCTAssertGreaterThan(maximum, 0.0016, "Spectrum bin \(bin) must produce a local visible response.")
            centers.append(weightedX / max(energy,0.0001))
        }
        XCTAssertGreaterThan(centers[55] - centers[8], Float(width) * 0.25,
                             "Distant frequency bins must illuminate different spatial parts of the ink.")
    }

    func testActualInkReachesBothEdgesAcrossPortraitAndWideViews() throws {
        let (device, queue) = try environment()
        let renderer = try InkRenderer(device: device)
        let fluid = try InkFluid(device: device)
        let water = try makeWater(device: device)
        let empty = try makeDensity(device: device) { _ in .zero }
        var frame = VisualFrame()
        frame.rms = 0.4; frame.vocal = 0.6; frame.loudness = 0.55; frame.density = 0.65
        let seed = try XCTUnwrap(queue.makeCommandBuffer())
        try fluid.encode(command: seed, frame: frame, elapsed: 1.0 / 30)
        seed.commit(); seed.waitUntilCompleted()
        XCTAssertEqual(seed.status, .completed)
        for aspect: Float in [0.75,1.5,2.4] {
            let ink = try render(renderer,queue: queue,device: device,density: fluid.densityTexture,water: water,frame: frame,aspect: aspect)
            let background = try render(renderer,queue: queue,device: device,density: empty,water: water,frame: frame,aspect: aspect)
            for columns in [0..<8,(width-8)..<width] {
                var energy: Float = 0, maximum: Float = 0, litPixels = 0
                // Above the visible water, so this requires real primary ink at both edges.
                for y in 0..<Int(Float(height) * 0.62) { for x in columns {
                    let amount = distance(ink,background,index: (y * width + x) * 4)
                    energy += amount; maximum = max(maximum,amount)
                    if amount > 0.005 { litPixels += 1 }
                } }
                print("Ink edge aspect=\(aspect), x=\(columns): energy=\(energy), max=\(maximum), pixels=\(litPixels)")
                XCTAssertGreaterThan(energy,0.3,"Both outer 4% strips must contain actual ink, aspect=\(aspect).")
                XCTAssertGreaterThan(maximum,0.01,"An edge must visibly contain ink rather than only a background glow, aspect=\(aspect).")
                XCTAssertGreaterThan(litPixels,8,"Ink must reach a continuous edge area, aspect=\(aspect).")
            }
            var reflectedEnergy: Float = 0
            for y in 92..<103 { for x in (width/4)..<(width*3/4) {
                reflectedEnergy += distance(ink,background,index: (y * width + x) * 4)
            } }
            XCTAssertGreaterThan(reflectedEnergy,1,"Width fitting must retain actual volume reflection, aspect=\(aspect).")
            XCTAssertTrue((0.62...0.65).contains(InkRenderer.waterHorizon(aspect: aspect)))
        }
    }

    func testExpandedWorldKeepsTheCentralCloudAtItsOriginalSize() throws {
        let (device, queue) = try environment()
        let renderer = try InkRenderer(device: device)
        let water = try makeWater(device: device)
        let density = try makeDensity(device: device) { p in
            abs(p.x) < 0.7 && (2.0...3.0).contains(p.y) && (0.5...1.0).contains(p.z)
                ? SIMD3(0,3.5,0) : .zero
        }
        let empty = try makeDensity(device: device) { _ in .zero }
        let ink = try render(renderer,queue: queue,device: device,density: density,water: water)
        let background = try render(renderer,queue: queue,device: device,density: empty,water: water)
        var columns = Set<Int>()
        for y in 0..<Int(Float(height) * 0.62) { for x in 0..<width {
            if distance(ink,background,index: (y * width + x) * 4) > 0.01 { columns.insert(x) }
        } }
        let span = try XCTUnwrap(columns.max()) - XCTUnwrap(columns.min()) + 1
        // The original camera projects a 1.4-unit central cloud to roughly 33px here;
        // texture interpolation adds a few edge pixels. A 34% whole-volume zoom exceeds 42px.
        XCTAssertGreaterThan(span,28,"Expanding the world must not shrink its original central cloud.")
        XCTAssertLessThan(span,42,"Ink at the edges must come from additional world space, rather than magnifying the central cloud.")
    }

    func testActualFluidSeedAndSustainedFlowRenderColoredVolumes() throws {
        let (device, queue) = try environment()
        let fluid = try InkFluid(device: device)
        let renderer = try InkRenderer(device: device)
        let water = try makeWater(device: device)
        let w = 960, h = 540
        let previewDirectory = ProcessInfo.processInfo.environment["MUSIC_PRAYER_INK_PREVIEW_DIR"]
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
        func texture(_ format: MTLPixelFormat) throws -> MTLTexture {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: w, height: h, mipmapped: false)
            descriptor.storageMode = .shared
            descriptor.usage = [.renderTarget, .shaderRead]
            return try XCTUnwrap(device.makeTexture(descriptor: descriptor))
        }
        let scene = try texture(.rgba16Float), bloom = try texture(.rgba16Float)
        let display = try texture(.bgra8Unorm_srgb)
        var frame = VisualFrame()
        frame.trackID = UUID()
        frame.rms = 0.4; frame.bass = 0.5; frame.vocal = 0.6
        frame.drums = 0.55; frame.bassInstrument = 0.6; frame.treble = 0.35
        frame.hasAnalysis = 1; frame.tempo = 1.08; frame.pace = 0.7; frame.other = 0.4
        frame.loudness = 0.55; frame.density = 0.65; frame.peak = 0.3
        frame.hue = 0.02; frame.modeBias = 0.5
        frame.spectrum = (0..<64).map { 0.16 + 0.10 * sin(Float($0) * 0.21) }
        frame.sectionSeparation = 0.55; frame.sectionThickness = 0.55
        frame.sectionDepth = 0.55; frame.sectionGlow = 0.55; frame.sectionWater = 0.55
        let initialFrame = frame
        let seed = try XCTUnwrap(queue.makeCommandBuffer())
        try fluid.encode(command: seed, frame: frame, elapsed: 1.0 / 30)
        seed.commit(); seed.waitUntilCompleted()
        XCTAssertEqual(seed.status, .completed, seed.error?.localizedDescription ?? "Ink seed failed")

        func export(_ path: String, densityOverride: MTLTexture? = nil) throws -> [UInt8] {
            let command = try XCTUnwrap(queue.makeCommandBuffer())
            try renderer.encode(command: command, target: scene, density: densityOverride ?? fluid.densityTexture,
                                frame: frame, water: water, aspect: Float(w) / Float(h))
            let clear = MTLRenderPassDescriptor()
            clear.colorAttachments[0].texture = bloom
            clear.colorAttachments[0].loadAction = .clear
            clear.colorAttachments[0].storeAction = .store
            let clearEncoder = try XCTUnwrap(command.makeRenderCommandEncoder(descriptor: clear))
            clearEncoder.endEncoding()
            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = display
            pass.colorAttachments[0].loadAction = .dontCare
            pass.colorAttachments[0].storeAction = .store
            try renderer.encodeComposite(command: command, pass: pass, scene: scene, bloom: bloom)
            command.commit(); command.waitUntilCompleted()
            XCTAssertEqual(command.status, .completed, command.error?.localizedDescription ?? "Actual ink volume failed")
            let milliseconds = max(0, command.gpuEndTime - command.gpuStartTime) * 1000
            print("Ink volume + composite \(w)x\(h), time=\(frame.time): GPU \(String(format: "%.2f", milliseconds)) ms")
            var pixels = [UInt8](repeating: 0, count: w * h * 4)
            display.getBytes(&pixels, bytesPerRow: w * 4, from: MTLRegionMake2D(0,0,w,h), mipmapLevel: 0)
            let coloredPixels = stride(from: 0, to: pixels.count, by: 4).filter {
                max(pixels[$0], max(pixels[$0 + 1], pixels[$0 + 2])) > 45
            }.count
            XCTAssertGreaterThan(coloredPixels, w * h / 6, "The actual solver must retain a substantial lit volume, rather than a tiny isolated point.")
            // Explicit integration previews requested for visual acceptance; they are not app resources.
            let originalPixels = pixels
            guard let previewDirectory else { return originalPixels }
            for index in stride(from: 0, to: pixels.count, by: 4) { pixels.swapAt(index, index + 2) }
            let provider = try XCTUnwrap(CGDataProvider(data: Data(pixels) as CFData))
            let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
            let image = try XCTUnwrap(CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32,
                                             bytesPerRow: w * 4, space: space,
                                             bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                                             provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent))
            let url = previewDirectory.appendingPathComponent(path)
            let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
            CGImageDestinationAddImage(destination, image, nil)
            XCTAssertTrue(CGImageDestinationFinalize(destination))
            return originalPixels
        }
        let initial = try export("music-prayer-ink-seed.png")
        var computeMilliseconds: Double = 0
        // Production fluid steps are measured without adding CPU waits to every simulation step.
        func advance(_ batches: Range<Int>) throws {
            for batch in batches {
                let command = try XCTUnwrap(queue.makeCommandBuffer())
                for index in 1...30 {
                    let step = batch * 30 + index
                    frame.time = Float(step) / 30
                    frame.rms = 0.4 + sin(frame.time * 2.1) * 0.12
                    frame.beat = step % 15 == 0 ? 1 : 0
                    frame.bar = step % 60 == 0 ? 1 : 0
                    frame.beatPhase = Float(step % 15) / 15
                    frame.barPhase = Float(step % 60) / 60
                    frame.sectionProgress = Float(step % 480) / 480
                    frame.segmentProgress = Float(step % 120) / 120
                    frame.phraseProgress = Float(step % 60) / 60
                    frame.sectionTransition = step % 480 == 0 ? 1 : 0
                    frame.peak = frame.beat > 0 ? 0.85 : 0.3
                    frame.spectrum = (0..<64).map {
                        0.16 + 0.10 * sin(Float($0) * 0.21 + frame.time * 0.6)
                    }
                    try fluid.encode(command: command, frame: frame, elapsed: 1.0 / 30)
                }
                command.commit(); command.waitUntilCompleted()
                XCTAssertEqual(command.status, .completed, command.error?.localizedDescription ?? "Sustained fluid flow failed")
                computeMilliseconds += max(0, command.gpuEndTime - command.gpuStartTime) * 1000
            }
        }
        try advance(0..<5)
        let flowed = try export("music-prayer-ink-after5.png")
        let changed = zip(initial, flowed).filter { abs(Int($0.0) - Int($0.1)) > 10 }.count
        XCTAssertGreaterThan(changed, w * h / 8, "Actual advection and audio forces must materially change the visible 3D volume.")
        try advance(5..<30)
        print("Ink fluid: 900 production steps, GPU mean \(String(format: "%.2f", computeMilliseconds / 900)) ms / step")
        let sustained = try export("music-prayer-ink-after30.png")
        let sustainedChange = zip(flowed, sustained).filter { abs(Int($0.0) - Int($0.1)) > 10 }.count
        XCTAssertGreaterThan(sustainedChange, w * h / 8, "Sustained audio input must continue to change the spatial ink flow.")
        if previewDirectory != nil {
            // Optional visual acceptance for all six genuine solver forces. Identical musical
            // input isolates their fluid geometry; direction itself is covered by InkFluidTests.
            for kind in InkMotionKind.allCases {
                let modeFluid = try InkFluid(device: device)
                let motion = InkMotionState.focused(kind, activity: 0.8, peak: 0.3)
                frame = initialFrame
                let seed = try XCTUnwrap(queue.makeCommandBuffer())
                try modeFluid.encode(command: seed, frame: frame, elapsed: 1.0 / 30, motion: motion)
                seed.commit(); seed.waitUntilCompleted()
                XCTAssertEqual(seed.status, .completed, seed.error?.localizedDescription ?? "Mode seed failed")
                for batch in 0..<5 {
                    let command = try XCTUnwrap(queue.makeCommandBuffer())
                    for index in 1...30 {
                        frame.time = Float(batch * 30 + index) / 30
                        try modeFluid.encode(command: command, frame: frame, elapsed: 1.0 / 30, motion: motion)
                    }
                    command.commit(); command.waitUntilCompleted()
                    XCTAssertEqual(command.status, .completed, command.error?.localizedDescription ?? "Mode flow failed")
                }
                _ = try export("music-prayer-ink-motion-\(kind).png", densityOverride: modeFluid.densityTexture)
            }
        }
    }

    private func environment() throws -> (MTLDevice, MTLCommandQueue) {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("Metal device unavailable") }
        return (device, try XCTUnwrap(device.makeCommandQueue()))
    }

    private func makeDensity(device: MTLDevice, values: (SIMD3<Float>) -> SIMD3<Float>) throws -> MTLTexture {
        let minimum = InkFluid.domainMinimum
        let extent = InkFluid.domainMaximum - minimum
        // Preserve the original central field's 0.15-unit x cell width as world space grows.
        let w = Int(round(extent.x / 0.15)), h = 48, d = 32
        let descriptor = MTLTextureDescriptor()
        descriptor.textureType = .type3D
        descriptor.pixelFormat = .rgba16Float
        descriptor.width = w; descriptor.height = h; descriptor.depth = d
        descriptor.storageMode = .shared
        descriptor.usage = [.shaderRead]
        let texture = try XCTUnwrap(device.makeTexture(descriptor: descriptor))
        var data = [Float16](repeating: 0, count: w * h * d * 4)
        for z in 0..<d { for y in 0..<h { for x in 0..<w {
            let p = minimum + SIMD3<Float>((Float(x) + 0.5) / Float(w),
                                           (Float(y) + 0.5) / Float(h),
                                           (Float(z) + 0.5) / Float(d)) * extent
            let rgb = values(p)
            let i = ((z * h + y) * w + x) * 4
            data[i] = Float16(rgb.x); data[i + 1] = Float16(rgb.y); data[i + 2] = Float16(rgb.z)
            data[i + 3] = Float16(rgb.x + rgb.y + rgb.z)
        } } }
        data.withUnsafeBytes { texture.replace(region: MTLRegionMake3D(0,0,0,w,h,d), mipmapLevel: 0, slice: 0,
                                               withBytes: $0.baseAddress!, bytesPerRow: w * 8, bytesPerImage: w * h * 8) }
        return texture
    }

    private func makeWater(device: MTLDevice, localWave: Bool = false) throws -> MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rg32Float, width: 32, height: 16, mipmapped: false)
        descriptor.storageMode = .shared
        descriptor.usage = [.shaderRead]
        let texture = try XCTUnwrap(device.makeTexture(descriptor: descriptor))
        var heights = [Float](repeating: 0, count: 32 * 16 * 2)
        if localWave {
            for y in 0..<16 { for x in 0..<32 {
                let offset = (SIMD2<Float>((Float(x) + 0.5) / 32, (Float(y) + 0.5) / 16)
                              - SIMD2<Float>(0.5, 0.35)) / SIMD2<Float>(0.22, 0.18)
                let height = 0.24 * exp(-simd_length_squared(offset) * 2)
                let index = (y * 32 + x) * 2
                heights[index] = height
                heights[index + 1] = height
            } }
        }
        heights.withUnsafeBytes { texture.replace(region: MTLRegionMake2D(0,0,32,16), mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: 32 * 8) }
        return texture
    }

    private func makeTarget(device: MTLDevice) throws -> MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: width, height: height, mipmapped: false)
        descriptor.storageMode = .shared
        descriptor.usage = [.renderTarget, .shaderRead]
        return try XCTUnwrap(device.makeTexture(descriptor: descriptor))
    }

    private func render(_ renderer: InkRenderer, queue: MTLCommandQueue, device: MTLDevice,
                        density: MTLTexture, water: MTLTexture, frame: VisualFrame = VisualFrame(), aspect: Float = 1.5) throws -> [Float] {
        let target = try makeTarget(device: device)
        let command = try XCTUnwrap(queue.makeCommandBuffer())
        try renderer.encode(command: command, target: target, density: density, frame: frame, water: water, aspect: aspect)
        command.commit()
        command.waitUntilCompleted()
        XCTAssertEqual(command.status, .completed, command.error?.localizedDescription ?? "Ink volume failed")
        var data = [Float16](repeating: 0, count: width * height * 4)
        target.getBytes(&data, bytesPerRow: width * 8, from: MTLRegionMake2D(0,0,width,height), mipmapLevel: 0)
        return data.map(Float.init)
    }

    private func distance(_ a: [Float], _ b: [Float], index: Int) -> Float {
        simd_length(SIMD3(a[index] - b[index], a[index + 1] - b[index + 1], a[index + 2] - b[index + 2]))
    }
}
