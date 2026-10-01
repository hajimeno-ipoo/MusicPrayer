#include <metal_stdlib>
using namespace metal;

struct FrameUniforms {
    float4 clockAudio;             // time, rms, peak, bass FFT
    float4 bandsBeat;              // mid, treble, beat, bar
    float4 rhythmInstruments;      // pace, vocal, drums, bass activity
    float4 instrumentsStructure;   // other, section, segment, phrase
    float4 structureColor;         // section transition, hue, mode, loudness
    float4 lightState;             // density, has analysis, track presence, unused
    float4 viewport;               // aspect, width, height, horizon
    float4 tempoPhase;             // BPM / 120, beat phase, bar phase, unused
    float4 sceneLayout;            // Section mean: separation, thickness, depth, glow
    float4 sceneWater;             // Section mean: water intensity, unused
    float4 cameraEye;
    float4 cameraTarget;
};
struct RibbonOut {
    float4 position [[position]];
    float3 world;
    float2 uv;
    float3 color;
    float activity;
    float glow;
    float opacity;
};
struct ScreenOut { float4 position [[position]]; float2 uv; };
constexpr sampler linearSampler(coord::normalized, address::clamp_to_edge, filter::linear);
constexpr sampler nearestSampler(coord::normalized, address::clamp_to_edge, filter::nearest);
constant float tau = 6.28318530718;

float4 projectWorld(float3 world, constant FrameUniforms& f) {
    float3 forward = normalize(f.cameraTarget.xyz - f.cameraEye.xyz);
    float3 right = normalize(cross(forward, float3(0, 1, 0)));
    float3 up = cross(right, forward);
    float3 relative = world - f.cameraEye.xyz;
    float depth = dot(relative, forward);
    return float4(dot(relative, right) * 2 / f.viewport.x, dot(relative, up) * 2.142857,
                  depth * (30.0 / 29.8) - (6.0 / 29.8), depth);
}

float3 hueRotate(float3 color, float angle) {
    float3 axis = normalize(float3(1));
    return max(float3(0), color * cos(angle) + cross(axis, color) * sin(angle) + axis * dot(axis, color) * (1 - cos(angle)));
}

vertex RibbonOut ribbonVertex(uint vertexID [[vertex_id]], uint ribbon [[instance_id]],
                               constant FrameUniforms& f [[buffer(0)]],
                               constant float* spectrum [[buffer(1)]]) {
    float u = float(vertexID % 384) / 383;
    float v = float(vertexID / 384) / 31;
    float analysis = f.lightState.y;
    float pace = mix(0.35, f.rhythmInstruments.x, analysis);
    float4 layout = mix(float4(0.5), clamp(f.sceneLayout, 0.0, 1.0), analysis);
    float separation = mix(0.78, 1.22, layout.x);
    float thickness = mix(0.78, 1.22, layout.y);
    float spatialDepth = mix(0.75, 1.25, layout.z);
    float phase = float(ribbon) * 1.74 + (float(ribbon) - 1.5) * (separation - 1.0) * 0.32;
    float tempo = mix(1.0, clamp(f.tempoPhase.x, 0.35, 2.4), analysis);
    float t = f.clockAudio.x * 0.43 * (1 + float(ribbon) * 0.08) * tempo;
    float activity = ribbon == 0 ? f.instrumentsStructure.x : ribbon == 1 ? f.rhythmInstruments.w : ribbon == 2 ? f.rhythmInstruments.y : f.rhythmInstruments.z;
    activity = mix(0.38, activity, analysis);
    float spectralIndex = u * 63;
    uint lower = uint(spectralIndex);
    float spectral = mix(spectrum[lower], spectrum[min(lower + 1, 63u)], fract(spectralIndex));
    float envelope = 0.28 + 0.72 * sin(u * 3.14159265);
    float section = analysis * f.instrumentsStructure.y;
    float segment = analysis * f.instrumentsStructure.z;
    float phrase = analysis * sin(f.instrumentsStructure.w * tau);
    float transition = analysis * f.structureColor.x;
    float wave = sin(u * tau * (1.12 + section * 0.20) - t + phase)
               + 0.43 * sin(u * tau * 2.28 + t * 0.67 + phase * 1.5 + segment * 0.7)
               + 0.15 * sin(u * tau * 3.8 - t * 0.45 + phase * 0.9) * (0.75 + pace * 0.7);
    wave += sin(u * tau * 0.8 - t * 0.7 + phase) * f.clockAudio.w * 0.66;
    wave += sin(u * tau * 4.7 + phase + t) * f.bandsBeat.x * 0.13;
    wave += sin(u * tau * 11 + t * 3.6 + phase) * f.bandsBeat.y * 0.025;
    wave += spectral * 0.17 * sin(u * tau * 6.0 + phase);
    float beat = f.bandsBeat.z, bar = f.bandsBeat.w;
    float drumImpulse = analysis * f.rhythmInstruments.z * beat;
    float attack = drumImpulse * 0.22;
    float width = (ribbon == 0 ? 0.78 : ribbon == 1 ? 0.90 : ribbon == 2 ? 0.76 : 0.60)
                * (1 + f.clockAudio.y * 0.34 + beat * 0.09 + bar * 0.11 + activity * 0.18 + phrase * 0.045)
                * (0.42 + 0.68 * sin(u * 3.14159265))
                * (1 + analysis * sin(f.tempoPhase.y * tau) * 0.025 + drumImpulse * 0.07) * thickness;
    float twist = sin(u * tau * 1.48 - t * 0.56 + phase) * 1.35
                + sin(u * tau * 0.6 + phase) * 0.34
                + analysis * sin(f.tempoPhase.z * tau + u * tau) * 0.12;
    float across = (v - 0.5) * width;
    float ripple = sin(u * 52 + v * 12 - t * 3) * 0.015 * (0.25 + f.bandsBeat.y) * (0.75 + pace * 0.7);
    float amplitude = (0.57 + activity * 0.13 + f.clockAudio.y * 0.20 + attack + transition * 0.12)
                    * envelope * mix(0.85, 1.15, layout.y);
    float x = (u - 0.5) * 6.2 * f.viewport.x;
    float y = 0.34 + wave * amplitude + across * cos(twist) + ripple;
    y += (float(ribbon) - 1.5) * (separation - 1.0) * 0.22;
    y += phrase * 0.03 + bar * sin(u * tau * 1.3) * 0.045;
    float z = -0.60 + float(ribbon) * 0.32 * separation
            + (sin(u * 9 + phase + t * 0.3) * 0.67 + across * sin(twist)) * spatialDepth;
    float vocal = ribbon == 2 ? analysis * f.rhythmInstruments.y : 0;
    z += vocal * 0.18;
    float presence = clamp(f.lightState.z, 0.0, 1.0);
    // Keep the musical swells inside the composition, with a soft rather than clipped limit.
    y = 0.34 + 1.35 * tanh((y - 0.34) / 1.35) * presence;
    float3 world = float3(x, y, z);
    RibbonOut out;
    out.position = projectWorld(world, f);
    out.world = world;
    out.uv = float2(u, v);
    float3 blue = float3(0.005, 0.07, 0.72);
    float3 cyan = float3(0.005, 0.70, 1.05);
    float3 magenta = float3(0.78, 0.006, 0.49);
    float gradient = 0.5 + 0.5 * sin(v * 3.14159265 + u * 4 + phase);
    float3 color = ribbon == 0 ? mix(blue, magenta, gradient * 0.40)
                 : ribbon == 1 ? mix(blue, cyan, gradient)
                 : ribbon == 2 ? mix(magenta, cyan, smoothstep(0.85, 1.0, v))
                 : mix(blue, cyan, gradient * 0.75);
    color = mix(color, magenta, vocal * 0.25);
    out.color = hueRotate(color, analysis * f.structureColor.y * 0.24);
    out.activity = activity;
    out.glow = f.clockAudio.y * 0.3 + f.clockAudio.z * 0.15 + beat * 0.10 + attack + f.structureColor.w * analysis * 0.20;
    out.glow += (layout.w - 0.5) * 0.16;
    out.glow *= presence;
    out.opacity = ribbon == 0 ? 0.58 : ribbon == 1 ? 1.0 : ribbon == 2 ? 1.0 : 0.68;
    return out;
}

fragment float4 ribbonFragment(RibbonOut in [[stage_in]], constant FrameUniforms& f [[buffer(0)]]) {
    float edgeSoftness = smoothstep(0.0, 0.025, in.uv.y) * smoothstep(0.0, 0.025, 1 - in.uv.y);
    float sideFade = smoothstep(0.0, 0.06, in.uv.x) * smoothstep(0.0, 0.06, 1 - in.uv.x);
    float threadCoordinate = in.uv.y * 72 + in.uv.x * 3;
    float threadAA = max(fwidth(threadCoordinate), 0.05);
    // Integrate the fibre signal over the pixel footprint; frequencies above one cycle per pixel converge to their mean.
    float fibreFilter = threadAA < 1 ? sin(3.14159265 * threadAA) / (3.14159265 * threadAA) : 0;
    float threads = pow(0.5 + 0.5 * cos(threadCoordinate * tau) * fibreFilter, 4);
    float3 normal = normalize(cross(dfdx(in.world), dfdy(in.world)));
    float3 eye = normalize(f.cameraEye.xyz - in.world);
    float fresnel = pow(1 - abs(dot(normal, eye)), 2.1);
    float rim = pow(abs(in.uv.y * 2 - 1), 12);
    float foldLight = pow(0.5 + 0.5 * sin(in.uv.x * 17 + in.uv.y * 3 + f.clockAudio.x * 0.17), 8);
    float density = mix(0.2, f.lightState.x, f.lightState.y);
    float alpha = edgeSoftness * sideFade * (0.24 + threads * 0.14 + fresnel * 0.10 + density * 0.04) * in.opacity;
    alpha *= clamp(f.lightState.z, 0.0, 1.0);
    float brightness = 0.92 + threads * 0.85 + fresnel * 0.50 + rim * 1.65 + foldLight * 0.20 + in.glow;
    brightness *= 1 + f.structureColor.z * f.lightState.y * 0.035;
    float3 color = in.color * brightness;
    return float4(color * alpha, alpha);
}

vertex ScreenOut fullscreenVertex(uint id [[vertex_id]]) {
    float2 pos = id == 0 ? float2(-1, -1) : id == 1 ? float2(3, -1) : float2(-1, 3);
    ScreenOut out; out.position = float4(pos, 0, 1); out.uv = float2(pos.x * 0.5 + 0.5, 0.5 - pos.y * 0.5); return out;
}

fragment float4 resolveRibbonsFragment(ScreenOut in [[stage_in]],
                                      texture2d_array<float> colors [[texture(0)]],
                                      depth2d_array<float> depths [[texture(1)]]) {
    float4 layers[4];
    float z[4];
    for (uint i = 0; i < 4; ++i) {
        layers[i] = colors.sample(nearestSampler, in.uv, i);
        z[i] = depths.sample(nearestSampler, in.uv, i);
    }
    // The order can differ at every pixel, including a crossing within the same pair of ribbons.
    for (uint i = 1; i < 4; ++i) {
        float depth = z[i];
        float4 color = layers[i];
        uint j = i;
        while (j > 0 && z[j - 1] < depth) {
            z[j] = z[j - 1];
            layers[j] = layers[j - 1];
            --j;
        }
        z[j] = depth;
        layers[j] = color;
    }
    float4 result = float4(0);
    for (uint i = 0; i < 4; ++i) {
        result = layers[i] + result * (1 - layers[i].a);
    }
    return result;
}

fragment float4 brightFragment(ScreenOut in [[stage_in]], texture2d<float> scene [[texture(0)]]) {
    float3 color = scene.sample(linearSampler, in.uv).rgb;
    float luminance = max(color.r, max(color.g, color.b));
    return float4(color * smoothstep(0.36, 0.90, luminance), 1);
}

float3 toneMap(float3 color) { return clamp((color * (2.51 * color + 0.03)) / (color * (2.43 * color + 0.59) + 0.14), 0.0, 1.0); }

fragment float4 compositeFragment(ScreenOut in [[stage_in]], texture2d<float> scene [[texture(0)]],
                                  texture2d<float> bloom [[texture(1)]], texture2d<float> waves [[texture(2)]],
                                  constant FrameUniforms& f [[buffer(0)]]) {
    float2 uv = in.uv;
    float horizon = f.viewport.w;
    float t = f.clockAudio.x;
    float analysis = f.lightState.y;
    float pace = mix(0.35, f.rhythmInstruments.x, analysis);
    float4 layout = mix(float4(0.5), clamp(f.sceneLayout, 0.0, 1.0), analysis);
    float water = mix(0.5, clamp(f.sceneWater.x, 0.0, 1.0), analysis);
    float presence = clamp(f.lightState.z, 0.0, 1.0);
    float backgroundDensity = mix(0.70, 1.30, layout.z);
    float bloomStrength = mix(0.32, 0.52, layout.w);
    float3 background = mix(float3(0.001, 0.003, 0.015), float3(0.002, 0.009, 0.035), 1 - uv.y);
    float skyGlow = exp(-pow((uv.x - 0.48) * 1.8, 2) - pow((uv.y - 0.40) * 4.8, 2));
    background += float3(0.002, 0.007, 0.032) * skyGlow * backgroundDensity;
    float3 color;
    if (uv.y <= horizon) {
        color = scene.sample(linearSampler, uv).rgb + bloom.sample(linearSampler, uv).rgb * bloomStrength;
    } else {
        float distance = uv.y - horizon;
        float depth = distance / (1 - horizon);
        float ripple = sin(distance * 135 - t * (1.7 + pace * 2.0) + sin(uv.x * 35 + t) * 1.4);
        ripple += 0.42 * sin(distance * 280 + uv.x * 17 + t * 2.1);
        float amplitude = (0.0017 + f.clockAudio.w * 0.005) * (0.3 + depth * 2.5)
                        * mix(0.75, 1.25, water) * (1 + f.bandsBeat.w * 0.12);
        float2 reflected = float2(uv.x + ripple * amplitude * 3.7, horizon - 0.055 - distance * 1.10 + ripple * amplitude);
        float2 waterUV = float2(uv.x, depth);
        float2 texel = 1.0 / float2(waves.get_width(), waves.get_height());
        float waveHeight = waves.sample(linearSampler, waterUV).r;
        float2 slope = float2(waves.sample(linearSampler, waterUV + float2(texel.x, 0)).r
                            - waves.sample(linearSampler, waterUV - float2(texel.x, 0)).r,
                              waves.sample(linearSampler, waterUV + float2(0, texel.y)).r
                            - waves.sample(linearSampler, waterUV - float2(0, texel.y)).r);
        reflected += slope * float2(0.045 / f.viewport.x, 0.028) * (0.4 + depth);
        float attenuation = (0.65 + f.structureColor.w * analysis * 0.12) * pow(1 - depth, 1.15) * mix(0.78, 1.22, water);
        float waterLines = 0.68 + 0.32 * sin(distance * 340 + sin(uv.x * 38) * 3 + t * 2.0);
        color = (scene.sample(linearSampler, reflected).rgb + bloom.sample(linearSampler, reflected).rgb * (bloomStrength - 0.04))
              * attenuation * waterLines * presence;
        // Surface normals catch cyan/magenta light, making waves visible even on dark reflection.
        float crest = min(1.0, length(slope) * 2.0 + abs(waveHeight) * 0.06);
        color += mix(float3(0.003, 0.07, 0.14), float3(0.10, 0.005, 0.09), uv.x)
               * crest * (0.55 + 0.45 * (1 - depth));
        background += float3(0.001, 0.004, 0.018) * (1 - depth);
    }
    float horizonGlow = exp(-abs(uv.y - horizon) * 48) * exp(-pow((uv.x - 0.5) * 3, 2));
    background += float3(0.002, 0.025, 0.065) * horizonGlow;
    float vignette = 1 - 0.24 * pow(length((uv - float2(0.5, 0.45)) * float2(1.15, 1)), 1.8);
    return float4(toneMap((color + background) * vignette), 1);
}
