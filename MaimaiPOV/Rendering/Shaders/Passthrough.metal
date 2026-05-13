#include <metal_stdlib>
using namespace metal;

struct VertexOut {
    float4 position [[position]];
    float2 texCoord;
};

vertex VertexOut vertex_main(uint vid [[vertex_id]]) {
    // Fullscreen triangle (3 vertices cover entire viewport)
    float2 coords[3] = {
        float2(-1, -3), float2(-1, 1), float2(3, 1)
    };
    float2 uv[3] = {
        float2(0, 2), float2(0, 0), float2(2, 0)
    };
    VertexOut out;
    out.position = float4(coords[vid], 0, 1);
    out.texCoord = uv[vid];
    return out;
}

fragment float4 fragment_main(VertexOut in [[stage_in]],
                               texture2d<float> tex [[texture(0)]]) {
    constexpr sampler s(coord::normalized, address::clamp_to_edge, filter::linear);
    return tex.sample(s, in.texCoord);
}
