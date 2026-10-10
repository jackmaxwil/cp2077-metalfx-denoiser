#include "DynamicScale.hpp"

#include "ConfigVars.hpp"
#include "Logger.hpp"

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <mutex>
#include <string>

namespace DynamicScale {
namespace {

// Steps of 0.25 from minScale up, the last one to 3.0. Frame time model for a step (RT Psycho at 3456x2160, measured: 3x 22.4 ms, 2.5x
// 28.6, 2.25x 33.8, 2x 41.1): about a quarter of the frame does not depend on the render size, the rest goes with the
// pixel count (1 / scale^2). A step down (sharper) is only taken when the model says it still meets the target.
constexpr float kStep = 0.25f, kMax = 3.0f;
constexpr double kFixed = 0.25;
// A change at most every 2 s: each one resizes the game's render targets (and frame generation's interpolators).
constexpr double kHold = 2.0;

std::mutex s_mutex;
float s_target = 0, s_min = 3.0f, s_scale = 0;
double s_ema = 0, s_last = 0, s_changed = 0, s_slowest = 0;
int s_frames = 0;
bool s_settling = false; // log the slowest frame of the first 30 after a change

double Now()
{
    using namespace std::chrono;
    return duration<double>(steady_clock::now().time_since_epoch()).count();
}

double Predict(double ms, float from, float to)
{
    return ms * (kFixed + (1 - kFixed) * (from * from) / (to * to));
}

void Set(float scale, const char* why)
{
    std::string err;
    if (!ConfigVars::SetUltraScale(scale, err)) {
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
    if (s_frames < 30 || now - s_changed < kHold) {
        return;
    }
    const double target = 1.0 / s_target;
    if (s_ema > target * 1.04 && s_scale < kMax) {
        Set(std::min(kMax, s_scale + kStep), "over the target");
    } else if (const float down = std::max(s_min, s_scale - kStep);
               s_ema < target && s_scale > s_min && Predict(s_ema, s_scale, down) < target * 0.97) {
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
