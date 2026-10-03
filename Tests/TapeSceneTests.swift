import AppKit
import Metal
import simd
import XCTest
@testable import MusicPrayer

final class TapeSceneTests: XCTestCase {
    private var width = 640
    private var height = 480

    func testCassetteHasThicknessFiniteNormalsAndOpenReelHoles() throws {
        let vertices = TapeMesh.makeVertices()
        XCTAssertGreaterThan(vertices.count, 1_000)
        XCTAssertEqual(vertices.count % 3, 0)
        for vertex in vertices {
            XCTAssertTrue((0..<4).allSatisfy { vertex.position[$0].isFinite && vertex.normal[$0].isFinite && vertex.surface[$0].isFinite })
            XCTAssertEqual(simd_length(SIMD3(vertex.normal.x, vertex.normal.y, vertex.normal.z)), 1, accuracy: 0.0001)
        }
        let levels = vertices.map { $0.position.y }
        XCTAssertGreaterThan(try XCTUnwrap(levels.max()) - XCTUnwrap(levels.min()), 0.2,
                             "The cassette must have real model thickness.")
        XCTAssertTrue(Set(vertices.map { Int($0.surface.z) }).isSuperset(of: [0, 2, 3, 4, 5, 6, 7, 8]))
        for hole in [SIMD2<Float>(-0.9, -0.1), SIMD2<Float>(0.9, -0.1)] {
            for offset in [SIMD2<Float>.zero, SIMD2(0.1, 0), SIMD2(0, 0.1)] {
                let point = hole + offset
                let intersections = stride(from: 0, to: vertices.count, by: 3).filter { start in
                    let a = SIMD2(vertices[start].position.x, vertices[start].position.z)
                    let b = SIMD2(vertices[start + 1].position.x, vertices[start + 1].position.z)
                    let c = SIMD2(vertices[start + 2].position.x, vertices[start + 2].position.z)
                    return contains(point, a: a, b: b, c: c)
                }
                XCTAssertTrue(intersections.isEmpty,
                              "A vertical ray through the reel aperture must reach the floor, rather than intersect a covering mesh face.")
            }
        }
    }

    @MainActor
    func testGPUUsesSpectrumRhythmInstrumentsLoudnessStructureAndKey() throws {
        let (device, queue) = try environment()
        let renderer = try TapeSceneRenderer(device: device)
        let frame = musicalFrame()
        let baseline = try render(renderer, device: device, queue: queue, frame: frame)
        XCTAssertGreaterThan(Set(stride(from: 0, to: baseline.count, by: 4).map { baseline[$0] }).count, 30,
                             "The control image must contain a rendered scene.")
        let changes: [(String, (inout VisualFrame) -> Void)] = [
            ("low frequency bands", { $0.spectrum = Array(repeating: 0, count: 64); for index in 0..<8 { $0.spectrum[index] = 1 } }),
            ("high frequency bands", { $0.spectrum = Array(repeating: 0, count: 64); for index in 56..<64 { $0.spectrum[index] = 1 } }),
            ("audio volume", { $0.rms = 0.95 }),
            ("peak", { $0.peak = 1 }),
            ("bass", { $0.bass = 1 }),
            ("mid", { $0.mid = 1 }),
            ("treble", { $0.treble = 1 }),
            ("beat", { $0.beat = 1 }),
            ("bar", { $0.bar = 1 }),
            ("BPM", { $0.tempo = 1.7 }),
            ("pace", { $0.pace = 1 }),
            ("vocal", { $0.vocal = 1 }),
            ("drums", { $0.drums = 1 }),
            ("bass instrument", { $0.bassInstrument = 1 }),
            ("other instrument", { $0.other = 1 }),
            ("momentary loudness", { $0.loudness = 1 }),
            ("short term loudness", { $0.density = 1 }),
            ("section progress", { $0.sectionProgress = 0.85 }),
            ("section transition", { $0.sectionTransition = 1 }),
            ("section separation", { $0.sectionSeparation = 1 }),
            ("section thickness", { $0.sectionThickness = 1 }),
            ("section depth", { $0.sectionDepth = 1 }),
            ("section glow", { $0.sectionGlow = 1 }),
            ("segment", { $0.segmentProgress = 0.85 }),
            ("phrase", { $0.phraseProgress = 0.65 }),
            ("key", { $0.hue = 0.8 }),
            ("major minor mode", { $0.modeBias = -1 }),
            ("beat phase", { $0.beatPhase = 0.25 }),
            ("bar phase", { $0.barPhase = 0.5 }),
            ("track fading", { $0.presence = 0 })
        ]
        for (name, change) in changes {
            var updated = frame
            change(&updated)
            let image = try render(renderer, device: device, queue: queue, frame: updated)
            XCTAssertGreaterThan(changedPixels(baseline, image), 8, "\(name) must change actual presented GPU pixels.")
        }
        var noDrums = frame
        noDrums.drums = 0; noDrums.beat = 0
        let withoutBeat = try render(renderer, device: device, queue: queue, frame: noDrums)
        noDrums.beat = 1
        XCTAssertGreaterThan(changedPixels(withoutBeat, try render(renderer, device: device, queue: queue, frame: noDrums)), 8,
                             "Beat accents must remain visible even when no drums are measured.")
        try saveEvidence(baseline, name: "cassette-analysis")
        if ProcessInfo.processInfo.environment["MUSIC_PRAYER_TAPE_EVIDENCE_DIR"] != nil {
            width = 1440; height = 900
            defer { width = 640; height = 480 }
            try saveEvidence(render(renderer, device: device, queue: queue, frame: frame), name: "cassette-preview")
        }
    }

    func testDriveTeethGuideAperturesWindowAndMoldedOutline() throws {
        let mesh = TapeMesh.makeVertices()
        func hits(_ point: SIMD2<Float>) -> [(height: Float, material: Int)] {
            stride(from: 0, to: mesh.count, by: 3).compactMap { start in
                let a = SIMD2(mesh[start].position.x, mesh[start].position.z)
                let b = SIMD2(mesh[start + 1].position.x, mesh[start + 1].position.z)
                let c = SIMD2(mesh[start + 2].position.x, mesh[start + 2].position.z)
                guard contains(point, a: a, b: b, c: c) else { return nil }
                return ((mesh[start].position.y + mesh[start + 1].position.y + mesh[start + 2].position.y) / 3,
                        Int(mesh[start].surface.z))
            }
        }
        for x: Float in [-0.91, -0.63, 0.63, 0.91] {
            for offset in [SIMD2<Float>.zero, SIMD2(0.025, 0), SIMD2(0, 0.025)] {
                XCTAssertTrue(hits(SIMD2(x, 1.02) + offset).isEmpty,
                              "The capstan and alignment apertures must pass through the head deck and both shell halves.")
            }
        }
        for (x, material) in [(Float(-0.9), 3), (Float(0.9), 4)] {
            let center = SIMD2<Float>(x, -0.1)
            for tooth in 0..<6 {
                let angle = Float(tooth) * .pi / 3
                let drivePoint = center + SIMD2(cos(angle), sin(angle)) * 0.219
                XCTAssertTrue(hits(drivePoint).contains { $0.material == material })
                let gapAngle = angle + .pi / 6
                let gap = center + SIMD2(cos(gapAngle), sin(gapAngle)) * 0.219
                XCTAssertTrue(hits(gap).isEmpty, "The spaces between the drive teeth must remain open.")
            }
        }
        for point in [SIMD2<Float>(-0.36, -0.1), SIMD2(0, -0.1), SIMD2(0.36, -0.1)] {
            let windowHits = hits(point)
            XCTAssertFalse(windowHits.contains { $0.material == 5 || $0.height > 0.30 },
                           "The inspection window must not be covered by the artwork or bridge surface.")
            XCTAssertTrue(windowHits.contains { $0.material == 9 })
            XCTAssertTrue(windowHits.contains { $0.material == 13 || $0.material == 10 || $0.material == 11 })
        }
        XCTAssertTrue(hits(SIMD2(-0.36, -0.1)).contains { $0.material == 10 && $0.height < 0.28 })
        XCTAssertTrue(hits(SIMD2(0.36, -0.1)).contains { $0.material == 11 && $0.height < 0.28 })
        for x: Float in [-1.96, 1.96] {
            XCTAssertTrue(hits(SIMD2(x, 0.54)).isEmpty, "The lower side waist must be cut into the casing outline.")
            XCTAssertFalse(hits(SIMD2(x, 0.25)).isEmpty)
        }
        XCTAssertTrue(hits(SIMD2(1.20, 1.08)).contains { $0.height > 0.35 })
        XCTAssertFalse(hits(SIMD2(1.20, 0.68)).contains { $0.height > 0.35 },
                       "The raised lower deck must widen toward the front, forming a trapezoid.")
    }

    @MainActor
    func testPausedFrameHoldsAndSeekTrackLabelArtworkAndDurationRefresh() throws {
        let (device, queue) = try environment()
        let renderer = try TapeSceneRenderer(device: device)
        var frame = musicalFrame()
        frame.isPlaying = false
        let baseline = try render(renderer, device: device, queue: queue, frame: frame)
        XCTAssertEqual(try render(renderer, device: device, queue: queue, frame: frame), baseline,
                       "Paused output and reel positions must hold without a changed playback clock.")
        let updates: [(String, (inout VisualFrame) throws -> Void)] = [
            ("seek", { $0.time = 49.35 }),
            ("title", { $0.title = "Another song" }),
            ("artist", { $0.artist = "Another artist" }),
            ("duration", { $0.duration = 250 }),
            ("artwork", { $0.artwork = try self.artwork() })
        ]
        let presented = RenderInputs(frame: frame, size: CGSize(width: width, height: height))
        for (name, update) in updates {
            var updated = frame
            try update(&updated)
            XCTAssertFalse(RenderInputs(frame: updated, size: CGSize(width: width, height: height)).matches(presented),
                           "\(name) must invalidate the sleeping renderer.")
            let image = try render(renderer, device: device, queue: queue, frame: updated)
            XCTAssertGreaterThan(changedPixels(baseline, image), 8, "\(name) must refresh visible output while paused.")
            if name == "artwork" { try saveEvidence(image, name: "cassette-artwork") }
        }
        var ribbon = frame
        ribbon.style = .ribbons
        XCTAssertFalse(RenderInputs(frame: ribbon, size: CGSize(width: width, height: height)).matches(presented))
        var playing = frame
        playing.isPlaying = true
        XCTAssertFalse(RenderInputs(frame: playing, size: CGSize(width: width, height: height)).matches(presented))
    }

    @MainActor
    func testTapeTransfersBetweenReelsInsideInspectionWindow() throws {
        let (device, queue) = try environment()
        let renderer = try TapeSceneRenderer(device: device)
        var frame = musicalFrame()
        frame.time = 12; frame.duration = 120
        let supplyFull = try render(renderer, device: device, queue: queue, frame: frame)
        frame.duration = 15
        let takeUpFull = try render(renderer, device: device, queue: queue, frame: frame)
        // Fixed playback time preserves camera, audio and lights. Duration also
        // affects hub angles; the crop excludes both drive apertures.
        // This crop covers the inspection window in the 640x480 control view;
        // changed remaining-time text and the floor progress line are outside it.
        var changed = 0
        for y in 220..<238 {
            for x in 299..<346 {
                let index = (y * width + x) * 4
                let difference = (0..<3).reduce(0) { $0 + abs(Int(supplyFull[index + $1]) - Int(takeUpFull[index + $1])) }
                if difference > 3 { changed += 1 }
            }
        }
        XCTAssertGreaterThan(changed, 20, "The winding must visibly transfer inside the window, independently of reel rotation.")
        if ProcessInfo.processInfo.environment["MUSIC_PRAYER_TAPE_EVIDENCE_DIR"] != nil {
            width = 1440; height = 900
            defer { width = 640; height = 480 }
            for (name, duration) in [("window-supply", 120.0), ("window-middle", 24.0), ("window-takeup", 12.0 / 0.9)] {
                frame.duration = duration
                try saveEvidence(render(renderer, device: device, queue: queue, frame: frame), name: name)
            }
        }
    }

    @MainActor
    func testBothWindowSidesChangeIndependentlyIncludingEarlyTakeUp() throws {
        let (device, queue) = try environment()
        let renderer = try TapeSceneRenderer(device: device)
        var frame = musicalFrame()
        frame.time = 12
        var images = [[UInt8]]()
        for progress: Double in [0.1, 0.25, 0.5, 0.75, 0.9] {
            frame.duration = 12 / progress
            images.append(try render(renderer, device: device, queue: queue, frame: frame))
        }
        // Separate, non-overlapping crops of the window's left and right ends
        // in the fixed 640x480 view. A retreat on the left cannot satisfy the
        // right-side assertion. Playback clock, camera and light stay fixed.
        for (side, xs, ys) in [("supply", 294..<318, 216..<233),
                               ("take-up", 329..<354, 226..<244)] {
            // The coating is visibly dark against the neutral inner backing.
            // Count its presented pixels, rather than accepting arbitrary
            // colour changes that could come from a faint winding edge.
            let coatingPixels = images.map { image in
                ys.reduce(0) { count, y in
                    count + xs.filter { x in
                        let offset = (y * width + x) * 4
                        return (0..<3).reduce(0) { $0 + Int(image[offset + $1]) } < 85 * 3
                    }.count
                }
            }
            for index in 1..<images.count {
                var changed = 0
                for y in ys {
                    for x in xs {
                        let offset = (y * width + x) * 4
                        let difference = (0..<3).reduce(0) {
                            $0 + abs(Int(images[index - 1][offset + $1]) - Int(images[index][offset + $1]))
                        }
                        if difference > 3 { changed += 1 }
                    }
                }
                XCTAssertGreaterThan(changed, 15, "\(side), interval \(index): only \(changed) changing pixels; both winding edges must be visible, including early take-up.")
                if side == "supply" {
                    XCTAssertLessThan(coatingPixels[index], coatingPixels[index - 1], "The visible dark supply coating must recede: \(coatingPixels)")
                } else {
                    XCTAssertGreaterThan(coatingPixels[index], coatingPixels[index - 1], "The visible dark take-up coating must expand: \(coatingPixels)")
                }
            }
            if ProcessInfo.processInfo.environment["MUSIC_PRAYER_TAPE_EVIDENCE_DIR"] != nil {
                print("\(side) dark coating pixels at 10/25/50/75/90%: \(coatingPixels)")
            }
        }
    }

    @MainActor
    func testActualShaderWindingRadiiTransferAndConserveArea() throws {
        let (device, queue) = try environment()
        let url = try XCTUnwrap(Bundle.module.url(forResource: "TapeScene", withExtension: "metal"))
        let source = try String(contentsOf: url, encoding: .utf8) + """
        \n kernel void inspectTapeRadii(device float2 *out [[buffer(0)]], uint id [[thread_position_in_grid]]) {
            out[id] = tapeWindingRadii(float(id)/100);
        }
        """
        let library = try device.makeLibrary(source: source, options: nil)
        let state = try device.makeComputePipelineState(function: XCTUnwrap(library.makeFunction(name: "inspectTapeRadii")))
        let out = try XCTUnwrap(device.makeBuffer(length: 101 * MemoryLayout<SIMD2<Float>>.stride, options: .storageModeShared))
        let command = try XCTUnwrap(queue.makeCommandBuffer())
        let encoder = try XCTUnwrap(command.makeComputeCommandEncoder())
        encoder.setComputePipelineState(state)
        encoder.setBuffer(out, offset: 0, index: 0)
        encoder.dispatchThreads(MTLSize(width: 101, height: 1, depth: 1),
                                threadsPerThreadgroup: MTLSize(width: min(101, state.maxTotalThreadsPerThreadgroup), height: 1, depth: 1))
        encoder.endEncoding(); command.commit(); command.waitUntilCompleted()
        XCTAssertEqual(command.status, .completed)
        let values = out.contents().bindMemory(to: SIMD2<Float>.self, capacity: 101)
        let total = simd_length_squared(values[0])
        for index in 1...100 {
            XCTAssertLessThan(values[index].x, values[index - 1].x)
            XCTAssertGreaterThan(values[index].y, values[index - 1].y)
            XCTAssertEqual(simd_length_squared(values[index]), total, accuracy: 0.000001)
        }
        XCTAssertEqual(values[0].x, values[100].y, accuracy: 0.000001)
        XCTAssertEqual(values[0].y, values[100].x, accuracy: 0.000001)
        XCTAssertEqual(values[50].x, values[50].y, accuracy: 0.000001)
    }

    @MainActor
    func testActualTapePathStaysTangentConnectedAndClearOfGuideHoles() throws {
        let (device, queue) = try environment()
        let url = try XCTUnwrap(Bundle.module.url(forResource: "TapeScene", withExtension: "metal"))
        let source = try String(contentsOf: url, encoding: .utf8) + """
        \n kernel void inspectTapePath(device float4 *out [[buffer(0)]], uint id [[thread_position_in_grid]]) {
            bool left = id%2 == 0;
            float2 radii = tapeWindingRadii(float(id/2)/100);
            float radius = left ? radii.x : radii.y;
            TapeGuide guide = tapeGuidePoint(left,radius);
            out[id*5] = float4(guide.reelContact,guide.rollerContact);
            out[id*5+1] = float4(tapePathPoint(left,radius,1,false),tapePathPoint(left,radius,0,true));
            out[id*5+2] = float4(tapePathPoint(left,radius,1,true),guide.normal);
            out[id*5+3] = float4(radii,0,0);
            out[id*5+4] = float4(tapePathPoint(left,radius,0.5,false),tapePathNormal(left,radius,0.5,true));
        }
        """
        let values = try compute(source, function: "inspectTapePath", count: 202, rows: 5, device: device, queue: queue)
        for index in 0..<202 {
            let side: Float = index%2 == 0 ? -1 : 1
            let center = SIMD2<Float>(side*0.9,-0.1), roller = SIMD2<Float>(side*1.62,1.080)
            let row = index*5, contacts = values[row]
            let a = SIMD2(contacts.x,contacts.y), b = SIMD2(contacts.z,contacts.w)
            let radius = values[row+3][index%2]
            let direction = simd_normalize(b-a)
            XCTAssertEqual(simd_length(a-center),radius,accuracy: 0.00001)
            XCTAssertEqual(simd_length(b-roller),0.12,accuracy: 0.00001)
            XCTAssertEqual(simd_dot(direction,a-center),0,accuracy: 0.00001)
            XCTAssertEqual(simd_dot(direction,b-roller),0,accuracy: 0.00001)
            let join = values[row+1]
            XCTAssertEqual(join.x,join.z,accuracy: 0.00001)
            XCTAssertEqual(join.y,join.w,accuracy: 0.00001)
            let end = values[row+2]
            XCTAssertEqual(end.x,side*1.62,accuracy: 0.00001)
            XCTAssertEqual(end.y,1.200,accuracy: 0.00001)
            XCTAssertEqual(simd_length(SIMD2(end.z,end.w)),1,accuracy: 0.00001)
            // Check every transport segment against all four through-holes.
            for x: Float in [-0.91,-0.63,0.63,0.91] {
                let hole = SIMD2<Float>(x,1.02)
                let t = min(1,max(0,simd_dot(hole-a,b-a)/simd_length_squared(b-a)))
                XCTAssertGreaterThan(simd_length(hole-(a+(b-a)*t)),0.075)
                XCTAssertGreaterThan(simd_length(hole-roller),0.195)
                XCTAssertGreaterThan(abs(hole.y-1.200),0.075)
            }
        }
    }

    @MainActor
    func testFrontTapeCoatingMovesThroughSlotsAndHoldsWhilePaused() throws {
        let (device, queue) = try environment()
        let renderer = try TapeSceneRenderer(device: device)
        width = 1440; height = 900
        defer { width = 640; height = 480 }
        var frame = musicalFrame()
        frame.time = 12; frame.duration = 180; frame.tempo = 0; frame.isPlaying = false
        let before = try render(renderer,device: device,queue: queue,frame: frame)
        XCTAssertEqual(before,try render(renderer,device: device,queue: queue,frame: frame))
        frame.time = 12.06; frame.duration = Double(frame.time)*15
        let after = try render(renderer,device: device,queue: queue,frame: frame)
        try saveEvidence(before,name: "front-tape-before")
        try saveEvidence(after,name: "front-tape-after")
        // Separate crops contain only the five front slots. Tempo zero and
        // fixed time/duration keep the camera and winding geometry stationary.
        func isCoating(_ image: [UInt8], _ x: Int, _ y: Int) -> Bool {
            let i = (y*width+x)*4
            return Int(image[i+2]) > Int(image[i+1])+2 && Int(image[i+1]) > Int(image[i])+2
        }
        for (xs,ys) in [(501..<523,465..<478),(556..<586,485..<501),
                        (619..<673,509..<534),(708..<740,542..<561),(777..<802,568..<582)] {
            let samples = ys.flatMap { y in xs.compactMap { x in isCoating(before,x,y) ? (x,y) : nil } }
            XCTAssertGreaterThan(samples.count,100,"The coating needs readable height inside every front slot.")
            func error(dx: Int,dy: Int) -> Double {
                var total = 0.0, count = 0
                for (x,y) in samples where isCoating(after,x+dx,y+dy) {
                    let a = (y*width+x)*4, b = ((y+dy)*width+x+dx)*4
                    for channel in 0..<3 {
                        let difference = Double(Int(before[a+channel])-Int(after[b+channel]))
                        total += difference*difference; count += 1
                    }
                }
                return count > 60 ? total/Double(count) : .infinity
            }
            let offsets = (-8...8).flatMap { dx in (-4...4).map { dy in (dx,dy,error(dx: dx,dy: dy)) } }
            let best = try XCTUnwrap(offsets.min { $0.2 < $1.2 })
            XCTAssertGreaterThan(best.0,0,"Coating must move toward the right take-up reel.")
            XCTAssertGreaterThan(best.1,0,"World +X projects down/right in this fixed view.")
            XCTAssertLessThan(best.2,error(dx: 0,dy: 0)*0.4,
                              "A translated coating must match much better than a stationary pattern.")
        }
        frame.time = 12; frame.duration = 180
        XCTAssertEqual(before,try render(renderer,device: device,queue: queue,frame: frame),
                       "Seeking back must restore the same coating phase.")
    }

    @MainActor
    func testTransportKeepsLinearSpeedWhileReelRatesFollowWindingRadius() throws {
        let (device, queue) = try environment()
        let url = try XCTUnwrap(Bundle.module.url(forResource: "TapeScene", withExtension: "metal"))
        let source = try String(contentsOf: url, encoding: .utf8) + """
        \n kernel void inspectTapeTransport(device float4 *out [[buffer(0)]], uint id [[thread_position_in_grid]]) {
            float time = 1+float(id)*1.78;
            float3 before = tapeTransportAngles(time-0.1,180);
            float3 after = tapeTransportAngles(time+0.1,180);
            float2 radii = tapeWindingRadii(time/180);
            out[id*2] = float4((after-before)/0.2,0);
            out[id*2+1] = float4(radii,tapeTransportAngles(time,180).xy);
        }
        """
        let values = try compute(source, function: "inspectTapeTransport", count: 101, rows: 2, device: device, queue: queue)
        for index in 0...100 {
            let velocity = values[index*2], winding = values[index*2+1]
            XCTAssertEqual(-velocity.x*winding.x,0.646,accuracy: 0.0002)
            XCTAssertEqual(-velocity.y*winding.y,0.646,accuracy: 0.0002)
            XCTAssertEqual(-velocity.z*0.12,0.646,accuracy: 0.0002)
            XCTAssertLessThan(winding.z,0)
            XCTAssertLessThan(winding.w,0)
        }
        XCTAssertGreaterThan(abs(values[200].x),abs(values[0].x))
        XCTAssertLessThan(abs(values[200].y),abs(values[0].y))
    }

    func testFrontSlotsAreSeparatedByShellPillars() {
        let mesh = TapeMesh.makeVertices()
        func shellAt(_ x: Float, _ y: Float) -> Bool {
            stride(from: 0, to: mesh.count, by: 3).contains { start in
                guard [0,1,2].contains(Int(mesh[start].surface.z)),
                      (0..<3).allSatisfy({ mesh[start+$0].position.z >= 1.179 }) else { return false }
                let points = (0..<3).map { SIMD2(mesh[start+$0].position.x,mesh[start+$0].position.y) }
                return contains(SIMD2(x,y),a: points[0],b: points[1],c: points[2])
            }
        }
        for x: Float in [-1.35,-0.75,0,0.75,1.35] {
            XCTAssertFalse(shellAt(x,0.24),"Each front slot must open through the shell.")
        }
        for x: Float in [-1.08,-0.43,0.43,1.08,1.72] {
            XCTAssertTrue(shellAt(x,0.24),"The slots need molded separating pillars and closed ends.")
        }
    }

    @MainActor
    private func compute(_ source: String, function: String, count: Int, rows: Int,
                         device: MTLDevice, queue: MTLCommandQueue) throws -> [SIMD4<Float>] {
        let library = try device.makeLibrary(source: source, options: nil)
        let state = try device.makeComputePipelineState(function: XCTUnwrap(library.makeFunction(name: function)))
        let out = try XCTUnwrap(device.makeBuffer(length: count*rows*MemoryLayout<SIMD4<Float>>.stride, options: .storageModeShared))
        let command = try XCTUnwrap(queue.makeCommandBuffer())
        let encoder = try XCTUnwrap(command.makeComputeCommandEncoder())
        encoder.setComputePipelineState(state); encoder.setBuffer(out,offset: 0,index: 0)
        encoder.dispatchThreads(MTLSize(width: count,height: 1,depth: 1),
                                threadsPerThreadgroup: MTLSize(width: min(count,state.maxTotalThreadsPerThreadgroup),height: 1,depth: 1))
        encoder.endEncoding(); command.commit(); command.waitUntilCompleted()
        XCTAssertEqual(command.status,.completed,command.error?.localizedDescription ?? "Transport probe failed")
        return Array(UnsafeBufferPointer(start: out.contents().bindMemory(to: SIMD4<Float>.self,capacity: count*rows),count: count*rows))
    }

    private func musicalFrame() -> VisualFrame {
        var frame = VisualFrame()
        frame.style = .cassette
        frame.time = 12.25
        frame.duration = 180
        frame.title = "Sample track"
        frame.artist = "Sample artist"
        frame.isPlaying = true
        frame.hasAnalysis = 1
        frame.rms = 0.45; frame.peak = 0.35
        frame.bass = 0.3; frame.mid = 0.3; frame.treble = 0.3
        frame.beat = 0.25; frame.bar = 0.25
        frame.pace = 0.4; frame.vocal = 0.3; frame.drums = 0.3
        frame.bassInstrument = 0.3; frame.other = 0.3
        frame.loudness = 0.3; frame.density = 0.3
        frame.sectionProgress = 0.2; frame.sectionTransition = 0.2
        frame.segmentProgress = 0.2; frame.phraseProgress = 0.15
        frame.hue = 0.48; frame.modeBias = 0.5
        frame.spectrum = (0..<64).map { 0.25 + Float($0 % 9) * 0.04 }
        return frame
    }

    @MainActor
    private func environment() throws -> (MTLDevice, MTLCommandQueue) {
        _ = NSApplication.shared
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("Metal unavailable") }
        return (device, try XCTUnwrap(device.makeCommandQueue()))
    }

    private func render(_ renderer: TapeSceneRenderer, device: MTLDevice, queue: MTLCommandQueue,
                        frame: VisualFrame) throws -> [UInt8] {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: width, height: height, mipmapped: false)
        descriptor.storageMode = .private
        descriptor.usage = [.renderTarget, .shaderRead]
        let scene = try XCTUnwrap(device.makeTexture(descriptor: descriptor))
        let outputDescriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm_srgb, width: width, height: height, mipmapped: false)
        outputDescriptor.storageMode = .private
        outputDescriptor.usage = [.renderTarget]
        let output = try XCTUnwrap(device.makeTexture(descriptor: outputDescriptor))
        let buffer = try XCTUnwrap(device.makeBuffer(length: width * height * 4, options: .storageModeShared))
        let command = try XCTUnwrap(queue.makeCommandBuffer())
        try renderer.encode(command: command, target: scene, frame: frame, size: CGSize(width: width, height: height))
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = output
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        try renderer.encodePresentation(command: command, descriptor: pass, scene: scene)
        let blit = try XCTUnwrap(command.makeBlitCommandEncoder())
        blit.copy(from: output, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                  sourceSize: MTLSize(width: width, height: height, depth: 1), to: buffer, destinationOffset: 0,
                  destinationBytesPerRow: width * 4, destinationBytesPerImage: width * height * 4)
        blit.endEncoding()
        command.commit()
        command.waitUntilCompleted()
        XCTAssertEqual(command.status, .completed, command.error?.localizedDescription ?? "Cassette rendering failed")
        return Array(UnsafeBufferPointer(start: buffer.contents().assumingMemoryBound(to: UInt8.self), count: buffer.length))
    }

    private func changedPixels(_ a: [UInt8], _ b: [UInt8]) -> Int {
        stride(from: 0, to: min(a.count, b.count), by: 4).reduce(0) { count, index in
            let difference = (0..<3).reduce(0) { $0 + abs(Int(a[index + $1]) - Int(b[index + $1])) }
            return count + (difference > 3 ? 1 : 0)
        }
    }

    private func contains(_ p: SIMD2<Float>, a: SIMD2<Float>, b: SIMD2<Float>, c: SIMD2<Float>) -> Bool {
        func cross(_ x: SIMD2<Float>, _ y: SIMD2<Float>) -> Float { x.x * y.y - x.y * y.x }
        let area = cross(b - a, c - a)
        guard abs(area) > 0.000001 else { return false }
        let u = cross(b - p, c - p) / area
        let v = cross(c - p, a - p) / area
        let w = 1 - u - v
        return min(u, min(v, w)) >= -0.00001
    }

    private func artwork() throws -> Data {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 32, pixelsHigh: 32,
                                                    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                                    isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 128, bitsPerPixel: 32))
        let pixels = try XCTUnwrap(bitmap.bitmapData)
        for index in 0..<(32 * 32) {
            pixels[index * 4] = 235; pixels[index * 4 + 1] = 45; pixels[index * 4 + 2] = 22; pixels[index * 4 + 3] = 255
        }
        return try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
    }

    private func saveEvidence(_ pixels: [UInt8], name: String) throws {
        guard let directory = ProcessInfo.processInfo.environment["MUSIC_PRAYER_TAPE_EVIDENCE_DIR"] else { return }
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                                                    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                                    isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: width * 4, bitsPerPixel: 32))
        let destination = try XCTUnwrap(bitmap.bitmapData)
        for index in stride(from: 0, to: pixels.count, by: 4) {
            destination[index] = pixels[index + 2]; destination[index + 1] = pixels[index + 1]
            destination[index + 2] = pixels[index]; destination[index + 3] = pixels[index + 3]
        }
        let url = URL(fileURLWithPath: directory, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: url.appendingPathComponent(name + ".png"))
    }
}
