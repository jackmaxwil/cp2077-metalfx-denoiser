#import "Input.hpp"

#import <AppKit/AppKit.h>
#import <Metal/Metal.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>

#include <algorithm>
#include <atomic>
#include <chrono>
#include <thread>
#include <cstdio>
#include <deque>
#include <condition_variable>
#include <map>
#include <mutex>
#include <string>
#include <vector>

#include "Logger.hpp"

namespace {

std::mutex g_mutex;
Input::FrameInput g_pending, g_current; // the newest mouse event since the last present call; the current frame's
struct Sample {
    double t, x, y; // event time, cumulative movement
};
std::deque<Sample> g_samples; // the last eight seconds
double g_x = 0, g_y = 0;

using NextFn = NSEvent* (*)(id, SEL, NSEventMask, NSDate*, NSRunLoopMode, BOOL);
NextFn o_next = nullptr;

// Frame limiter (SetFrameLimit): the wait goes right before the game reads input for a frame (its first event pump after
// a pause of over 4 ms), so the frame starts from the newest input; a limiter that waits after the input read (or at
// present) lets the input age by the wait. Main thread only.
std::atomic<double> g_limitInterval{0};
std::atomic<double> g_slept{0}; // seconds waited since the last TakeLimiterWait
std::atomic<double> g_frameStart{0}; // when the latest frame started (the limiter released it)
double g_lastPump = 0, g_nextStart = 0;

// Low-latency pacing (SetLowLatency; like NVIDIA Reflex): when the GPU limits the frame rate, the game reads input,
// runs its CPU frame, and the frame then waits behind the previous ones on the GPU, so the input ages by that queue (in
// play with 4x frame generation: present call to GPU done 65 ms for 39 ms frames). Here the frame starts (and reads
// input) only when its CPU part will end about when the GPU finishes the frame before it: at the previous frame's GPU
// end plus one GPU frame interval minus one CPU frame, both smoothed. Main thread only, except NoteGpuDone.
std::atomic<bool> g_lowLatency{false};
std::mutex g_gpuMutex;
std::condition_variable g_gpuCv;
double g_gpuEnd[8] = {};        // GPU end of frame n at [n % 8]
uint64_t g_gpuEndFrame[8] = {};
uint64_t g_presented = 0;       // the game's frames presented (present calls)
double g_gpuInt = 0, g_cpu = 0; // smoothed GPU frame interval (consecutive GPU ends) and CPU frame (start to present)
double g_lastGpuEnd = 0;
uint64_t g_lastGpuFrame = 0;

void PaceToGpu()
{
    uint64_t frame;
    double gpuInt, cpu;
    {
        std::lock_guard<std::mutex> lock(g_gpuMutex);
        frame = g_presented; // the latest frame presented: N; the frame starting is N + 1
        gpuInt = g_gpuInt;
        cpu = g_cpu;
    }
    if (frame < 2 || gpuInt <= 0 || gpuInt > 0.2) {
        return;
    }
    const uint64_t prev = frame - 1; // its GPU end, plus one GPU frame (N), is when the GPU frees up
    double prevEnd = 0;
    {
        std::unique_lock<std::mutex> lock(g_gpuMutex);
        g_gpuCv.wait_for(lock, std::chrono::milliseconds(100), [&] { return g_gpuEndFrame[prev % 8] == prev; });
        if (g_gpuEndFrame[prev % 8] != prev) {
            return;
        }
        prevEnd = g_gpuEnd[prev % 8];
    }
    const double target = prevEnd + gpuInt - cpu - 0.002; // 2 ms early: a GPU bubble costs throughput
    const double now = CACurrentMediaTime();
    if (target > now) {
        std::this_thread::sleep_for(std::chrono::duration<double>(std::min(target - now, 0.1)));
    }
}

void Limit()
{
    const double interval = g_limitInterval.load(std::memory_order_relaxed);
    const double now = CACurrentMediaTime();
    const bool burst = now - g_lastPump > 0.004;
    g_lastPump = now;
    if (!burst || interval <= 0) {
        return;
    }
    if (now < g_nextStart) {
        std::this_thread::sleep_for(std::chrono::duration<double>(g_nextStart - now));
    }
    if (g_lowLatency.load(std::memory_order_relaxed)) {
        PaceToGpu();
    }
    const double start = CACurrentMediaTime();
    g_frameStart.store(start, std::memory_order_relaxed);
    g_slept.fetch_add(start - now, std::memory_order_relaxed);
    // The next start one interval after this one's target (no drift); first, or over a frame late: from now.
    g_nextStart = start - g_nextStart > interval ? start + interval : g_nextStart + interval;
    g_lastPump = start;
}

NSEvent* H_next(id self, SEL sel, NSEventMask mask, NSDate* until, NSRunLoopMode mode, BOOL dequeue)
{
    Limit();
    NSEvent* ev = o_next(self, sel, mask, until, mode, dequeue);
    g_lastPump = CACurrentMediaTime();
    if (ev && dequeue) {
        const NSEventType type = ev.type;
        if (type == NSEventTypeMouseMoved || type == NSEventTypeLeftMouseDragged ||
            type == NSEventTypeRightMouseDragged || type == NSEventTypeOtherMouseDragged) {
            std::lock_guard<std::mutex> lock(g_mutex);
            g_pending.event = ev.timestamp; // seconds since boot: the same clock as CACurrentMediaTime
            g_pending.read = CACurrentMediaTime();
            g_x += ev.deltaX;
            g_y += ev.deltaY;
            g_samples.push_back({ev.timestamp, g_x, g_y});
            while (g_samples.size() > 2 && ev.timestamp - g_samples[1].t > 8.0) {
                g_samples.pop_front();
            }
        }
    }
    return ev;
}

// Per path: samples of the three parts (ms), and frames whose drawable was not shown.
struct Samples {
    std::vector<double> total, toRead, toPresent, toShown;
    int unshown = 0;
};
std::mutex g_statsMutex;
std::map<std::string, Samples> g_stats;

double Pct(std::vector<double> v, double p)
{
    std::sort(v.begin(), v.end());
    return v[std::min(v.size() - 1, static_cast<size_t>(p * v.size()))];
}

} // namespace

namespace Input {

void Start()
{
    static std::atomic<bool> started{false};
    if (started.exchange(true)) {
        return;
    }
    dispatch_async(dispatch_get_main_queue(), ^{
      Method m = class_getInstanceMethod([NSApplication class],
                                         @selector(nextEventMatchingMask:untilDate:inMode:dequeue:));
      if (m) {
          o_next = reinterpret_cast<NextFn>(method_setImplementation(m, reinterpret_cast<IMP>(H_next)));
      }
      Logger::Info(std::string("Input: event pump hook ") + (o_next ? "installed" : "unavailable"));
    });
}

void SetFrameLimit(float fps)
{
    g_limitInterval.store(fps > 0 ? 1.0 / std::clamp(fps, 10.0f, 240.0f) : 0.0);
    if (fps > 0) {
        Logger::Info("Input: frame limit " + std::to_string(fps).substr(0, 5) + " fps (waits before the game reads input)");
    }
}

double FrameStart()
{
    return g_frameStart.load(std::memory_order_relaxed);
}

double TakeLimiterWait()
{
    return g_slept.exchange(0);
}

void SetLowLatency(bool on)
{
    g_lowLatency.store(on);
    Logger::Info(std::string("Input: low-latency pacing ") + (on ? "on (frames start when the GPU is about to be free)" : "off"));
}

uint64_t NotePresentCall()
{
    const double now = CACurrentMediaTime(), start = g_frameStart.load(std::memory_order_relaxed);
    std::lock_guard<std::mutex> lock(g_gpuMutex);
    if (start > 0 && now > start && now - start < 0.2) {
        g_cpu = g_cpu > 0 ? 0.9 * g_cpu + 0.1 * (now - start) : now - start;
    }
    return ++g_presented;
}

void NoteGpuDone(uint64_t frame, double gpuEnd)
{
    {
        std::lock_guard<std::mutex> lock(g_gpuMutex);
        g_gpuEnd[frame % 8] = gpuEnd;
        g_gpuEndFrame[frame % 8] = frame;
        if (frame == g_lastGpuFrame + 1 && gpuEnd > g_lastGpuEnd) {
            const double d = gpuEnd - g_lastGpuEnd;
            if (d < 0.2) {
                g_gpuInt = g_gpuInt > 0 ? 0.9 * g_gpuInt + 0.1 * d : d;
            }
        }
        if (frame > g_lastGpuFrame) {
            g_lastGpuFrame = frame;
            g_lastGpuEnd = gpuEnd;
        }
    }
    g_gpuCv.notify_all();
}

void BeginFrame()
{
    std::lock_guard<std::mutex> lock(g_mutex);
    g_current = g_pending;
    g_current.present = CACurrentMediaTime();
    g_current.x = g_x;
    g_current.y = g_y;
    g_pending = {};
}

FrameInput Current()
{
    std::lock_guard<std::mutex> lock(g_mutex);
    return g_current;
}

bool Counts(double t, double& x, double& y, double* latest)
{
    std::lock_guard<std::mutex> lock(g_mutex);
    if (g_samples.empty()) {
        x = g_x;
        y = g_y;
        return false;
    }
    if (latest) {
        *latest = g_samples.back().t;
    }
    if (t >= g_samples.back().t) {
        x = g_samples.back().x;
        y = g_samples.back().y;
        return true;
    }
    if (t < g_samples.front().t) {
        return false;
    }
    auto it = std::upper_bound(g_samples.begin(), g_samples.end(), t, [](double v, const Sample& s) { return v < s.t; });
    const Sample& b = *it;
    const Sample& a = *(it - 1);
    const double f = b.t > a.t ? (t - a.t) / (b.t - a.t) : 1.0;
    x = a.x + (b.x - a.x) * f;
    y = a.y + (b.y - a.y) * f;
    return true;
}

void Track(id drawable, const FrameInput& frame, const char* path)
{
    const FrameInput in = frame; // a copy: a block captures a reference as a reference (here to a temporary)
    if (in.event <= 0 || !drawable) {
        return; // no mouse movement went into this frame
    }
    const std::string name = path;
    [(id<MTLDrawable>)drawable addPresentedHandler:^(id<MTLDrawable> d) {
      const double shown = d.presentedTime;
      std::lock_guard<std::mutex> lock(g_statsMutex);
      Samples& s = g_stats[name];
      if (shown <= 0) {
          ++s.unshown;
          return;
      }
      s.total.push_back((shown - in.event) * 1000);
      s.toRead.push_back((in.read - in.event) * 1000);
      s.toPresent.push_back((in.present - in.read) * 1000);
      s.toShown.push_back((shown - in.present) * 1000);
      if (s.total.size() < 120) {
          return;
      }
      char buf[400];
      std::snprintf(buf, sizeof(buf),
                    "Latency (%s): mouse event to display %.1f ms median, %.1f ms p95; parts (median): event to the "
                    "game's read %.1f, read to present call %.1f, present call to display %.1f; %zu frames, %d not "
                    "shown", name.c_str(), Pct(s.total, 0.5), Pct(s.total, 0.95), Pct(s.toRead, 0.5),
                    Pct(s.toPresent, 0.5), Pct(s.toShown, 0.5), s.total.size(), s.unshown);
      Logger::Info(buf);
      s = {};
    }];
}

} // namespace Input
