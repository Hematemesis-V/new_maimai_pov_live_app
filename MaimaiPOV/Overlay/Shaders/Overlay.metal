#include <metal_stdlib>
using namespace metal;

struct OverlayUniforms {
    float posX;
    float posY;
    float scale;
    float opacity;
    float overlayWidth;
    float overlayHeight;
    float outWidth;
    float outHeight;
};

kernel void overlayBlend(
    texture2d<float, access::read_write> outputTexture [[texture(0)]],
    texture2d<float, access::sample> overlayTexture [[texture(1)]],
    constant OverlayUniforms& u [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= uint(u.outWidth) || gid.y >= uint(u.outHeight)) return;

    float overlayPixelW = u.overlayWidth * u.scale;
    float overlayPixelH = u.overlayHeight * u.scale;
    float centerX = u.posX * u.outWidth;
    float centerY = u.posY * u.outHeight;
    float left = centerX - overlayPixelW / 2.0;
    float top = centerY - overlayPixelH / 2.0;

    float relX = (float(gid.x) - left) / overlayPixelW;
    float relY = (float(gid.y) - top) / overlayPixelH;

    if (relX < 0.0 || relX > 1.0 || relY < 0.0 || relY > 1.0) return;

    constexpr sampler s(coord::normalized, address::clamp_to_edge, filter::linear);
    float4 overlay = overlayTexture.sample(s, float2(relX, relY));

    float alpha = overlay.a * u.opacity;
    if (alpha < 0.001) return;

    float4 background = outputTexture.read(gid);
    float4 result = float4(
        overlay.rgb * alpha + background.rgb * (1.0 - alpha),
        1.0
    );
    outputTexture.write(result, gid);
}
