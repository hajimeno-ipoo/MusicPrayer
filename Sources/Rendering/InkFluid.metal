#include <metal_stdlib>
using namespace metal;

struct InkUniforms {
    float4 minimum;
    float4 extent;
    float4 clock; // simulation time, audio step, onset impulse, presence
    float4 levels; // rms, low, middle, high
    float4 music; // vocal, drums, bass instrument, other
    float4 rhythm; // beat phase, bar phase, downbeat, tempo / 120
    float4 structure; // activity / pace, phrase, segment, section progress
    float4 layout; // separation, thickness, depth, section transition
    float4 expression; // song-relative density, mode bias, key hue, has analysis
    float4 motionA; // suction, eruption, collision, breathing
    float4 motionB; // sinking, split/rejoin, real-time activity, peak
};
constexpr sampler inkSampler(coord::normalized, address::clamp_to_edge, filter::linear);

float inkHash(float3 p) {
    p = fract(p * float3(0.1031, 0.11369, 0.13787));
    p += dot(p, p.yzx + 19.19);
    return fract((p.x + p.y) * p.z);
}
float inkNoise(float3 p) {
    float3 i = floor(p), f = fract(p);
    f = f * f * (3.0 - 2.0 * f);
    float a = mix(inkHash(i), inkHash(i + float3(1, 0, 0)), f.x);
    float b = mix(inkHash(i + float3(0, 1, 0)), inkHash(i + float3(1, 1, 0)), f.x);
    float c = mix(inkHash(i + float3(0, 0, 1)), inkHash(i + float3(1, 0, 1)), f.x);
    float d = mix(inkHash(i + float3(0, 1, 1)), inkHash(i + float3(1, 1, 1)), f.x);
    return mix(mix(a, b, f.y), mix(c, d, f.y), f.z);
}
float inkFBM(float3 p) {
    float result = 0, weight = 0.55;
    for (uint octave = 0; octave < 4; ++octave) {
        result += weight * inkNoise(p);
        p = p * 2.03 + float3(7.1, 1.7, 3.2);
        weight *= 0.5;
    }
    return result;
}
float inkEllipsoid(float3 p, float3 center, float3 radius) {
    return (length((p - center) / radius) - 1.0) * min(radius.x, min(radius.y, radius.z));
}
float inkJoin(float a, float b, float width) {
    float h = saturate(0.5 + 0.5 * (b - a) / width);
    return mix(b, a, h) - width * h * (1.0 - h);
}
float3 inkCoordinate(uint3 id, uint3 size) { return (float3(id) + 0.5) / float3(size); }
float3 inkCellSize(uint3 size, constant InkUniforms &u) { return u.extent.xyz / float3(size); }
bool outsideInk(uint3 id, uint3 size) { return any(id >= size); }
uint3 inkNeighbor(int3 p, uint3 size) { return uint3(clamp(p, int3(0), int3(size) - 1)); }

// Analytic divergence-free eddies at two scales. Pressure projection also removes divergence
// introduced by buoyancy, source impulses, boundaries and interpolation.
float3 inkEddies(float3 p, float time, float high) {
    float3 q = p * 2.4 + float3(time * 0.17, -time * 0.11, time * 0.09);
    float3 large = float3(sin(q.y) * cos(q.z), sin(q.z) * cos(q.x), sin(q.x) * cos(q.y));
    float3 r = p * 7.3 + float3(-time * 0.41, time * 0.23, time * 0.33);
    float3 fine = float3(sin(r.y) * cos(r.z), sin(r.z) * cos(r.x), sin(r.x) * cos(r.y));
    return large * 0.17 + fine * (0.015 + high * 0.12);
}
// Curl of an azimuthal Gaussian vector potential. Unlike a radial push, these
// expanding vortex rings retain their circulation after the pressure solve.
float3 inkRisingRing(float3 r, float radial, float axial) {
    float rr = r.x * r.x + r.z * r.z;
    float falloff = exp(-radial * rr - axial * r.y * r.y);
    return float3(2.0 * axial * r.y * r.x, 2.0 * (1.0 - radial * rr),
                  2.0 * axial * r.y * r.z) * falloff;
}
float3 inkForwardRing(float3 r) {
    float rr = r.x * r.x + r.y * r.y;
    float falloff = exp(-0.9 * rr - 1.1 * r.z * r.z);
    return float3(2.2 * r.z * r.x, 2.2 * r.z * r.y, 2.0 * (1.0 - 0.9 * rr)) * falloff;
}
float3 inkAxialRing(float3 r, float3 axis, float radial, float axial) {
    float along = dot(r, axis);
    float3 across = r - axis * along;
    float radiusSquared = dot(across, across);
    float falloff = exp(-radial * radiusSquared - axial * along * along);
    return (2.0 * axial * along * across + 2.0 * (1.0 - radial * radiusSquared) * axis) * falloff;
}
float3 inkMotionFlow(float3 p, constant InkUniforms &u) {
    float3 r = p - float3(0, 2.50, -0.1);
    float3 yAxis(0, 1, 0), xAxis(1, 0, 0), zAxis(0, 0, 1);
    float3 swirl = cross(yAxis, r) * exp(-dot(r, r) * 0.22);
    float3 suction = inkAxialRing(p - float3(-1.20, 2.50, -0.1), xAxis, 0.65, 0.42)
                   + inkAxialRing(p - float3(1.20, 2.50, -0.1), -xAxis, 0.65, 0.42)
                   + swirl * 0.80;
    float3 eruption = inkAxialRing(p - float3(0, 2.25, -0.75), zAxis, 0.48, 0.65);
    float3 collision = inkAxialRing(p - float3(-2.05, 1.65, 0.15), xAxis, 0.85, 0.90)
                     + inkAxialRing(p - float3(2.05, 1.65, 0.15), -xAxis, 0.85, 0.90)
                     + cross(zAxis, p - float3(0, 1.65, 0.15)) * exp(-dot(r, r) * 0.32) * 0.60;
    float breath = cos(u.clock.x * 1.70 + u.structure.y * u.expression.w * 6.2831853);
    float3 breathing = (inkAxialRing(r, xAxis, 0.48, 0.50)
                       + inkAxialRing(r, yAxis, 0.42, 0.50)) * breath;
    float3 sinking = inkAxialRing(p - float3(0, 2.40, 0.05), -yAxis, 0.25, 0.32)
                   + inkAxialRing(p - float3(0, 0.85, 0.05), -yAxis, 0.48, 1.1) * 0.55;
    float splitPhase = cos(u.clock.x * 0.95 + u.structure.z * u.expression.w * 6.2831853);
    float3 split = (inkAxialRing(p - float3(-0.9, 2.80, 0), -xAxis, 0.52, 0.70)
                   + inkAxialRing(p - float3(0.9, 2.80, 0), xAxis, 0.52, 0.70)) * splitPhase;
    return suction * u.motionA.x + eruption * u.motionA.y + collision * u.motionA.z
         + breathing * u.motionA.w + sinking * u.motionB.x + split * u.motionB.y;
}
// Every FFT bin has its own position, rotation axis and pigment. Only the local
// 3 x 3 neighbors are evaluated at each cell; no band is collapsed into an average.
float3 inkSpectrumCenter(uint band, constant InkUniforms &u) {
    float2 grid(float(band % 8), float(band / 8));
    return u.minimum.xyz + float3((grid.x + 0.5) / 8.0 * u.extent.x,
                                  (grid.y + 0.5) / 8.0 * u.extent.y,
                                  0.70 + 0.18 * sin(float(band) * 0.73));
}
void inkSpectrumFields(float3 p, float3 uvw, constant InkUniforms &u, constant float *spectrum,
                       thread float3 &force, thread float3 &pigment) {
    int2 cell = clamp(int2(uvw.xy * 8.0), int2(0), int2(7));
    force = 0; pigment = 0;
    for (int dy = -1; dy <= 1; ++dy) {
        for (int dx = -1; dx <= 1; ++dx) {
            int2 grid = cell + int2(dx, dy);
            if (any(grid < 0) || any(grid >= 8)) continue;
            uint band = uint(grid.y * 8 + grid.x);
            float amplitude = spectrum[band];
            if (amplitude <= 0.0001) continue;
            float3 offset = p - inkSpectrumCenter(band, u);
            float3 axis = normalize(float3(sin(float(band) * 1.37 + 0.4),
                                            cos(float(band) * 0.81 + 0.2),
                                            sin(float(band) * 0.63 + 0.7)));
            float falloff = exp(-dot(offset, offset) * 6.0);
            force += amplitude * cross(axis, offset) * falloff * 13.0;
            // Rotation has a broad neighborhood, but new dye stays inside one narrow
            // filament. Filling all 64 neighborhoods continuously made a uniform curtain.
            float source = amplitude * exp(-dot(offset, offset) * 16.0) * 0.24;
            float bin = float(band) / 63.0;
            pigment += source * float3(0.25 + bin * 0.60, 0.85 - bin * 0.55,
                                       0.20 + 0.55 * sin(bin * 3.14159265));
        }
    }
}
float3 inkSourceCenter(bool right, constant InkUniforms &u) {
    float analyzed = u.expression.w;
    float separation = mix(1.75, 1.10 + u.layout.x * 1.30, analyzed);
    float depth = analyzed * (u.layout.z - 0.5) * 0.90;
    float turn = analyzed * sin(u.structure.w * 6.2831853) * 0.20;
    return float3(right ? separation + turn : -separation + turn, 0.65,
                  (right ? 0.35 : 0.10) + depth);
}
float3 inkBoundary(float3 v, uint3 id, uint3 size) {
    if (id.x == 0 || id.x + 1 == size.x) v.x = 0;
    if (id.y == 0 || id.y + 1 == size.y) v.y = 0;
    if (id.z == 0 || id.z + 1 == size.z) v.z = 0;
    return clamp(select(float3(0), v, isfinite(v)), float3(-3), float3(3));
}

kernel void seedInk(texture3d<half, access::write> density [[texture(0)]],
                    texture3d<half, access::write> velocity [[texture(1)]],
                    constant InkUniforms &u [[buffer(0)]], uint3 id [[thread_position_in_grid]]) {
    uint3 size(density.get_width(), density.get_height(), density.get_depth());
    if (outsideInk(id, size)) return;
    float3 uvw = inkCoordinate(id, size), p = u.minimum.xyz + uvw * u.extent.xyz;
    // Irregular smoothly joined lobes retain thick round cores. Noise erodes the outer
    // transition, rather than cutting all concentrations into disconnected wisps.
    float3 warp = float3(inkFBM(p * 1.25 + 8.7), inkFBM(p * 1.3 + 37.1), inkFBM(p * 1.4 - 9.3)) - 0.48;
    float3 q = p + warp * float3(0.95, 0.70, 0.95);
    q += inkEddies(p * 0.85, 0.7, 0.45) * 0.9;
    float coarse = inkFBM(q * 2.0 + float3(1.1, 4.2, 9.5));
    float medium = inkFBM(q * 4.1 + float3(3.1, 0.8, -6.0));
    float fine = inkFBM(q * 8.0 + 19.1);
    float folds = 1.0 - abs(sin(inkFBM(q * 2.5 + float3(1.2, 4.8, 7.3)) * 19.0));
    float pores = smoothstep(0.32, 0.53, inkNoise(q * 1.9 + 17.3));
    float detail = (0.50 + 0.95 * medium + 0.20 * fine) * mix(0.03, 1.0, pores)
                 * (0.75 + 0.42 * folds);
    float leftDistance = inkEllipsoid(q, float3(-1.9, 4.85, -0.05), float3(1.3, 1.7, 0.95));
    leftDistance = inkJoin(leftDistance, inkEllipsoid(q, float3(-2.45, 3.25, 0.20), float3(1.1, 1.15, 0.85)), 0.35);
    leftDistance = inkJoin(leftDistance, inkEllipsoid(q, float3(-1.40, 2.40, 0.45), float3(1.05, 1.25, 0.95)), 0.33);
    leftDistance = inkJoin(leftDistance, inkEllipsoid(q, float3(-0.70, 3.85, 0.10), float3(0.7, 0.8, 0.60)), 0.28);
    leftDistance = inkJoin(leftDistance, inkEllipsoid(q, float3(-2.70, 1.85, 0.70), float3(0.78, 0.87, 0.75)), 0.28);
    leftDistance = inkJoin(leftDistance, inkEllipsoid(q, float3(-1.60, 1.20, -0.35), float3(1.25, 1.2, 0.90)), 0.32);
    leftDistance = inkJoin(leftDistance, inkEllipsoid(q, float3(-2.55, 0.60, 0.20), float3(1.4, 0.80, 0.95)), 0.32);
    leftDistance = inkJoin(leftDistance, inkEllipsoid(q, float3(-0.75, 0.55, 0.45), float3(1.0, 0.8, 0.85)), 0.32);
    float rightDistance = inkEllipsoid(q, float3(2.35, 1.0, 0.15), float3(1.0, 1.05, 0.85));
    rightDistance = inkJoin(rightDistance, inkEllipsoid(q, float3(1.55, 2.05, 0.35), float3(0.87, 0.95, 0.75)), 0.28);
    rightDistance = inkJoin(rightDistance, inkEllipsoid(q, float3(2.70, 2.65, -0.25), float3(0.73, 0.82, 0.65)), 0.25);
    rightDistance = inkJoin(rightDistance, inkEllipsoid(q, float3(1.05, 0.50, 0.45), float3(0.75, 0.65, 0.75)), 0.27);
    rightDistance = inkJoin(rightDistance, inkEllipsoid(q, float3(3.00, 0.45, 0.0), float3(0.90, 0.65, 0.90)), 0.27);
    float edgeNoise = (coarse - 0.48) * 0.70 + (medium - 0.48) * 0.18;
    float left = smoothstep(0.26, -0.13, leftDistance + edgeNoise);
    float right = smoothstep(0.24, -0.12, rightDistance + edgeNoise);
    float leftCore = smoothstep(0.08, -0.32, leftDistance);
    float rightCore = smoothstep(0.06, -0.30, rightDistance);
    // Add distinct outer plumes in the expanded space; all central lobe positions
    // and radii above stay in world units, rather than stretching the old field.
    float outerLeftDistance = inkEllipsoid(q, float3(-4.20, 1.25, -0.25), float3(0.72, 1.30, 0.80));
    outerLeftDistance = inkJoin(outerLeftDistance,
        inkEllipsoid(q, float3(-4.0, 3.0, -0.55), float3(0.63, 0.95, 0.70)), 0.24);
    float outerRightDistance = inkEllipsoid(q, float3(4.12, 1.85, -0.35), float3(0.68, 1.12, 0.78));
    outerRightDistance = inkJoin(outerRightDistance,
        inkEllipsoid(q, float3(4.28, 0.65, 0.0), float3(0.72, 0.75, 0.70)), 0.22);
    float outerLeft = smoothstep(0.20, -0.12, outerLeftDistance + edgeNoise);
    float outerRight = smoothstep(0.20, -0.12, outerRightDistance + edgeNoise);
    float outerDetail = mix(detail, 0.88 + coarse * 0.12,
                            smoothstep(0.06, -0.25, min(outerLeftDistance, outerRightDistance)));
    float coreDetail = 0.90 + coarse * 0.15;
    float rearShape = 1.0 - length(float2((q.x - 0.30) / 1.9, (q.z + 0.85) / 0.7)) + (coarse - 0.46) * 2.0;
    float blue = smoothstep(-0.1, 0.5, rearShape) * (0.10 + 0.24 * medium);
    float centralShape = 1.0 - length(float2((q.x - 0.12) / 0.70, (q.z + 0.55) / 0.50))
                       + (inkFBM(q * 3.1 + 35.2) - 0.46) * 2.3;
    float centralPink = smoothstep(-0.2, 0.55, centralShape) * smoothstep(0.55, 1.75, q.y)
                      * (0.08 + 0.16 * folds) * mix(0.2, 1.0, pores);
    float edge = smoothstep(0.0, 0.035, uvw.x) * smoothstep(1.0, 0.95, uvw.x)
               * smoothstep(0.0, 0.05, uvw.z) * smoothstep(1.0, 0.95, uvw.z)
               * smoothstep(1.0, 0.98, uvw.y);
    float3 dye = clamp(float3(blue * (0.6 + medium) + outerRight * outerDetail * 0.32,
                              left * 2.4 * mix(detail, coreDetail, leftCore) + outerLeft * outerDetail * 1.20,
                              right * 1.15 * mix(detail, coreDetail, rightCore) + centralPink
                              + outerRight * outerDetail * 0.42), float3(0), float3(3)) * edge;
    density.write(half4(half3(dye), half(dye.x + dye.y + dye.z)), id);
    float3 v = inkEddies(p, u.clock.x, 0) * 0.6 + float3(0, 0.045 * (left + right), 0);
    velocity.write(half4(half3(inkBoundary(v, id, size)), 0), id);
}

kernel void advectInkVelocity(texture3d<half, access::sample> oldVelocity [[texture(0)]],
                              texture3d<half, access::read> density [[texture(1)]],
                              texture3d<half, access::write> newVelocity [[texture(2)]],
                              constant InkUniforms &u [[buffer(0)]], constant float *spectrum [[buffer(1)]],
                              uint3 id [[thread_position_in_grid]]) {
    uint3 size(newVelocity.get_width(), newVelocity.get_height(), newVelocity.get_depth());
    if (outsideInk(id, size)) return;
    float dt = u.clock.y;
    float3 uvw = inkCoordinate(id, size), p = u.minimum.xyz + uvw * u.extent.xyz;
    float3 v = float3(oldVelocity.sample(inkSampler, uvw).xyz);
    v = float3(oldVelocity.sample(inkSampler, uvw - v * dt / u.extent.xyz).xyz) * exp(-dt * 0.85);
    float concentration = float(density.read(id).w);
    float low = max(u.levels.y, u.music.z), analyzed = u.expression.w;
    float activity = saturate(u.levels.x * 0.7 + low * 0.45 + u.music.x * 0.35 + u.music.y * 0.25 + u.music.w * 0.15);
    float pace = mix(1.0, 0.65 + u.structure.x * 1.85, analyzed);
    float tempo = mix(1.0, u.rhythm.w, analyzed);
    float lift = (0.018 + low * 0.075) * min(1.8, concentration);
    float3 leftOffset = p - inkSourceCenter(false, u), rightOffset = p - inkSourceCenter(true, u);
    float width = mix(1.0, 0.70 + u.layout.y * 0.65, analyzed);
    float3 rising = inkRisingRing(leftOffset, 0.85 / width, 0.60)
                  + inkRisingRing(rightOffset, 1.05 / width, 0.75);
    // Pace changes circulation speed; beat phase breathes each ring between onsets.
    float beatBreath = 1.0 + analyzed * 0.28 * cos(u.rhythm.x * 6.2831853);
    v += dt * (inkEddies(p, u.clock.x * pace, u.levels.w) * (0.6 + activity * 1.65) * pace
               + float3(0, lift, 0) + rising * low * 0.20 * pace * beatBreath);
    v += u.clock.z * 0.42 * rising;
    // A downbeat rolls the full plume sideways. Phrase / segment / section progress
    // continuously turn the axis; key and mode bias the direction, without reseeding.
    float angle = 6.2831853 * (u.rhythm.y * 0.35 + u.structure.y * 0.45
                               + u.structure.z * 0.25 + u.structure.w * 0.30 + u.expression.z * 4.5)
                + u.expression.y * 0.45;
    float3 axis(cos(angle), 0.28 * sin(u.structure.y * 6.2831853), sin(angle));
    float3 center(0, 2.2, -0.2), r = p - center;
    float3 roll = cross(axis, r) * exp(-dot(r * r, float3(0.10, 0.16, 0.28)));
    float composition = 0.20 + u.expression.x * 0.28 + u.layout.w * 0.32;
    v += dt * analyzed * activity * roll * (composition + u.rhythm.z * 1.45) * tempo;
    // Singing visibly advances the right pink stream into the foreground.
    v += dt * u.music.x * (inkForwardRing(rightOffset - float3(0, 0.55, -0.15)) * 0.65
                          + inkRisingRing(rightOffset, 1.1, 0.8) * 0.12);
    // The remaining instruments stir the rear blue layer at a broader scale.
    v += dt * u.music.w * inkEddies(p * 0.65, u.clock.x * 0.7, 0.15) * 1.20;
    float3 spectrumForce, spectrumPigment;
    inkSpectrumFields(p, uvw, u, spectrum, spectrumForce, spectrumPigment);
    float strength = 0.20 + u.motionB.z * 1.30 + u.motionB.w * 0.45
                   + u.levels.x * 0.35 + low * 0.35 + u.levels.z * 0.25 + u.levels.w * 0.20;
    v += dt * (inkMotionFlow(p, u) * strength + spectrumForce * (0.65 + u.motionB.z * 0.65));
    float3 outerLeftOffset = p - float3(-4.15, 1.35, -0.2);
    float3 outerRightOffset = p - float3(4.12, 1.35, -0.2);
    v += dt * (inkRisingRing(outerLeftOffset, 1.4, 0.85)
               - inkRisingRing(outerRightOffset, 1.4, 0.85)) * (0.06 + activity * 0.28);
    newVelocity.write(half4(half3(inkBoundary(v, id, size)), 0), id);
}

kernel void inkDivergence(texture3d<half, access::read> velocity [[texture(0)]],
                          texture3d<half, access::write> divergence [[texture(1)]],
                          texture3d<half, access::write> zeroPressure [[texture(2)]],
                          constant InkUniforms &u [[buffer(0)]], uint3 id [[thread_position_in_grid]]) {
    uint3 size(velocity.get_width(), velocity.get_height(), velocity.get_depth());
    if (outsideInk(id, size)) return;
    int3 c = int3(id);
    float3 h = inkCellSize(size, u);
    float x = float(velocity.read(inkNeighbor(c + int3(1, 0, 0), size)).x)
            - float(velocity.read(inkNeighbor(c - int3(1, 0, 0), size)).x);
    float y = float(velocity.read(inkNeighbor(c + int3(0, 1, 0), size)).y)
            - float(velocity.read(inkNeighbor(c - int3(0, 1, 0), size)).y);
    float z = float(velocity.read(inkNeighbor(c + int3(0, 0, 1), size)).z)
            - float(velocity.read(inkNeighbor(c - int3(0, 0, 1), size)).z);
    divergence.write(half4(half(0.5 * (x / h.x + y / h.y + z / h.z))), id);
    zeroPressure.write(half4(0), id);
}

kernel void solveInkPressure(texture3d<half, access::read> oldPressure [[texture(0)]],
                             texture3d<half, access::read> divergence [[texture(1)]],
                             texture3d<half, access::write> newPressure [[texture(2)]],
                             constant InkUniforms &u [[buffer(0)]], uint3 id [[thread_position_in_grid]]) {
    uint3 size(oldPressure.get_width(), oldPressure.get_height(), oldPressure.get_depth());
    if (outsideInk(id, size)) return;
    int3 c = int3(id);
    float3 h = inkCellSize(size, u), w = 1.0 / (h * h);
    float x = float(oldPressure.read(inkNeighbor(c + int3(1, 0, 0), size)).x)
            + float(oldPressure.read(inkNeighbor(c - int3(1, 0, 0), size)).x);
    float y = float(oldPressure.read(inkNeighbor(c + int3(0, 1, 0), size)).x)
            + float(oldPressure.read(inkNeighbor(c - int3(0, 1, 0), size)).x);
    float z = float(oldPressure.read(inkNeighbor(c + int3(0, 0, 1), size)).x)
            + float(oldPressure.read(inkNeighbor(c - int3(0, 0, 1), size)).x);
    float p = (dot(float3(x, y, z), w) - float(divergence.read(id).x)) / (2.0 * (w.x + w.y + w.z));
    newPressure.write(half4(half(clamp(p, -10.0, 10.0))), id);
}

kernel void projectInkVelocity(texture3d<half, access::read> oldVelocity [[texture(0)]],
                               texture3d<half, access::read> pressure [[texture(1)]],
                               texture3d<half, access::write> newVelocity [[texture(2)]],
                               constant InkUniforms &u [[buffer(0)]], uint3 id [[thread_position_in_grid]]) {
    uint3 size(oldVelocity.get_width(), oldVelocity.get_height(), oldVelocity.get_depth());
    if (outsideInk(id, size)) return;
    int3 c = int3(id);
    float3 h = inkCellSize(size, u);
    float x = float(pressure.read(inkNeighbor(c + int3(1, 0, 0), size)).x)
            - float(pressure.read(inkNeighbor(c - int3(1, 0, 0), size)).x);
    float y = float(pressure.read(inkNeighbor(c + int3(0, 1, 0), size)).x)
            - float(pressure.read(inkNeighbor(c - int3(0, 1, 0), size)).x);
    float z = float(pressure.read(inkNeighbor(c + int3(0, 0, 1), size)).x)
            - float(pressure.read(inkNeighbor(c - int3(0, 0, 1), size)).x);
    float3 v = float3(oldVelocity.read(id).xyz) - 0.5 * float3(x, y, z) / h;
    newVelocity.write(half4(half3(inkBoundary(v, id, size)), 0), id);
}

kernel void predictInkDensity(texture3d<half, access::sample> oldDensity [[texture(0)]],
                              texture3d<half, access::read> velocity [[texture(1)]],
                              texture3d<half, access::write> predictedDensity [[texture(2)]],
                              constant InkUniforms &u [[buffer(0)]], uint3 id [[thread_position_in_grid]]) {
    uint3 size(predictedDensity.get_width(), predictedDensity.get_height(), predictedDensity.get_depth());
    if (outsideInk(id, size)) return;
    float3 uvw = inkCoordinate(id, size);
    float3 back = uvw - float3(velocity.read(id).xyz) * u.clock.y / u.extent.xyz;
    float3 dye = any(back < 0.0) || any(back > 1.0) ? float3(0)
                : float3(oldDensity.sample(inkSampler, back).xyz);
    predictedDensity.write(half4(half3(dye), half(dye.x + dye.y + dye.z)), id);
}

kernel void advectInkDensity(texture3d<half, access::sample> oldDensity [[texture(0)]],
                             texture3d<half, access::read> velocity [[texture(1)]],
                             texture3d<half, access::write> newDensity [[texture(2)]],
                             texture3d<half, access::sample> predictedDensity [[texture(3)]],
                             constant InkUniforms &u [[buffer(0)]], constant float *spectrum [[buffer(1)]],
                             uint3 id [[thread_position_in_grid]]) {
    uint3 size(newDensity.get_width(), newDensity.get_height(), newDensity.get_depth());
    if (outsideInk(id, size)) return;
    float dt = u.clock.y;
    float3 uvw = inkCoordinate(id, size), p = u.minimum.xyz + uvw * u.extent.xyz;
    float3 v = float3(velocity.read(id).xyz);
    float3 back = uvw - v * dt / u.extent.xyz;
    // A backtrace leaving the domain contains no dye. Repeating a dense floor texel here
    // would continuously stretch it upward and eventually turn each plume into a full wall.
    float3 dye = float3(predictedDensity.read(id).xyz);
    float3 forward = uvw + v * dt / u.extent.xyz;
    if (all(back >= 0.0) && all(back <= 1.0) && all(forward >= 0.0) && all(forward <= 1.0)) {
        // Correct the interpolation loss by transporting the prediction back. Clamp
        // to the donor cells so restored folds cannot introduce new extrema or dye.
        float3 reversed = float3(predictedDensity.sample(inkSampler, forward).xyz);
        float3 corrected = dye + 0.5 * (float3(oldDensity.read(id).xyz) - reversed);
        int3 donor = int3(floor(back * float3(size) - 0.5));
        float3 lower(3), upper(0);
        for (int z = 0; z < 2; ++z) for (int y = 0; y < 2; ++y) for (int x = 0; x < 2; ++x) {
            float3 value = float3(oldDensity.read(inkNeighbor(donor + int3(x, y, z), size)).xyz);
            lower = min(lower, value); upper = max(upper, value);
        }
        dye = clamp(corrected, lower, upper);
    }
    // Dense violet cores linger; dilute mixed pigment disperses before it can
    // accumulate into one unbroken sheet across the volume.
    float3 decay = mix(float3(0.24, 0.20, 0.26), float3(0.13, 0.055, 0.15),
                       smoothstep(float3(0.08), float3(0.65), dye));
    dye *= exp(-dt * decay);
    float3 leftOffset = p - inkSourceCenter(false, u), rightOffset = p - inkSourceCenter(true, u);
    float3 rearOffset = p - float3(0.3, 0.55, -0.9), centralOffset = p - float3(0.1, 1.15, -0.55);
    float analyzed = u.expression.w;
    float thickness = mix(1.0, 0.55 + u.layout.y * 0.90, analyzed);
    float leftSource = exp(-dot(leftOffset * leftOffset, float3(1.6, 2.1, 2.4)) / thickness);
    float rightSource = exp(-dot(rightOffset * rightOffset, float3(1.9, 2.4, 2.6)) / thickness);
    float rearSource = exp(-dot(rearOffset * rearOffset, float3(1.2, 2.4, 1.8)));
    float centralSource = exp(-dot(centralOffset * centralOffset, float3(6.0, 1.8, 5.0)));
    float supplyNoise = inkNoise(p * 3.5 + float3(0, -u.clock.x * 0.35, 0));
    float folded = 0.06 + 1.55 * smoothstep(0.34, 0.70, supplyNoise);
    float low = max(u.levels.y, u.music.z), amplitude = u.levels.x;
    float richness = 1.0 + analyzed * (u.expression.x * 0.28 + u.layout.w * 0.22);
    float3 injection = folded * richness * float3(rearSource * (amplitude * 0.45 + u.levels.w * 0.35),
                                                 leftSource * (amplitude * 0.28 + low * 0.65),
                                                 rightSource * (amplitude * 0.18 + u.music.x * 0.60) + centralSource * u.music.x * 0.08);
    float3 outerLeftOffset = p - float3(-4.15, 0.65, -0.2);
    float3 outerRightOffset = p - float3(4.12, 0.65, -0.2);
    float outerLeftSource = exp(-dot(outerLeftOffset, outerLeftOffset) * 2.4);
    float outerRightSource = exp(-dot(outerRightOffset, outerRightOffset) * 2.4);
    injection += folded * float3(outerRightSource * (u.music.w * 0.25 + u.levels.w * 0.20),
                                 outerLeftSource * (low * 0.30 + amplitude * 0.12),
                                 outerRightSource * u.music.x * 0.22);
    float3 spectrumForce, spectrumPigment;
    inkSpectrumFields(p, uvw, u, spectrum, spectrumForce, spectrumPigment);
    // Fresh pigment stops entering an already dense cell. Existing lobes are not
    // clipped to this budget: they advect and dissipate naturally.
    float3 pigmentRoom = saturate(1.0 - dye / float3(0.45, 1.4, 1.5));
    dye += dt * u.clock.w * (injection + spectrumPigment) * pigmentRoom;
    // Forward ejections keep moving, then disperse rather than collect as a front wall.
    dye *= exp(-dt * smoothstep(0.60, 0.94, uvw.z) * 0.30);
    float edge = smoothstep(0.0, 0.045, uvw.x) * smoothstep(1.0, 0.955, uvw.x)
               * smoothstep(0.0, 0.06, uvw.z) * smoothstep(1.0, 0.94, uvw.z)
               * smoothstep(1.0, 0.97, uvw.y);
    dye *= exp(-dt * (1.0 - edge) * 3.0);
    dye = clamp(select(float3(0), dye, isfinite(dye)), float3(0), float3(3));
    newDensity.write(half4(half3(dye), half(dye.x + dye.y + dye.z)), id);
}
