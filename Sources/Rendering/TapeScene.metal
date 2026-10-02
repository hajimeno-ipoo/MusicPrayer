#include <metal_stdlib>
using namespace metal;

// Match TapeSceneRenderer.Uniforms: one matrix, nine aligned float4 groups.
struct TapeUniforms {
    float4x4 viewProjection;
    float4 eye;
    float4 clockAudio;
    float4 bandsBeat;
    float4 rhythm;
    float4 instruments;
    float4 structure;
    float4 layout;
    float4 viewportProgress;
    float4 phasesPresence;
};
struct TapeVertex { float4 position; float4 normal; float4 surface; };
struct TapeVarying {
    float4 position [[position]];
    float3 world;
    float3 normal;
    float3 surface;
};
float3 tapeHue(float hue) {
    return clamp(abs(fract(hue + float3(0, 2.0/3.0, 1.0/3.0)) * 6 - 3) - 1, 0.0, 1.0);
}
float tapeHash(float2 p) { return fract(sin(dot(p, float2(127.1, 311.7))) * 43758.5453); }
float2 tapeWindingRadii(float progress) {
    const float core = 0.30, full = 0.76;
    float amount = clamp(progress,0.0,1.0);
    float tapeArea = full*full-core*core;
    return sqrt(float2(full*full-tapeArea*amount,core*core+tapeArea*amount));
}
float tapeRoundedBox(float2 p, float2 halfSize, float radius) {
    float2 q = abs(p) - halfSize + radius;
    return length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - radius;
}
float3 tapeLight(float3 base, float3 world, float3 normal, float roughness, constant TapeUniforms &u) {
    float3 n = normalize(normal), view = normalize(u.eye.xyz - world);
    float3 light = normalize(float3(-3.8, 7.5, -4.0) - world);
    float diffuse = max(0.0, dot(n, light));
    float3 halfVector = normalize(view + light);
    float specular = pow(max(0.0, dot(n, halfVector)), mix(150.0, 18.0, roughness));
    float fresnel = pow(1 - max(0.0, dot(n, view)), 5.0);
    float3 accent = tapeHue(u.viewportProgress.w);
    float lighting = 0.34 + diffuse * 0.73;
    float analysisGlow = u.instruments.w * 0.07 + u.clockAudio.z * 0.035 + u.layout.w * 0.03;
    float3 fill = mix(float3(0.77, 0.89, 1), accent, 0.15 + u.rhythm.z * 0.08);
    return base * lighting * fill + float3(specular * (0.18 + (1-roughness)*0.35))
         + accent * (analysisGlow + fresnel * 0.12);
}

vertex TapeVarying tapeMeshVertex(uint id [[vertex_id]], constant TapeUniforms &u [[buffer(0)]],
                                 const device TapeVertex *vertices [[buffer(1)]]) {
    TapeVertex v = vertices[id];
    float3 p = v.position.xyz, n = v.normal.xyz;
    if (v.surface.z == 10 || v.surface.z == 11) {
        float3 center = float3(v.surface.z == 10 ? -0.9 : 0.9, 0, -0.1);
        float2 radii = tapeWindingRadii(u.viewportProgress.z);
        // Tape cross-sectional area transfers from supply to take-up reel.
        // Keep the core radius fixed while changing the outer winding radius.
        float radius = v.surface.z == 10 ? radii.x : radii.y;
        float2 local = p.xz-center.xz;
        float r = length(local);
        if (r > 0.001) p.xz = center.xz + local/r * (0.30+(r-0.30)*(radius-0.30)/0.46);
    }
    if (v.surface.z == 3 || v.surface.z == 4) {
        float3 center = float3(v.surface.z == 3 ? -0.9 : 0.9, 0, -0.1);
        float angle = u.clockAudio.x * 0.85;
        float c = cos(angle), s = sin(angle);
        p -= center;
        p.xz = float2(c*p.x-s*p.z, s*p.x+c*p.z);
        p += center;
        n.xz = float2(c*n.x-s*n.z, s*n.x+c*n.z);
    }
    TapeVarying out;
    out.world = p; out.normal = n; out.surface = v.surface.xyz;
    out.position = u.viewProjection * float4(p, 1);
    return out;
}
fragment float4 tapeMeshFragment(TapeVarying in [[stage_in]], constant TapeUniforms &u [[buffer(0)]],
                                texture2d<float> artwork [[texture(0)]], texture2d<float> title [[texture(1)]],
                                texture2d<float> lower [[texture(2)]]) {
    constexpr sampler sample(filter::linear, address::clamp_to_edge);
    if (u.phasesPresence.z < 0.001) discard_fragment();
    int material = int(in.surface.z + 0.5);
    float3 base = float3(0.42, 0.78, 0.80);
    float roughness = 0.28;
    if (material == 1) { base = float3(0.20, 0.48, 0.51); roughness = 0.20; }
    if (material == 2) { base = float3(0.015, 0.026, 0.032); roughness = 0.53; }
    if (material == 3 || material == 4) { base = float3(0.56, 0.70, 0.72); roughness = 0.40; }
    // CGContext bitmap rows already run from the texture's top edge downward.
    float2 uv = in.surface.xy;
    if (material == 5) { base = artwork.sample(sample, uv).rgb; roughness = 0.18; }
    if (material == 6) { base = title.sample(sample, uv).rgb; roughness = 0.68; }
    if (material == 7) { base = lower.sample(sample, uv).rgb * float3(0.67, 0.90, 0.92); roughness = 0.5; }
    if (material == 8) { base = float3(0.61, 0.71, 0.73); roughness = 0.15; }
    if (material == 10 || material == 11) {
        float2 center = float2(material == 10 ? -0.9 : 0.9, -0.1);
        float radius = length(in.world.xz-center);
        float footprint = fwidth(radius)*260;
        float layers = sin(radius*260)/(1+footprint*footprint);
        float winding = 0.76+0.24*layers;
        base = float3(0.025,0.012,0.006)*winding;
        // The dark magnetic coating must remain distinct from the inner bed.
        // The shell's additive glow and broad highlights wash out this edge.
        float diffuse = max(0.0,dot(normalize(in.normal),normalize(float3(-3.8,7.5,-4.0)-in.world)));
        return float4(base*(0.34+diffuse*0.73),clamp(u.phasesPresence.z,0.0,1.0));
    }
    if (material == 13) {
        // Matte neutral backing inside the shell, under the clear window.
        return float4(float3(0.10,0.12,0.14),clamp(u.phasesPresence.z,0.0,1.0));
    }
    if (material == 12) { base = float3(0.075,0.045,0.028); roughness = 0.68; }
    if (material == 9) {
        float3 view = normalize(u.eye.xyz-in.world);
        float fresnel = pow(1-max(0.0,dot(normalize(in.normal),view)),5.0);
        float glint = pow(max(0.0,dot(normalize(in.normal),normalize(view+float3(-0.4,1,-0.4)))),64);
        return float4(float3(0.63,0.79,0.82)+glint*0.3,
                      (0.045+fresnel*0.16+glint*0.10)*clamp(u.phasesPresence.z,0.0,1.0));
    }
    float grain = (tapeHash(in.world.xz * 800) - 0.5) * (material == 0 ? 0.015 : 0.005);
    float3 color = tapeLight(base + grain, in.world, in.normal, roughness, u);
    return float4(color, clamp(u.phasesPresence.z, 0.0, 1.0));
}

constant float2 tapeQuad[6] = {float2(0,0),float2(0,1),float2(1,0),float2(1,0),float2(0,1),float2(1,1)};
vertex TapeVarying tapeFloorVertex(uint id [[vertex_id]], constant TapeUniforms &u [[buffer(0)]]) {
    float2 q = (tapeQuad[id]-0.5)*60;
    TapeVarying out;
    out.world = float3(q.x, 0, q.y); out.normal = float3(0,1,0); out.surface = float3(0);
    out.position = u.viewProjection * float4(out.world, 1);
    return out;
}
fragment float4 tapeFloorFragment(TapeVarying in [[stage_in]], constant TapeUniforms &u [[buffer(0)]]) {
    float2 p = in.world.xz;
    float grain = (tapeHash(p*380)-0.5)*0.022 + (tapeHash(p*94)-0.5)*0.018;
    float mottling = sin(p.x*1.4 + sin(p.y*1.1)) * sin(p.y*0.8) * 0.012;
    float3 base = float3(0.29,0.32,0.38) + grain + mottling;
    float pool = exp(-dot(p-float2(-2.4,-3.5),p-float2(-2.4,-3.5))/65);
    base += pool * float3(0.16,0.16,0.15);
    // A raised slab casts an offset penumbra, with tighter contact occlusion under its rim.
    float shadowDistance = tapeRoundedBox(p-float2(0.16,0.19), float2(2.03,1.28), 0.14);
    float shadow = 1-smoothstep(-0.12,0.35,shadowDistance);
    float contactDistance = tapeRoundedBox(p,float2(1.97,1.22),0.14);
    float contact = 1-smoothstep(-0.02,0.12,contactDistance);
    base *= 1-shadow*0.62;
    base *= 1-contact*0.43;
    // Diffuse cast shadow beneath the upright spectrum, softened toward the foreground.
    float span = 2.28 + u.instruments.y*0.15;
    float spectrumShadow = exp(-pow((p.y+1.62)/0.21,2.0)) * (1-smoothstep(span,span+0.15,abs(p.x)));
    base *= 1-spectrumShadow*(0.12+u.clockAudio.y*0.08);
    float line = 1-smoothstep(0.006,0.014,abs(p.y-1.65));
    line *= (1-smoothstep(2.03,2.06,abs(p.x)));
    float progress = -2.03+4.06*u.viewportProgress.z;
    float active = 1-smoothstep(progress,progress+0.015,p.x);
    base = mix(base,float3(0.18,0.63,0.60)*(0.35+active*0.65),line*0.95);
    float cursor = 1-smoothstep(0.025,0.039,abs(length(p-float2(progress,1.65))-0.04));
    base = mix(base,float3(0.18,0.70,0.65),cursor);
    return float4(base,1);
}

// Face-local quads form real cuboids; their side faces carry lighting and depth.
vertex TapeVarying tapeSpectrumVertex(uint id [[vertex_id]], uint bar [[instance_id]],
                                     constant TapeUniforms &u [[buffer(0)]], const device float *spectrum [[buffer(2)]]) {
    uint face = id/6;
    float2 q = tapeQuad[id%6];
    float midRegion = exp(-pow((float(bar)/63-0.5)*3,2.0));
    float neighbours = (spectrum[max(int(bar)-1,0)] + spectrum[bar] + spectrum[min(bar+1,63u)])/3;
    float spectral = mix(spectrum[bar],neighbours,u.rhythm.z*midRegion*0.35);
    float heightSignal = sqrt(clamp(spectral,0.0,1.0));
    float low = 1-float(bar)/63;
    float pulse = u.bandsBeat.z*(0.10+u.rhythm.w*0.24) + u.bandsBeat.w*0.16;
    float beatBreathing = 1 + sin(u.phasesPresence.x*6.283)*0.025*u.phasesPresence.w;
    float activity = 1 + u.rhythm.y*0.18*sin(float(bar)*0.45 + u.clockAudio.x*u.rhythm.x*2);
    float segment = 1 + sin(u.structure.y*6.283 + float(bar)*0.07)*0.06;
    float height = 0.025 + heightSignal*(0.62 + u.instruments.z*0.30 + u.clockAudio.y*0.30)
                             * (1 + pulse + low*u.instruments.x*0.20) * activity * segment * beatBreathing;
    float width = (4.2 + u.instruments.y*0.3 + u.layout.x*0.12)/64;
    float thickness = 0.038 + low*(u.instruments.x*0.022 + u.clockAudio.w*0.025) + u.layout.y*0.008;
    float x = (float(bar)-31.5)*width;
    float z = -1.73-u.layout.z*0.09-u.structure.w*0.035;
    float3 a, n;
    switch(face) {
        case 0: a=float3(q.x,q.y,1); n=float3(0,0,1); break;
        case 1: a=float3(1-q.x,q.y,0); n=float3(0,0,-1); break;
        case 2: a=float3(0,q.y,q.x); n=float3(-1,0,0); break;
        case 3: a=float3(1,q.y,1-q.x); n=float3(1,0,0); break;
        case 4: a=float3(q.x,1,q.y); n=float3(0,1,0); break;
        default:a=float3(q.x,0,1-q.y); n=float3(0,-1,0); break;
    }
    float3 p = float3(x+(a.x-0.5)*width*0.76,a.y*height+0.012,z+(a.z-0.5)*thickness);
    TapeVarying out;
    out.position=u.viewProjection*float4(p,1); out.world=p; out.normal=n;
    out.surface=float3(a.x,a.y*height,float(bar)/63);
    return out;
}
fragment float4 tapeSpectrumFragment(TapeVarying in [[stage_in]], constant TapeUniforms &u [[buffer(0)]]) {
    float stripe = smoothstep(0.008,0.012,abs(fract(in.world.y/0.022)-0.5)*0.022);
    float3 accent = tapeHue(u.viewportProgress.w);
    float3 base = mix(float3(0.91,0.96,0.98),accent,0.045+u.structure.w*0.09);
    float midRegion = exp(-pow((in.surface.z-0.5)*3,2.0));
    float highRegion = in.surface.z*in.surface.z;
    float shimmer = 0.5 + 0.5*sin(in.world.y*40-u.clockAudio.x*u.rhythm.x*4);
    float glow = 0.27 + u.rhythm.z*midRegion*0.18 + u.instruments.w*0.15 + u.clockAudio.z*0.12;
    glow += u.bandsBeat.x*midRegion*0.12 + u.bandsBeat.y*highRegion*shimmer*0.12;
    float3 lit=tapeLight(base,in.world,in.normal,0.58,u)+base*glow;
    if (u.phasesPresence.z < 0.001) discard_fragment();
    return float4(lit*(0.70+stripe*0.30),clamp(u.phasesPresence.z,0.0,1.0));
}
vertex TapeVarying tapeTimeVertex(uint id [[vertex_id]], uint side [[instance_id]], constant TapeUniforms &u [[buffer(0)]]) {
    float2 q=tapeQuad[id];
    float3 p=float3((side==0?-3.38:3.38)+(q.x-0.5)*2.0,0.014,(q.y-0.5)*0.72);
    TapeVarying out;
    out.position=u.viewProjection*float4(p,1); out.world=p; out.normal=float3(0,1,0);
    out.surface=float3(q.x,q.y*0.5+(side==0?0.5:0.0),0);
    return out;
}
fragment float4 tapeTimeFragment(TapeVarying in [[stage_in]], texture2d<float> times [[texture(0)]]) {
    constexpr sampler s(filter::linear,address::clamp_to_edge);
    float4 color=times.sample(s,in.surface.xy);
    if(color.a<0.005) discard_fragment();
    return float4(color.rgb/max(color.a,0.001),color.a*0.94);
}
struct TapeFullscreen { float4 position [[position]]; float2 uv; };
vertex TapeFullscreen tapeFullscreenVertex(uint id [[vertex_id]]) {
    float2 p=float2(id==2?3:-1,id==1?3:-1);
    return {float4(p,0,1),p*float2(0.5,-0.5)+0.5};
}
fragment float4 tapeCompositeFragment(TapeFullscreen in [[stage_in]], texture2d<float> scene [[texture(0)]],
                                     depth2d<float> depth [[texture(1)]], constant TapeUniforms &u [[buffer(0)]]) {
    constexpr sampler s(filter::linear,address::clamp_to_edge);
    float d=depth.sample(s,in.uv);
    float distance=0.1*80/(80-d*79.9);
    float focalDistance=length(u.eye.xyz-float3(0,0.22,0));
    float blur=clamp((distance-focalDistance-0.8)*0.30,0.0,2.5);
    float3 color=scene.sample(s,in.uv).rgb;
    if(blur>0.01) {
        float3 sum=color*2;
        float2 pixel=blur/u.viewportProgress.xy;
        for(int i=0;i<8;i++) {
            float angle=float(i)*0.785398;
            float2 offset=float2(cos(angle),sin(angle))*pixel;
            sum+=scene.sample(s,in.uv+offset).rgb;
        }
        color=sum/10;
    }
    float vignette=1-dot(in.uv-0.5,in.uv-0.5)*0.24;
    color*=vignette;
    // Linear HDR scene is written into an sRGB drawable by Metal.
    return float4(clamp(color,0.0,1.0),1);
}
