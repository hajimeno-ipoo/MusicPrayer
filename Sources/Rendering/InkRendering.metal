#include <metal_stdlib>
using namespace metal;

struct InkUniforms {
    float4 viewport; // aspect, music clock, presence, RMS
    float4 audio;    // bass, vocal, drums, treble
    float4 rhythm;   // beat, bar, section change, loudness
    float4 timing;   // beat phase, bar phase, tempo / 120, musical activity
    float4 structure; // section, segment, phrase progress, analysis available
    float4 scene;    // separation, thickness, depth, glow from actual section statistics
    float4 material; // short term relative loudness, peak, section water, mid band
    float4 music;    // small key hue rotation, mode temperature, bounded detail phase/travel
    float4 instruments; // singing, drums, bass, other activity
    float4 domainMinimum; // shared with actual fluid world bounds
    float4 domainExtent;
    float4 sampling; // signed separation, inverse thickness/depth, phrase breathing
    float4 offset;   // section x drift, segment lift, singing/phrase forward motion
    float4 eye;
    float4 target;
    float4 layout;   // display width / density width, water horizon
};
struct InkVertex { float4 position [[position]]; float2 uv; };
vertex InkVertex inkFullscreenVertex(uint id [[vertex_id]]) {
    float2 p = float2((id << 1) & 2, id & 2);
    return {float4(p * 2.0 - 1.0, 0.0, 1.0), float2(p.x, 1.0 - p.y)};
}
constexpr sampler inkLinear(coord::normalized, address::clamp_to_edge, filter::linear);

float inkHash(float3 p) {
    p = fract(p * float3(0.1031, 0.1030, 0.0973));
    p += dot(p, p.yxz + 33.33);
    return fract((p.x + p.y) * p.z);
}
float inkNoise(float3 p) {
    float3 i = floor(p), f = fract(p);
    f = f * f * (3.0 - 2.0 * f);
    return mix(mix(mix(inkHash(i), inkHash(i + float3(1,0,0)), f.x),
                   mix(inkHash(i + float3(0,1,0)), inkHash(i + float3(1,1,0)), f.x), f.y),
               mix(mix(inkHash(i + float3(0,0,1)), inkHash(i + float3(1,0,1)), f.x),
                   mix(inkHash(i + float3(0,1,1)), inkHash(i + float3(1,1,1)), f.x), f.y), f.z);
}
// Value noise and its analytic 3D derivative use the same eight corner samples.
// The derivatives describe real density folds, not a brightness texture on a flat image.
float4 inkNoiseGradient(float3 p) {
    float3 i = floor(p), v = fract(p);
    float3 f = v * v * (3.0 - 2.0 * v), df = 6.0 * v * (1.0 - v);
    float a = inkHash(i), b = inkHash(i + float3(1,0,0));
    float c = inkHash(i + float3(0,1,0)), d = inkHash(i + float3(1,1,0));
    float e = inkHash(i + float3(0,0,1)), g = inkHash(i + float3(1,0,1));
    float h = inkHash(i + float3(0,1,1)), j = inkHash(i + float3(1,1,1));
    float frontBottom = mix(a,b,f.x), frontTop = mix(c,d,f.x);
    float backBottom = mix(e,g,f.x), backTop = mix(h,j,f.x);
    float front = mix(frontBottom,frontTop,f.y), back = mix(backBottom,backTop,f.y);
    float dx = mix(mix(b-a,d-c,f.y), mix(g-e,j-h,f.y), f.z) * df.x;
    float dy = mix(frontTop-frontBottom, backTop-backBottom, f.z) * df.y;
    float dz = (back-front) * df.z;
    return float4(mix(front,back,f.z), dx, dy, dz);
}
float inkSmoothDerivative(float a, float b, float x) {
    float t = saturate((x-a)/(b-a));
    return 6.0 * t * (1.0-t) / (b-a);
}
float2 inkLocalSpectrum(float3 p, constant InkUniforms &u, constant float *spectrum) {
    // The 64 bins remain separate: ascending frequency follows the moving ink across x.
    // Adjacent-bin interpolation avoids sharp stripes; no low/mid/high average replaces them.
    float position = clamp(((p.x / u.layout.x - u.domainMinimum.x) / u.domainExtent.x) * 63.0
                           + sin(p.y * 1.05 + p.z * 0.45) * 0.6, 0.0, 63.0);
    uint lower = uint(position);
    float amplitude = mix(spectrum[lower], spectrum[min(lower + 1, 63u)], fract(position));
    return float2(amplitude, position / 63.0);
}
float3 inkDetailPosition(float3 p, constant InkUniforms &u) {
    // Pace controls fine curls, tempo controls their periodic sway. Music time freezes on pause.
    // Activity/tempo are bounded offsets, never musicTime * a changing multiplier:
    // an analysis update several minutes into a song cannot teleport the noise field.
    float phase = u.music.z;
    float curlTravel = u.music.w;
    float phrase = u.sampling.w;
    return float3(p.x / u.layout.x + sin(phase + p.y * 0.65) * (0.035 + phrase * 0.08),
                  p.y - curlTravel,
                  p.z + sin(phase * 0.72 + p.y) * (0.05 + u.timing.w * 0.09));
}
float4 inkCoreDetail(float3 p, constant InkUniforms &u) {
    float3 q = inkDetailPosition(p,u);
    float4 body = inkNoiseGradient(q * 2.7 + float3(1.7,8.1,4.3));
    float4 wrinkle = inkNoiseGradient(q * 6.3 + float3(4.2,7.8,1.6));
    float broad = 0.60 + body.x * 0.70;
    float fine = 0.90 + wrinkle.x * 0.20;
    float3 gradient = body.yzw * (2.7 * 0.70) * fine + wrinkle.yzw * (6.3 * 0.20) * broad;
    gradient.x /= u.layout.x;
    // Concentrated ink retains a solid body: this never opens holes in its core.
    return float4(broad * fine, gradient);
}
float4 inkCloudDetail(float3 p, constant InkUniforms &u, float2 band) {
    float3 q = inkDetailPosition(p,u);
    float curlPhase = p.y * (2.0 + band.y * 5.0) + u.viewport.y * (0.4 + band.y * 0.3);
    q += float3(sin(curlPhase + p.z * 3.0) * 0.045,
                sin(p.x * 3.0 + curlPhase) * 0.025,
                cos(curlPhase + p.x * 2.0) * 0.035) * band.x;
    // Coherent 3D billows alternate dense cores with empty pockets.
    float4 coarse = inkNoiseGradient(q * 2.7 + float3(1.7,8.1,4.3));
    float core = smoothstep(0.43,0.72,coarse.x);
    float ridgeDistance = abs(coarse.x-0.42);
    float sheet = 1.0 - smoothstep(0.015,0.075,ridgeDistance);
    float broad = core + sheet * 0.26;
    // Empty pockets have zero density and derivative, independent of the fine noise.
    if (broad == 0.0) return 0.0;
    float4 fine = inkNoiseGradient(q * 8.3 + float3(7.4,2.6,9.8));
    float fineMask = smoothstep(0.26,0.71,fine.x);
    float detail = broad * (0.34 + fineMask * 0.86);
    float coreDerivative = inkSmoothDerivative(0.43,0.72,coarse.x);
    float sheetDerivative = -inkSmoothDerivative(0.015,0.075,ridgeDistance) * sign(coarse.x-0.42);
    float3 gradient = coarse.yzw * 2.7 * (coreDerivative + sheetDerivative * 0.26)
                    * (0.34 + fineMask * 0.86)
                    + broad * 0.86 * fine.yzw * 8.3 * inkSmoothDerivative(0.26,0.71,fine.x);
    gradient.x /= u.layout.x;
    return float4(detail,gradient);
}
float4 inkDensity(texture3d<half> field, float3 p, constant InkUniforms &u) {
    float3 samplePoint = p;
    // Section statistics reshape real 3D dye, without choosing a theme by section number.
    float side = p.x / u.layout.x * 1.4;
    samplePoint.x -= side / (1.0 + abs(side)) * u.sampling.x * u.layout.x;
    samplePoint.y = 2.2 + (p.y - 2.2) * u.sampling.y;
    samplePoint.z = p.z * u.sampling.z;
    samplePoint.x -= u.offset.x * u.layout.x;
    samplePoint.y -= u.offset.y;
    samplePoint.z -= u.offset.z;
    samplePoint.x /= u.layout.x;
    float3 uv = (samplePoint - u.domainMinimum.xyz) / u.domainExtent.xyz;
    if (any(uv < 0.0) || any(uv > 1.0)) return 0.0;
    return float4(field.sample(inkLinear, uv)) * saturate(u.viewport.z);
}
float inkCoreConcentration(float4 dye) {
    // Do not turn overlapping dilute pigments into a solid core merely by summing their channels.
    return max(dye.x,max(dye.y,dye.z));
}
float inkOpticalDensity(float4 dye) {
    // The dye texture stores pigment amounts, rather than calibrated extinction.
    // Dilute overlapping colors transmit light; concentrated ink remains fully absorbing.
    float concentration = max(0.0,dye.a);
    float extinction = 0.12 + 0.88 * smoothstep(0.10,0.60,concentration);
    return concentration * extinction;
}
float inkShapedDensity(texture3d<half> field, float3 p, constant InkUniforms &u) {
    float4 dye = inkDensity(field,p,u);
    float value = inkOpticalDensity(dye);
    if (dye.a < 0.008) return 0.0;
    // Soft shadows use the same broad pockets; tiny folds are filtered to their mean.
    // One coarse noise here avoids evaluating six full material gradients per shadow sample.
    float3 q = inkDetailPosition(p,u);
    float solidCore = smoothstep(0.35,1.2,inkCoreConcentration(dye));
    float coarse = inkNoise(q * 2.7 + float3(1.7,8.1,4.3));
    if (solidCore > 0.995) return value * (0.60 + coarse * 0.70);
    float core = smoothstep(0.43,0.72,coarse);
    float sheet = 1.0 - smoothstep(0.015,0.075,abs(coarse-0.42));
    return value * mix((core + sheet * 0.26) * 0.77, 0.60 + coarse * 0.70, solidCore);
}
bool inkBounds(float3 origin, float3 direction, constant InkUniforms &u, thread float2 &range) {
    float3 inv = 1.0 / (direction + float3(1e-7));
    float3 minimum = u.domainMinimum.xyz;
    float3 maximum = minimum + u.domainExtent.xyz;
    minimum.x *= u.layout.x; maximum.x *= u.layout.x;
    float3 a = (minimum - origin) * inv;
    float3 b = (maximum - origin) * inv;
    float3 lo = min(a,b), hi = max(a,b);
    range = float2(max(0.0, max(lo.x, max(lo.y, lo.z))), min(hi.x, min(hi.y, hi.z)));
    return range.y > range.x;
}
float3 inkBackground(float2 uv) {
    float mist = exp(-dot((uv - float2(0.58,0.16)) * float2(1.9,1.3),
                          (uv - float2(0.58,0.16)) * float2(1.9,1.3)) * 3.5);
    return float3(0.003,0.008,0.022) + float3(0.028,0.046,0.077) * mist;
}

float3 inkKeyColor(float3 pigment, constant InkUniforms &u) {
    // Key only nudges the current palette; instrument colors keep their identity.
    float angle = u.music.x * 2.0 * M_PI_F;
    float3 axis = normalize(float3(1.0));
    float3 shifted = pigment * cos(angle) + cross(axis,pigment) * sin(angle)
                   + axis * dot(axis,pigment) * (1.0-cos(angle));
    return max(shifted * (1.0 + float3(0.12,0.015,-0.10) * u.music.y), 0.0);
}

// Front-to-back Beer-Lambert absorption: foreground ink actually hides ink behind it.
float4 inkMarch(texture3d<half> field, float3 origin, float3 direction,
                constant InkUniforms &u, constant float *spectrum, float jitter, uint steps) {
    float2 interval;
    if (!inkBounds(origin, direction, u, interval)) return 0.0;
    float stepLength = (interval.y - interval.x) / float(steps);
    float travel = interval.x + stepLength * jitter;
    float3 accumulated = 0.0;
    float transmittance = 1.0;
    // Back light travels through the moving ink, rather than washing its front surface.
    float3 lightPosition = float3(0.35 * u.layout.x, 4.8, -2.1);
    float energy = saturate(u.viewport.w * 0.7 + u.rhythm.w * 0.85);
    float phrase = u.sampling.w;
    float pulse = saturate(u.rhythm.x + u.rhythm.y * 0.55);
    for (uint i = 0; i < steps; ++i, travel += stepLength) {
        float3 p = origin + direction * travel;
        float4 sample = inkDensity(field, p, u);
        if (sample.a < 0.008) continue;
        // This detail changes the actual optical density. Empty pockets remain transparent,
        // and thin folded sheets overlap at their real z depth inside the advected dye.
        float solidCore = smoothstep(0.35,1.2,inkCoreConcentration(sample));
        float2 localBand = inkLocalSpectrum(p,u,spectrum);
        // A fully dilute sample never uses the solid-core material. Avoid evaluating it.
        float4 detailShape;
        if (solidCore == 0.0) {
            detailShape = inkCloudDetail(p,u,localBand);
        } else if (solidCore > 0.995) {
            detailShape = inkCoreDetail(p,u);
        } else {
            detailShape = mix(inkCloudDetail(p,u,localBand),inkCoreDetail(p,u),solidCore);
        }
        float detail = detailShape.x;
        float materialDensity = max(0.0,sample.a) * detail;
        float density = inkOpticalDensity(sample) * detail;
        if (density < 0.0008) continue;
        float3 weights = max(sample.rgb, 0.0);
        weights /= max(0.0001, weights.x + weights.y + weights.z);
        float3 violetPigment = mix(float3(0.32,0.105,0.48), float3(0.205,0.13,0.255),
                                   smoothstep(0.35,1.4,inkCoreConcentration(sample)));
        float3 singingPigment = mix(float3(0.90,0.38,0.34), float3(0.92,0.15,0.48), u.instruments.x * 0.8);
        float3 pigment = weights.x * float3(0.045,0.23,0.46)
                       + weights.y * violetPigment
                       + weights.z * singingPigment;
        pigment *= 1.0 - weights.y * smoothstep(0.65,2.0,sample.a) * 0.26;
        pigment = inkKeyColor(pigment,u);
        float3 towardLight = normalize(lightPosition - p);
        float shadowDepth = 0.0;
        const float shadowDistances[4] = {0.12, 0.35, 0.75, 1.35};
        const float shadowLengths[4] = {0.20, 0.30, 0.50, 0.65};
        for (uint s = 0; s < 4; ++s) {
            shadowDepth += inkShapedDensity(field, p + towardLight * shadowDistances[s], u) * shadowLengths[s];
        }
        float illumination = exp(-shadowDepth * 2.1);
        // Six genuine density neighbours reveal the curls' orientation in three dimensions.
        // Noise adds small porous folds inside that moving dye, never a screen-space image.
        // One actual fluid voxel retains folds that a fixed three-voxel normal blurred away.
        float3 delta = u.domainExtent.xyz / float3(field.get_width(),field.get_height(),field.get_depth());
        delta.x *= u.layout.x;
        delta.y /= u.sampling.y;
        delta.z /= u.sampling.z;
        float3 gradient;
        gradient.x = inkOpticalDensity(inkDensity(field, p + float3(delta.x,0,0), u))
                   - inkOpticalDensity(inkDensity(field, p - float3(delta.x,0,0), u));
        gradient.y = inkOpticalDensity(inkDensity(field, p + float3(0,delta.y,0), u))
                   - inkOpticalDensity(inkDensity(field, p - float3(0,delta.y,0), u));
        gradient.z = inkOpticalDensity(inkDensity(field, p + float3(0,0,delta.z), u))
                   - inkOpticalDensity(inkDensity(field, p - float3(0,0,delta.z), u));
        gradient /= delta * 2.0;
        gradient = gradient * detail + inkOpticalDensity(sample) * detailShape.yzw * 0.20;
        float gradientLength = length(gradient);
        float3 normal = -gradient / max(0.0001, gradientLength);
        float fold = saturate(dot(normal, towardLight));
        float backlight = pow(saturate(dot(direction, towardLight)), 3.0) * (1.0-solidCore * 0.8);
        float3 fillDirection = normalize(float3(3.0 * u.layout.x, 4.5, 4.0) - p);
        // Front light has its own optical path. Back-light occlusion must not erase
        // an exposed front curve, and a hidden front fold must not receive a flat fill.
        float fillThickness = inkShapedDensity(field,p + fillDirection * 0.24,u) * 0.40
                            + inkShapedDensity(field,p + fillDirection * 0.65,u) * 0.60;
        float fillVisibility = exp(-fillThickness * 1.8);
        float fillStrength = 0.30 + energy * 0.07 + pulse * 0.10
                           + u.instruments.x * 0.15 + u.instruments.w * 0.13 + u.instruments.z * 0.05;
        float fill = saturate(dot(normal,fillDirection)) * fillStrength * fillVisibility;
        float3 ambient = float3(0.34,0.38,0.53) * (0.40 + p.y * 0.025);
        ambient *= (1.0 - weights.z * 0.40) * (0.62 + sqrt(illumination) * 0.38);
        float3 lamp = float3(1.18,0.96,0.91) * illumination
                    * (0.16 + fold * 1.55 + backlight * 0.7);
        float3 radiance = pigment * (ambient + lamp * (0.75 + energy * 1.4) * (1.0 - weights.z * 0.15)
                                    + float3(0.60,0.67,0.83) * fill);
        // Thin folds catch the backlight while the thick purple bodies keep a dark core.
        float edge = exp(-materialDensity * 0.65);
        float depthLight = 0.15 + energy * 0.85 + u.scene.w * 0.20 + phrase * 0.10
                         + u.instruments.w * 0.18 + u.material.w * 0.08;
        float wavefront = exp(-pow((p.y - (0.35 + u.timing.x * 5.1)) / 0.50, 2.0));
        float accent = pulse * (0.20 + wavefront * 1.0) + u.material.y * 0.26;
        // Singing lights the advancing pink channel; drums briefly illuminate its folded edges.
        // Excited ink still has a solid, shadowed core. Internal light escapes most strongly
        // through thin illuminated curls, rather than flattening dense pink dye into white.
        float internalVisibility = exp(-materialDensity * 1.60) * (0.08 + fold * 0.55)
                                 * (0.10 + illumination * 0.90);
        radiance += pigment * (depthLight + accent + weights.z * u.instruments.x * 0.75) * internalVisibility;
        // Warm light scatters along the actual back-light path wherever thin ink moves.
        float backPass = pow(saturate(dot(direction,towardLight)),3.0) * illumination
                       * exp(-materialDensity * 2.0) * (1.0-solidCore);
        radiance += float3(0.32,0.255,0.22) * backPass * (0.55 + energy * 0.45);
        // Beat light follows a moving 3D wavefront and actual exposed curls. It cannot
        // illuminate a shadowed body as an even foreground veil.
        radiance += pigment * pulse * (0.25 + wavefront * 1.1) * fold * illumination * edge;
        radiance += pigment * u.material.y * 0.50 * fold * illumination * edge;
        radiance += pigment * u.instruments.y * (0.42 + u.rhythm.x * 0.35) * fold * edge;
        // Each instrument excites the material it is already carried by. This escaping
        // light follows exposed density curves, rather than brightening the whole cloud.
        float instrumentLight = u.instruments.x * weights.z
                              + u.instruments.z * weights.x
                              + u.instruments.w * (1.0 - weights.z);
        radiance += pigment * instrumentLight * 1.35 * fold * illumination * edge;
        radiance += float3(0.13,0.22,0.30) * u.audio.w * fold * edge * (1.0-solidCore * 0.8);
        radiance += pigment * u.rhythm.z * (0.25 + u.scene.w * 0.45) * illumination;
        radiance *= 1.0 - weights.z * (1.0 - illumination) * 0.25;
        // Real-time spectral light escapes through local fine curls. Dense cores stay absorbing.
        float3 spectralColor = mix(float3(0.12,0.31,0.40), float3(0.34,0.16,0.36), localBand.y);
        radiance += spectralColor * localBand.x * (0.08 + fold * 0.42)
                  * illumination * illumination
                  * exp(-materialDensity * 1.15) * (1.0 - solidCore * 0.92);
        float alpha = 1.0 - exp(-density * 2.7 * stepLength);
        accumulated += radiance * (transmittance * alpha);
        transmittance *= 1.0 - alpha;
        if (transmittance < 0.014) break;
    }
    return float4(accumulated, 1.0 - transmittance);
}

fragment half4 inkVolumeFragment(InkVertex in [[stage_in]], constant InkUniforms &u [[buffer(0)]],
                                 constant float *spectrum [[buffer(1)]],
                                 texture3d<half> field [[texture(0)]], texture2d<float> water [[texture(1)]]) {
    float2 uv = in.uv;
    float3 background = inkBackground(uv);
    if (u.viewport.z <= 0.0001) return half4(half3(background), 1.0h);
    float3 forward = normalize(u.target.xyz - u.eye.xyz);
    float3 right = normalize(cross(forward, float3(0,1,0)));
    float3 up = normalize(cross(right, forward));
    float2 clip = float2(uv.x * 2.0 - 1.0, 1.0 - uv.y * 2.0);
    float3 ray = normalize(forward + right * clip.x * u.viewport.x / u.eye.w + up * clip.y / u.eye.w);
    float jitter = inkHash(float3(floor(in.position.xy), 13.0));
    float4 volume = inkMarch(field, u.eye.xyz, ray, u, spectrum, jitter, 72);
    float3 color = volume.rgb + background * (1.0 - volume.a);
    if (ray.y < -0.001) {
        float floorDistance = -u.eye.y / ray.y;
        if (floorDistance > 0.0) {
            float3 floorPoint = u.eye.xyz + ray * floorDistance;
            float2 waterUV = float2(uv.x, saturate((uv.y - u.layout.y) / max(0.01, 1.0 - u.layout.y)));
            float2 texel = 1.0 / float2(water.get_width(), water.get_height());
            float wave = water.sample(inkLinear, waterUV).r;
            float dx = water.sample(inkLinear, waterUV + float2(texel.x,0)).r
                     - water.sample(inkLinear, waterUV - float2(texel.x,0)).r;
            float dy = water.sample(inkLinear, waterUV + float2(0,texel.y)).r
                     - water.sample(inkLinear, waterUV - float2(0,texel.y)).r;
            float ripples = sin(floorPoint.z * 14.0 + sin(floorPoint.x * 2.5) + u.viewport.y * 0.9
                                + sin(u.timing.x * M_PI_F * 2.0) * u.timing.z * 0.20)
                          * sin(floorPoint.x * 9.0 + floorPoint.z * 2.2 - u.viewport.y * 0.4);
            float3 normal = normalize(float3(-dx * 0.75 + ripples * 0.025,
                                            1.0, -dy * 0.6 + wave * 0.02));
            float3 reflectionDirection = reflect(ray, normal);
            float4 reflected = inkMarch(field, floorPoint + float3(0,0.012,0), reflectionDirection, u, spectrum, jitter, 48);
            float fresnel = 0.10 + 0.82 * pow(1.0 - saturate(-ray.y), 5.0);
            float distanceFade = exp(-floorDistance * 0.015);
            float3 waterColor = float3(0.0025,0.007,0.018)
                             + reflected.rgb * fresnel * distanceFade * (0.84 + u.material.z * 0.24);
            // Accents follow actual wave crests and inherit the reflected ink's color.
            // Flat, unlit water cannot acquire an independent blue beam from a beat.
            float crest = saturate(length(float2(dx, dy)) * 2.0 + abs(wave) * 0.06);
            float musicalLight = 0.12 + u.rhythm.x * 0.18 + u.rhythm.y * 0.14;
            waterColor += reflected.rgb * crest * musicalLight * fresnel * distanceFade * u.viewport.z;
            float waterVisibility = smoothstep(u.layout.y - 0.06, u.layout.y + 0.02, uv.y);
            waterColor = mix(background, waterColor, waterVisibility);
            color = volume.rgb + waterColor * (1.0 - volume.a);
        }
    }
    // Fine high-frequency highlights live on the thin cloud edges, not over the entire frame.
    float glint = pow(inkHash(float3(floor(in.position.xy * 0.45), floor(u.viewport.y * 7.0))), 42.0);
    color += float3(0.010,0.016,0.022) * glint * saturate(u.audio.w) * volume.a * (1.0 - volume.a) * 3.0;
    return half4(half3(max(color, 0.0)), 1.0h);
}
fragment half4 inkCompositeFragment(InkVertex in [[stage_in]], texture2d<half> scene [[texture(0)]],
                                    texture2d<half> bloom [[texture(1)]]) {
    float3 color = float3(scene.sample(inkLinear,in.uv).rgb)
                 + float3(bloom.sample(inkLinear,in.uv).rgb) * 0.24;
    // A restrained filmic curve retains the reference's dark violet shadows.
    color = (color * (2.51 * color + 0.03)) / (color * (2.43 * color + 0.59) + 0.14);
    return half4(half3(saturate(color)),1.0h);
}
