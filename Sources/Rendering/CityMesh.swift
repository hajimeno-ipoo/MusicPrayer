import simd

/// Position, normal and UV/material/height anchor match CityVertex in Metal.
struct CityVertex {
    var position: SIMD4<Float>
    var normal: SIMD4<Float>
    var surface: SIMD4<Float>
}

/// Like TapeMesh, solid parts are built once and shared by the displayed towers.
enum CityMesh {
    static let buildingCount = 40
    // Eight positions along the foreground edge, five along the depth axis.
    // The GPU table in SpectrumCity.metal uses the same coordinates.
    private static let buildingCells: [SIMD2<Int>] = [
        SIMD2(0, 0), SIMD2(1, 0), SIMD2(0, 1), SIMD2(2, 0), SIMD2(1, 1), SIMD2(0, 2), SIMD2(3, 0), SIMD2(2, 1),
        SIMD2(1, 2), SIMD2(0, 3), SIMD2(4, 0), SIMD2(3, 1), SIMD2(2, 2), SIMD2(1, 3), SIMD2(0, 4), SIMD2(4, 1),
        SIMD2(3, 2), SIMD2(2, 3), SIMD2(1, 4), SIMD2(0, 5), SIMD2(4, 2), SIMD2(3, 3), SIMD2(2, 4), SIMD2(1, 5),
        SIMD2(0, 6), SIMD2(4, 3), SIMD2(3, 4), SIMD2(2, 5), SIMD2(1, 6), SIMD2(0, 7), SIMD2(4, 4), SIMD2(3, 5),
        SIMD2(2, 6), SIMD2(1, 7), SIMD2(4, 5), SIMD2(3, 6), SIMD2(2, 7), SIMD2(4, 6), SIMD2(3, 7), SIMD2(4, 7)
    ]
    static func gridCoordinate(for band: Int) -> SIMD2<Int> { buildingCells[band] }

    /// Every one of the 64 analysed FFT bins belongs to exactly one visible tower.
    /// Keep the strongest bin in each group so narrow peaks remain visible.
    static func displaySpectrum(_ spectrum: [Float]) -> [Float] {
        (0..<buildingCount).map { tower in
            let lower = tower * 64 / buildingCount
            let upper = (tower + 1) * 64 / buildingCount
            return (lower..<upper).reduce(Float(0)) { value, bin in
                max(value, bin < spectrum.count ? min(1, max(0, spectrum[bin])) : 0)
            }
        }
    }

    // Materials: foundation, plinth, glass, roof metal, aluminum, front/roof light,
    // warm light, studio floor, side light.
    static func buildingVertices() -> [CityVertex] {
        var b = Builder()
        b.beveledBox(half: SIMD2(0.47, 0.49), bottom: 0.012, top: 0.12,
                     bevel: 0.022, material: 1, anchor: 1)
        b.beveledBox(half: SIMD2(0.39, 0.41), bottom: 0, top: 1,
                     bevel: 0.016, material: 2, anchor: 0)

        // Clean crystal faces are framed only at their outer edges.
        for x: Float in [-0.375, 0.375] {
            for z: Float in [-0.417, 0.417] {
                b.box(minimum: SIMD3(x - 0.012, 0.015, z - 0.010),
                      maximum: SIMD3(x + 0.012, 0.995, z + 0.010), material: 4, anchor: 0)
                b.box(minimum: SIMD3(x - 0.010, 0.012, z + (z > 0 ? 0.010 : -0.012)),
                      maximum: SIMD3(x + 0.010, 0.985, z + (z > 0 ? 0.012 : -0.010)), material: 5, anchor: 0,
                      faceNormal: SIMD3(0, 0, z > 0 ? 1 : -1))
            }
        }
        for z: Float in [-0.395, 0.395] {
            for x: Float in [-0.397, 0.397] {
                b.box(minimum: SIMD3(x - 0.010, 0.015, z - 0.012),
                      maximum: SIMD3(x + 0.010, 0.995, z + 0.012), material: 4, anchor: 0)
                b.box(minimum: SIMD3(x + (x > 0 ? 0.010 : -0.012), 0.012, z - 0.010),
                      maximum: SIMD3(x + (x > 0 ? 0.012 : -0.010), 0.985, z + 0.010), material: 8, anchor: 0,
                      faceNormal: SIMD3(x > 0 ? 1 : -1, 0, 0))
            }
        }

        // The roof has a recessed center, raised parapets and a luminous inner rim.
        b.beveledBox(half: SIMD2(0.392, 0.412), bottom: 0, top: 0.025,
                     bevel: 0.010, material: 3, anchor: 2)
        for z: Float in [-0.399, 0.399] {
            b.box(minimum: SIMD3(-0.383, 0.025, z - 0.013),
                  maximum: SIMD3(0.383, 0.061, z + 0.013), material: 4, anchor: 2)
            b.box(minimum: SIMD3(-0.37, 0.062, z - 0.022),
                  maximum: SIMD3(0.37, 0.070, z + 0.022), material: 5, anchor: 2,
                  faceNormal: SIMD3(0, 1, 0))
        }
        for x: Float in [-0.378, 0.378] {
            b.box(minimum: SIMD3(x - 0.013, 0.025, -0.386),
                  maximum: SIMD3(x + 0.013, 0.061, 0.386), material: 4, anchor: 2)
            b.box(minimum: SIMD3(x - 0.022, 0.062, -0.385),
                  maximum: SIMD3(x + 0.022, 0.070, 0.385), material: 5, anchor: 2,
                  faceNormal: SIMD3(0, 1, 0))
        }
        b.beveledBox(half: SIMD2(0.095, 0.060), center: SIMD2(0.14, -0.16),
                     bottom: 0.025, top: 0.082, bevel: 0.008, material: 3, anchor: 2)

        // Entrance recess and small curb lamps make the street scale readable.
        b.box(minimum: SIMD3(-0.11, 0.028, 0.491), maximum: SIMD3(0.11, 0.08, 0.497), material: 2, anchor: 1)
        b.box(minimum: SIMD3(-0.12, 0.08, 0.49), maximum: SIMD3(0.12, 0.085, 0.50), material: 6, anchor: 1)
        for x: Float in [-0.51, 0.51] {
            for z: Float in [-0.53, 0.53] {
                b.box(minimum: SIMD3(x - 0.012, 0.005, z - 0.024),
                      maximum: SIMD3(x + 0.012, 0.024, z + 0.024), material: 6, anchor: 1)
            }
        }
        return b.vertices
    }

    static func foundationVertices() -> [CityVertex] {
        var b = Builder()
        b.box(minimum: SIMD3(-30, -0.56, -30), maximum: SIMD3(30, -0.55, 30), material: 7, anchor: 1)
        b.beveledBox(half: SIMD2(4.6, 5.3), bottom: -0.55, top: 0,
                     bevel: 0.055, material: 0, anchor: 1)
        return b.vertices
    }

    /// The reference light sweeps in a broad curve across the foreground and
    /// right-hand blocks. Building depth clips its occluded sections on GPU.
    static func goldLightRoute() -> [SIMD4<Float>] {
        let points: [SIMD2<Float>] = (0...1024).map { index in
            let angle = Float(index) / 1024 * 2 * .pi
            return SIMD2(-0.08 + cos(angle) * 1.70, 0.10 + sin(angle) * 3.15)
        }
        var distances: [Float] = [0]
        for index in 1..<points.count { distances.append(distances.last! + simd_length(points[index] - points[index - 1])) }
        let total = distances.last!
        var edge = 0
        return (0...512).map { index in
            let distance = total * Float(index) / 512
            while edge + 1 < distances.count - 1 && distances[edge + 1] < distance { edge += 1 }
            let fraction = (distance - distances[edge]) / max(0.00001, distances[edge + 1] - distances[edge])
            let point = simd_mix(points[edge], points[edge + 1], SIMD2(repeating: fraction))
            return SIMD4(point.x, 0, point.y, Float(index) / 512)
        }
    }

    /// Tube topology only: x is distance behind the head, y is cross-section angle.
    /// Seven instances share these vertices and the route in scene and mirror passes.
    static func goldLightVertices() -> [CityVertex] {
        var vertices: [CityVertex] = []
        for segment in 0..<192 {
            for side in 0..<6 {
                let a = SIMD2(Float(segment) / 192, Float(side) / 6 * 2 * .pi)
                let b = SIMD2(Float(segment + 1) / 192, a.y)
                let c = SIMD2(b.x, Float(side + 1) / 6 * 2 * .pi)
                let d = SIMD2(a.x, c.y)
                for point in [a, b, c, a, c, d] {
                    vertices.append(CityVertex(position: SIMD4(point.x, point.y, 0, 1),
                                               normal: .zero, surface: .zero))
                }
            }
        }
        return vertices
    }

    private struct Builder {
        var vertices: [CityVertex] = []

        mutating func triangle(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ c: SIMD3<Float>,
                               normal: SIMD3<Float>, material: Float, anchor: Float,
                               uvA: SIMD2<Float>, uvB: SIMD2<Float>, uvC: SIMD2<Float>) {
            let reverse = simd_dot(simd_cross(b - a, c - a), normal) < 0
            let points = reverse ? [a, c, b] : [a, b, c]
            let uvs = reverse ? [uvA, uvC, uvB] : [uvA, uvB, uvC]
            for i in 0..<3 {
                vertices.append(CityVertex(position: SIMD4(points[i], 1), normal: SIMD4(normal, 0),
                                           surface: SIMD4(uvs[i].x, uvs[i].y, material, anchor)))
            }
        }

        mutating func quad(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ c: SIMD3<Float>, _ d: SIMD3<Float>,
                           normal: SIMD3<Float>, material: Float, anchor: Float) {
            triangle(a, b, c, normal: normal, material: material, anchor: anchor,
                     uvA: SIMD2(0, 0), uvB: SIMD2(1, 0), uvC: SIMD2(1, 1))
            triangle(a, c, d, normal: normal, material: material, anchor: anchor,
                     uvA: SIMD2(0, 0), uvB: SIMD2(1, 1), uvC: SIMD2(0, 1))
        }

        mutating func box(minimum a: SIMD3<Float>, maximum b: SIMD3<Float>, material: Float, anchor: Float,
                          faceNormal: SIMD3<Float>? = nil) {
            // LEDs are surfaces on the solid metal fins. Their tiny side edges
            // must not become subpixel light sources or duplicate the inner face.
            func includes(_ normal: SIMD3<Float>) -> Bool { faceNormal == nil || faceNormal == normal }
            if includes(SIMD3(0, 0, 1)) {
                quad(SIMD3(a.x, a.y, b.z), SIMD3(b.x, a.y, b.z), SIMD3(b.x, b.y, b.z), SIMD3(a.x, b.y, b.z),
                     normal: SIMD3(0, 0, 1), material: material, anchor: anchor)
            }
            if includes(SIMD3(0, 0, -1)) {
                quad(SIMD3(b.x, a.y, a.z), SIMD3(a.x, a.y, a.z), SIMD3(a.x, b.y, a.z), SIMD3(b.x, b.y, a.z),
                     normal: SIMD3(0, 0, -1), material: material, anchor: anchor)
            }
            if includes(SIMD3(-1, 0, 0)) {
                quad(SIMD3(a.x, a.y, a.z), SIMD3(a.x, a.y, b.z), SIMD3(a.x, b.y, b.z), SIMD3(a.x, b.y, a.z),
                     normal: SIMD3(-1, 0, 0), material: material, anchor: anchor)
            }
            if includes(SIMD3(1, 0, 0)) {
                quad(SIMD3(b.x, a.y, b.z), SIMD3(b.x, a.y, a.z), SIMD3(b.x, b.y, a.z), SIMD3(b.x, b.y, b.z),
                     normal: SIMD3(1, 0, 0), material: material, anchor: anchor)
            }
            if includes(SIMD3(0, 1, 0)) {
                quad(SIMD3(a.x, b.y, b.z), SIMD3(b.x, b.y, b.z), SIMD3(b.x, b.y, a.z), SIMD3(a.x, b.y, a.z),
                     normal: SIMD3(0, 1, 0), material: material, anchor: anchor)
            }
            if includes(SIMD3(0, -1, 0)) {
                quad(SIMD3(a.x, a.y, a.z), SIMD3(b.x, a.y, a.z), SIMD3(b.x, a.y, b.z), SIMD3(a.x, a.y, b.z),
                     normal: SIMD3(0, -1, 0), material: material, anchor: anchor)
            }
        }

        mutating func beveledBox(half: SIMD2<Float>, center: SIMD2<Float> = .zero,
                                 bottom: Float, top: Float, bevel: Float, material: Float, anchor: Float) {
            let r = min(bevel, (top - bottom) * 0.3)
            func contour(_ inset: Float) -> [SIMD2<Float>] {
                let h = half - SIMD2(repeating: inset)
                let c = max(0.001, bevel - inset * 0.5)
                return [SIMD2(h.x - c, h.y), SIMD2(-h.x + c, h.y), SIMD2(-h.x, h.y - c),
                        SIMD2(-h.x, -h.y + c), SIMD2(-h.x + c, -h.y), SIMD2(h.x - c, -h.y),
                        SIMD2(h.x, -h.y + c), SIMD2(h.x, h.y - c)].map { $0 + center }
            }
            let outer = contour(0), inner = contour(r)
            let rings = [inner, outer, outer, inner]
            let levels = [bottom, bottom + r, top - r, top]
            for level in 0..<3 {
                for i in 0..<8 {
                    let j = (i + 1) % 8
                    let a = SIMD3(rings[level][i].x, levels[level], rings[level][i].y)
                    let b = SIMD3(rings[level][j].x, levels[level], rings[level][j].y)
                    let c = SIMD3(rings[level + 1][j].x, levels[level + 1], rings[level + 1][j].y)
                    let d = SIMD3(rings[level + 1][i].x, levels[level + 1], rings[level + 1][i].y)
                    let normal = simd_normalize(simd_cross(d - a, b - a))
                    quad(a, b, c, d, normal: normal, material: material, anchor: anchor)
                }
            }
            for i in 0..<8 {
                let j = (i + 1) % 8
                for (height, normal) in [(top, SIMD3<Float>(0, 1, 0)), (bottom, SIMD3<Float>(0, -1, 0))] {
                    triangle(SIMD3(center.x, height, center.y), SIMD3(inner[i].x, height, inner[i].y),
                             SIMD3(inner[j].x, height, inner[j].y), normal: normal, material: material, anchor: anchor,
                             uvA: SIMD2(repeating: 0.5), uvB: (inner[i] - center) / (half * 2) + SIMD2(repeating: 0.5),
                             uvC: (inner[j] - center) / (half * 2) + SIMD2(repeating: 0.5))
                }
            }
        }
    }
}
