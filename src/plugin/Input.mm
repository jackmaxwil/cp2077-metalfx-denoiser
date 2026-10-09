#import "Input.hpp"

#import <AppKit/AppKit.h>
#import <GameController/GameController.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>

#include <algorithm>
#include <atomic>
#include <deque>
#include <mutex>
#include <vector>
#include <unistd.h>

#include "Logger.hpp"

namespace {

struct Sample {
    double t, x, y; // host time, cumulative movement
};

std::mutex g_mutex; // everything below except the pump state (main thread only)
std::deque<Sample> g_raw, g_game;
double g_rawX = 0, g_rawY = 0, g_gameX = 0, g_gameY = 0;
std::vector<double> g_bursts, g_ages;
std::atomic<double> g_delay{0};
dispatch_queue_t g_mouseQueue;

double g_lastPump = 0, g_burstStart = 0; // main thread

// Keeps eight seconds, and the sample before them (the movement up to the window's start).
void Push(std::deque<Sample>& q, double t, double x, double y)
{
    q.push_back({t, x, y});
    while (q.size() >= 2 && t - q[1].t > 8.0) {
        q.pop_front();
    }
}

bool At(const std::deque<Sample>& q, double t, double& x, double& y)
{
    if (q.empty() || t < q.front().t) {
        return false;
    }
    auto it = std::upper_bound(q.begin(), q.end(), t, [](double v, const Sample& s) { return v < s.t; });
    --it; // the last sample at or before t
    x = it->x;
    y = it->y;
    return true;
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
        if (const double d = g_delay.load(); d > 0) {
            usleep(static_cast<useconds_t>(d * 1e6));
        }
        std::lock_guard<std::mutex> lock(g_mutex);
        if (g_burstStart > 0) {
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
            Push(g_game, after, g_gameX, g_gameY);
            if (g_ages.size() < 100000) {
                g_ages.push_back((after - ev.timestamp) * 1000.0);
            }
        }
    }
    return ev;
}

std::atomic<bool> g_rawOn{false};

void Attach(GCMouse* mouse) // main thread
{
    if (!g_rawOn.load()) {
        mouse.mouseInput.mouseMovedHandler = nil;
        return;
    }
    mouse.handlerQueue = g_mouseQueue;
    mouse.mouseInput.mouseMovedHandler = ^(GCMouseInput*, float dx, float dy) {
      Input::InjectRaw(CACurrentMediaTime(), dx, dy);
    };
    Logger::Info(std::string("Input: GCMouse attached (") + (mouse.vendorName ? mouse.vendorName.UTF8String : "mouse") +
                 ")");
}

} // namespace

namespace Input {

void Start()
{
    static std::atomic<bool> started{false};
    if (started.exchange(true)) {
        return;
    }
    g_mouseQueue = dispatch_queue_create("metalfx.mouse",
                                         dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL,
                                                                                 QOS_CLASS_USER_INTERACTIVE, 0));
    dispatch_async(dispatch_get_main_queue(), ^{
      Method m = class_getInstanceMethod([NSApplication class],
                                         @selector(nextEventMatchingMask:untilDate:inMode:dequeue:));
      if (m) {
          o_next = reinterpret_cast<NextFn>(method_setImplementation(m, reinterpret_cast<IMP>(H_next)));
      }
      Logger::Info(std::string("Input: event pump hook ") + (o_next ? "installed" : "unavailable") + " (app class " +
                   (NSApp ? class_getName([NSApp class]) : "none") + ")");
      [[NSNotificationCenter defaultCenter] addObserverForName:GCMouseDidConnectNotification
                                                        object:nil
                                                         queue:[NSOperationQueue mainQueue]
                                                    usingBlock:^(NSNotification* note) {
                                                      Attach(note.object);
                                                    }];
    });
}

void SetRaw(bool on)
{
    if (g_rawOn.exchange(on) == on) {
        return;
    }
    dispatch_async(dispatch_get_main_queue(), ^{
      for (GCMouse* mouse in GCMouse.mice) {
          Attach(mouse);
      }
      if (!on) {
          Logger::Info("Input: GCMouse detached");
      }
    });
}

bool Counts(double t, double& x, double& y)
{
    std::lock_guard<std::mutex> lock(g_mutex);
    return At(g_raw, t, x, y);
}

bool GameCounts(double t, double& x, double& y)
{
    std::lock_guard<std::mutex> lock(g_mutex);
    return At(g_game, t, x, y);
}

void SetGameDelay(double seconds)
{
    seconds = std::clamp(seconds, 0.0, 0.05);
    if (g_delay.exchange(seconds) != seconds) {
        Logger::Info("Input: game-thread delay " + std::to_string(static_cast<int>(seconds * 1000 + 0.5)) + " ms");
    }
}

double GameDelay()
{
    return g_delay.load();
}

PumpStats TakePumpStats()
{
    std::lock_guard<std::mutex> lock(g_mutex);
    PumpStats s{Median(g_bursts), Median(g_ages), g_bursts.size()};
    g_bursts.clear();
    g_ages.clear();
    return s;
}

void InjectRaw(double t, double dx, double dy)
{
    std::lock_guard<std::mutex> lock(g_mutex);
    g_rawX += dx;
    g_rawY += dy;
    Push(g_raw, t, g_rawX, g_rawY);
}

} // namespace Input
