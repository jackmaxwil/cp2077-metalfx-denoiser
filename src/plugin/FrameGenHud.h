// The frame generation HUD kernels (FrameGen.mm), shared with tests/fg_bench.mm.
#pragma once
#import <Foundation/Foundation.h>

static NSString* const kHudSource = @R"(
#include <metal_stdlib>
using namespace metal;
// Snapshots of the UI layer's alpha (level 0, and its 16x mip when it has one), taken in the game's HUD composite. The
// 16x mip is stored widened by one texel (the max of its 3x3 neighbours), so fg_hud tests a 16x texel with one read.
kernel void fg_ui_copy_array(texture2d_array<float, access::read> src [[texture(0)]],
                             texture2d<float, access::write> dst [[texture(1)]],
                             constant uint& lod [[buffer(0)]], uint2 p [[thread_position_in_grid]])
{
    if (p.x >= dst.get_width() || p.y >= dst.get_height()) return;
    if (lod == 0u) { dst.write(float4(src.read(p, 0, 0).a), p); return; }
    const int2 m = int2(dst.get_width(), dst.get_height()) - 1;
    float b = 0.0;
    for (int y = -1; y <= 1; ++y)
        for (int x = -1; x <= 1; ++x)
            b = max(b, src.read(uint2(clamp(int2(p) + int2(x, y), int2(0), m)), 0, lod).a);
    dst.write(float4(b), p);
}
kernel void fg_ui_copy(texture2d<float, access::read> src [[texture(0)]], texture2d<float, access::write> dst [[texture(1)]],
                       constant uint& lod [[buffer(0)]], uint2 p [[thread_position_in_grid]])
{
    if (p.x >= dst.get_width() || p.y >= dst.get_height()) return;
    if (lod == 0u) { dst.write(float4(src.read(p, 0).a), p); return; }
    const int2 m = int2(dst.get_width(), dst.get_height()) - 1;
    float b = 0.0;
    for (int y = -1; y <= 1; ++y)
        for (int x = -1; x <= 1; ++x)
            b = max(b, src.read(uint2(clamp(int2(p) + int2(x, y), int2(0), m)), lod).a);
    dst.write(float4(b), p);
}
struct HudParams { uint debug; uint hasLow; float2 mvToOut; float2 outToIn; };
// The generated frame (gen) into dst, with the real frame's (cur) pixels wherever the HUD or its copies may be.
kernel void fg_hud(texture2d<float, access::read> gen [[texture(0)]],
                   texture2d<float, access::read> cur [[texture(1)]],
                   texture2d<float, access::read> ui [[texture(2)]],
                   texture2d<float, access::read> low [[texture(3)]],
                   texture2d<float, access::read> motion [[texture(4)]],
                   texture2d<float, access::write> dst [[texture(5)]],
                   constant HudParams& h [[buffer(0)]],
                   uint2 p [[thread_position_in_grid]])
{
    if (p.x >= dst.get_width() || p.y >= dst.get_height()) return;
    const int2 s = int2(ui.get_width(), ui.get_height()) - 1;
    float a = 0.0;
    for (int y = -1; y <= 1; ++y)
        for (int x = -1; x <= 1; ++x)
            a = max(a, ui.read(uint2(clamp(int2(p) + int2(x, y), int2(0), s))).r);
    // The game's HUD composite also adds soft offset copies of the HUD (up to about 40 px out, from the UI layer's
    // mips): cover them with the layer's widened 16x mip (about +-32 px).
    if (a == 0.0 && h.hasLow != 0u) {
        const int2 m = int2(low.get_width(), low.get_height()) - 1;
        const float2 size = float2(dst.get_width(), dst.get_height());
        auto covered = [&](float2 q) { return low.read(uint2(clamp(int2(q / 16.0), int2(0), m))).r; };
        a = covered(float2(p));
        // The copies the game's HUD composite adds: the UI layer sampled at uv + o * d, d = 2 * (uv - 0.5), with these
        // offsets o (its constants, logged from the game): up to about 44 px out at the screen's edges.
        const float2 uv = (float2(p) + 0.5) / size, d = (uv - 0.5) * 2.0;
        const float2 o[3] = {float2(-0.0050, -0.0025), float2(-0.0108, -0.0068), float2(-0.0126, -0.0073)};
        for (int i = 0; i < 3 && a == 0.0; ++i)
            a = covered((uv + o[i] * d) * size);
        // The interpolator fills a pixel from along the scene's motion: where that path crosses the HUD, it can drag HUD
        // pixels here.
        if (a == 0.0) {
            const int2 ms = int2(motion.get_width(), motion.get_height()) - 1;
            const float2 mv = motion.read(uint2(clamp(int2(float2(p) * h.outToIn), int2(0), ms))).xy * h.mvToOut;
            if (dot(mv, mv) > 1.0)
                for (int i = -4; i <= 4 && a == 0.0; ++i)
                    a = covered(float2(p) + mv * (float(i) / 4.0));
        }
    }
    // Any coverage takes the real pixel whole: a partial blend keeps part of the interpolated (dragged) HUD.
    if (h.debug != 0u) dst.write(a > 0.0 ? float4(1, 0, 1, 1) : float4(0, 1, 0, 1), p);
    else dst.write(a > 0.0 ? cur.read(p) : gen.read(p), p);
}
)";
