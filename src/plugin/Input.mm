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
#include <map>
#include <mutex>
#include <string>
#include <vector>

#include "Logger.hpp"

namespace {

std::mutex g_mutex;
Input::FrameInput g_pending, g_current; // the newest mouse event since the last present call; the current frame's

using NextFn = NSEvent* (*)(id, SEL, NSEventMask, NSDate*, NSRunLoopMode, BOOL);
NextFn o_next = nullptr;

// Frame limiter (SetFrameLimit): the wait goes right before the game reads input for a frame (its first event pump after
// a pause of over 4 ms), so the frame starts from the newest input; a limiter that waits after the input read (or at
// present) lets the input age by the wait. Main thread only.
std::atomic<double> g_limitInterval{0};
double g_lastPump = 0, g_nextStart = 0;

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
    const double start = CACurrentMediaTime();
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

void BeginFrame()
{
    std::lock_guard<std::mutex> lock(g_mutex);
    g_current = g_pending;
    g_current.present = CACurrentMediaTime();
    g_pending = {};
}

FrameInput Current()
{
    std::lock_guard<std::mutex> lock(g_mutex);
    return g_current;
}

void Track(id drawable, const FrameInput& in, const char* path)
{
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
