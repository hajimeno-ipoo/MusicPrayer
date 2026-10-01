#include <metal_stdlib>
using namespace metal;

struct WaveStepUniforms { float4 geometry; float4 control; };
// Height and previous height form a damped, finite-difference wave equation.
kernel void advanceWater(texture2d<float, access::read> previous [[texture(0)]],
                         texture2d<float, access::write> next [[texture(1)]],
                         constant WaveStepUniforms& u [[buffer(0)]],
                         constant float4* pulses [[buffer(1)]], uint2 p [[thread_position_in_grid]]) {
    uint width = next.get_width(), height = next.get_height();
    if (p.x >= width || p.y >= height) return;
    float2 state = u.control.y > 0 ? float2(0) : previous.read(p).rg;
    float lap = 0;
    if (u.control.y == 0) {
        uint2 left = uint2(p.x > 0 ? p.x - 1 : 0, p.y);
        uint2 right = uint2(min(p.x + 1, width - 1), p.y);
        uint2 above = uint2(p.x, p.y > 0 ? p.y - 1 : 0);
        uint2 below = uint2(p.x, min(p.y + 1, height - 1));
        lap = (previous.read(left).r + previous.read(right).r - 2 * state.x) * u.geometry.z
            + previous.read(above).r + previous.read(below).r - 2 * state.x;
    }
    float2 uv = (float2(p) + 0.5) / float2(width, height);
    float border = min(min(uv.x, 1 - uv.x), min(uv.y, 1 - uv.y));
    float damping = mix(0.88, 0.997, smoothstep(0.0, 0.075, border));
    float value = (2 * state.x - state.y + u.geometry.w * lap) * damping;
    for (uint i = 0; i < uint(u.control.x); ++i) {
        float4 pulse = pulses[i];
        float2 offset = (uv - pulse.xy) * float2(u.geometry.x, 1 - u.geometry.y);
        value += pulse.z * exp(-dot(offset, offset) / max(0.00001, pulse.w * pulse.w));
    }
    next.write(float4(value, state.x, 0, 0), p);
}
