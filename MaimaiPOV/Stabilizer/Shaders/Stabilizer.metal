#include <metal_stdlib>
using namespace metal;

struct StabilizerUniforms {
    float  inputWidth;
    float  inputHeight;
    float  outputWidth;
    float  outputHeight;

    float4 qCenter;
    float4 qTop;
    float4 qBottom;
    float4 qAnchor;

    float  fovRadHalf;
    float  distRatio;
    uint   useRollingShutter;

    float4x4 R_view;

    float  fx;
    float  fy;
    float  cx;
    float  cy;
    float  k1;
    float  k2;
    float  k3;
    float  k4;

    float  calibWidth;
    float  calibHeight;
};

// --- Quaternion rotation: v' = q * v * q^-1 ---
float3 q_rot(float4 q, float3 v) {
    float3 a = q.xyz;
    float3 c = cross(a, v);
    float3 t = 2.0 * c;
    float3 d = cross(a, t);
    return v + q.w * t + d;
}

float4 q_inv(float4 q) {
    return float4(-q.x, -q.y, -q.z, q.w);
}

float4 q_norm(float4 q) {
    float len = length(q);
    return (len > 1e-10) ? q / len : float4(0, 0, 0, 1);
}

// --- Fisheye distortion ---
float2 distort(float3 ray, float k1, float k2, float k3, float k4) {
    float rxy = length(ray.xy);
    if (rxy < 1e-10) return float2(0, 0);
    float theta = atan2(rxy, ray.z);
    float th2 = theta * theta;
    float th4 = th2 * th2;
    float th6 = th4 * th2;
    float th8 = th4 * th4;
    float theta_d = theta * (1.0 + k1 * th2 + k2 * th4 + k3 * th6 + k4 * th8);
    float s = theta_d / rxy;
    return float2(ray.x * s, ray.y * s);
}

// --- NV12 to RGB ---
float3 nv12_to_rgb(float y_val, float cb, float cr) {
    float yn = (y_val - 16.0 / 255.0) * 255.0 / 219.0;
    float cbn = (cb - 128.0 / 255.0) * 255.0 / 224.0;
    float crn = (cr - 128.0 / 255.0) * 255.0 / 224.0;
    float r = yn + 1.402   * crn;
    float g = yn - 0.34414 * cbn - 0.71414 * crn;
    float b = yn + 1.772   * cbn;
    return clamp(float3(r, g, b), 0.0, 1.0);
}

// ================================================================
// Main stabilizer kernel
//
// The stabilizer works in portrait coordinate space internally
// (matching the Python production_stabilizer.py pipeline).
// Lens calibration params (fx,fy,cx,cy) are calibrated for portrait
// images (calibWidth x calibHeight = 1440x1920).
//
// The CVPixelBuffer from iPhone back camera is in landscape
// (sensor-native, e.g. 1920x1440). We compensate by:
// 1. Using calibWidth/calibHeight for distortion normalization
// 2. Transforming portrait UV → landscape UV at sampling time
//    Mapping: u_landscape = v_portrait, v_landscape = 1 - u_portrait
//    (inverse of rot90(k=-1) which rotated landscape → portrait)
//
// IMU quaternions are pre-transformed via align_imu (conjugation by
// 180° X rotation) to convert from device frame to camera frame.
// ================================================================
kernel void stabilize(
    texture2d<float, access::sample>  texY      [[texture(0)]],
    texture2d<float, access::sample>  texCbCr   [[texture(1)]],
    texture2d<float, access::write>   outTex    [[texture(2)]],
    constant StabilizerUniforms& u   [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]])
{
    uint w_out = uint(u.outputWidth);
    uint h_out = uint(u.outputHeight);
    if (gid.x >= w_out || gid.y >= h_out) return;

    // ---- Step 1: output pixel → ray direction (FOV + distortion blend) ----
    float x_s = float(gid.x) - u.outputWidth  * 0.5;
    float y_s = float(gid.y) - u.outputHeight * 0.5;
    float r_len = sqrt(x_s*x_s + y_s*y_s);
    float r_safe = max(r_len, 1e-5);
    float r_norm = r_len / (u.outputWidth * 0.5);

    float theta_rect = atan(r_norm * tan(u.fovRadHalf));
    float theta_fish = r_norm * u.fovRadHalf;
    float theta = u.distRatio * theta_rect + (1.0 - u.distRatio) * theta_fish;

    float rz = cos(theta);
    float r_xy = sin(theta);
    float rx = r_xy * x_s / r_safe;
    float ry = r_xy * y_s / r_safe;
    float3 ray_virtual = float3(rx, ry, rz);

    // ---- Step 2: user view rotation ----
    float3 ray_view = (u.R_view * float4(ray_virtual, 0.0)).xyz;

    // ---- Step 3: anchor rotation → world space ----
    float3 ray_world = q_rot(u.qAnchor, ray_view);

    // ---- Step 4: camera inverse → local, then fisheye → sensor coords ----
    float4 qCenterInv = q_inv(u.qCenter);
    float2 sample_uv;

    if (u.useRollingShutter) {
        float3 ray_local_c = q_rot(qCenterInv, ray_world);
        float2 xd = distort(ray_local_c, u.k1, u.k2, u.k3, u.k4);
        float x_frac = clamp((u.fx * xd.x + u.cx) / u.calibWidth, 0.0f, 1.0f);

        float4 q_row = q_norm(u.qTop * x_frac + u.qBottom * (1.0 - x_frac));
        float4 q_row_inv = q_inv(q_row);

        float3 ray_local_r = q_rot(q_row_inv, ray_world);
        float2 xf = distort(ray_local_r, u.k1, u.k2, u.k3, u.k4);

        float mx = 2.0 * (u.fx * xf.x + u.cx) / (u.calibWidth - 1.0) - 1.0;
        float my = 2.0 * (u.fy * xf.y + u.cy) / (u.calibHeight - 1.0) - 1.0;
        float u_portrait = mx * 0.5 + 0.5;
        float v_portrait = my * 0.5 + 0.5;
        sample_uv = float2(v_portrait, 1.0 - u_portrait);
    } else {
        float3 ray_local = q_rot(qCenterInv, ray_world);
        float2 xf = distort(ray_local, u.k1, u.k2, u.k3, u.k4);

        float mx = 2.0 * (u.fx * xf.x + u.cx) / (u.calibWidth - 1.0) - 1.0;
        float my = 2.0 * (u.fy * xf.y + u.cy) / (u.calibHeight - 1.0) - 1.0;
        float u_portrait = mx * 0.5 + 0.5;
        float v_portrait = my * 0.5 + 0.5;
        sample_uv = float2(v_portrait, 1.0 - u_portrait);
    }

    // ---- Step 5: sample NV12 & convert to RGB ----
    constexpr sampler texSampler(coord::normalized, address::clamp_to_edge, filter::linear);

    float y_val  = texY.sample(texSampler, sample_uv).r;
    float2 cbcr  = texCbCr.sample(texSampler, sample_uv).rg;

    float3 rgb = nv12_to_rgb(y_val, cbcr.x, cbcr.y);
    outTex.write(float4(rgb, 1.0), gid);
}
