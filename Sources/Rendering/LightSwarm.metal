#include <metal_stdlib>
using namespace metal;

struct SwarmParticle { float4 position; float4 velocity; float4 appearance; };
struct SwarmUniforms {
    float4 clock, music, levels, eye, target, layout;
};
constant uint swarmHistoryCount = 8;

kernel void updateLightSwarm(device SwarmParticle *particles [[buffer(0)]],
                            device float4 *history [[buffer(1)]],
                            constant SwarmUniforms &u [[buffer(2)]],
                            uint id [[thread_position_in_grid]]) {
    if (id >= uint(u.layout.y)) return;
    SwarmParticle p = particles[id];
    float dt = u.clock.y;
    float seed = p.velocity.w;
    float3 position = p.position.xyz;
    float t = u.clock.x;
    float bass = max(u.music.y, u.music.w);
    // A bounded curl-like flow carries the lights along the same spatial band as the ribbons.
    float3 flow = float3(cos(position.y * 2.8 + t * .31 + seed * 6.28),
                        sin(position.x * 1.1 - t * .42 + seed * 6.28) * .58,
                        sin(position.x * .8 + position.y * 1.7 + t * .27) * .45);
    float3 center = float3(sin(t * .37 + seed * 6.28) * 1.8,
                          .35 + sin(t * .52 + position.x) * .22,
                          .4 + u.music.x * .75);
    float3 force = flow * (.18 + bass * .8) + (center - position) * (.055 + u.music.x * .3);
    force.y += (.35 - position.y) * .25;
    // Soft confinement turns the flow inward before the edge; collision handles strong drum impulses.
    force.y += 1.2 * (1 - smoothstep(-.85, -.4, position.y) - smoothstep(1.25, 1.7, position.y));
    force.z += 1.2 * (1 - smoothstep(-1.5, -1.05, position.z) - smoothstep(1.35, 1.8, position.z));
    float3 velocity = p.velocity.xyz * exp(-dt * .65) + force * dt;
    // Only the rising beat injects an impulse. Holding a beat never re-injects it every frame.
    float3 radial = normalize(position - float3(0, .35, 0) + float3(.001));
    velocity += radial * u.clock.z * (.65 + seed * .8);
    float speed = length(velocity);
    velocity *= min(1.0, 2.4 / max(.001, speed));
    position += velocity * dt;
    float extent = 3.3 * u.layout.x;
    bool wrapped = false;
    if (position.x > extent) { position.x = -extent; wrapped = true; }
    if (position.x < -extent) { position.x = extent; wrapped = true; }
    if (position.y > 1.7) { position.y = 3.4 - position.y; velocity.y = -abs(velocity.y) * .65; }
    if (position.y < -.85) { position.y = -1.7 - position.y; velocity.y = abs(velocity.y) * .65; }
    if (position.z > 1.8) { position.z = 3.6 - position.z; velocity.z = -abs(velocity.z) * .65; }
    if (position.z < -1.5) { position.z = -3.0 - position.z; velocity.z = abs(velocity.z) * .65; }
    p.appearance.w += dt;
    if (wrapped) {
        for (uint k = 0; k < swarmHistoryCount; ++k) history[id * swarmHistoryCount + k] = float4(position, 0);
    } else if (p.appearance.w >= .025) {
        for (uint k = swarmHistoryCount - 1; k > 0; --k)
            history[id * swarmHistoryCount + k] = history[id * swarmHistoryCount + k - 1];
        history[id * swarmHistoryCount] = float4(position, 0);
        p.appearance.w = fmod(p.appearance.w, .025);
    }
    float activity = clamp(u.levels.x * 1.2 + u.music.x * .3 + bass * .2, 0.0, 1.0);
    p.appearance.x += (activity - p.appearance.x) * (1 - exp(-dt * 5));
    p.position = float4(position, p.position.w + dt);
    p.velocity.xyz = velocity;
    particles[id] = p;
}

struct SwarmVertex {
    float4 position [[position]];
    float2 uv;
    float3 color;
    float brightness;
    float trail;
};

vertex SwarmVertex lightSwarmVertex(uint vertexID [[vertex_id]], uint instance [[instance_id]],
                                   const device SwarmParticle *particles [[buffer(0)]],
                                   const device float4 *history [[buffer(1)]],
                                   constant SwarmUniforms &u [[buffer(2)]]) {
    uint id = instance / swarmHistoryCount, part = instance % swarmHistoryCount;
    SwarmParticle p = particles[id];
    float3 forward = normalize(u.target.xyz - u.eye.xyz);
    float3 right = normalize(cross(forward, float3(0, 1, 0)));
    float3 up = cross(right, forward);
    const float2 corners[6] = {float2(-1,-1), float2(1,-1), float2(-1,1),
                              float2(-1,1), float2(1,-1), float2(1,1)};
    float2 corner = corners[vertexID];
    float3 world;
    float visibility = clamp(u.clock.w, 0.0, 1.0);
    float radius = .007 + p.appearance.y * .006 + u.clock.z * .004;
    if (part == 0) {
        world = p.position.xyz + (right * corner.x + up * corner.y) * radius;
    } else {
        float3 a = part == 1 ? p.position.xyz : history[id * swarmHistoryCount + part - 2].xyz;
        float3 b = history[id * swarmHistoryCount + part - 1].xyz;
        float3 tangent = b - a;
        float3 side = cross(tangent, forward);
        side = side / max(length(side), .00001);
        world = mix(a, b, (corner.x + 1) * .5) + side * corner.y * radius * .36;
    }
    float3 relative = world - u.eye.xyz;
    float depth = dot(relative, forward);
    SwarmVertex out;
    out.position = float4(dot(relative, right) * 2 / u.layout.x,
                          dot(relative, up) * 2.142857,
                          30.0 / 29.8 * depth - 6.0 / 29.8, depth);
    out.uv = corner;
    float magenta = clamp(u.music.x * .9 + p.appearance.y * .28, 0.0, 1.0);
    out.color = mix(float3(.035,.65,1.4), float3(1.25,.055,.92), magenta);
    float twinkle = .7 + .3 * sin(u.clock.x * 1.3 + p.appearance.z * 31.4);
    out.brightness = p.appearance.x * visibility * twinkle * (part == 0 ? .72 : .14 * (1 - float(part) / 8));
    out.trail = part == 0 ? 0 : 1;
    return out;
}

fragment float4 lightSwarmFragment(SwarmVertex in [[stage_in]],
                                  depth2d_array<float> ribbonDepths [[texture(0)]]) {
    uint2 pixel = uint2(in.position.xy);
    float closest = 1;
    if (pixel.x < ribbonDepths.get_width() && pixel.y < ribbonDepths.get_height())
        for (uint layer = 0; layer < 4; ++layer) closest = min(closest, ribbonDepths.read(pixel, layer));
    float visibility = in.position.z > closest + .00001 ? .4 : 1;
    float glow = in.trail > .5 ? exp(-in.uv.y * in.uv.y * 3.5) : exp(-dot(in.uv, in.uv) * 2.8);
    float brightness = in.brightness * glow * visibility;
    return float4(in.color * brightness, brightness);
}
