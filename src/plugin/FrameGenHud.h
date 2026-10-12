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
// warp != 0: the scene is turned (camera warp, Warp.mm): each output pixel samples gen where its direction lies in gen's
// view (M: new view to gen's view; P: view to clip); HUD pixels stay put.
// detail: half-size gen frames get detail from the real frames (upsample_detail; tau its cutoff).
// reactive: the denoiser's reactive mask (transparencies: smoke, particles) is bound (texture 9).
struct HudParams { uint debug; uint hasLow; float2 mvToOut; float2 outToIn; uint warp; float phase; uint detail; float tau;
                   uint reactive; float4x4 P; float4x4 Pinv; float3x3 M; };
// Half size (each texel the mean of 2x2: one bilinear sample at their shared corner), for interpolating at half output.
kernel void fg_down(texture2d<float, access::sample> src [[texture(0)]], texture2d<float, access::write> dst [[texture(1)]],
                    uint2 p [[thread_position_in_grid]])
{
    constexpr sampler bilinear(filter::linear, address::clamp_to_edge);
    if (p.x < dst.get_width() && p.y < dst.get_height())
        dst.write(src.sample(bilinear, (float2(p) + 0.5) / float2(dst.get_width(), dst.get_height())), p);
}
static inline int2 s_max(texture2d<float, access::read> t) { return int2(t.get_width(), t.get_height()) - 1; }
// Catmull-Rom in 9 bilinear taps, for 4x's half-size generated frames: bilinear upsampling kept 60% of the real frame's
// edge detail (Laplacian, in-game frames halved and upsampled), so edges pulsed sharp/soft at the rendered rate;
// Catmull-Rom keeps 74% (+3.3 dB).
static inline float4 sample_cr(texture2d<float, access::sample> t, float2 uv)
{
    constexpr sampler bilinear(filter::linear, address::clamp_to_edge);
    const float2 size = float2(t.get_width(), t.get_height());
    const float2 pos = uv * size, c = floor(pos - 0.5) + 0.5, f = pos - c;
    const float2 w0 = f * (-0.5 + f * (1.0 - 0.5 * f)), w1 = 1.0 + f * f * (-2.5 + 1.5 * f);
    const float2 w2 = f * (0.5 + f * (2.0 - 1.5 * f)), w3 = f * f * (-0.5 + 0.5 * f);
    const float2 w12 = w1 + w2, o12 = w2 / w12;
    const float2 t0 = (c - 1.0) / size, t3 = (c + 2.0) / size, t12 = (c + o12) / size;
    float4 r = t.sample(bilinear, float2(t0.x, t0.y)) * w0.x * w0.y + t.sample(bilinear, float2(t12.x, t0.y)) * w12.x * w0.y +
               t.sample(bilinear, float2(t3.x, t0.y)) * w3.x * w0.y + t.sample(bilinear, float2(t0.x, t12.y)) * w0.x * w12.y +
               t.sample(bilinear, float2(t12.x, t12.y)) * w12.x * w12.y + t.sample(bilinear, float2(t3.x, t12.y)) * w3.x * w12.y +
               t.sample(bilinear, float2(t0.x, t3.y)) * w0.x * w3.y + t.sample(bilinear, float2(t12.x, t3.y)) * w12.x * w3.y +
               t.sample(bilinear, float2(t3.x, t3.y)) * w3.x * w3.y;
    return max(r, float4(0.0)); // the negative lobes can undershoot
}
// A half-size generated frame at output pixel q (pixel units, centers at +0.5): Catmull-Rom, plus the fine detail it
// lacks, taken from a real frame moved to the generated frame's moment (phase t: from the real frame at q - (1 - t) m,
// or from the previous one at q + t m, m the motion vector at q in output pixels; mode 1 the nearer one, 2 both
// weighted by nearness). The detail is the real frame minus its half-size copy upsampled the same way; it is added
// only where that half-size copy agrees with the generated frame (tau: the relative difference where it stops), so
// disocclusions and content the motion vectors do not carry (particles, smoke) keep the interpolator's pixels.
struct DetailParams { float2 mvToOut; float2 outToIn; float phase; uint mode; float tau; };
static inline float detail_weight(float3 base, float3 lo, float tau)
{
    const float3 d = abs(base - lo);
    const float l = max(max(max(lo.r, lo.g), lo.b), max(max(base.r, base.g), base.b));
    return saturate(1.0 - max(max(d.r, d.g), d.b) / (tau * l + 0.004));
}
static inline float4 upsample_detail(texture2d<float, access::sample> gen, texture2d<float, access::sample> cur,
                                     texture2d<float, access::sample> curHalf, texture2d<float, access::sample> prev,
                                     texture2d<float, access::sample> prevHalf, texture2d<float, access::read> motion,
                                     texture2d<float, access::read> ui, float2 q, float2 size, DetailParams dp)
{
    const float4 base = sample_cr(gen, q / size);
    if (dp.mode == 0u) return base;
    const int2 ms = int2(motion.get_width(), motion.get_height()) - 1;
    const float2 mv = motion.read(uint2(clamp(int2(q * dp.outToIn), int2(0), ms))).xy * dp.mvToOut;
    if (!all(isfinite(mv))) return base;
    float3 add = float3(0.0);
    float wsum = 0.0;
    for (int k = 0; k < 2; ++k) {
        const bool fromCur = k == 0;
        const float near = fromCur ? dp.phase : 1.0 - dp.phase; // 1 at that frame's moment
        if (dp.mode == 1u && (fromCur ? dp.phase < 0.5 : dp.phase >= 0.5)) continue;
        const float2 r = fromCur ? q - mv * (1.0 - dp.phase) : q + mv * dp.phase;
        if (any(r < float2(0.0)) || any(r > size)) continue;
        // The real frames have the HUD: no detail from there.
        if (ui.read(uint2(clamp(int2(r), int2(0), int2(ui.get_width(), ui.get_height()) - 1))).r > 0.0) continue;
        const float2 ruv = r / size;
        const float3 hi = sample_cr(fromCur ? cur : prev, ruv).rgb;
        const float3 lo = sample_cr(fromCur ? curHalf : prevHalf, ruv).rgb;
        const float w = detail_weight(base.rgb, lo, dp.tau) * (dp.mode == 1u ? 1.0 : near);
        add += w * (hi - lo);
        wsum += dp.mode == 1u ? 1.0 : near;
    }
    return float4(max(base.rgb + (wsum > 0.0 ? add / wsum : float3(0.0)), float3(0.0)), base.a);
}
kernel void fg_upsample_detail(texture2d<float, access::sample> gen [[texture(0)]],
                               texture2d<float, access::sample> cur [[texture(1)]],
                               texture2d<float, access::sample> curHalf [[texture(2)]],
                               texture2d<float, access::sample> prev [[texture(3)]],
                               texture2d<float, access::sample> prevHalf [[texture(4)]],
                               texture2d<float, access::read> motion [[texture(5)]],
                               texture2d<float, access::read> ui [[texture(6)]],
                               texture2d<float, access::write> dst [[texture(7)]],
                               constant DetailParams& dp [[buffer(0)]], uint2 p [[thread_position_in_grid]])
{
    if (p.x >= dst.get_width() || p.y >= dst.get_height()) return;
    const float2 size = float2(dst.get_width(), dst.get_height());
    dst.write(upsample_detail(gen, cur, curHalf, prev, prevHalf, motion, ui, float2(p) + 0.5, size, dp), p);
}
// The generated frame (gen, output size or smaller: sampled bilinear) into dst. HUD pixels take the real frame (cur) as
// it is (the HUD does not move on screen); around the HUD, where the interpolator may have dragged HUD pixels, the scene
// comes from the real frame reprojected to the generated frame's moment (phase: 0 the previous frame, 1 the real one):
// the motion vector m at p points to where p was in the previous frame, so at phase t the content is at p - (1 - t) m
// (in-game sequence: the previous frame from the real one this way 46-47 dB, holding the real frame 30 dB). Before,
// the real pixel at p filled the whole area around the HUD, a band of another moment (and unturned by the camera warp)
// that showed as distortion around the HUD in fast turns.
kernel void fg_hud(texture2d<float, access::sample> gen [[texture(0)]],
                   texture2d<float, access::sample> cur [[texture(1)]],
                   texture2d<float, access::read> ui [[texture(2)]],
                   texture2d<float, access::read> low [[texture(3)]],
                   texture2d<float, access::read> motion [[texture(4)]],
                   texture2d<float, access::write> dst [[texture(5)]],
                   texture2d<float, access::sample> curHalf [[texture(6)]],
                   texture2d<float, access::sample> prev [[texture(7)]],
                   texture2d<float, access::sample> prevHalf [[texture(8)]],
                   texture2d<float, access::read> reactive [[texture(9)]],
                   constant HudParams& h [[buffer(0)]],
                   uint2 p [[thread_position_in_grid]])
{
    if (p.x >= dst.get_width() || p.y >= dst.get_height()) return;
    const int2 s = int2(ui.get_width(), ui.get_height()) - 1;
    float a = 0.0;
    for (int y = -1; y <= 1; ++y)
        for (int x = -1; x <= 1; ++x)
            a = max(a, ui.read(uint2(clamp(int2(p) + int2(x, y), int2(0), s))).r);
    const bool hud = a > 0.0;
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
    // HUD pixels take the real pixel whole: a partial blend keeps part of the interpolated (dragged) HUD.
    if (h.debug != 0u) {
        dst.write(hud ? float4(1, 0, 1, 1) : a > 0.0 ? float4(1, 1, 0, 1) : float4(0, 1, 0, 1), p);
        return;
    }
    if (hud) {
        dst.write(cur.read(p), p);
        return;
    }
    constexpr sampler bilinear(filter::linear, address::clamp_to_edge);
    const float2 size = float2(dst.get_width(), dst.get_height());
    float2 uv = (float2(p) + 0.5) / size;
    bool turned = false;
    if (h.warp != 0u) {
        const float4 v = h.Pinv * float4(uv.x * 2.0 - 1.0, 1.0 - uv.y * 2.0, 0.5, 1.0);
        const float4 c = h.P * float4(h.M * (v.xyz / v.w), 1.0);
        const float2 t = float2(c.x / c.w * 0.5 + 0.5, 0.5 - c.y / c.w * 0.5);
        // Where the turned direction lands on the HUD, the scene there is hidden: keep this pixel unturned.
        const int2 q = int2(clamp(t * size, float2(0.0), size - 1.0));
        const bool hudThere = ui.read(uint2(clamp(q, int2(0), s_max(ui)))).r > 0.0 ||
                              (h.hasLow != 0u && low.read(uint2(clamp(q / 16, int2(0), s_max(low)))).r > 0.0);
        if (!hudThere) {
            uv = t;
            turned = true;
        }
    }
    if (a > 0.0) { // around the HUD: the real frame, reprojected to this moment (and turned with the rest)
        const float2 q = clamp(uv * size, float2(0.0), size - 1.0);
        const int2 ms = int2(motion.get_width(), motion.get_height()) - 1;
        const float2 mv = motion.read(uint2(clamp(int2(q * h.outToIn), int2(0), ms))).xy * h.mvToOut;
        const float2 r = q - mv * (1.0 - h.phase);
        const int2 ri = int2(clamp(r, float2(0.0), size - 1.0));
        // Unless that lands on the HUD itself (the real frame has the HUD there): then the generated pixel.
        if (ui.read(uint2(clamp(ri, int2(0), s))).r == 0.0) {
            dst.write(cur.sample(bilinear, r / size), p);
            return;
        }
        if (!turned) {
            dst.write(cur.read(p), p);
            return;
        }
    }
    if (gen.get_width() >= dst.get_width()) {
        dst.write(gen.sample(bilinear, uv), p);
        return;
    }
    const DetailParams dp = {h.mvToOut, h.outToIn, h.phase, h.detail, h.tau};
    float4 o = upsample_detail(gen, cur, curHalf, prev, prevHalf, motion, ui, uv * size, size, dp);
    // Transparencies (smoke, exhaust, particles) have no motion vectors of their own: the interpolator moves them with
    // what is behind them (the road under a car's exhaust), so they jump. Where the reactive mask marks them and the
    // two real frames agree better unmoved than moved by the motion vector (smoke that stays on screen with the car),
    // blend the real frames in place instead.
    if (h.reactive != 0u && h.detail != 0u && reactive.get_width() == motion.get_width() &&
        reactive.get_height() == motion.get_height()) {
        const float2 q = uv * size;
        const int2 rs = int2(reactive.get_width(), reactive.get_height()) - 1;
        const float r = reactive.read(uint2(clamp(int2(q * h.outToIn), int2(0), rs))).r;
        const int2 ms = int2(motion.get_width(), motion.get_height()) - 1;
        const float2 mv = motion.read(uint2(clamp(int2(q * h.outToIn), int2(0), ms))).xy * h.mvToOut;
        if (r > 0.02 && all(isfinite(mv))) {
            const float3 c0 = cur.sample(bilinear, uv).rgb, p0 = prev.sample(bilinear, uv).rgb;
            const float3 pm = prev.sample(bilinear, clamp((q + mv) / size, float2(0.0), float2(1.0))).rgb;
            const float3 e0 = abs(c0 - p0), em = abs(c0 - pm);
            if (max(max(e0.r, e0.g), e0.b) < max(max(em.r, em.g), em.b))
                o.rgb = mix(o.rgb, mix(p0, c0, h.phase), r);
        }
    }
    dst.write(o, p);
}
)";
