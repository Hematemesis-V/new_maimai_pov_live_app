#include <metal_stdlib>
using namespace metal;

struct YOLOPreprocessUniforms {
    float padding;
    float scale;
    float padLeft;
    float padTop;
    float padRight;
    float padBottom;
    float stabWidth;
    float stabHeight;
};

kernel void yoloPreprocess(
    texture2d<float, access::sample> stabOutput [[texture(0)]],
    texture2d<float, access::write>  yoloOutput [[texture(1)]],
    constant YOLOPreprocessUniforms& u [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]])
{
    uint yoloSize = uint(yoloOutput.get_width());
    if (gid.x >= yoloSize || gid.y >= yoloSize) return;

    if (gid.x < uint(u.padLeft) || gid.x >= yoloSize - uint(u.padRight) ||
        gid.y < uint(u.padTop)  || gid.y >= yoloSize - uint(u.padBottom)) {
        yoloOutput.write(float4(0.0, 0.0, 0.0, 1.0), gid);
        return;
    }

    float stab_x = (float(gid.x) - u.padLeft) / u.scale + u.padding;
    float stab_y = (float(gid.y) - u.padTop) / u.scale + u.padding;

    float2 uv = float2(stab_x / u.stabWidth, stab_y / u.stabHeight);

    constexpr sampler s(coord::normalized, address::clamp_to_edge, filter::linear);
    float4 rgba = stabOutput.sample(s, uv);

    yoloOutput.write(float4(rgba.b, rgba.g, rgba.r, rgba.a), gid);
}
