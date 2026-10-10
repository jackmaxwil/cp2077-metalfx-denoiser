#include "Warp.hpp"

#import <QuartzCore/QuartzCore.h>

#include <algorithm>
#include <iterator>
#include <atomic>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <deque>
#include <mutex>
#include <string>
#include <vector>

#include "Denoise.hpp"
#include "Input.hpp"
#include "Logger.hpp"

namespace {

std::atomic<bool> g_enabled{false};
std::mutex g_mutex; // everything below
Warp::View g_prev;
uint64_t g_serial = 0;
// Calibration samples: per pair of consecutive frames, the camera's yaw and pitch change and the mouse counts between.
struct Pair {
    double dyaw, dpitch, dx, dy;
};
std::deque<Pair> g_pairs;
bool g_cal = false;
double g_kx = 0, g_ky = 0, g_r2 = 0;
// Input lead: display time minus the newest mouse event's time, at the game's frames (seconds), last 2 s.
std::deque<double> g_leads;
double g_lead = 0.05;
// Log counters.
int g_frames = 0, g_warped = 0, g_captures = 0, g_noCamera = 0;
int g_skip[4] = {}; // shown frames not warped: not calibrated, no view, no input at the target time, turn too small
double g_angleSum = 0;

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

// Least squares through zero over the pairs with mouse movement (caller holds g_mutex).
void Calibrate()
{
    double sxy = 0, sxx = 0, syy = 0, pxy = 0, pxx = 0, pyy = 0;
    int moving = 0;
    for (const Pair& p : g_pairs) {
        sxy += p.dyaw * p.dx;
        sxx += p.dx * p.dx;
        syy += p.dyaw * p.dyaw;
        pxy += p.dpitch * p.dy;
        pxx += p.dy * p.dy;
        pyy += p.dpitch * p.dpitch;
        moving += p.dx != 0;
    }
    if (moving < 15 || sxx <= 0 || syy < 1e-4) { // about half a degree of turning in all
        return;
    }
    g_r2 = sxy * sxy / (sxx * syy);
    if (g_r2 >= 0.8) {
        g_kx = sxy / sxx;
        // Pitch: fitted when there was enough vertical movement; until then no pitch warp.
        if (pxx > 0 && pyy > 1e-5 && pxy * pxy / (pxx * pyy) >= 0.6) {
            g_ky = pxy / pxx;
        }
        g_cal = true;
    } else if (g_r2 < 0.5) {
        g_cal = false; // the camera turns without the mouse
    }
}

} // namespace

namespace Warp {

void SetEnabled(bool on)
{
    // The camera comes from NRD's constants, read by Denoise's hooks: on also when the Apple denoiser is off.
    Denoise::SetWatch(on);
    if (g_enabled.exchange(on) != on) {
        Logger::Info(std::string("Warp: camera warp ") + (on ? "on" : "off"));
    }
}

bool Enabled()
{
    return g_enabled.load();
}

View Capture()
{
    View v;
    float delta[4], v2w[16], p[16];
    uint64_t serial = 0;
    if (!g_enabled.load()) {
        return v;
    }
    {
        std::lock_guard<std::mutex> lock(g_mutex);
        if (++g_captures % 240 == 0) {
            char buf[300];
            std::snprintf(buf, sizeof(buf), "Warp: %s (fit R2 %.2f over %zu frame pairs, %.3f / %.3f mrad per count), "
                          "input lead %.1f ms, %d of the last 240 frames without a new camera, %d shown frames warped "
                          "(mean turn %.2f deg); not warped: %d uncalibrated, %d no view, %d no input, %d no turn",
                          g_cal ? "on" : "waiting for a fit", g_r2, g_pairs.size(), g_kx * 1000, g_ky * 1000,
                          g_lead * 1000, g_noCamera, g_warped, g_warped ? g_angleSum / g_warped * 180 / M_PI : 0.0,
                          g_skip[0], g_skip[1], g_skip[2], g_skip[3]);
            Logger::Info(buf);
            g_noCamera = g_warped = 0;
            std::fill(std::begin(g_skip), std::end(g_skip), 0);
            g_angleSum = 0;
        }
    }
    if (!Denoise::Camera(delta, v2w, serial) || !Denoise::ViewToClip(p)) {
        std::lock_guard<std::mutex> lock(g_mutex);
        ++g_noCamera;
        return v;
    }
    const Input::FrameInput in = Input::Current();
    v.read = in.present;
    v.x = in.x;
    v.y = in.y;
    v.R = simd_matrix(simd_make_float3(v2w[0], v2w[1], v2w[2]), simd_make_float3(v2w[4], v2w[5], v2w[6]),
                      simd_make_float3(v2w[8], v2w[9], v2w[10]));
    std::memcpy(&v.P, p, 64);
    const simd_float3 fwd = v.R.columns[2]; // gViewToWorld: column 2 forward, column 1 up (measured)
    v.yaw = std::atan2(fwd.y, fwd.x);
    v.pitch = Pitch(fwd);
    std::lock_guard<std::mutex> lock(g_mutex);
    v.ok = serial != g_serial; // a new ray traced frame (else the camera is a previous frame's)
    g_serial = serial;
    g_noCamera += v.ok ? 0 : 1;
    if (v.ok && g_prev.ok && v.read - g_prev.read < 0.2) {
        g_pairs.push_back({Wrap(v.yaw - g_prev.yaw), v.pitch - g_prev.pitch, v.x - g_prev.x, v.y - g_prev.y});
        while (g_pairs.size() > 120) {
            g_pairs.pop_front();
        }
        if (++g_frames % 30 == 0) {
            Calibrate();
        }
    }
    g_prev = v;
    return v;
}

void NoteReal(double shown)
{
    double x, y, latest = 0;
    // Only while the mouse moves (its newest event within 100 ms of now): a still mouse says nothing about the lead.
    if (!Input::Counts(shown, x, y, &latest) || latest <= 0 || CACurrentMediaTime() - latest > 0.1) {
        return;
    }
    std::lock_guard<std::mutex> lock(g_mutex);
    g_leads.push_back(std::clamp(shown - latest, 0.0, 0.2));
    while (g_leads.size() > 120) {
        g_leads.pop_front();
    }
    // The lead most frames can meet (90th percentile): the target input is then nearly always already read.
    std::vector<double> v(g_leads.begin(), g_leads.end());
    std::nth_element(v.begin(), v.begin() + v.size() * 9 / 10, v.end());
    g_lead = v[v.size() * 9 / 10];
}

bool Make(const View& prev, const View& cur, double phase, double shown, Params& out)
{
    double kx, ky, lead;
    {
        std::lock_guard<std::mutex> lock(g_mutex);
        if (!g_enabled.load() || !g_cal || !cur.ok || !prev.ok) {
            ++g_skip[g_enabled.load() && g_cal ? 1 : 0];
            return false;
        }
        kx = g_kx;
        ky = g_ky;
        lead = g_lead;
    }
    double x, y;
    if (!Input::Counts(shown - lead, x, y)) {
        std::lock_guard<std::mutex> lock(g_mutex);
        ++g_skip[2];
        return false;
    }
    // The image's input: between the two frames' (generated frames), or the game frame's own.
    const double ix = prev.x + (cur.x - prev.x) * phase, iy = prev.y + (cur.y - prev.y) * phase;
    const double yaw = std::clamp(kx * (x - ix), -0.07, 0.07), pitch = std::clamp(ky * (y - iy), -0.07, 0.07);
    if (std::abs(yaw) < 2e-5 && std::abs(pitch) < 2e-5) {
        std::lock_guard<std::mutex> lock(g_mutex);
        ++g_skip[3];
        return false;
    }
    // The image's camera: cur's turned back by the part of the change prev -> cur it does not show yet.
    const double back = (1 - phase) * Wrap(cur.yaw - prev.yaw), backPitch = (1 - phase) * (cur.pitch - prev.pitch);
    const simd_float3 right = cur.R.columns[0], fwd = cur.R.columns[2];
    // Pitch as Pitch() measures it: the sign of a turn about the camera's right axis.
    const double up = Pitch(simd_mul(Rot(right, 1e-3f), fwd)) - Pitch(fwd);
    const float s = up < 0 ? -1.0f : 1.0f;
    const simd_float3x3 img = simd_mul(Rot(simd_make_float3(0, 0, 1), static_cast<float>(-back)),
                                       simd_mul(Rot(right, s * static_cast<float>(-backPitch)), cur.R));
    const simd_float3x3 A = simd_mul(Rot(simd_make_float3(0, 0, 1), static_cast<float>(yaw)),
                                     Rot(img.columns[0], s * static_cast<float>(pitch)));
    out.P = cur.P;
    out.Pinv = simd_inverse(cur.P);
    out.M = simd_mul(simd_transpose(img), simd_mul(A, img)); // new view to the image's view
    std::lock_guard<std::mutex> lock(g_mutex);
    ++g_warped;
    g_angleSum += std::hypot(yaw, pitch);
    return true;
}

} // namespace Warp
