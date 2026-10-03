import Foundation
import simd

/// Three float4 groups match the Metal vertex structure without implicit padding.
struct TapeVertex {
    var position: SIMD4<Float>
    var normal: SIMD4<Float>
    /// UV, material ID, path section. Texture top points toward negative world Z.
    var surface: SIMD4<Float>
}

/// A cassette lies on the XZ plane. All apertures are actual mesh openings.
enum TapeMesh {
    private static let frontSlots: [ClosedRange<Float>] = [
        -1.52 ... -1.18, -0.96 ... -0.54, -0.32 ... 0.32,
        0.54 ... 0.96, 1.18 ... 1.52
    ]

    static func makeVertices() -> [TapeVertex] {
        var mesh = Builder()
        let bottom = caseContour(halfWidth: 1.96, halfDepth: 1.21, radius: 0.19)
        let side = caseContour(halfWidth: 2, halfDepth: 1.25, radius: 0.22)
        let seam = caseContour(halfWidth: 1.994, halfDepth: 1.244, radius: 0.218)
        let upperSide = caseContour(halfWidth: 1.98, halfDepth: 1.23, radius: 0.20)
        let top = caseContour(halfWidth: 1.93, halfDepth: 1.18, radius: 0.18)
        let opening = contour(halfWidth: 1.72, halfDepth: 0.82, radius: 0.14, centerZ: -0.12)
        let recess = contour(halfWidth: 1.68, halfDepth: 0.78, radius: 0.12, centerZ: -0.12)
        let guideCenters = [SIMD2<Float>(-0.91, 1.02), SIMD2<Float>(-0.63, 1.02),
                            SIMD2<Float>(0.63, 1.02), SIMD2<Float>(0.91, 1.02)]
        let guideHoles = guideCenters.enumerated().map { index, center in
            index == 0 || index == 3 ? circle(center: center, radius: 0.075) :
                contour(halfWidth: 0.054, halfDepth: 0.058, radius: 0.018, centerZ: center.y)
                    .map { $0 + SIMD2(center.x, 0) }
        }

        // Molded two-piece shell, recessed waist on both sides, and a real
        // opening along the front edge for the head and pressure-pad assembly.
        mesh.wall(bottom, at: 0.12, side, at: 0.16, material: 1)
        mesh.wall(side, at: 0.16, side, at: 0.218, material: 0, frontOpening: true)
        mesh.wall(side, at: 0.218, seam, at: 0.226, material: 2, frontOpening: true)
        mesh.wall(seam, at: 0.226, upperSide, at: 0.296, material: 0, frontOpening: true)
        mesh.wall(upperSide, at: 0.296, top, at: 0.34, material: 1)
        mesh.plate(top, holes: [opening] + guideHoles, y: 0.34, material: 0)
        mesh.wall(opening, at: 0.34, recess, at: 0.275, material: 2, inward: true)
        mesh.plate(bottom, holes: [recess] + guideHoles, y: 0.12, material: 0, upward: false)
        mesh.cavityWall(recess)
        mesh.frontSlotInsets()

        let reelCenters = [SIMD2<Float>(-0.9, -0.1), SIMD2<Float>(0.9, -0.1)]
        let islandBase = contour(halfWidth: 1.47, halfDepth: 0.365, radius: 0.14, centerZ: -0.1)
        let islandTop = contour(halfWidth: 1.44, halfDepth: 0.34, radius: 0.13, centerZ: -0.1)
        let reelHoles = reelCenters.map { circle(center: $0, radius: 0.307) }
        // Extend the inspection opening toward both hubs so the growing
        // take-up pack is visible before one third of the track has played.
        let window = contour(halfWidth: 0.565, halfDepth: 0.135, radius: 0.023, centerZ: -0.1)
        let windowBottom = contour(halfWidth: 0.55, halfDepth: 0.112, radius: 0.019, centerZ: -0.1)

        // The artwork surrounds an integrated reel bridge; it never covers the
        // central inspection window or either drive aperture.
        let insert = contour(halfWidth: 1.67, halfDepth: 0.63, radius: 0.035, centerZ: 0.02)
        mesh.plate(insert, holes: [islandBase], y: 0.285, material: 5,
                   textureMinimum: SIMD2(-1.67, -0.61), textureMaximum: SIMD2(1.67, 0.65))
        mesh.wall(islandBase, at: 0.285, islandTop, at: 0.314, material: 0)
        mesh.plate(islandTop, holes: reelHoles + [window], y: 0.314, material: 0)
        mesh.wall(windowBottom, at: 0.275, window, at: 0.314, material: 1, inward: true)
        // A recessed dark bed and wound tape are visible through the window.
        mesh.plate(recess, holes: reelCenters.map { circle(center: $0, radius: 0.237) },
                   y: 0.15, material: 13)
        for (index, center) in reelCenters.enumerated() {
            let hubMaterial = Float(index + 3)
            let tapeMaterial = Float(index + 10)
            mesh.annulus(center: center, inner: 0.30, outer: 0.76, y: 0.257, material: tapeMaterial)
            mesh.cylinderWall(center: center, radius: 0.76, bottom: 0.16, top: 0.257, material: tapeMaterial)
            let apertureBottom = circle(center: center, radius: 0.292)
            mesh.wall(apertureBottom, at: 0.291, reelHoles[index], at: 0.314, material: 1, inward: true)
            mesh.cylinderWall(center: center, radius: 0.292, bottom: 0.15, top: 0.291, material: 2, inward: true)
            let hubPorts = (0..<12).map { port in
                let angle = Float(port) * .pi / 6 + .pi / 12
                return circle(center: center + SIMD2(cos(angle), sin(angle)) * 0.260, radius: 0.006, segments: 16)
            }
            mesh.plate(circle(center: center, radius: 0.282),
                       holes: [circle(center: center, radius: 0.237)] + hubPorts,
                       y: 0.299, material: hubMaterial)
            for port in hubPorts {
                mesh.wall(port, at: 0.17, port, at: 0.299, material: hubMaterial, inward: true)
            }
            mesh.cylinderWall(center: center, radius: 0.282, bottom: 0.17, top: 0.299, material: hubMaterial)
            mesh.cylinderWall(center: center, radius: 0.237, bottom: 0.17, top: 0.299, material: hubMaterial, inward: true)
            // Six broad, inward-facing drive teeth, with gaps between them.
            for tooth in 0..<6 {
                mesh.radialBlock(center: center, inner: 0.204, outer: 0.252,
                                 angle: Float(tooth) * .pi / 3, width: 0.064,
                                 bottom: 0.239, top: 0.299, material: hubMaterial)
            }
        }
        mesh.roundedPlate(halfWidth: 1.64, halfDepth: 0.17, radius: 0.055,
                          centerZ: -0.79, bottom: 0.286, top: 0.307, material: 6)

        // The sloping lower head deck is part of the casing, rather than a
        // rectangular sticker. Capstan and alignment holes pass through it.
        let deckBottom = [SIMD2<Float>(-1.14, 0.59), SIMD2<Float>(1.14, 0.59),
                          SIMD2<Float>(1.39, 1.20), SIMD2<Float>(-1.39, 1.20)]
        let deckTop = [SIMD2<Float>(-1.11, 0.615), SIMD2<Float>(1.11, 0.615),
                       SIMD2<Float>(1.35, 1.18), SIMD2<Float>(-1.35, 1.18)]
        mesh.wall(deckBottom, at: 0.34, deckTop, at: 0.365, material: 1)
        mesh.plate(deckTop, holes: guideHoles, y: 0.365, material: 0)
        for (index, hole) in guideHoles.enumerated() {
            let center = guideCenters[index]
            let inset = hole.map { center + ($0 - center) * 0.88 }
            mesh.wall(inset, at: 0.344, hole, at: 0.365, material: 1, inward: true)
            mesh.wall(inset, at: 0.12, inset, at: 0.344, material: 2, inward: true)
        }
        mesh.roundedPlate(halfWidth: 1.00, halfDepth: 0.10, radius: 0.025,
                          centerZ: 0.755, bottom: 0.365, top: 0.368, material: 7)
        // A thin spring sits behind the felt pressure pad; its front contacts
        // the tape rather than protruding through the magnetic coating.
        mesh.box(minimum: SIMD3(-0.40, 0.17, 1.161), maximum: SIMD3(0.40, 0.257, 1.170), material: 8)
        mesh.box(minimum: SIMD3(-0.18, 0.17, 1.170), maximum: SIMD3(0.18, 0.257, 1.199), material: 16)
        mesh.box(minimum: SIMD3(-1.62, 0.16, 1.200), maximum: SIMD3(1.62, 0.257, 1.202), material: 12)
        for (x, material) in [(Float(-1.62), Float(17)), (Float(1.62), Float(18))] {
            let center = SIMD2<Float>(x, 1.080)
            let grooves = [Float(-0.075), Float(0.075)].map { offset in
                contour(halfWidth: 0.024, halfDepth: 0.006, radius: 0.004, centerZ: center.y)
                    .map { $0 + SIMD2(center.x + offset, 0) }
            }
            mesh.plate(circle(center: center, radius: 0.12),
                       holes: [circle(center: center, radius: 0.032)] + grooves,
                       y: 0.260, material: material)
            mesh.cylinderWall(center: center, radius: 0.12, bottom: 0.15, top: 0.260, material: material, segments: 48)
            mesh.cylinderWall(center: center, radius: 0.032, bottom: 0.15, top: 0.260, material: material, inward: true, segments: 48)
            for groove in grooves {
                mesh.wall(groove, at: 0.15, groove, at: 0.260, material: material, inward: true)
            }
            // The fixed axle is independent of the slotted rotating roller.
            mesh.annulus(center: center, inner: 0, outer: 0.024, y: 0.266, material: 8, segments: 32)
            mesh.cylinderWall(center: center, radius: 0.024, bottom: 0.15, top: 0.266, material: 8, segments: 32)
        }
        for material: Float in [14, 15] {
            mesh.tapePathTemplate(material: material, section: 0, segments: 1)
            mesh.tapePathTemplate(material: material, section: 1, segments: 32)
        }

        // Four corner fasteners and one centered on the head deck.
        for center in [SIMD2<Float>(-1.77, -1.01), SIMD2<Float>(1.77, -1.01),
                       SIMD2<Float>(-1.77, 1.03), SIMD2<Float>(1.77, 1.03), SIMD2<Float>(0, 0.96)] {
            let y: Float = center.x == 0 ? 0.366 : 0.343
            mesh.annulus(center: center, inner: 0.047, outer: 0.061, y: y, material: 2, segments: 32)
            mesh.annulus(center: center, inner: 0, outer: 0.044, y: y + 0.003, material: 8, segments: 32)
            mesh.cylinderWall(center: center, radius: 0.044, bottom: y - 0.009, top: y + 0.003, material: 8, segments: 32)
            mesh.box(minimum: SIMD3(center.x - 0.027, y + 0.0035, center.y - 0.005),
                     maximum: SIMD3(center.x + 0.027, y + 0.004, center.y + 0.005), material: 2)
            mesh.box(minimum: SIMD3(center.x - 0.005, y + 0.0035, center.y - 0.027),
                     maximum: SIMD3(center.x + 0.005, y + 0.004, center.y + 0.027), material: 2)
        }
        // Transparent inspection cover is last so the recessed tape has already
        // populated depth and color. This glass does not cover either hub hole.
        mesh.plate(windowBottom, holes: [], y: 0.281, material: 9)
        return mesh.vertices
    }

    private static func circle(center: SIMD2<Float>, radius: Float, segments: Int = 96) -> [SIMD2<Float>] {
        (0..<segments).map { index in
            let angle = Float(index) * .pi * 2 / Float(segments)
            return center + SIMD2(cos(angle), sin(angle)) * radius
        }
    }

    private static func caseContour(halfWidth: Float, halfDepth: Float, radius: Float) -> [SIMD2<Float>] {
        let points = contour(halfWidth: halfWidth, halfDepth: halfDepth, radius: radius)
        var result: [SIMD2<Float>] = []
        for index in points.indices {
            let a = points[index], b = points[(index + 1) % points.count]
            var fractions: [Float] = [0]
            if abs(a.x - b.x) < 0.0001 && abs(a.x) > halfWidth - 0.001 {
                for z: Float in [0.36, 0.42, 0.66, 0.72] {
                    let t = (z - a.y) / (b.y - a.y)
                    if t > 0 && t < 1 { fractions.append(t) }
                }
            }
            if abs(a.y - b.y) < 0.0001 && a.y > halfDepth - 0.001 {
                for x in frontSlots.flatMap({ [$0.lowerBound, $0.upperBound] }) {
                    let t = (x - a.x) / (b.x - a.x)
                    if t > 0 && t < 1 { fractions.append(t) }
                }
            }
            for t in fractions.sorted() {
                var p = a + (b - a) * t
                let notch = min(1, max(0, (p.y - 0.36) / 0.06)) * min(1, max(0, (0.72 - p.y) / 0.06))
                p.x -= (p.x > 0 ? 1 : -1) * 0.07 * notch
                result.append(p)
            }
        }
        return result
    }

    /// Equal point counts let outer and inner loops form a watertight ring.
    private static func contour(halfWidth: Float, halfDepth: Float, radius: Float,
                                centerZ: Float = 0) -> [SIMD2<Float>] {
        let centers = [SIMD2(halfWidth - radius, halfDepth - radius),
                       SIMD2(-halfWidth + radius, halfDepth - radius),
                       SIMD2(-halfWidth + radius, -halfDepth + radius),
                       SIMD2(halfWidth - radius, -halfDepth + radius)]
        return centers.enumerated().flatMap { corner, center in
            (0...16).map { step in
                let angle = Float(corner) * .pi / 2 + Float(step) * .pi / 32
                return center + SIMD2(cos(angle), sin(angle)) * radius + SIMD2(0, centerZ)
            }
        }
    }

    private struct Builder {
        var vertices: [TapeVertex] = []

        mutating func triangle(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ c: SIMD3<Float>,
                               normal: SIMD3<Float>, material: Float,
                               uvA: SIMD2<Float> = .zero, uvB: SIMD2<Float> = .zero,
                               uvC: SIMD2<Float> = .zero) {
            // Every triangle winds outward; the renderer can enable back culling.
            let reverse = simd_dot(simd_cross(b - a, c - a), normal) < 0
            let points = reverse ? [a, c, b] : [a, b, c]
            let uvs = reverse ? [uvA, uvC, uvB] : [uvA, uvB, uvC]
            for index in 0..<3 {
                vertices.append(TapeVertex(position: SIMD4(points[index], 1), normal: SIMD4(normal, 0),
                                           surface: SIMD4(uvs[index].x, uvs[index].y, material, 0)))
            }
        }

        mutating func quad(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ c: SIMD3<Float>, _ d: SIMD3<Float>,
                           normal: SIMD3<Float>, material: Float) {
            triangle(a, b, c, normal: normal, material: material)
            triangle(a, c, d, normal: normal, material: material)
        }

        mutating func wall(_ lower: [SIMD2<Float>], at lowY: Float,
                           _ upper: [SIMD2<Float>], at highY: Float,
                           material: Float, inward: Bool = false, frontOpening: Bool = false) {
            for index in lower.indices {
                let next = (index + 1) % lower.count
                if frontOpening && lower[index].y > 1.19 && lower[next].y > 1.19 &&
                    TapeMesh.frontSlots.contains(where: { $0.contains((lower[index].x + lower[next].x) / 2) }) { continue }
                let a = SIMD3(lower[index].x, lowY, lower[index].y)
                let b = SIMD3(lower[next].x, lowY, lower[next].y)
                let c = SIMD3(upper[next].x, highY, upper[next].y)
                let d = SIMD3(upper[index].x, highY, upper[index].y)
                var normal = simd_normalize(simd_cross(d - a, b - a))
                let edge = lower[next] - lower[index]
                let outward = SIMD3(edge.y, 0, -edge.x)
                if simd_dot(normal, outward) < 0 { normal = -normal }
                if inward { normal = -normal }
                quad(a, b, c, d, normal: normal, material: material)
            }
        }

        /// Keep the recess wall except where the reel-to-roller tape passes.
        /// Split at passage boundaries so the upper and lower casing lips stay.
        mutating func cavityWall(_ edge: [SIMD2<Float>]) {
            for index in edge.indices {
                let a = edge[index], b = edge[(index + 1) % edge.count]
                var fractions: [Float] = [0, 1]
                if abs(b.x - a.x) > 0.000001 {
                    for x: Float in [-1.10, 1.10] {
                        let t = (x - a.x) / (b.x - a.x)
                        if t > 0 && t < 1 { fractions.append(t) }
                    }
                }
                if abs(b.y - a.y) > 0.000001 {
                    let t = (-0.30 - a.y) / (b.y - a.y)
                    if t > 0 && t < 1 { fractions.append(t) }
                }
                fractions.sort()
                for part in 1..<fractions.count {
                    let p = a + (b - a) * fractions[part - 1]
                    let q = a + (b - a) * fractions[part]
                    let midpoint = (p + q) / 2
                    let passage = abs(midpoint.x) > 1.10 && midpoint.y > -0.30
                    let spans: [(Float, Float)] = passage ? [(0.12, 0.16), (0.257, 0.275)] : [(0.12, 0.275)]
                    let normal = simd_normalize(SIMD3<Float>(-(q.y - p.y), 0, q.x - p.x))
                    for (bottom, top) in spans {
                        quad(SIMD3(p.x, bottom, p.y), SIMD3(q.x, bottom, q.y),
                             SIMD3(q.x, top, q.y), SIMD3(p.x, top, p.y), normal: normal, material: 2)
                    }
                }
            }
        }

        /// Side jambs and inner faces make each front opening visibly thick.
        mutating func frontSlotInsets() {
            for slot in TapeMesh.frontSlots {
                for (x, direction) in [(slot.lowerBound, Float(1)), (slot.upperBound, Float(-1))] {
                    quad(SIMD3(x, 0.16, 1.21), SIMD3(x, 0.16, 1.25),
                         SIMD3(x, 0.296, 1.25), SIMD3(x, 0.296, 1.21),
                         normal: SIMD3(direction, 0, 0), material: 1)
                }
                for (y, direction) in [(Float(0.16), Float(1)), (Float(0.296), Float(-1))] {
                    quad(SIMD3(slot.lowerBound, y, 1.21), SIMD3(slot.upperBound, y, 1.21),
                         SIMD3(slot.upperBound, y, 1.25), SIMD3(slot.lowerBound, y, 1.25),
                         normal: SIMD3(0, direction, 0), material: 1)
                }
            }
        }

        /// The vertex shader replaces XZ with the changing tangent and arc.
        /// UV encodes path progress/vertical edge and W chooses the section.
        mutating func tapePathTemplate(material: Float, section: Float, segments: Int) {
            for segment in 0..<segments {
                let start = Float(segment) / Float(segments)
                let end = Float(segment + 1) / Float(segments)
                for uv in [SIMD2(start, 0), SIMD2(start, 1), SIMD2(end, 0),
                           SIMD2(end, 0), SIMD2(start, 1), SIMD2(end, 1)] {
                    vertices.append(TapeVertex(position: SIMD4(0, 0.16 + uv.y * 0.097, 0, 1),
                                               normal: SIMD4(0, 0, 1, 0),
                                               surface: SIMD4(uv.x, uv.y, material, section)))
                }
            }
        }

        /// Tessellate a planar outline with any number of actual holes. Each
        /// Z strip ends at a contour vertex, so its filled spans are trapezoids.
        /// Even/odd intersections exclude apertures without covering triangles.
        mutating func plate(_ outline: [SIMD2<Float>], holes: [[SIMD2<Float>]], y: Float,
                            material: Float, upward: Bool = true,
                            textureMinimum: SIMD2<Float> = .zero,
                            textureMaximum: SIMD2<Float> = SIMD2(1, 1)) {
            let loops = [outline] + holes
            let levels = Array(Set(loops.flatMap { $0.map(\.y) })).sorted()
            let edges = loops.flatMap { loop in
                loop.indices.map { (loop[$0], loop[($0 + 1) % loop.count]) }
            }
            let normal = SIMD3<Float>(0, upward ? 1 : -1, 0)
            func uv(_ p: SIMD3<Float>) -> SIMD2<Float> {
                (SIMD2(p.x, p.z) - textureMinimum) / (textureMaximum - textureMinimum)
            }
            for strip in 1..<levels.count {
                let low = levels[strip - 1], high = levels[strip]
                if high - low < 0.000001 { continue }
                let mid = (low + high) / 2
                func x(_ edge: (SIMD2<Float>, SIMD2<Float>), at z: Float) -> Float {
                    edge.0.x + (edge.1.x - edge.0.x) * (z - edge.0.y) / (edge.1.y - edge.0.y)
                }
                let crossings = edges.filter { min($0.0.y, $0.1.y) < mid && max($0.0.y, $0.1.y) > mid }
                    .sorted { x($0, at: mid) < x($1, at: mid) }
                for index in stride(from: 0, to: crossings.count - 1, by: 2) {
                    let left = crossings[index], right = crossings[index + 1]
                    let a = SIMD3(x(left, at: low), y, low), b = SIMD3(x(right, at: low), y, low)
                    let c = SIMD3(x(right, at: high), y, high), d = SIMD3(x(left, at: high), y, high)
                    if simd_length_squared(simd_cross(b - a, c - a)) > 1e-14 {
                        triangle(a, b, c, normal: normal, material: material, uvA: uv(a), uvB: uv(b), uvC: uv(c))
                    }
                    if simd_length_squared(simd_cross(c - a, d - a)) > 1e-14 {
                        triangle(a, c, d, normal: normal, material: material, uvA: uv(a), uvB: uv(c), uvC: uv(d))
                    }
                }
            }
        }

        mutating func ring(_ outer: [SIMD2<Float>], _ inner: [SIMD2<Float>], y: Float,
                           material: Float, upward: Bool = true) {
            for index in outer.indices {
                let next = (index + 1) % outer.count
                quad(SIMD3(outer[index].x, y, outer[index].y), SIMD3(outer[next].x, y, outer[next].y),
                     SIMD3(inner[next].x, y, inner[next].y), SIMD3(inner[index].x, y, inner[index].y),
                     normal: SIMD3(0, upward ? 1 : -1, 0), material: material)
            }
        }

        mutating func roundedPlate(halfWidth: Float, halfDepth: Float, radius: Float,
                                   centerZ: Float, bottom: Float, top: Float, material: Float) {
            let edge = TapeMesh.contour(halfWidth: halfWidth, halfDepth: halfDepth,
                                        radius: radius, centerZ: centerZ)
            wall(edge, at: bottom, edge, at: top, material: 1)
            let center = SIMD3<Float>(0, top, centerZ)
            for index in edge.indices {
                let next = (index + 1) % edge.count
                let a = SIMD3(edge[index].x, top, edge[index].y)
                let b = SIMD3(edge[next].x, top, edge[next].y)
                func uv(_ point: SIMD3<Float>) -> SIMD2<Float> {
                    SIMD2((point.x + halfWidth) / (halfWidth * 2),
                          (point.z - centerZ + halfDepth) / (halfDepth * 2))
                }
                triangle(center, a, b, normal: SIMD3(0, 1, 0), material: material,
                         uvA: uv(center), uvB: uv(a), uvC: uv(b))
            }
        }

        mutating func annulus(center: SIMD2<Float>, inner: Float, outer: Float, y: Float,
                              material: Float, segments: Int = 96) {
            let outerPoints = (0..<segments).map { index in
                center + SIMD2(cos(Float(index) * .pi * 2 / Float(segments)), sin(Float(index) * .pi * 2 / Float(segments))) * outer
            }
            let innerPoints = outerPoints.map { center + ($0 - center) * (inner / outer) }
            if inner == 0 {
                for index in outerPoints.indices {
                    let next = (index + 1) % segments
                    triangle(SIMD3(center.x, y, center.y),
                             SIMD3(outerPoints[index].x, y, outerPoints[index].y),
                             SIMD3(outerPoints[next].x, y, outerPoints[next].y),
                             normal: SIMD3(0, 1, 0), material: material)
                }
            } else {
                ring(outerPoints, innerPoints, y: y, material: material)
            }
        }

        mutating func cylinderWall(center: SIMD2<Float>, radius: Float, bottom: Float, top: Float,
                                   material: Float, inward: Bool = false, segments: Int = 96) {
            let points = (0..<segments).map { index in
                center + SIMD2(cos(Float(index) * .pi * 2 / Float(segments)), sin(Float(index) * .pi * 2 / Float(segments))) * radius
            }
            wall(points, at: bottom, points, at: top, material: material, inward: inward)
        }

        mutating func radialBlock(center: SIMD2<Float>, inner: Float, outer: Float, angle: Float,
                                  width: Float, bottom: Float, top: Float, material: Float) {
            let along = SIMD2<Float>(cos(angle), sin(angle))
            let across = SIMD2<Float>(-along.y, along.x) * width / 2
            let points = [center + along * outer + across, center + along * inner + across,
                          center + along * inner - across, center + along * outer - across]
            wall(points, at: bottom, points, at: top, material: material)
            quad(SIMD3(points[0].x, top, points[0].y), SIMD3(points[1].x, top, points[1].y),
                 SIMD3(points[2].x, top, points[2].y), SIMD3(points[3].x, top, points[3].y),
                 normal: SIMD3(0, 1, 0), material: material)
        }

        mutating func box(minimum: SIMD3<Float>, maximum: SIMD3<Float>, material: Float) {
            let points = [SIMD2(minimum.x, minimum.z), SIMD2(maximum.x, minimum.z),
                          SIMD2(maximum.x, maximum.z), SIMD2(minimum.x, maximum.z)]
            wall(points, at: minimum.y, points, at: maximum.y, material: material)
            quad(SIMD3(minimum.x, maximum.y, minimum.z), SIMD3(maximum.x, maximum.y, minimum.z),
                 SIMD3(maximum.x, maximum.y, maximum.z), SIMD3(minimum.x, maximum.y, maximum.z),
                 normal: SIMD3(0, 1, 0), material: material)
        }
    }
}
