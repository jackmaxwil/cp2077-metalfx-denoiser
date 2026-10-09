#import "Input.hpp"

#import <AppKit/AppKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>

#include <algorithm>
#include <atomic>
#include <cstdio>
#include <cstdlib>
#include <deque>
#include <mutex>
#include <string>
#include <vector>

#include "Logger.hpp"

namespace {

struct Sample {
    double t, x, y; // host time, cumulative movement
};

std::mutex g_mutex; // everything below except the pump state (main thread only)
std::deque<Sample> g_game;
double g_gameX = 0, g_gameY = 0;
std::vector<double> g_bursts, g_ages;

double g_lastPump = 0, g_burstStart = 0; // main thread
// METALFX_WARP_RECORD=<prefix>: the game's mouse events as the pump takes them, to <prefix>-events.csv (research).
FILE* g_record = [] {
    const char* prefix = std::getenv("METALFX_WARP_RECORD");
    return prefix && *prefix ? std::fopen((std::string(prefix) + "-events.csv").c_str(), "w") : nullptr;
}();

// Keeps eight seconds, and the sample before them (the movement up to the window's start).
void Push(double t, double x, double y) // caller holds g_mutex
{
    g_game.push_back({t, x, y});
    while (g_game.size() >= 2 && t - g_game[1].t > 8.0) {
        g_game.pop_front();
    }
}

double Median(std::vector<double> v)
{
    if (v.empty()) {
        return 0;
    }
    std::nth_element(v.begin(), v.begin() + v.size() / 2, v.end());
    return v[v.size() / 2];
}

using NextFn = NSEvent* (*)(id, SEL, NSEventMask, NSDate*, NSRunLoopMode, BOOL);
NextFn o_next = nullptr;

NSEvent* H_next(id self, SEL sel, NSEventMask mask, NSDate* until, NSRunLoopMode mode, BOOL dequeue)
{
    const double now = CACurrentMediaTime();
    if (now - g_lastPump > 0.004) { // the first pump of a burst: the game starts reading input for a frame
        std::lock_guard<std::mutex> lock(g_mutex);
        if (g_burstStart > 0 && g_bursts.size() < 100000) {
            g_bursts.push_back((now - g_burstStart) * 1000.0);
        }
        g_burstStart = now;
    }
    NSEvent* ev = o_next(self, sel, mask, until, mode, dequeue);
    const double after = CACurrentMediaTime();
    g_lastPump = after;
    if (ev && dequeue) {
        const NSEventType type = ev.type;
        if (type == NSEventTypeMouseMoved || type == NSEventTypeLeftMouseDragged ||
            type == NSEventTypeRightMouseDragged || type == NSEventTypeOtherMouseDragged) {
            std::lock_guard<std::mutex> lock(g_mutex);
            g_gameX += ev.deltaX;
            g_gameY += ev.deltaY;
            Push(after, g_gameX, g_gameY);
            if (g_ages.size() < 100000) {
                g_ages.push_back((after - ev.timestamp) * 1000.0);
            }
            if (g_record) {
                std::fprintf(g_record, "%.6f,%.6f,%.3f,%.3f\n", after, ev.timestamp, g_gameX, g_gameY);
                std::fflush(g_record);
            }
        }
    }
    return ev;
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
      Logger::Info(std::string("Input: event pump hook ") + (o_next ? "installed" : "unavailable") + " (app class " +
                   (NSApp ? class_getName([NSApp class]) : "none") + ")");
    });
}

bool GameCounts(double t, double& x, double& y)
{
    std::lock_guard<std::mutex> lock(g_mutex);
    if (g_game.empty() || t < g_game.front().t) {
        return false;
    }
    auto it = std::upper_bound(g_game.begin(), g_game.end(), t, [](double v, const Sample& s) { return v < s.t; });
    --it; // the last sample at or before t
    x = it->x;
    y = it->y;
    return true;
}

PumpStats TakePumpStats()
{
    std::lock_guard<std::mutex> lock(g_mutex);
    PumpStats s{Median(g_bursts), Median(g_ages), g_bursts.size()};
    g_bursts.clear();
    g_ages.clear();
    return s;
}

void InjectGame(double t, double dx, double dy)
{
    std::lock_guard<std::mutex> lock(g_mutex);
    g_gameX += dx;
    g_gameY += dy;
    Push(t, g_gameX, g_gameY);
}

} // namespace Input
