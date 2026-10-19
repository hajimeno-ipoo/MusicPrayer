import AppKit
import Metal
import simd
import XCTest
@testable import MusicPrayer

final class CitySceneTests: XCTestCase {
    @MainActor
    func testCityGlassSeparatesBackgroundFromOpaqueGeometryWithoutFadingColor() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("Metal unavailable") }
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let renderer = try CitySceneRenderer(device: device)
        var frame = musicalFrame()
        frame.isPlaying = false
        let width = 960, height = 540
        let opaque = try render(renderer, device: device, queue: queue, frame: frame,
                                width: width, height: height, backgroundOpacity: 1).pixels
        let glass = try render(renderer, device: device, queue: queue, frame: frame,
                               width: width, height: height, backgroundOpacity: 0.18).pixels
        XCTAssertEqual(opaque.count, width * height * 4)
        XCTAssertEqual(glass.count, opaque.count)
        guard opaque.count == width * height * 4, glass.count == opaque.count else { return }
        var translucentBackground = 0, opaqueGeometry = 0, visibleGeometry = 0
        var maximumGeometryDifference = 0, invalidPremultipliedPixels = 0, nonOpaqueReferencePixels = 0
        for index in stride(from: 0, to: glass.count, by: 4) {
            let alpha = Int(glass[index + 3])
            if opaque[index + 3] != 255 { nonOpaqueReferencePixels += 1 }
            if alpha < 80 { translucentBackground += 1 }
            if (0..<3).contains(where: { Int(glass[index + $0]) > alpha + 1 }) {
                invalidPremultipliedPixels += 1
            }
            if alpha == 255 {
                opaqueGeometry += 1
                // Compare visible surfaces, where uniformly fading RGB would be
                // measurable. Dark background pixels cannot satisfy this check.
                let referencePeak = max(opaque[index], max(opaque[index + 1], opaque[index + 2]))
                if referencePeak >= 64 {
                    visibleGeometry += 1
                    for channel in 0..<3 {
                        maximumGeometryDifference = max(maximumGeometryDifference,
                            abs(Int(glass[index + channel]) - Int(opaque[index + channel])))
                    }
                }
            }
        }
        XCTAssertEqual(nonOpaqueReferencePixels, 0, "Reduce Transparency must retain an opaque drawable.")
        XCTAssertGreaterThan(translucentBackground, width * height / 4,
                             "The studio surround must reveal glass across a substantial area.")
        XCTAssertGreaterThan(opaqueGeometry, width * height / 100,
                             "Solid city geometry must remain opaque in the same frame as the transparent surround.")
        XCTAssertGreaterThan(visibleGeometry, 500,
                             "The color comparison must cover visible city surfaces, not just black pixels.")
        XCTAssertLessThanOrEqual(maximumGeometryDifference, 3,
                                 "Background transparency must not fade the RGB of solid city surfaces.")
        XCTAssertEqual(invalidPremultipliedPixels, 0,
                       "Stored sRGB channels must be premultiplied for Core Animation compositing.")
    }

    @MainActor
    func testGoldLightDisappearsDuringSilenceAndPauseWithCachedAnalysis() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("Metal unavailable") }
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let renderer = try CitySceneRenderer(device: device)
        var frame = musicalFrame()
        frame.other = 0; frame.vocal = 0
        frame.beat = 1; frame.bar = 1; frame.peak = 1
        func images(_ state: VisualFrame) throws -> ([UInt8], [UInt8]) {
            var first = state; first.barPhase = 0.1
            var next = state; next.barPhase = 0.6
            return (try render(renderer, device: device, queue: queue, frame: first).pixels,
                    try render(renderer, device: device, queue: queue, frame: next).pixels)
        }
        frame.rms = 0
        let silence = try images(frame)
        XCTAssertLessThanOrEqual(maximumChannelDifference(silence.0, silence.1), 1,
                                 "Cached beats, peak and analysis must not leave gold geometry or spill in silence.")
        try saveEvidence(silence.0, width: 640, height: 384, name: "city-gold-silent")
        frame.rms = 0.25; frame.isPlaying = false
        let paused = try images(frame)
        XCTAssertLessThanOrEqual(maximumChannelDifference(paused.0, paused.1), 1,
                                 "Pause must remove the body, mirror and gold surface illumination immediately.")
        frame.isPlaying = true
        let playing = try images(frame)
        XCTAssertGreaterThan(changedPixels(playing.0, playing.1), 100,
                             "Resuming audible input must restore travelling light.")
        XCTAssertGreaterThan(changedPixels(paused.0, playing.0), 100,
                             "Paused pixels must differ from a frozen luminous arc.")
        frame.rms = 0.025
        let quiet = try images(frame)
        XCTAssertGreaterThan(changedPixels(quiet.0, playing.0), 100,
                             "Gold brightness must follow live audio strength.")
    }

    func testGoldCurveHasRealHeightMotionAndContinuousWrapOnGPU() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("Metal unavailable") }
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let sourceURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/Rendering/SpectrumCity.metal")
        let source = try String(contentsOf: sourceURL, encoding: .utf8) + """

        kernel void cityGoldGeometryTest(uint id [[thread_position_in_grid]],
            constant CityUniforms &u [[buffer(0)]], const device float4 *route [[buffer(3)]],
            device float4 *positions [[buffer(4)]]) {
            positions[id]=float4(cityGoldPoint(float(id)/256,u,route),1);
        }
        """
        let library = try device.makeLibrary(source: source, options: nil)
        let pipeline = try device.makeComputePipelineState(function: try XCTUnwrap(library.makeFunction(name: "cityGoldGeometryTest")))
        let route = CityMesh.goldLightRoute()
        let routeBuffer = try XCTUnwrap(device.makeBuffer(bytes: route, length: route.count * MemoryLayout<SIMD4<Float>>.stride))
        let output = try XCTUnwrap(device.makeBuffer(length: 257 * MemoryLayout<SIMD4<Float>>.stride, options: .storageModeShared))
        func positions(phase: Float) throws -> [SIMD4<Float>] {
            // CityUniforms: two matrices followed by ten float4 values.
            var uniforms = Array(repeating: SIMD4<Float>.zero, count: 18)
            uniforms[14] = SIMD4(repeating: 0.5)
            uniforms[15] = SIMD4(0, phase, 1, 1)
            let command = try XCTUnwrap(queue.makeCommandBuffer())
            let encoder = try XCTUnwrap(command.makeComputeCommandEncoder())
            encoder.setComputePipelineState(pipeline)
            uniforms.withUnsafeBytes { encoder.setBytes($0.baseAddress!, length: $0.count, index: 0) }
            encoder.setBuffer(routeBuffer, offset: 0, index: 3)
            encoder.setBuffer(output, offset: 0, index: 4)
            encoder.dispatchThreads(MTLSize(width: 257, height: 1, depth: 1),
                                    threadsPerThreadgroup: MTLSize(width: 64, height: 1, depth: 1))
            encoder.endEncoding(); command.commit(); command.waitUntilCompleted()
            XCTAssertEqual(command.status, .completed)
            return Array(UnsafeBufferPointer(start: output.contents().assumingMemoryBound(to: SIMD4<Float>.self), count: 257))
        }
        let first = try positions(phase: 0)
        let middle = try positions(phase: 0.5)
        let wrapped = try positions(phase: 1)
        XCTAssertTrue(first.allSatisfy { $0.y > 0.20 && $0.y < 0.90 }, "The body must occupy space above the floor.")
        XCTAssertGreaterThan(zip(first, middle).map { abs($0.y - $1.y) }.max()!, 0.5,
                             "Advancing only music phase must change the actual GPU world height.")
        XCTAssertLessThan(zip(first, wrapped).map { simd_length($0 - $1) }.max()!, 0.0001,
                          "Position and height must join continuously at the next bar.")
        let tangents = (0..<256).map { simd_normalize(SIMD2(first[$0 + 1].x - first[$0].x, first[$0 + 1].z - first[$0].z)) }
        XCTAssertGreaterThan((0..<256).map { simd_dot(tangents[$0], tangents[($0 + 1) % 256]) }.min()!, 0.98,
                             "The reference's broad curve must not turn into a square route.")
    }

    @MainActor
    func testReducedRectangularLayoutKeepsAllFFTInputsAndGPUPositionsConsistent() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("Metal unavailable") }
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let sourceURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/Rendering/SpectrumCity.metal")
        let source = try String(contentsOf: sourceURL, encoding: .utf8) + """

        kernel void cityLayoutTest(uint id [[thread_position_in_grid]], device uint4 *result [[buffer(0)]]) {
            uint2 cell=cityGridForBand(id);
            result[id]=uint4(cell,cityBandAtGrid(cell),cityBandAtGrid(uint2(id%5,id/5)));
        }
        """
        let library = try device.makeLibrary(source: source, options: nil)
        let pipeline = try device.makeComputePipelineState(function: try XCTUnwrap(library.makeFunction(name: "cityLayoutTest")))
        let output = try XCTUnwrap(device.makeBuffer(length: CityMesh.buildingCount * MemoryLayout<SIMD4<UInt32>>.stride, options: .storageModeShared))
        let command = try XCTUnwrap(queue.makeCommandBuffer())
        let encoder = try XCTUnwrap(command.makeComputeCommandEncoder())
        encoder.setComputePipelineState(pipeline)
        encoder.setBuffer(output, offset: 0, index: 0)
        encoder.dispatchThreads(MTLSize(width: CityMesh.buildingCount, height: 1, depth: 1),
                                threadsPerThreadgroup: MTLSize(width: 40, height: 1, depth: 1))
        encoder.endEncoding(); command.commit(); command.waitUntilCompleted()
        XCTAssertEqual(command.status, .completed)
        let cells = Array(UnsafeBufferPointer(start: output.contents().assumingMemoryBound(to: SIMD4<UInt32>.self), count: CityMesh.buildingCount))
        var occupied = Set<SIMD2<Int>>()
        for band in 0..<CityMesh.buildingCount {
            let cell = SIMD2(Int(cells[band].x), Int(cells[band].y))
            XCTAssertEqual(cell, CityMesh.gridCoordinate(for: band), "Transparency sorting must match the actual GPU tower position.")
            XCTAssertEqual(cells[band].z, UInt32(band), "The floor must look up the same tower as the geometry.")
            XCTAssertTrue(cell.x >= 0 && cell.x < 5 && cell.y >= 0 && cell.y < 8)
            occupied.insert(cell)
        }
        XCTAssertEqual(occupied.count, 40)
        XCTAssertEqual(Set(occupied.map(\.x)).count, 5)
        XCTAssertEqual(Set(occupied.map(\.y)).count, 8)
        XCTAssertEqual(Set(cells.map(\.w)), Set((0..<40).map(UInt32.init)))
        let foundation = CityMesh.foundationVertices().filter { $0.surface.z == 0 }
        let width = foundation.map { $0.position.x }.max()! - foundation.map { $0.position.x }.min()!
        let depth = foundation.map { $0.position.z }.max()! - foundation.map { $0.position.z }.min()!
        XCTAssertGreaterThan(depth / width, 1.1, "The floor's long edge must follow the foreground direction.")

        var respondingTowers = Set<Int>()
        for bin in 0..<64 {
            var input = Array(repeating: Float(0), count: 64)
            input[bin] = 0.85
            let displayed = CityMesh.displaySpectrum(input)
            let responding = displayed.indices.filter { displayed[$0] > 0 }
            XCTAssertEqual(responding.count, 1, "Every analysed bin must reach exactly one displayed tower.")
            XCTAssertEqual(displayed.max(), 0.85, "Grouping must preserve a narrow spectral peak.")
            respondingTowers.formUnion(responding)
        }
        XCTAssertEqual(respondingTowers.count, 40)
        XCTAssertEqual(CityMesh.displaySpectrum([]), Array(repeating: 0, count: 40))
        XCTAssertEqual(CityMesh.displaySpectrum(Array(repeating: 1, count: 64)), Array(repeating: 1, count: 40))
    }

    @MainActor
    func testRenderedCityRespondsToSpectrumAndBeatAndRestoresAfterSeek() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("Metal unavailable") }
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let renderer = try CitySceneRenderer(device: device)
        let frame = musicalFrame()
        let baseline = try render(renderer, device: device, queue: queue, frame: frame).pixels
        let visible = stride(from: 0, to: baseline.count, by: 4).filter {
            max(baseline[$0], max(baseline[$0 + 1], baseline[$0 + 2])) > 70
        }.count
        XCTAssertGreaterThan(visible, 1_000, "The city must contain visible illuminated geometry.")

        let changes: [(String, (inout VisualFrame) -> Void)] = [
            ("low frequency towers", { $0.spectrum = Array(repeating: 0, count: 64); for i in 0..<8 { $0.spectrum[i] = 0.85 } }),
            ("high frequency towers", { $0.spectrum = Array(repeating: 0, count: 64); for i in 56..<64 { $0.spectrum[i] = 0.85 } }),
            ("beat wave", { $0.beat = 1; $0.beatPhase = 0.12 }),
            ("bar accent", { $0.bar = 1; $0.barPhase = 0.2 }),
            ("loudness", { $0.loudness = 1; $0.density = 1 }),
            ("section transition", { $0.sectionTransition = 1; $0.sectionProgress = 0.8 }),
            ("time", { $0.time = 36 })
        ]
        for (name, change) in changes {
            var updated = frame
            change(&updated)
            let image = try render(renderer, device: device, queue: queue, frame: updated).pixels
            XCTAssertGreaterThan(changedPixels(baseline, image), 40, "\(name) must change presented GPU pixels.")
        }
        let restored = try render(renderer, device: device, queue: queue, frame: frame).pixels
        XCTAssertLessThanOrEqual(maximumChannelDifference(baseline, restored), 1,
                                 "Seeking back must restore the city within 8-bit quantization.")
        try saveEvidence(baseline, width: 640, height: 384, name: "city-spectrum")
    }

    @MainActor
    func testVocalAndOtherActivitiesHaveIndependentVisibleReactions() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("Metal unavailable") }
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let renderer = try CitySceneRenderer(device: device)
        var frame = musicalFrame()
        frame.vocal = 0; frame.other = 0; frame.beat = 0; frame.bar = 0; frame.drums = 0
        let baseline = try render(renderer, device: device, queue: queue, frame: frame).pixels
        var vocalFrame = frame
        vocalFrame.vocal = 1
        let vocal = try render(renderer, device: device, queue: queue, frame: vocalFrame).pixels
        var quietVocalFrame = frame
        quietVocalFrame.vocal = 0.45
        let quietVocal = try render(renderer, device: device, queue: queue, frame: quietVocalFrame).pixels
        var otherFrame = frame
        otherFrame.other = 1
        let other = try render(renderer, device: device, queue: queue, frame: otherFrame).pixels
        XCTAssertGreaterThan(changedPixels(baseline, vocal), 300, "Vocal activity must visibly change the city with the same FFT and beat.")
        XCTAssertGreaterThan(changedPixels(quietVocal, vocal), 300, "Vocal strength must change the visible fill rather than simply toggle an effect.")
        XCTAssertGreaterThan(changedPixels(baseline, other), 300, "Other-instrument activity must visibly change the city with the same FFT and beat.")
        XCTAssertGreaterThan(changedPixels(vocal, other), 300, "The two activities must produce distinguishable images.")

        var nextBar = frame
        nextBar.barPhase = 0.15
        let silentNextBar = try render(renderer, device: device, queue: queue, frame: nextBar).pixels
        // Gold now moves continuously in bar phase, even between beats. Compare the
        // dedicated other-instrument contribution against the off image at the same phase.
        nextBar.other = 1
        let flowing = try render(renderer, device: device, queue: queue, frame: nextBar).pixels
        XCTAssertGreaterThan(changedPixels(silentNextBar, flowing), 300,
                             "Other-instrument activity must add visible light at the same gold-light phase.")
        XCTAssertGreaterThan(changedPixels(other, flowing), 300, "Other-instrument street light must advance with bar phase.")

        frame.hasAnalysis = 0
        let noAnalysis = try render(renderer, device: device, queue: queue, frame: frame).pixels
        frame.vocal = 1; frame.other = 1
        let residualInput = try render(renderer, device: device, queue: queue, frame: frame).pixels
        XCTAssertLessThanOrEqual(maximumChannelDifference(noAnalysis, residualInput), 1,
                                 "Removing analysis must disable dedicated activity effects immediately.")
        frame.hasAnalysis = 1; frame.vocal = 0; frame.other = 0
        let restored = try render(renderer, device: device, queue: queue, frame: frame).pixels
        XCTAssertLessThanOrEqual(maximumChannelDifference(baseline, restored), 1,
                                 "Restoring the same inputs must restore the visible reactions after a seek.")

        if ProcessInfo.processInfo.environment["MUSIC_PRAYER_CITY_EVIDENCE_DIR"] != nil {
            for (name, state) in [("city-activities-off", frame), ("city-vocal-middle", quietVocalFrame), ("city-vocal-on", vocalFrame),
                                  ("city-other-on", otherFrame), ("city-other-next-bar", nextBar)] {
                let pixels = try render(renderer, device: device, queue: queue, frame: state, width: 1920, height: 1080).pixels
                try saveEvidence(pixels, width: 1920, height: 1080, name: name)
            }
        }
    }

    @MainActor
    func testGoldLightMovesThroughCityAndRestoresAfterSeek() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("Metal unavailable") }
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let renderer = try CitySceneRenderer(device: device)
        var frame = musicalFrame()
        frame.vocal = 0; frame.other = 0; frame.drums = 0; frame.beat = 0; frame.bar = 0
        let idle = try render(renderer, device: device, queue: queue, frame: frame, width: 960, height: 540).pixels
        let goldPixels = stride(from: 0, to: idle.count, by: 4).filter { i in
            let blue = Int(idle[i]), green = Int(idle[i + 1]), red = Int(idle[i + 2])
            return red > 70 && green > 35 && red > green + 20 && green > blue + 10
        }.count
        XCTAssertGreaterThan(goldPixels, 600, "Warm street and floor light must remain visible between beats.")
        print("CITY_GOLD_IDLE_PIXELS \(goldPixels)")

        frame.beat = 1; frame.bar = 0.7; frame.drums = 0.5
        frame.beatPhase = 0.15; frame.barPhase = 0.2
        let first = try render(renderer, device: device, queue: queue, frame: frame, width: 960, height: 540).pixels
        var next = frame
        next.barPhase = 0.65
        let second = try render(renderer, device: device, queue: queue, frame: next, width: 960, height: 540).pixels
        XCTAssertGreaterThan(changedPixels(idle, first), 300, "Beat and bar must illuminate the streets and their floor footprints.")
        XCTAssertGreaterThan(changedPixels(first, second), 300, "Changing only music phase must move the gold street pulse.")
        let restored = try render(renderer, device: device, queue: queue, frame: frame, width: 960, height: 540).pixels
        XCTAssertLessThanOrEqual(maximumChannelDifference(first, restored), 1,
                                 "The street light must restore after seeking back to the same phase.")
        frame.hasAnalysis = 0; next.hasAnalysis = 0
        let unanalysedFirst = try render(renderer, device: device, queue: queue, frame: frame).pixels
        let unanalysedSecond = try render(renderer, device: device, queue: queue, frame: next).pixels
        XCTAssertLessThanOrEqual(maximumChannelDifference(unanalysedFirst, unanalysedSecond), 1,
                                 "Missing analysis must disable phase-driven gold light, including bar activity.")

        try saveEvidence(idle, width: 960, height: 540, name: "city-gold-between-beats")
        try saveEvidence(first, width: 960, height: 540, name: "city-gold-first-phase")
        try saveEvidence(second, width: 960, height: 540, name: "city-gold-next-phase")
        if ProcessInfo.processInfo.environment["MUSIC_PRAYER_CITY_EVIDENCE_DIR"] != nil {
            frame.hasAnalysis = 1
            // Hold FFT, time and activity constant: only the musical bar phase advances.
            // Capture a complete cycle to review the curved bundle moving between buildings.
            var firstInCycle: [UInt8]?
            var previous: [UInt8]?
            for index in 0..<48 {
                frame.barPhase = Float(index) / 48
                let pixels = try render(renderer, device: device, queue: queue, frame: frame, width: 960, height: 540).pixels
                if let previous {
                    XCTAssertGreaterThan(changedPixels(previous, pixels), 20,
                                         "The light head must advance at every phase step with the other inputs fixed.")
                } else { firstInCycle = pixels }
                previous = pixels
                try saveEvidence(pixels, width: 960, height: 540, name: String(format: "city-gold-motion-%02d", index))
            }
            frame.barPhase = 1
            let wrapped = try render(renderer, device: device, queue: queue, frame: frame, width: 960, height: 540).pixels
            XCTAssertLessThanOrEqual(maximumChannelDifference(try XCTUnwrap(firstInCycle), wrapped), 1,
                                     "The closed routes must join the same starting position at the next bar.")
        }
    }

    @MainActor
    func testCityRendersWithoutAnalysisAndAfterLandscapePortraitResize() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("Metal unavailable") }
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let renderer = try CitySceneRenderer(device: device)
        var frame = musicalFrame()
        frame.hasAnalysis = 0
        frame.beat = 0; frame.bar = 0
        frame.vocal = 0; frame.drums = 0; frame.bassInstrument = 0; frame.other = 0
        let landscape = try render(renderer, device: device, queue: queue, frame: frame).pixels
        let portrait = try render(renderer, device: device, queue: queue, frame: frame, width: 512, height: 768).pixels
        XCTAssertGreaterThan(Set(portrait).count, 40)
        let resizedBack = try render(renderer, device: device, queue: queue, frame: frame).pixels
        // Recreated MSAA/MPS targets can round a channel by one 8-bit step.
        XCTAssertLessThanOrEqual(maximumChannelDifference(landscape, resizedBack), 1,
                                 "Resizing must preserve the city within 8-bit quantization.")
        try saveEvidence(portrait, width: 512, height: 768, name: "city-portrait")
    }

    @MainActor
    func testMeasureCityGPUTimeAtHDAndRetinaResolution() throws {
        guard let directory = ProcessInfo.processInfo.environment["MUSIC_PRAYER_CITY_EVIDENCE_DIR"] else {
            throw XCTSkip("Performance evidence is collected only when requested.")
        }
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("Metal unavailable") }
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let renderer = try CitySceneRenderer(device: device)
        var frame = musicalFrame()
        var results: [[String: Any]] = []
        for (width, height) in [(1920, 1080), (3840, 2160)] {
            var timings: [Double] = []
            for i in 0..<36 {
                frame.time = 12 + Float(i) / 60
                frame.beatPhase = Float(i % 30) / 30
                frame.beat = exp(-frame.beatPhase * 8)
                let result = try render(renderer, device: device, queue: queue, frame: frame,
                                        width: width, height: height, readPixels: false)
                if i >= 6, result.gpuMilliseconds > 0 { timings.append(result.gpuMilliseconds) }
            }
            XCTAssertEqual(timings.count, 30)
            timings.sort()
            let result: [String: Any] = ["width": width, "height": height, "samples": timings.count,
                "median_gpu_ms": timings[timings.count / 2], "p95_gpu_ms": timings[Int(Double(timings.count - 1) * 0.95)],
                "maximum_gpu_ms": timings.last!]
            results.append(result)
            print("CITY_GPU \(result)")
        }
        let path = URL(fileURLWithPath: directory, isDirectory: true)
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: ["device": device.name, "measurements": results], options: [.prettyPrinted, .sortedKeys])
            .write(to: path.appendingPathComponent("city-gpu-timings.json"))
        frame = musicalFrame()
        let preview = try render(renderer, device: device, queue: queue, frame: frame, width: 1920, height: 1080).pixels
        try saveEvidence(preview, width: 1920, height: 1080, name: "city-preview")
    }

    @MainActor
    func testStrongSpectrumKeepsIlluminatedBuildingsInsideTheView() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("Metal unavailable") }
        let renderer = try CitySceneRenderer(device: device)
        let queue = try XCTUnwrap(device.makeCommandQueue())
        var frame = musicalFrame()
        frame.spectrum = Array(repeating: 1, count: 64)
        frame.vocal = 1; frame.other = 1
        for (width, height) in [(960, 540), (512, 768)] {
            let pixels = try render(renderer, device: device, queue: queue, frame: frame, width: width, height: height).pixels
            let boundary = (0..<width).map { $0 } + (0..<width).map { (height - 1) * width + $0 }
                + (0..<height).map { $0 * width } + (0..<height).map { $0 * width + width - 1 }
            let brightBoundary = boundary.filter { i in
                // Colored studio-floor spill may continue beyond the view; bright
                // emission cores have all three channels, unlike that soft spill.
                min(pixels[i * 4], min(pixels[i * 4 + 1], pixels[i * 4 + 2])) > 70
            }
            XCTAssertTrue(brightBoundary.isEmpty, "Strong bands must not clip the city at \(width)x\(height).")
            try saveEvidence(pixels, width: width, height: height, name: "city-maximum-\(width)")
        }
    }

    private func musicalFrame() -> VisualFrame {
        var frame = VisualFrame()
        frame.style = .spectrumCity
        frame.isPlaying = true
        frame.time = 12; frame.duration = 180; frame.hasAnalysis = 1
        frame.rms = 0.25; frame.bass = 0.3; frame.mid = 0.2; frame.treble = 0.15
        frame.beat = 0.1; frame.bar = 0.05; frame.beatPhase = 0.4; frame.barPhase = 0.6
        frame.vocal = 0.3; frame.drums = 0.3; frame.bassInstrument = 0.35; frame.other = 0.2
        frame.loudness = 0.35; frame.density = 0.3; frame.phraseProgress = 0.2
        frame.spectrum = (0..<64).map { i in
            max(0.05, min(0.98, 0.86 - Float(i) * 0.009 + sin(Float(i) * 0.81) * 0.18))
        }
        return frame
    }

    private func maximumChannelDifference(_ first: [UInt8], _ second: [UInt8]) -> Int {
        guard first.count == second.count else { return Int.max }
        return zip(first, second).reduce(0) { max($0, abs(Int($1.0) - Int($1.1))) }
    }

    private func render(_ renderer: CitySceneRenderer, device: MTLDevice, queue: MTLCommandQueue,
                        frame: VisualFrame, width: Int = 640, height: Int = 384,
                        readPixels: Bool = true, backgroundOpacity: Float = 1) throws -> (pixels: [UInt8], gpuMilliseconds: Double) {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm_srgb,
                                                                  width: width, height: height, mipmapped: false)
        descriptor.storageMode = .private; descriptor.usage = [.renderTarget]
        let output = try XCTUnwrap(device.makeTexture(descriptor: descriptor))
        let command = try XCTUnwrap(queue.makeCommandBuffer())
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = output
        pass.colorAttachments[0].loadAction = .clear; pass.colorAttachments[0].storeAction = .store
        try renderer.encode(command: command, descriptor: pass, frame: frame, size: CGSize(width: width, height: height),
                            backgroundOpacity: backgroundOpacity)
        var buffer: MTLBuffer?
        if readPixels {
            buffer = try XCTUnwrap(device.makeBuffer(length: width * height * 4, options: .storageModeShared))
            let blit = try XCTUnwrap(command.makeBlitCommandEncoder())
            blit.copy(from: output, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                      sourceSize: MTLSize(width: width, height: height, depth: 1), to: buffer!, destinationOffset: 0,
                      destinationBytesPerRow: width * 4, destinationBytesPerImage: width * height * 4)
            blit.endEncoding()
        }
        command.commit(); command.waitUntilCompleted()
        XCTAssertEqual(command.status, .completed, command.error?.localizedDescription ?? "City rendering failed")
        let pixels = buffer.map { Array(UnsafeBufferPointer(start: $0.contents().assumingMemoryBound(to: UInt8.self), count: $0.length)) } ?? []
        return (pixels, (command.gpuEndTime - command.gpuStartTime) * 1_000)
    }

    private func changedPixels(_ a: [UInt8], _ b: [UInt8]) -> Int {
        stride(from: 0, to: min(a.count, b.count), by: 4).reduce(0) { count, i in
            let difference = (0..<3).reduce(0) { $0 + abs(Int(a[i + $1]) - Int(b[i + $1])) }
            return count + (difference > 3 ? 1 : 0)
        }
    }

    private func saveEvidence(_ pixels: [UInt8], width: Int, height: Int, name: String) throws {
        guard let directory = ProcessInfo.processInfo.environment["MUSIC_PRAYER_CITY_EVIDENCE_DIR"] else { return }
        let image = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                                                  bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                                  isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: width * 4, bitsPerPixel: 32))
        let bytes = try XCTUnwrap(image.bitmapData)
        for i in stride(from: 0, to: pixels.count, by: 4) {
            bytes[i] = pixels[i + 2]; bytes[i + 1] = pixels[i + 1]; bytes[i + 2] = pixels[i]; bytes[i + 3] = pixels[i + 3]
        }
        let path = URL(fileURLWithPath: directory, isDirectory: true)
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        try XCTUnwrap(image.representation(using: .png, properties: [:])).write(to: path.appendingPathComponent(name + ".png"))
    }
}
