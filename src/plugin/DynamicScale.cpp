#include "DynamicScale.hpp"

#include "ConfigVars.hpp"
#include "EngineDrs.hpp"
#include "Logger.hpp"

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <mutex>
#include <string>
#include <utility>

namespace DynamicScale {
namespace {

// Steps of 0.25 from minScale up, the last one to 3.0. Each change costs a hitch: the game resizes its render-size
// resources and rebuilds its upscaler (path tracing: one 150-170 ms frame, then about a second of 50-60 ms frames).
// So changes are rare: a step up (coarser) when the frame interval is 8% over the target, a step down (sharper) only
// when the frame time scaled by the pixel count (no fixed part: path tracing grew faster than the pixel count, 2.75x
// 27.9 ms to 2.5x 34.8 ms) stays 15% under it, at least 10 s apart, and never back down within 60 s of a step up (the
// sharper scale was just over the target). The earlier 4% / 3% margins, 2 s hold and a model with a quarter of the
// frame fixed flipped path tracing between 2.5 and 2.75 every 2-5 s.
// With the engine's own dynamic resolution running (MetalFX "Dynamic", EngineDrs) a change only moves the content
// rectangle: no reallocation, no new scaler, history kept. Then the holds are short.
constexpr float kStep = 0.25f, kMax = 3.0f;
constexpr double kHold = 10.0, kNoDownAfterUp = 60.0, kEngineHold = 2.0, kEngineNoDownAfterUp = 10.0;

std::mutex s_mutex;
float s_target = 0, s_min = 3.0f, s_scale = 0;
double s_ema = 0, s_last = 0, s_changed = 0, s_slowest = 0, s_noDownUntil = 0;
int s_frames = 0;
bool s_settling = false; // log the slowest frame of the first 30 after a change

double Now()
{
    using namespace std::chrono;
    return duration<double>(steady_clock::now().time_since_epoch()).count();
}

double Predict(double ms, float from, float to)
{
    return ms * (from * from) / (to * to);
}

void Set(float scale, const char* why)
{
    std::string err;
    static bool hinted = false;
    if (EngineDrs::Active()) {
        EngineDrs::SetScale(scale, s_min);
    } else if (!std::exchange(hinted, true)) {
        Logger::Info("Dynamic scale: the game's dynamic resolution is off, so each change reallocates (about 160 ms); "
                     "set DynamicResolutionScaling to true under /graphics/presets in UserSettings.json for "
                     "hitch-free changes");
    }
    if (!EngineDrs::Active() && !ConfigVars::SetUltraScale(scale, err)) {
        Logger::Warn("Dynamic scale: " + std::to_string(scale) + " not applied (" + err + "): off");
        s_target = 0;
        return;
    }
    char buf[160];
    std::snprintf(buf, sizeof(buf), "Dynamic scale: %.2f -> %.2f (%s; frame %.1f ms, target %.1f ms)", s_scale, scale,
                  why, s_ema * 1000, 1000 / s_target);
    Logger::Info(buf);
    s_scale = scale;
}

} // namespace

void Configure(float targetFps, float minScale)
{
    std::lock_guard<std::mutex> lock(s_mutex);
    s_target = targetFps > 0 ? std::clamp(targetFps, 10.0f, 240.0f) : 0;
    if (minScale > 0 || s_scale <= 0) {
        if (minScale > 0) {
            s_min = std::clamp(minScale, 2.0f, kMax); // the player's scale exactly (steps go from it to 3.0)
        }
        s_scale = s_min; // what ApplyUltra set
    } else if (s_scale > 0 && s_scale != s_min) { // back to the sharpest (request "dynscale")
        std::string err;
        if (ConfigVars::SetUltraScale(s_min, err)) {
            s_scale = s_min;
        }
    }
    EngineDrs::SetScale(s_target > 0 ? s_scale : 0, s_target > 0 ? s_min : 0);
    s_ema = 0;
    s_frames = 0;
    if (s_target > 0) {
        Logger::Info("Dynamic scale: " + std::to_string(static_cast<int>(s_target)) + " fps, scale " +
                     std::to_string(s_min).substr(0, 4) + " to 3.00");
    }
}

void OnFrame()
{
    const double now = Now();
    std::lock_guard<std::mutex> lock(s_mutex);
    const double dt = s_last > 0 ? now - s_last : 0;
    s_last = now;
    if (s_target <= 0 || dt <= 0 || dt > 0.5) { // off, or a loading screen or pause
        s_ema = 0;
        s_frames = 0;
        return;
    }
    s_ema = s_ema > 0 ? 0.95 * s_ema + 0.05 * dt : dt;
    s_slowest = std::max(s_slowest, dt);
    if (++s_frames == 30 && s_settling) {
        char buf[160];
        std::snprintf(buf, sizeof(buf), "Dynamic scale: at %.2f, frame %.1f ms; slowest of the 30 frames after the change "
                      "%.1f ms", s_scale, s_ema * 1000, s_slowest * 1000);
        Logger::Info(buf);
        s_settling = false;
    }
    const bool engine = EngineDrs::Active();
    if (s_frames < 30 || now - s_changed < (engine ? kEngineHold : kHold)) {
        return;
    }
    const double target = 1.0 / s_target;
    if (s_ema > target * 1.08 && s_scale < kMax) {
        Set(std::min(kMax, s_scale + kStep), "over the target");
        s_noDownUntil = now + (engine ? kEngineNoDownAfterUp : kNoDownAfterUp);
    } else if (const float down = std::max(s_min, s_scale - kStep);
               now >= s_noDownUntil && s_scale > s_min && Predict(s_ema, s_scale, down) < target * 0.85) {
        Set(down, "room under the target");
    } else {
        return;
    }
    s_changed = now;
    s_frames = 0;
    s_ema = 0;
    s_slowest = 0;
    s_settling = true;
}

} // namespace DynamicScale
