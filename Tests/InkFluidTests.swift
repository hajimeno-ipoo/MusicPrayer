import XCTest
import Metal
import simd
@testable import MusicPrayer

final class InkFluidTests: XCTestCase {
    private let resolution = SIMD3<Int>(40, 36, 24)

    func testSeedIsColoredVolumetricDensityWithDepthAndConcentratedClouds() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let fluid = try InkFluid(device: device, resolution: resolution)
        try advance(fluid, queue: queue, frame: VisualFrame())
        let pixels = try read(fluid.densityTexture, queue: queue)
        var violetLeft: Float = 0, pinkRight: Float = 0, depthDifference: Float = 0
        var samples = 0
        for z in 0..<resolution.z {
            for y in 0..<resolution.y {
                for x in 0..<resolution.x {
                    let p = pixels[(z * resolution.y + y) * resolution.x + x]
                    XCTAssertTrue(p.x.isFinite && p.y.isFinite && p.z.isFinite && p.w.isFinite)
                    XCTAssertGreaterThanOrEqual(p.w, 0)
                    XCTAssertEqual(p.w, p.x + p.y + p.z, accuracy: 0.005)
                    if x < resolution.x / 2 { violetLeft += p.y }
                    if x >= resolution.x / 2 { pinkRight += p.z }
                    if z < resolution.z - 1 {
                        depthDifference += abs(p.w - pixels[((z + 1) * resolution.y + y) * resolution.x + x].w)
                    }
                    samples += 1
                }
            }
        }
        XCTAssertGreaterThan(violetLeft / Float(samples), 0.03)
        XCTAssertGreaterThan(pinkRight / Float(samples), 0.003)
        XCTAssertGreaterThan(depthDifference / Float(samples), 0.003,
                             "The cloud must vary through depth, rather than extrude a flat image.")
    }

    func testActualGPUAdvectionAndAudioForcesChangeDensityAndVelocity() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let calm = try InkFluid(device: device, resolution: resolution)
        let active = try InkFluid(device: device, resolution: resolution)
        var quiet = VisualFrame(), music = VisualFrame()
        music.rms = 0.9; music.bass = 1; music.bassInstrument = 1; music.vocal = 1
        music.drums = 1; music.treble = 1
        try advance(calm, queue: queue, frame: quiet)
        try advance(active, queue: queue, frame: music)
        let original = try read(calm.densityTexture, queue: queue)
        for step in 1...16 {
            quiet.time = Float(step) / 30
            music.time = quiet.time
            music.beat = step == 4 || step == 10 ? 1 : 0
            try advance(calm, queue: queue, frame: quiet)
            try advance(active, queue: queue, frame: music)
        }
        let calmDensity = try read(calm.densityTexture, queue: queue)
        let activeDensity = try read(active.densityTexture, queue: queue)
        let calmVelocity = try read(calm.velocityTexture, queue: queue)
        let activeVelocity = try read(active.velocityTexture, queue: queue)
        let moved = zip(original, calmDensity).reduce(Float(0)) { $0 + abs($1.0.w - $1.1.w) } / Float(original.count)
        let pinkGain = zip(calmDensity, activeDensity).reduce(Float(0)) { $0 + $1.1.z - $1.0.z } / Float(original.count)
        func speed(_ values: [SIMD4<Float>]) -> Float {
            values.reduce(Float(0)) { $0 + simd_length(SIMD3($1.x, $1.y, $1.z)) } / Float(values.count)
        }
        XCTAssertGreaterThan(moved, 0.0005, "Advection must move the dye volume itself.")
        XCTAssertGreaterThan(pinkGain, 0.0002, "Singing must inject more pink dye, not only recolor the final image.")
        XCTAssertGreaterThan(speed(activeVelocity), speed(calmVelocity) + 0.005,
                             "Bass and drum forces must change the actual velocity field.")
        for p in activeDensity {
            XCTAssertTrue(p.x.isFinite && p.y.isFinite && p.z.isFinite && p.w.isFinite)
            XCTAssertTrue((0...3).contains(p.x) && (0...3).contains(p.y) && (0...3).contains(p.z))
        }
        for z in 0..<resolution.z {
            for y in 0..<resolution.y {
                for x in 0..<resolution.x {
                    let v = activeVelocity[(z * resolution.y + y) * resolution.x + x]
                    XCTAssertTrue(v.x.isFinite && v.y.isFinite && v.z.isFinite)
                    XCTAssertTrue(abs(v.x) <= 3 && abs(v.y) <= 3 && abs(v.z) <= 3)
                    if x == 0 || x + 1 == resolution.x { XCTAssertEqual(v.x, 0) }
                    if y == 0 || y + 1 == resolution.y { XCTAssertEqual(v.y, 0) }
                    if z == 0 || z + 1 == resolution.z { XCTAssertEqual(v.z, 0) }
                }
            }
        }
    }

    func testPauseAndDuplicateDisplayFramesUseOnlyTheMusicClock() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let sixty = try InkFluid(device: device, resolution: resolution)
        let oneTwenty = try InkFluid(device: device, resolution: resolution)
        var frame = VisualFrame()
        frame.rms = 0.7; frame.vocal = 0.8; frame.bass = 0.6; frame.drums = 0.9
        for step in 0...16 {
            frame.time = Float(step) / 60
            frame.beat = step == 6 ? 1 : 0
            try advance(sixty, queue: queue, frame: frame, elapsed: 1 / 60)
            try advance(oneTwenty, queue: queue, frame: frame, elapsed: 1 / 120, repetitions: 2)
        }
        let sixtyDensity = try read(sixty.densityTexture, queue: queue)
        let sixtyVelocity = try read(sixty.velocityTexture, queue: queue)
        XCTAssertTrue(sixtyDensity == (try read(oneTwenty.densityTexture, queue: queue)))
        XCTAssertTrue(sixtyVelocity == (try read(oneTwenty.velocityTexture, queue: queue)))
        try advance(sixty, queue: queue, frame: frame, elapsed: 5, repetitions: 20)
        XCTAssertTrue(sixtyDensity == (try read(sixty.densityTexture, queue: queue)), "Pause must hold every dye voxel.")
        XCTAssertTrue(sixtyVelocity == (try read(sixty.velocityTexture, queue: queue)), "Pause must hold velocity too.")
    }

    func testVocalBassDrumOtherAndTrebleEachChangeTheirOwnGPUFlow() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let calm = try InkFluid(device: device, resolution: resolution)
        let singing = try InkFluid(device: device, resolution: resolution)
        let bass = try InkFluid(device: device, resolution: resolution)
        let drums = try InkFluid(device: device, resolution: resolution)
        let treble = try InkFluid(device: device, resolution: resolution)
        let other = try InkFluid(device: device, resolution: resolution)
        for step in 0...8 {
            var frame = VisualFrame()
            frame.time = Float(step) / 30
            try advance(calm, queue: queue, frame: frame)
            frame.vocal = 1
            try advance(singing, queue: queue, frame: frame)
            frame.vocal = 0; frame.bass = 1
            try advance(bass, queue: queue, frame: frame)
            frame.bass = 0; frame.drums = 1; frame.beat = step == 8 ? 1 : 0
            try advance(drums, queue: queue, frame: frame)
            frame.drums = 0; frame.beat = 0; frame.treble = 1
            try advance(treble, queue: queue, frame: frame)
            frame.treble = 0; frame.other = 1
            try advance(other, queue: queue, frame: frame)
        }
        let calmDye = try read(calm.densityTexture, queue: queue)
        let vocalDye = try read(singing.densityTexture, queue: queue)
        let pinkGain = zip(calmDye, vocalDye).reduce(Float(0)) { $0 + $1.1.z - $1.0.z } / Float(calmDye.count)
        XCTAssertGreaterThan(pinkGain, 0.0002, "Vocal alone must add pink concentration.")
        let quietVelocity = try read(calm.velocityTexture, queue: queue)
        let bassVelocity = try read(bass.velocityTexture, queue: queue)
        var liftGain: Float = 0, sourceCount = 0
        for z in 0..<resolution.z {
            for y in 0..<resolution.y / 3 {
                for x in 0..<resolution.x {
                    let worldX = InkFluid.domainMinimum.x + (Float(x) + 0.5)
                        * (InkFluid.domainMaximum.x - InkFluid.domainMinimum.x) / Float(resolution.x)
                    let worldZ = -1.8 + (Float(z) + 0.5) * 3.6 / Float(resolution.z)
                    if abs(worldX + 1.45) < 0.7 && abs(worldZ - 0.1) < 0.5 {
                        let index = (z * resolution.y + y) * resolution.x + x
                        liftGain += bassVelocity[index].y - quietVelocity[index].y
                        sourceCount += 1
                    }
                }
            }
        }
        XCTAssertGreaterThan(liftGain / Float(sourceCount), 0.002,
                             "Bass alone must lift the thick left plume.")
        let drumVelocity = try read(drums.velocityTexture, queue: queue)
        func speed(_ values: [SIMD4<Float>]) -> Float {
            values.reduce(Float(0)) { $0 + simd_length(SIMD3($1.x, $1.y, $1.z)) } / Float(values.count)
        }
        XCTAssertGreaterThan(speed(drumVelocity), speed(quietVelocity) + 0.003,
                             "A drum/beat onset must produce a velocity impulse without vocal or bass.")
        let highVelocity = try read(treble.velocityTexture, queue: queue)
        // Differences between adjacent velocities measure fine spatial flow rather than hue.
        var fineChange: Float = 0, fineCount = 0
        for z in 0..<resolution.z {
            for y in 0..<resolution.y {
                for x in 1..<resolution.x {
                    let i = (z * resolution.y + y) * resolution.x + x
                    let deltaA = highVelocity[i] - highVelocity[i - 1]
                    let deltaB = quietVelocity[i] - quietVelocity[i - 1]
                    fineChange += simd_length(deltaA - deltaB)
                    fineCount += 1
                }
            }
        }
        XCTAssertGreaterThan(fineChange / Float(fineCount), 0.0005,
                             "Treble alone must alter the small eddies in actual spatial velocity.")
        let otherVelocity = try read(other.velocityTexture, queue: queue)
        let otherDye = try read(other.densityTexture, queue: queue)
        let otherFlowDifference = zip(quietVelocity, otherVelocity).reduce(Float(0)) { $0 + simd_length($1.1 - $1.0) } / Float(otherVelocity.count)
        let otherDensityDifference = zip(calmDye, otherDye).reduce(Float(0)) { $0 + simd_length($1.1 - $1.0) } / Float(otherDye.count)
        XCTAssertGreaterThan(otherFlowDifference, 0.005, "Other instruments must stir the broad flow.")
        XCTAssertGreaterThan(otherDensityDifference, 0.00002, "Other instruments must move actual pigment.")
    }

    func testSeekingAndChangingTracksReseedWithoutSimulatingSkippedMinutes() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let fluid = try InkFluid(device: device, resolution: resolution)
        var frame = VisualFrame()
        frame.trackID = UUID()
        try advance(fluid, queue: queue, frame: frame)
        let seed = try read(fluid.densityTexture, queue: queue)
        frame.rms = 1; frame.vocal = 1
        for step in 1...4 {
            frame.time = Float(step) / 30
            try advance(fluid, queue: queue, frame: frame)
        }
        XCTAssertFalse(seed == (try read(fluid.densityTexture, queue: queue)))
        frame.time = 180
        try advance(fluid, queue: queue, frame: frame)
        XCTAssertTrue(seed == (try read(fluid.densityTexture, queue: queue)))
        frame.time += 1 / 15
        try advance(fluid, queue: queue, frame: frame)
        XCTAssertFalse(seed == (try read(fluid.densityTexture, queue: queue)))
        frame.trackID = UUID()
        try advance(fluid, queue: queue, frame: frame)
        XCTAssertTrue(seed == (try read(fluid.densityTexture, queue: queue)), "Track identity must reset even if the clock is unchanged.")
        frame.rms = .nan; frame.bass = .infinity; frame.drums = .nan
        frame.vocal = .infinity; frame.treble = -.infinity
        frame.time += 1 / 30
        try advance(fluid, queue: queue, frame: frame)
        XCTAssertTrue(try read(fluid.densityTexture, queue: queue).allSatisfy {
            $0.x.isFinite && $0.y.isFinite && $0.z.isFinite && $0.w.isFinite
        })
    }

    func testMusicUnderstandingSignalsIndividuallyMoveTheActualGPUVolume() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let queue = try XCTUnwrap(device.makeCommandQueue())
        var base = VisualFrame()
        base.hasAnalysis = 1; base.rms = 0.55; base.bass = 0.65; base.vocal = 0.7
        base.drums = 0.5; base.treble = 0.25
        let variants: [(String, (inout VisualFrame) -> Void)] = [
            ("Pace", { $0.pace = 1 }),
            ("Beat phase", { $0.beatPhase = 0.5 }),
            ("Bar phase", { $0.barPhase = 0.7 }),
            ("Downbeat", { $0.bar = 1 }),
            ("Tempo", { $0.tempo = 2 }),
            ("Phrase", { $0.phraseProgress = 0.65 }),
            ("Segment", { $0.segmentProgress = 0.7 }),
            ("Section", { $0.sectionProgress = 0.7 }),
            ("Section separation", { $0.sectionSeparation = 1 }),
            ("Section thickness", { $0.sectionThickness = 1 }),
            ("Section depth", { $0.sectionDepth = 1 }),
            ("Section change", { $0.sectionTransition = 1 }),
            ("Song-relative density", { $0.density = 1 }),
            ("Positive key hue", { $0.hue = 0.033 }),
            ("Negative key hue", { $0.hue = -0.033 }),
            ("Mode", { $0.modeBias = -1 })
        ]
        func run(_ frame: VisualFrame) throws -> ([SIMD4<Float>], [SIMD4<Float>]) {
            let fluid = try InkFluid(device: device, resolution: resolution)
            for step in 0...12 {
                var current = frame
                current.time = Float(step) / 30
                try advance(fluid, queue: queue, frame: current)
            }
            return (try read(fluid.densityTexture, queue: queue), try read(fluid.velocityTexture, queue: queue))
        }
        let (baseDye, baseVelocity) = try run(base)
        for (name, change) in variants {
            var variant = base
            change(&variant)
            let (dye, velocity) = try run(variant)
            let densityDifference = zip(baseDye, dye).reduce(Float(0)) { $0 + simd_length($1.1 - $1.0) } / Float(dye.count)
            let velocityDifference = zip(baseVelocity, velocity).reduce(Float(0)) { $0 + simd_length($1.1 - $1.0) } / Float(velocity.count)
            XCTAssertGreaterThan(densityDifference, 0.00002, "\(name) must move actual pigment, not only alter the final color.")
            XCTAssertGreaterThan(velocityDifference, 0.00025, "\(name) must influence the projected flow.")
        }
        // An unavailable analysis must not synthesize phrase, key or section flow.
        base.hasAnalysis = 0
        var unavailable = base
        for (_, change) in variants { change(&unavailable) }
        let neutral = try run(base), ignored = try run(unavailable)
        XCTAssertTrue(neutral.0 == ignored.0, "Unavailable structural analysis must leave every pigment voxel identical.")
        XCTAssertTrue(neutral.1 == ignored.1, "Unavailable structural analysis must leave every projected velocity identical.")
    }

    func testVocalAdvancesPinkFlowAndStrongMusicRemainsBoundedWithOpenWater() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let quiet = try InkFluid(device: device, resolution: resolution)
        let singing = try InkFluid(device: device, resolution: resolution)
        for step in 0...30 {
            var frame = VisualFrame()
            frame.time = Float(step) / 30
            try advance(quiet, queue: queue, frame: frame)
            frame.vocal = 1
            try advance(singing, queue: queue, frame: frame)
        }
        let quietVelocity = try read(quiet.velocityTexture, queue: queue)
        let vocalVelocity = try read(singing.velocityTexture, queue: queue)
        var forwardGain: Float = 0, count = 0
        for z in 0..<resolution.z {
            for y in 0..<resolution.y {
                for x in 0..<resolution.x {
                    let p = InkFluid.domainMinimum + (SIMD3(Float(x), Float(y), Float(z)) + 0.5)
                        / SIMD3(Float(resolution.x), Float(resolution.y), Float(resolution.z))
                        * (InkFluid.domainMaximum - InkFluid.domainMinimum)
                    if abs(p.x - 1.75) < 0.55 && abs(p.y - 1.2) < 0.55 && abs(p.z - 0.2) < 0.5 {
                        let i = (z * resolution.y + y) * resolution.x + x
                        forwardGain += vocalVelocity[i].z - quietVelocity[i].z
                        count += 1
                    }
                }
            }
        }
        XCTAssertGreaterThan(forwardGain / Float(count), 0.05, "Singing must visibly propel the pink plume toward the camera.")
        // Sustained loud music exercises projected rings, source movement and fade over 15 seconds.
        var music = VisualFrame()
        music.hasAnalysis = 1; music.rms = 1; music.bass = 1; music.vocal = 1
        music.drums = 1; music.treble = 1; music.pace = 1; music.density = 1
        for batch in 0..<15 {
            let command = try XCTUnwrap(queue.makeCommandBuffer())
            for step in (batch * 30 + 31)...(batch * 30 + 60) {
                music.time = Float(step) / 30
                music.beat = step % 15 == 0 ? 1 : 0
                music.bar = step % 60 < 6 ? 1 : 0
                music.beatPhase = Float(step % 15) / 15
                music.barPhase = Float(step % 60) / 60
                music.phraseProgress = Float(step % 120) / 120
                music.sectionProgress = Float(step % 240) / 240
                try singing.encode(command: command, frame: music, elapsed: 1 / 30)
            }
            command.commit(); command.waitUntilCompleted()
            XCTAssertNil(command.error)
        }
        let density = try read(singing.densityTexture, queue: queue)
        let velocity = try read(singing.velocityTexture, queue: queue)
        XCTAssertTrue(density.allSatisfy { $0.x.isFinite && $0.y.isFinite && $0.z.isFinite && $0.w.isFinite
            && (0...3).contains($0.x) && (0...3).contains($0.y) && (0...3).contains($0.z) })
        XCTAssertTrue(velocity.allSatisfy { $0.x.isFinite && $0.y.isFinite && $0.z.isFinite
            && abs($0.x) <= 3 && abs($0.y) <= 3 && abs($0.z) <= 3 })
        let openFraction = Float(density.filter { $0.w < 0.05 }.count) / Float(density.count)
        XCTAssertGreaterThan(openFraction, 0.12, "Strong flow must retain open volume instead of filling the box with an opaque wall.")
    }

    func testSixGesturesChangeProjectedDirectionAndAdvectDifferentVolumes() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let queue = try XCTUnwrap(device.makeCommandQueue())
        var frame = VisualFrame()
        frame.rms = 0.45; frame.mid = 0.5; frame.bass = 0.25; frame.treble = 0.25
        func simulate(_ motion: InkMotionState, start: Float = 0) throws -> ([SIMD4<Float>], [SIMD4<Float>]) {
            let fluid = try InkFluid(device: device, resolution: resolution)
            for step in 0...24 {
                frame.time = start + Float(step) / 30
                try advance(fluid, queue: queue, frame: frame, motion: motion)
            }
            return (try read(fluid.densityTexture, queue: queue), try read(fluid.velocityTexture, queue: queue))
        }
        let neutral = try simulate(InkMotionState())
        var results = [InkMotionKind: ([SIMD4<Float>], [SIMD4<Float>])]()
        for kind in InkMotionKind.allCases {
            let result = try simulate(.focused(kind, activity: 0.75, peak: 0.45))
            results[kind] = result
            let dyeDifference = zip(neutral.0, result.0).reduce(Float(0)) { $0 + simd_length($1.1 - $1.0) } / Float(result.0.count)
            let velocityDifference = zip(neutral.1, result.1).reduce(Float(0)) { $0 + simd_length($1.1 - $1.0) } / Float(result.1.count)
            XCTAssertGreaterThan(dyeDifference, 0.001, "\(kind) must advect pigment through the volume.")
            XCTAssertGreaterThan(velocityDifference, 0.02, "\(kind) must survive the pressure projection.")
        }
        func localGain(_ kind: InkMotionKind, center: SIMD3<Float>, axis: SIMD3<Float>) throws -> Float {
            let values = try XCTUnwrap(results[kind]).1
            var sum: Float = 0, count: Float = 0
            for z in 0..<resolution.z { for y in 0..<resolution.y { for x in 0..<resolution.x {
                let world = worldPosition(x, y, z)
                if simd_length(world - center) < 0.45 {
                    let i = (z * resolution.y + y) * resolution.x + x
                    sum += simd_dot(SIMD3(values[i].x - neutral.1[i].x, values[i].y - neutral.1[i].y,
                                         values[i].z - neutral.1[i].z), axis)
                    count += 1
                }
            } } }
            return sum / max(1, count)
        }
        XCTAssertGreaterThan(try localGain(.suction, center: SIMD3(-1.2, 2.5, -0.1), axis: SIMD3(1, 0, 0)), 0.05)
        XCTAssertGreaterThan(try localGain(.eruption, center: SIMD3(0, 2.25, -0.75), axis: SIMD3(0, 0, 1)), 0.05)
        XCTAssertGreaterThan(try localGain(.collision, center: SIMD3(-2.05, 1.65, 0.15), axis: SIMD3(1, 0, 0)), 0.05)
        XCTAssertGreaterThan(try localGain(.collision, center: SIMD3(2.05, 1.65, 0.15), axis: SIMD3(-1, 0, 0)), 0.05)
        XCTAssertGreaterThan(try localGain(.breathing, center: SIMD3(0, 2.5, -0.1), axis: SIMD3(0, 1, 0)), 0.05)
        XCTAssertGreaterThan(try localGain(.sinking, center: SIMD3(0, 2.4, 0.05), axis: SIMD3(0, -1, 0)), 0.05)
        XCTAssertGreaterThan(try localGain(.sinking, center: SIMD3(0.9, 0.35, 0.05), axis: SIMD3(1, 0, 0)), 0.03,
                             "Sinking must turn outward along the floor.")
        XCTAssertGreaterThan(try localGain(.split, center: SIMD3(-0.9, 2.8, 0), axis: SIMD3(-1, 0, 0)), 0.05)
        // The same breathing gesture reverses its actual velocity later in its cycle.
        let contracting = try simulate(.focused(.breathing, activity: 0.75, peak: 0.45), start: 1.8)
        let expanding = try XCTUnwrap(results[.breathing])
        var gain: Float = 0, count: Float = 0
        for z in 0..<resolution.z { for y in 0..<resolution.y { for x in 0..<resolution.x {
            if simd_length(worldPosition(x, y, z) - SIMD3(0, 2.5, -0.1)) < 0.45 {
                let i = (z * resolution.y + y) * resolution.x + x
                gain += expanding.1[i].y - contracting.1[i].y
                count += 1
            }
        } } }
        XCTAssertGreaterThan(gain / max(1, count), 0.15, "Breathing must reverse flow, rather than only brighten a rising plume.")
        let rejoining = try simulate(.focused(.split, activity: 0.75, peak: 0.45), start: 2.7)
        let splitting = try XCTUnwrap(results[.split])
        var returnGain: Float = 0, returnCount: Float = 0
        for z in 0..<resolution.z { for y in 0..<resolution.y { for x in 0..<resolution.x {
            if simd_length(worldPosition(x, y, z) - SIMD3(-0.9, 2.8, 0)) < 0.45 {
                let i = (z * resolution.y + y) * resolution.x + x
                returnGain += rejoining.1[i].x - splitting.1[i].x
                returnCount += 1
            }
        } } }
        XCTAssertGreaterThan(returnGain / max(1, returnCount), 0.15,
                             "Split must reverse toward the center during the rejoining phase.")
        for first in InkMotionKind.allCases { for second in InkMotionKind.allCases where second.rawValue > first.rawValue {
            let a = try XCTUnwrap(results[first]), b = try XCTUnwrap(results[second])
            let difference = zip(a.0, b.0).reduce(Float(0)) { $0 + simd_length($1.1 - $1.0) } / Float(a.0.count)
            XCTAssertGreaterThan(difference, 0.001, "\(first) and \(second) must result in different dye volumes.")
        } }
    }

    func testEverySpectrumBinHasItsOwnLocalProjectedFlowAndPigment() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let motion = InkMotionState.focused(.suction, activity: 0.5, peak: 0)
        func simulate(_ band: Int?) throws -> ([SIMD4<Float>], [SIMD4<Float>]) {
            let fluid = try InkFluid(device: device, resolution: resolution)
            var frame = VisualFrame()
            if let band { frame.spectrum[band] = 1 }
            for step in 0...12 {
                frame.time = Float(step) / 30
                try advance(fluid, queue: queue, frame: frame, motion: motion)
            }
            return (try read(fluid.densityTexture, queue: queue), try read(fluid.velocityTexture, queue: queue))
        }
        let baseline = try simulate(nil)
        var centroids = [Int: SIMD3<Float>]()
        for band in 0..<64 {
            let result = try simulate(band)
            let densityDifference = zip(baseline.0, result.0).reduce(Float(0)) { $0 + simd_length($1.1 - $1.0) } / Float(result.0.count)
            let velocityDifference = zip(baseline.1, result.1).reduce(Float(0)) { $0 + simd_length($1.1 - $1.0) } / Float(result.1.count)
            XCTAssertGreaterThan(densityDifference, 0.00002, "FFT bin \(band) must change actual pigment.")
            XCTAssertGreaterThan(velocityDifference, 0.00002, "FFT bin \(band) must survive pressure projection.")
            if band == 0 || band == 7 || band == 56 || band == 63 {
                var weighted = SIMD3<Float>.zero, total: Float = 0
                for z in 0..<resolution.z { for y in 0..<resolution.y { for x in 0..<resolution.x {
                    let i = (z * resolution.y + y) * resolution.x + x
                    let weight = simd_length(result.1[i] - baseline.1[i])
                    weighted += worldPosition(x, y, z) * weight
                    total += weight
                } } }
                centroids[band] = weighted / max(total, 0.00001)
            }
        }
        XCTAssertGreaterThan(try XCTUnwrap(centroids[7]).x - XCTUnwrap(centroids[0]).x, 3.0,
                             "Distant horizontal bins must stir distant positions.")
        XCTAssertGreaterThan(try XCTUnwrap(centroids[56]).y - XCTUnwrap(centroids[0]).y, 2.0,
                             "Distant vertical bins must stir distant positions.")
        XCTAssertGreaterThan(try simd_length(XCTUnwrap(centroids[63]) - XCTUnwrap(centroids[0])), 4.0)
    }

    func testAllGesturesRemainFiniteAndKeepOpenVolumeDuringStrongSpectrum() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let queue = try XCTUnwrap(device.makeCommandQueue())
        for kind in InkMotionKind.allCases {
            let fluid = try InkFluid(device: device, resolution: resolution)
            var frame = VisualFrame()
            frame.rms = 1; frame.peak = 1; frame.bass = 1; frame.mid = 1; frame.treble = 1
            frame.spectrum = Array(repeating: 1, count: 64)
            let motion = InkMotionState.focused(kind, activity: 1, peak: 1)
            try advance(fluid, queue: queue, frame: frame, motion: motion)
            for batch in 0..<10 {
                let command = try XCTUnwrap(queue.makeCommandBuffer())
                for step in (batch * 30 + 1)...(batch * 30 + 30) {
                    frame.time = Float(step) / 30
                    try fluid.encode(command: command, frame: frame, elapsed: 1 / 30, motion: motion)
                }
                command.commit(); command.waitUntilCompleted()
                XCTAssertNil(command.error)
            }
            let dye = try read(fluid.densityTexture, queue: queue)
            let velocity = try read(fluid.velocityTexture, queue: queue)
            XCTAssertTrue(dye.allSatisfy { $0.x.isFinite && $0.y.isFinite && $0.z.isFinite && $0.w.isFinite
                && (0...3).contains($0.x) && (0...3).contains($0.y) && (0...3).contains($0.z) }, "\(kind)")
            XCTAssertTrue(velocity.allSatisfy { $0.x.isFinite && $0.y.isFinite && $0.z.isFinite
                && abs($0.x) <= 3 && abs($0.y) <= 3 && abs($0.z) <= 3 }, "\(kind)")
            XCTAssertGreaterThan(Float(dye.filter { $0.w < 0.05 }.count) / Float(dye.count), 0.12,
                                 "\(kind) must keep open volume after sustained music.")
        }
    }

    func testExpandedDomainAddsOuterDyeWithoutScalingTheCentralCloud() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let production = try InkFluid(device: device)
        XCTAssertEqual(production.densityTexture.width, 144)
        XCTAssertEqual((InkFluid.domainMaximum.x - InkFluid.domainMinimum.x) / 144,
                       7.2 / 112, accuracy: 0.003, "Extra width must add cells at the existing physical cell size.")
        let fluid = try InkFluid(device: device, resolution: resolution)
        var frame = VisualFrame()
        frame.rms = 0.5; frame.bass = 0.5; frame.vocal = 0.6; frame.other = 0.6
        try advance(fluid, queue: queue, frame: frame)
        let initial = try read(fluid.densityTexture, queue: queue)
        var outerLeft: Float = 0, outerRight: Float = 0, outerCount: Float = 0
        var centerMass: Float = 0, centerX: Float = 0
        for z in 0..<resolution.z { for y in 0..<resolution.y { for x in 0..<resolution.x {
            let p = worldPosition(x, y, z)
            let value = initial[(z * resolution.y + y) * resolution.x + x]
            if abs(p.x) > 3.6 {
                if p.x < 0 { outerLeft += value.w } else { outerRight += value.w }
                outerCount += 1
            }
            // The main upper purple lobe remains around its original world X=-1.9.
            if p.y > 3.7 && p.y < 4.8 && abs(p.z) < 0.6 && p.x > -3.3 && p.x < -0.4 {
                centerMass += value.y
                centerX += value.y * p.x
            }
        } } }
        XCTAssertGreaterThan(outerLeft / outerCount, 0.015, "New left space must contain actual seeded dye.")
        XCTAssertGreaterThan(outerRight / outerCount, 0.006, "New right space must contain a separate dye plume.")
        XCTAssertEqual(centerX / centerMass, -1.9, accuracy: 0.55,
                       "The central lobe must retain its original world position rather than scale by 4/3.")
        for step in 1...30 {
            frame.time = Float(step) / 30
            try advance(fluid, queue: queue, frame: frame)
        }
        let moved = try read(fluid.densityTexture, queue: queue)
        let velocity = try read(fluid.velocityTexture, queue: queue)
        var outerMotion: Float = 0, outerDyeChange: Float = 0
        for z in 0..<resolution.z { for y in 0..<resolution.y { for x in 0..<resolution.x {
            if abs(worldPosition(x, y, z).x) > 3.6 {
                let i = (z * resolution.y + y) * resolution.x + x
                outerMotion += simd_length(velocity[i])
                outerDyeChange += simd_length(moved[i] - initial[i])
            }
        } } }
        XCTAssertGreaterThan(outerMotion / outerCount, 0.01, "The added space must have its own projected flow.")
        XCTAssertGreaterThan(outerDyeChange / outerCount, 0.005, "Outer dye must actually advect.")
    }

    func testSustainedVocalMusicRetainsTransparentSightlinesAndThickClouds() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let fluid = try InkFluid(device: device, resolution: resolution)
        var frame = VisualFrame()
        frame.hasAnalysis = 1
        frame.vocal = 0.66; frame.bassInstrument = 0.61; frame.drums = 0.36; frame.other = 0.61
        frame.rms = 0.42; frame.peak = 0.63; frame.bass = 0.45; frame.mid = 0.3; frame.treble = 0.32
        frame.density = 0.55; frame.loudness = 0.60; frame.tempo = 130 / 120; frame.pace = 0.55
        frame.spectrum = (0..<64).map { 0.17 + 0.08 * sin(Float($0) * 0.31) }
        // Keep the observed foreground-eruption state throughout the sustained singing.
        let motion = InkMotionState.focused(.eruption, activity: 0.6, peak: 0.63)
        try advance(fluid, queue: queue, frame: frame, motion: motion)
        for batch in 0..<60 {
            let command = try XCTUnwrap(queue.makeCommandBuffer())
            for step in (batch * 30 + 1)...(batch * 30 + 30) {
                frame.time = Float(step) / 30
                let beats = frame.time * 130 / 60
                frame.beatPhase = beats - floor(beats)
                frame.barPhase = beats / 4 - floor(beats / 4)
                frame.beat = exp(-frame.beatPhase * 15)
                frame.bar = exp(-frame.barPhase * 50)
                frame.phraseProgress = beats / 32 - floor(beats / 32)
                frame.sectionProgress = min(1, frame.time / 64)
                try fluid.encode(command: command, frame: frame, elapsed: 1 / 30, motion: motion)
            }
            command.commit(); command.waitUntilCompleted()
            XCTAssertNil(command.error)
            if batch == 29 || batch == 59 {
                let dye = try read(fluid.densityTexture, queue: queue)
                // Unmodified GPU dye is integrated along front-facing Z sightlines.
                // Optical attenuation uses the renderer's extinction coefficient 2.7.
                var visibleLines: Float = 0, count: Float = 0, denseCells: Float = 0
                for y in 0..<resolution.y { for x in 0..<resolution.x {
                    let p = worldPosition(x, y, 0)
                    if p.x < 0 || p.x > 3.3 || p.y < 1.2 || p.y > 4.5 { continue }
                    var opticalDepth: Float = 0
                    for z in 0..<resolution.z {
                        let value = dye[(z * resolution.y + y) * resolution.x + x]
                        opticalDepth += value.w * (InkFluid.domainMaximum.z - InkFluid.domainMinimum.z)
                            / Float(resolution.z) * 2.7
                    }
                    if exp(-opticalDepth) > 0.15 { visibleLines += 1 }
                    count += 1
                } }
                for value in dye { if value.w > 0.35 { denseCells += 1 } }
                XCTAssertGreaterThan(visibleLines / count, 0.25,
                                     "After \(batch + 1) seconds, the central/right view must retain transparent paths.")
                XCTAssertGreaterThan(denseCells / Float(dye.count), 0.005,
                                     "Limiting supply must preserve thick clouds instead of clearing all ink.")
            }
        }
    }

    private func worldPosition(_ x: Int, _ y: Int, _ z: Int) -> SIMD3<Float> {
        InkFluid.domainMinimum + (SIMD3(Float(x), Float(y), Float(z)) + 0.5)
            / SIMD3(Float(resolution.x), Float(resolution.y), Float(resolution.z))
            * (InkFluid.domainMaximum - InkFluid.domainMinimum)
    }

    func testDyeTransportRetainsTheCoreAndGapWithoutCreatingNewExtrema() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let sourceURL = try XCTUnwrap(Bundle.module.url(forResource: "InkFluid", withExtension: "metal"))
        let library = try device.makeLibrary(source: String(contentsOf: sourceURL, encoding: .utf8), options: nil)
        let prediction = try device.makeComputePipelineState(function: XCTUnwrap(library.makeFunction(name: "predictInkDensity")))
        let correction = try device.makeComputePipelineState(function: XCTUnwrap(library.makeFunction(name: "advectInkDensity")))
        let size = SIMD3<Int>(64, 8, 8)
        func texture(_ values: [Float16]) throws -> MTLTexture {
            let descriptor = MTLTextureDescriptor()
            descriptor.textureType = .type3D; descriptor.pixelFormat = .rgba16Float
            descriptor.width = size.x; descriptor.height = size.y; descriptor.depth = size.z
            descriptor.storageMode = .shared; descriptor.usage = [.shaderRead, .shaderWrite]
            let result = try XCTUnwrap(device.makeTexture(descriptor: descriptor))
            values.withUnsafeBytes {
                result.replace(region: MTLRegionMake3D(0, 0, 0, size.x, size.y, size.z), mipmapLevel: 0,
                               slice: 0, withBytes: $0.baseAddress!, bytesPerRow: size.x * 8,
                               bytesPerImage: size.x * size.y * 8)
            }
            return result
        }
        var seed = [Float16](repeating: 0, count: size.x * size.y * size.z * 4)
        var velocity = seed
        for z in 0..<size.z { for y in 0..<size.y { for x in 0..<size.x {
            let i = ((z * size.y + y) * size.x + x) * 4
            // A half-unit wide purple slab travels 1.2 world units in two seconds.
            if (16..<24).contains(x) { seed[i + 1] = 1; seed[i + 3] = 1 }
            velocity[i] = Float16(0.6)
        } } }
        let dye = try [texture(seed), texture(Array(repeating: 0, count: seed.count))]
        let predicted = try texture(Array(repeating: 0, count: seed.count))
        let flow = try texture(velocity)
        var uniforms = [SIMD4<Float>](repeating: .zero, count: 11)
        uniforms[1] = SIMD4(4, 4, 4, 0)
        uniforms[2] = SIMD4(0, 1 / 30, 0, 0) // Zero presence disables all pigment supply.
        let spectrum = [Float](repeating: 0, count: 64)
        let command = try XCTUnwrap(queue.makeCommandBuffer())
        var current = 0
        func encode(_ pipeline: MTLComputePipelineState, _ textures: [MTLTexture]) throws {
            let encoder = try XCTUnwrap(command.makeComputeCommandEncoder())
            encoder.setComputePipelineState(pipeline)
            for (index, texture) in textures.enumerated() { encoder.setTexture(texture, index: index) }
            uniforms.withUnsafeBytes { encoder.setBytes($0.baseAddress!, length: $0.count, index: 0) }
            spectrum.withUnsafeBytes { encoder.setBytes($0.baseAddress!, length: $0.count, index: 1) }
            encoder.dispatchThreads(MTLSize(width: size.x, height: size.y, depth: size.z),
                                    threadsPerThreadgroup: MTLSize(width: 8, height: 4, depth: 4))
            encoder.endEncoding()
        }
        for step in 0..<60 {
            uniforms[2].x = Float(step) / 30
            try encode(prediction, [dye[current], flow, predicted])
            try encode(correction, [dye[current], flow, dye[1 - current], predicted])
            current = 1 - current
        }
        command.commit(); command.waitUntilCompleted(); XCTAssertNil(command.error)
        let moved = try read(dye[current], queue: queue)
        func concentration(_ x: Int) -> Float { moved[(3 * size.y + 4) * size.x + x].y }
        // Exact translation moves the slab to cells 35.2...43.2. Dense violet has
        // exp(-0.055 * 2) = 0.896 survival. The two central cells retain at least
        // 0.8 of their initial concentration, allowing less than 0.1 transport loss.
        for x in 38...39 {
            XCTAssertGreaterThan(concentration(x), 0.8, "Transport must retain a dense core at its theoretical destination.")
        }
        for x in [31, 47] {
            XCTAssertLessThan(concentration(x), 0.03, "Transport must leave a gap outside the moved slab.")
        }
        XCTAssertTrue(moved.allSatisfy { $0.y.isFinite && $0.y >= 0 && $0.y <= 1.001 },
                      "Error correction must not create concentrations above the original source maximum.")
    }

    private func advance(_ fluid: InkFluid, queue: MTLCommandQueue, frame: VisualFrame,
                         elapsed: Double = 1 / 60, repetitions: Int = 1, motion: InkMotionState? = nil) throws {
        let command = try XCTUnwrap(queue.makeCommandBuffer())
        for _ in 0..<repetitions { try fluid.encode(command: command, frame: frame, elapsed: elapsed, motion: motion) }
        command.commit()
        command.waitUntilCompleted()
        XCTAssertNil(command.error)
    }

    private func read(_ texture: MTLTexture, queue: MTLCommandQueue) throws -> [SIMD4<Float>] {
        let rowBytes = ((texture.width * 8 + 255) / 256) * 256
        let imageBytes = rowBytes * texture.height
        let buffer = try XCTUnwrap(queue.device.makeBuffer(length: imageBytes * texture.depth, options: .storageModeShared))
        let command = try XCTUnwrap(queue.makeCommandBuffer())
        let encoder = try XCTUnwrap(command.makeBlitCommandEncoder())
        encoder.copy(from: texture, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                     sourceSize: MTLSize(width: texture.width, height: texture.height, depth: texture.depth),
                     to: buffer, destinationOffset: 0, destinationBytesPerRow: rowBytes, destinationBytesPerImage: imageBytes)
        encoder.endEncoding()
        command.commit(); command.waitUntilCompleted()
        XCTAssertNil(command.error)
        var result = [SIMD4<Float>]()
        result.reserveCapacity(texture.width * texture.height * texture.depth)
        for z in 0..<texture.depth {
            for y in 0..<texture.height {
                let row = buffer.contents().advanced(by: z * imageBytes + y * rowBytes).assumingMemoryBound(to: UInt16.self)
                for x in 0..<texture.width {
                    result.append(SIMD4(Float(Float16(bitPattern: row[x * 4])), Float(Float16(bitPattern: row[x * 4 + 1])),
                                        Float(Float16(bitPattern: row[x * 4 + 2])), Float(Float16(bitPattern: row[x * 4 + 3]))))
                }
            }
        }
        return result
    }
}
