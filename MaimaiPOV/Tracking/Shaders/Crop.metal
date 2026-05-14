#include <metal_stdlib>
using namespace metal;

struct CropUniforms {
    float cropX1;
    float cropY1;
    float cropW;
    float cropH;
    float stabWidth;
    float stabHeight;
    float outWidth;
    float outHeight;
};

kernel void cropAndResize(
    texture2d<float, access::sample> stabOutput [[texture(0)]],
    texture2d<float, access::write>  cropOutput [[texture(1)]],
    constant CropUniforms& u [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= uint(u.outWidth) || gid.y >= uint(u.outHeight)) return;

    float srcX = u.cropX1 + (float(gid.x) / u.outWidth) * u.cropW;
    float srcY = u.cropY1 + (float(gid.y) / u.outHeight) * u.cropH;

    if (srcX < 0.0 || srcX >= u.stabWidth || srcY < 0.0 || srcY >= u.stabHeight) {
        cropOutput.write(float4(0.0, 0.0, 0.0, 1.0), gid);
        return;
    }

    float2 uv = float2(srcX / u.stabWidth, srcY / u.stabHeight);
    constexpr sampler s(coord::normalized, address::clamp_to_edge, filter::linear);
    float4 rgba = stabOutput.sample(s, uv);
    cropOutput.write(rgba, gid);
}
