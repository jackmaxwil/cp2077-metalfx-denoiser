#import "Warp.hpp"

#import <Metal/Metal.h>
#import <QuartzCore/QuartzCore.h>
#include <simd/simd.h>

#include <algorithm>
#include <atomic>
#include <cmath>
#include <cstdio>
#include <deque>
#include <mutex>

#include "Denoise.hpp"
#include "Input.hpp"
#include "Logger.hpp"
#include "MetalTrace.hpp"

namespace {

NSString* const kSource = @R"(
#include <metal_stdlib>
using namespace metal;
struct WarpParams { float4x4 P; float4x4 Pinv; float3x3 M; uint hud; };
// For each output pixel (the new camera's view), the pixel of src (the frame's camera) that shows the same direction.
kernel void fg_warp(texture2d<float, access::sample> src [[texture(0)]],
                    texture2d<float, access::read> cur [[texture(1)]],
                    texture2d<float, access::read> ui [[texture(2)]],
                    texture2d<float, access::write> dst [[texture(3)]],
                    constant WarpParams& w [[buffer(0)]],
                    uint2 p [[thread_position_in_grid]])
{
    const uint W = dst.get_width(), H = dst.get_height();
    if (p.x >= W || p.y >= H) return;
    const float2 size = float2(W, H);
    const float2 uv = (float2(p) + 0.5) / size;
    const float4 v = w.Pinv * float4(uv.x * 2.0 - 1.0, 1.0 - uv.y * 2.0, 0.5, 1.0);
    const float4 c = w.P * float4(w.M * (v.xyz / v.w), 1.0);
    const float2 s = float2(c.x / c.w * 0.5 + 0.5, 0.5 - c.y / c.w * 0.5);
    constexpr sampler lin(filter::linear, address::clamp_to_edge);
    float4 o = src.sample(lin, s);
    if (w.hud != 0u) {
        const uint2 sp = uint2(clamp(s * size, float2(0.0), size - 1.0));
        if (ui.read(sp).a > 0.0) o = src.sample(lin, uv); // the source is HUD: this pixel stays unturned
        o = mix(o, cur.read(p), saturate(ui.read(p).a * 2.0));
    }
    dst.write(o, p);
}
)";

struct Params {
    simd_float4x4 P, Pinv;
    simd_float3x3 M;
    uint32_t hud;
};

struct Frame {
    double t;
    double yaw, pitch;
    simd_float3x3 R; // view to world
    simd_float4x4 P; // view to clip
};

std::atomic<bool> g_enabled{false};
std::atomic<unsigned long long> g_encoded{0};
id<MTLComputePipelineState> g_pso;

std::mutex g_mutex; // everything below
std::deque<Frame> g_frames;
uint64_t g_serial = 0;
bool g_live = false;
size_t g_count = 0;
// Calibration: latency from moving the mouse to the game's present call, sensitivity (radians per count).
bool g_cal = false;
double g_lat = 0, g_kx = 0, g_ky = 0, g_r2 = 0, g_gameLat = 0, g_gameR2 = 0;
std::vector<double> g_shown;
bool g_test = false;
float g_testV2w[16], g_testP[16];

double Wrap(double a)
{
    while (a > M_PI) {
        a -= 2 * M_PI;
    }
    while (a < -M_PI) {
        a += 2 * M_PI;
    }
    return a;
}

simd_float3x3 Rot(simd_float3 axis, float angle)
{
    return simd_matrix3x3(simd_quaternion(angle, simd_normalize(axis)));
}

double Pitch(simd_float3 f)
{
    return std::asin(std::clamp(static_cast<double>(f.z), -1.0, 1.0));
}

double Median(std::vector<double> v)
{
    if (v.empty()) {
        return 0;
    }
    std::nth_element(v.begin(), v.begin() + v.size() / 2, v.end());
    return v[v.size() / 2];
}

// Fits over the frames of the last few seconds (caller holds g_mutex).
void Calibrate()
{
    std::vector<double> t, dyaw, dpitch;
    const double now = g_frames.back().t;
    for (size_t i = 1; i < g_frames.size(); ++i) {
        const Frame &a = g_frames[i - 1], &b = g_frames[i];
        if (now - a.t > 6.0 || b.t - a.t > 0.2) {
            t.clear(); // a gap: start the series after it
            dyaw.clear();
            dpitch.clear();
            continue;
        }
        if (t.empty()) {
            t.push_back(a.t);
        }
        t.push_back(b.t);
        dyaw.push_back(Wrap(b.yaw - a.yaw));
        dpitch.push_back(b.pitch - a.pitch);
    }
    auto raw = [](int axis) {
        return [axis](double at) {
            double x, y;
            return Input::Counts(at, x, y) ? (axis ? y : x) : NAN;
        };
    };
    double lat, k, r2;
    if (Warp::FitLatency(t, dyaw, raw(0), lat, k, r2)) {
        g_r2 = r2;
        if (r2 >= 0.6) {
            g_lat = lat;
            g_kx = k;
            g_cal = true;
            // Pitch at the same latency (no search: vertical movement is often too small to place it).
            double sdc = 0, scc = 0, sdd = 0;
            for (size_t i = 0; i < dpitch.size(); ++i) {
                const double c = raw(1)(t[i + 1] - lat) - raw(1)(t[i] - lat);
                if (std::isfinite(c)) {
                    sdc += dpitch[i] * c;
                    scc += c * c;
                    sdd += dpitch[i] * dpitch[i];
                }
            }
            if (scc > 0 && sdd > 1e-6 && sdc * sdc / (scc * sdd) >= 0.5) {
                g_ky = sdc / scc;
            }
        } else if (r2 < 0.4) {
            g_cal = false; // the camera turns without the mouse (vehicle, scripted camera, cutscene)
        }
    }
    auto game = [](double at) {
        double x, y;
        return Input::GameCounts(at, x, y) ? x : NAN;
    };
    if (Warp::FitLatency(t, dyaw, game, lat, k, r2)) {
        g_gameLat = lat;
        g_gameR2 = r2;
    }
}

void Log() // caller holds g_mutex
{
    const Input::PumpStats pump = Input::TakePumpStats();
    char buf[500];
    std::snprintf(buf, sizeof(buf),
                  "Input lag: mouse to present call %.0f ms (fit R2 %.2f), game input read to present call %.0f ms "
                  "(R2 %.2f), mouse event age at the read %.1f ms, game frame %.1f ms (%zu), present call to display "
                  "%.1f ms; frame warp %s (%.4f, %.4f mrad per count), game-thread delay %.0f ms",
                  g_lat * 1000, g_r2, g_gameLat * 1000, g_gameR2, pump.eventAgeMs, pump.frameMs, pump.bursts,
                  Median(g_shown), !g_enabled.load() ? "off" : g_cal ? "on" : "waiting for a fit", g_kx * 1000,
                  g_ky * 1000, Input::GameDelay() * 1000);
    Logger::Info(buf);
    g_shown.clear();
}

} // namespace

namespace Warp {

void SetEnabled(bool on)
{
    if (g_enabled.exchange(on) != on) {
        Logger::Info(std::string("Warp: frame warp ") + (on ? "on" : "off"));
    }
    Input::SetRaw(on);
}

bool Enabled()
{
    return g_enabled.load();
}

unsigned long long Encoded()
{
    return g_encoded.load();
}

bool FitLatency(const std::vector<double>& t, const std::vector<double>& d, const std::function<double(double)>& counts,
                double& latency, double& k, double& r2)
{
    if (t.size() != d.size() + 1 || d.size() < 20) {
        return false;
    }
    bool found = false;
    r2 = -1;
    std::vector<double> c(t.size());
    for (double lat = 0; lat <= 0.2501; lat += 0.002) {
        for (size_t i = 0; i < t.size(); ++i) {
            c[i] = counts(t[i] - lat);
        }
        double sdc = 0, scc = 0, sdd = 0;
        int moving = 0;
        for (size_t i = 0; i < d.size(); ++i) {
            const double x = c[i + 1] - c[i];
            if (!std::isfinite(x)) {
                continue;
            }
            sdc += d[i] * x;
            scc += x * x;
            sdd += d[i] * d[i];
            moving += x != 0;
        }
        if (moving < 15 || scc <= 0 || sdd < 1e-4) { // about half a degree in all
            continue;
        }
        const double fit = sdc * sdc / (scc * sdd);
        if (fit > r2) {
            r2 = fit;
            latency = lat;
            k = sdc / scc;
            found = true;
        }
    }
    return found;
}

void FramePresented(double t)
{
    float delta[4], v2w[16], p[16];
    uint64_t serial = 0;
    bool cam = Denoise::Camera(delta, v2w, serial) && Denoise::ViewToClip(p);
    std::lock_guard<std::mutex> lock(g_mutex);
    if (g_test) {
        std::memcpy(v2w, g_testV2w, 64);
        std::memcpy(p, g_testP, 64);
        serial = g_serial + 1;
        cam = true;
    }
    g_live = cam && serial != g_serial;
    if (!g_live) {
        return;
    }
    g_serial = serial;
    Frame f;
    f.t = t;
    f.R = simd_matrix(simd_make_float3(v2w[0], v2w[1], v2w[2]), simd_make_float3(v2w[4], v2w[5], v2w[6]),
                      simd_make_float3(v2w[8], v2w[9], v2w[10]));
    std::memcpy(&f.P, p, 64);
    const simd_float3 fwd = f.R.columns[2];
    f.yaw = std::atan2(fwd.y, fwd.x);
    f.pitch = Pitch(fwd);
    g_frames.push_back(f);
    while (g_frames.size() > 400) {
        g_frames.pop_front();
    }
    if (++g_count % 30 == 0) {
        Calibrate();
    }
    if (g_count % 240 == 0) {
        Log();
    }
}

void FrameShown(double call, double shown)
{
    std::lock_guard<std::mutex> lock(g_mutex);
    if (shown > call && g_shown.size() < 10000) {
        g_shown.push_back((shown - call) * 1000.0);
    }
}

void TestSetup(const float viewToWorld[16], const float viewToClip[16], double latency, double kx, double ky)
{
    std::lock_guard<std::mutex> lock(g_mutex);
    g_test = true;
    std::memcpy(g_testV2w, viewToWorld, 64);
    std::memcpy(g_testP, viewToClip, 64);
    g_cal = true;
    g_lat = latency;
    g_kx = kx;
    g_ky = ky;
}

bool Ready()
{
    std::lock_guard<std::mutex> lock(g_mutex);
    return g_enabled.load() && g_cal && g_live && g_frames.size() >= 2 &&
           CACurrentMediaTime() - g_frames.back().t < 0.25;
}

bool Encode(id commandBuffer, id src, id cur, id ui, id dst, double phase)
{
    Frame f, prev;
    double lat, kx, ky;
    {
        std::lock_guard<std::mutex> lock(g_mutex);
        if (!g_enabled.load() || !g_cal || !g_live || g_frames.size() < 2) {
            return false;
        }
        f = g_frames.back();
        prev = g_frames[g_frames.size() - 2];
        lat = g_lat;
        kx = g_kx;
        ky = g_ky;
    }
    double x0, y0, x1, y1;
    if (!Input::Counts(f.t - lat, x0, y0) || !Input::Counts(CACurrentMediaTime(), x1, y1)) {
        return false;
    }
    // The turn from src's camera to the newest input's: the movement the frame does not show yet, plus (for a
    // generated frame) the part of the last frame's change it does not show.
    const double yaw = std::clamp(kx * (x1 - x0) - phase * Wrap(f.yaw - prev.yaw), -0.07, 0.07);
    const double pitch = std::clamp(ky * (y1 - y0) - phase * (f.pitch - prev.pitch), -0.07, 0.07);
    if (std::abs(yaw) < 2e-5 && std::abs(pitch) < 2e-5) {
        return false;
    }
    float r[9], p[16];
    std::memcpy(r, &f.R.columns[0], 12);
    std::memcpy(r + 3, &f.R.columns[1], 12);
    std::memcpy(r + 6, &f.R.columns[2], 12);
    std::memcpy(p, &f.P, 64);
    return EncodeWith(commandBuffer, src, cur, ui, dst, r, p, yaw, pitch);
}

bool EncodeWith(id commandBuffer, id src, id cur, id ui, id dst, const float viewToWorld[9], const float viewToClip[16],
                double yaw, double pitch)
{
    id<MTLCommandBuffer> cb = commandBuffer;
    id<MTLTexture> out = dst, uiTex = ui, curTex = cur;
    if (!g_pso) {
        NSError* error = nil;
        id<MTLLibrary> lib = [cb.device newLibraryWithSource:kSource options:nil error:&error];
        g_pso = [cb.device newComputePipelineStateWithFunction:[lib newFunctionWithName:@"fg_warp"] error:&error];
        if (!g_pso) {
            Logger::Error(std::string("Warp: kernel failed: ") +
                          (error ? error.localizedDescription.UTF8String : "no library"));
            g_enabled.store(false);
            return false;
        }
    }
    const simd_float3x3 R = simd_matrix(simd_make_float3(viewToWorld[0], viewToWorld[1], viewToWorld[2]),
                                        simd_make_float3(viewToWorld[3], viewToWorld[4], viewToWorld[5]),
                                        simd_make_float3(viewToWorld[6], viewToWorld[7], viewToWorld[8]));
    const simd_float3 right = R.columns[0], fwd = R.columns[2];
    // Pitch as Pitch() measures it: the sign of a turn about the camera's right axis.
    const double up = Pitch(simd_mul(Rot(right, 1e-3f), fwd)) - Pitch(fwd);
    const float s = up < 0 ? -1.0f : 1.0f;
    const simd_float3x3 A = simd_mul(Rot(simd_make_float3(0, 0, 1), static_cast<float>(yaw)),
                                     Rot(right, s * static_cast<float>(pitch)));
    Params params;
    std::memcpy(&params.P, viewToClip, 64);
    params.Pinv = simd_inverse(params.P);
    params.M = simd_mul(simd_transpose(R), simd_mul(A, R)); // new view to src's view
    const bool hud = uiTex && curTex && uiTex.width == out.width && uiTex.height == out.height &&
                     curTex.width == out.width && curTex.height == out.height;
    params.hud = hud ? 1 : 0;
    MetalTrace::Internal internal;
    id<MTLComputeCommandEncoder> ce = [cb computeCommandEncoder];
    [ce setComputePipelineState:g_pso];
    [ce setTexture:src atIndex:0];
    [ce setTexture:hud ? curTex : src atIndex:1];
    [ce setTexture:hud ? uiTex : src atIndex:2];
    [ce setTexture:out atIndex:3];
    [ce setBytes:&params length:sizeof(params) atIndex:0];
    [ce dispatchThreads:MTLSizeMake(out.width, out.height, 1) threadsPerThreadgroup:MTLSizeMake(16, 16, 1)];
    [ce endEncoding];
    g_encoded.fetch_add(1);
    return true;
}

} // namespace Warp
