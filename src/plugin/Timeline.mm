#import "Timeline.hpp"

#import <Metal/Metal.h>
#import <QuartzCore/QuartzCore.h>

#include <algorithm>
#include <atomic>
#include <cstdio>
#include <fstream>
#include <map>
#include <mutex>
#include <string>
#include <vector>

#include "Logger.hpp"
#include "MetalTrace.hpp"

namespace {

struct Rec {
    double event = 0, read = 0, start = 0, present = 0;
    std::vector<std::pair<double, double>> game, plugin; // command buffer GPU intervals
    double shown[5] = {0, 0, 0, 0, 0};
};

std::mutex g_mutex;
std::map<uint64_t, Rec> g_recs;
std::atomic<int> g_want{0};          // frames still to start recording
uint64_t g_first = 0, g_last = 0;    // the frames being recorded [first, last]
std::atomic<bool> g_on{false};
int g_index = 0;

// Union length and [first start, last end] of intervals.
void Span(std::vector<std::pair<double, double>> iv, double& busy, double& first, double& last)
{
    busy = first = last = 0;
    if (iv.empty()) {
        return;
    }
    std::sort(iv.begin(), iv.end());
    first = iv[0].first;
    double s = iv[0].first, e = iv[0].second;
    for (const auto& [a, b] : iv) {
        if (a > e) {
            busy += e - s;
            s = a;
        }
        e = std::max(e, b);
        last = std::max(last, b);
    }
    busy += e - s;
}

double Median(std::vector<double> v)
{
    if (v.empty()) {
        return 0;
    }
    std::sort(v.begin(), v.end());
    return v[v.size() / 2];
}

void Write()
{
    std::map<uint64_t, Rec> recs;
    {
        std::lock_guard<std::mutex> lock(g_mutex);
        recs.swap(g_recs);
        g_on.store(false);
    }
    const std::string path = MetalTrace::TraceDir() + "/timeline-" + std::to_string(g_index++) + ".jsonl";
    std::ofstream f(path);
    std::vector<double> toRead, cpu, queue, gpu, gpuBusy, toReal, total, plugin;
    char buf[1024];
    for (const auto& [frame, r] : recs) {
        double gb, gs, ge, pb, ps, pe;
        Span(r.game, gb, gs, ge);
        Span(r.plugin, pb, ps, pe);
        std::snprintf(buf, sizeof(buf),
                      "{\"frame\":%llu,\"event\":%.6f,\"read\":%.6f,\"start\":%.6f,\"present\":%.6f,"
                      "\"game_gpu\":[%.6f,%.6f,%.6f],\"plugin_gpu\":[%.6f,%.6f,%.6f],\"game_cbs\":%zu,\"plugin_cbs\":%zu,"
                      "\"shown\":[%.6f,%.6f,%.6f,%.6f]}\n",
                      (unsigned long long)frame, r.event, r.read, r.start, r.present, gs, ge, gb, ps, pe, pb,
                      r.game.size(), r.plugin.size(), r.shown[1], r.shown[2], r.shown[3], r.shown[4]);
        f << buf;
        if (r.event > 0 && r.read > 0) {
            toRead.push_back((r.read - r.event) * 1000);
        }
        if (r.start > 0 && r.present > r.start) {
            cpu.push_back((r.present - r.start) * 1000);
        }
        if (gs > 0 && r.present > 0) {
            queue.push_back((gs - r.present) * 1000);
            gpu.push_back((ge - gs) * 1000);
            gpuBusy.push_back(gb * 1000);
        }
        if (pb > 0) {
            plugin.push_back(pb * 1000);
        }
        if (r.shown[4] > 0 && ge > 0) {
            toReal.push_back((r.shown[4] - ge) * 1000);
        }
        if (r.shown[4] > 0 && r.event > 0) {
            total.push_back((r.shown[4] - r.event) * 1000);
        }
    }
    std::snprintf(buf, sizeof(buf),
                  "Timeline: %zu frames (%s), medians ms: mouse to read %.1f, frame start to present call %.1f, present "
                  "call to game GPU start %.1f, game GPU start to end %.1f (busy %.1f), game GPU end to its frame shown "
                  "%.1f; plugin GPU busy %.1f; mouse to game frame shown %.1f",
                  recs.size(), path.c_str(), Median(toRead), Median(cpu), Median(queue), Median(gpu), Median(gpuBusy),
                  Median(toReal), Median(plugin), Median(total));
    Logger::Info(buf);
}

} // namespace

namespace Timeline {

void Arm(int frames)
{
    std::lock_guard<std::mutex> lock(g_mutex);
    g_recs.clear();
    g_want.store(std::clamp(frames, 0, 3600));
    g_on.store(false);
}

bool Armed()
{
    return g_on.load(std::memory_order_relaxed) || g_want.load(std::memory_order_relaxed) > 0;
}

void OnGamePresent(uint64_t frame, double event, double read, double start, double presentCall)
{
    if (!Armed()) {
        return;
    }
    std::lock_guard<std::mutex> lock(g_mutex);
    if (const int n = g_want.exchange(0); n > 0) {
        g_first = frame + 1; // whole frames: from the next one (its command buffers are all still to come)
        g_last = frame + n;
        g_on.store(true);
        return;
    }
    if (frame < g_first || frame > g_last) {
        return;
    }
    Rec& r = g_recs[frame];
    r.event = event;
    r.read = read;
    r.start = start;
    r.present = presentCall;
    if (frame == g_last) { // let the last frames' command buffers and presents complete
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC),
                       dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
                         Write();
                       });
    }
}

void OnCommit(void* commandBuffer, uint64_t frame, bool plugin)
{
    if (!g_on.load(std::memory_order_relaxed) || frame < g_first || frame > g_last) {
        return;
    }
    id<MTLCommandBuffer> cb = (__bridge id<MTLCommandBuffer>)commandBuffer;
    [cb addCompletedHandler:^(id<MTLCommandBuffer> done) {
      const double s = done.GPUStartTime, e = done.GPUEndTime;
      if (e > s) {
          std::lock_guard<std::mutex> lock(g_mutex);
          (plugin ? g_recs[frame].plugin : g_recs[frame].game).emplace_back(s, e);
      }
    }];
}

void OnShown(uint64_t frame, int index, double shownAt)
{
    if (index < 1 || index > 4 || shownAt <= 0 || !g_on.load(std::memory_order_relaxed) || frame < g_first ||
        frame > g_last) {
        return;
    }
    std::lock_guard<std::mutex> lock(g_mutex);
    g_recs[frame].shown[index] = shownAt;
}

} // namespace Timeline
