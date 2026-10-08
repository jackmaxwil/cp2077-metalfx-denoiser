// Native Metal tracing for the game's renderer (opt-in: [debug] trace_metal_compute or METALFX_TRACE=1).
//
// - Names every pipeline: the device's pipeline creation methods are swizzled and each new pipeline state is mapped
//   to its function name(s). Compute pipelines are created with binding reflection, which gives each texture and
//   buffer slot its shader-side name and access (read, write).
// - Frame trace: on request, every command buffer, encoder, dispatch (kernel, grid, bound textures), acceleration
//   structure build and MetalFX scaler call of one frame is written as JSON lines.
// - Frame timing: on request, GPU time of N frames (union of the frame's command buffer GPU intervals) and the
//   present-to-present time.
//
// - GPU capture: on request, one frame as an Xcode .gputrace document (needs MTL_CAPTURE_ENABLED=1 in the game's
//   environment), for per-pass timing and resource views in Xcode.
//
// - Skip test, to measure what work costs (the image is wrong while skipping): "skip listed" drops every compute
//   dispatch of the pipelines whose shader library fingerprint is in <plugin dir>/skip-fingerprints.txt
//   (scripts/skip_list.py, for example NRD's passes); "skip refit" drops acceleration structure refits (the structures
//   go stale; builds are never dropped); "skip raygen" drops the ray generation kernels (function names rgs_*);
//   "skip metalfx" drops the MetalFX temporal scaler's encode; "skip off".
//
// - Startup settings: <plugin dir>/cvar-startup.txt ("<group>/<name>=<value>" per line) is applied at the first frame
//   (tracing runs only; tools/rtbench writes it for RTBENCH_CVARS and deletes it afterwards).
//
// Requests are files in <plugin dir>/trace/: "req-*" containing "trace <name>", "perf <name> <frames>",
// "capture <name>", "dump <name> [pipelines]" (trace plus PNGs of render targets and chosen dispatches' textures, see s_dump), "skip listed|refit|raygen|metalfx|off", "denoise off|pass|fx" (Denoise.mm), "cvar <group>/<name>[=<value>]" (engine config
// variables, ConfigVars.cpp; results appended to cvar.jsonl) or "cvarbatch" (experiments from cvar-experiments.txt,
// see StartBatch). Results are written next to them: <name>.trace.jsonl, <name>.perf.json, <name>.gputrace.
// tools/cp-run writes the requests for scenario scripts.
//
// Built without ARC: hooks receive their arguments unretained, as the original methods do.

#include "MetalTrace.hpp"
#include "ConfigVars.hpp"
#include "Denoise.hpp"
#include "Logger.hpp"

#import <Metal/Metal.h>
#import <MetalFX/MetalFX.h>
#import <QuartzCore/CAMetalLayer.h>
#import <ImageIO/ImageIO.h>
#import <objc/message.h>
#import <objc/runtime.h>

#include <dirent.h>
#include <dlfcn.h>
#include <pthread.h>
#include <sys/stat.h>
#include <unistd.h>

#include <algorithm>
#include <cstdlib>
#include <atomic>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <fstream>
#include <memory>
#include <mutex>
#include <shared_mutex>
#include <string>
#include <unordered_map>
#include <unordered_set>
#include <vector>

namespace {

// --- swizzling ---------------------------------------------------------------------------------------------------
// One table per selector: the same selector is hooked on several classes (each encoder class, for example), and each
// keeps its own original implementation.
struct Orig {
    std::atomic<int> n{0};
    Class cls[8]{};
    IMP imp[8]{};
};

IMP Find(Orig& o, id self)
{
    const int n = o.n.load(std::memory_order_acquire);
    for (Class c = object_getClass(self); c; c = class_getSuperclass(c)) {
        for (int i = 0; i < n; ++i) {
            if (o.cls[i] == c) {
                return o.imp[i];
            }
        }
    }
    return o.imp[0];
}

std::mutex s_hookMutex;
std::vector<std::pair<Method, IMP>> s_installed;

bool Hook(Class cls, SEL sel, IMP repl, Orig& o)
{
    if (!cls) {
        return false;
    }
    std::lock_guard<std::mutex> lock(s_hookMutex);
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) {
        return false;
    }
    IMP imp = method_getImplementation(m);
    if (imp == repl) {
        return true; // inherited from a class already hooked
    }
    const int n = o.n.load(std::memory_order_relaxed);
    if (n >= 8) {
        Logger::Warn(std::string("Metal trace: too many classes for ") + sel_getName(sel));
        return false;
    }
    // Add the method to the concrete class when it is inherited, so a superclass shared with other classes (and
    // other hooks) is never modified.
    if (class_addMethod(cls, sel, imp, method_getTypeEncoding(m))) {
        m = class_getInstanceMethod(cls, sel);
    }
    o.cls[n] = cls;
    o.imp[n] = imp;
    o.n.store(n + 1, std::memory_order_release);
    method_setImplementation(m, repl);
    s_installed.emplace_back(m, imp);
    return true;
}

#define ORIG(o, Fn, self) reinterpret_cast<Fn>(Find(o, self))

// --- JSON helpers ------------------------------------------------------------------------------------------------
std::string Q(const char* s)
{
    std::string out = "\"";
    for (; s && *s; ++s) {
        const unsigned char c = static_cast<unsigned char>(*s);
        if (c == '"' || c == '\\') {
            out += '\\';
            out += static_cast<char>(c);
        } else if (c < 0x20) {
            char buf[8];
            std::snprintf(buf, sizeof(buf), "\\u%04x", c);
            out += buf;
        } else {
            out += static_cast<char>(c);
        }
    }
    return out + "\"";
}

std::string Q(NSString* s)
{
    return Q(s ? s.UTF8String : "");
}

std::string P(const void* p)
{
    char buf[24];
    std::snprintf(buf, sizeof(buf), "\"%llx\"", static_cast<unsigned long long>(reinterpret_cast<uintptr_t>(p)));
    return buf;
}

const char* FormatName(NSUInteger f)
{
    switch (f) {
    case 10: return "R8Unorm";
    case 13: return "R8Uint";
    case 20: return "R16Unorm";
    case 23: return "R16Uint";
    case 25: return "R16Float";
    case 30: return "RG8Unorm";
    case 53: return "R32Uint";
    case 55: return "R32Float";
    case 60: return "RG16Unorm";
    case 62: return "RG16Snorm";
    case 63: return "RG16Uint";
    case 65: return "RG16Float";
    case 70: return "RGBA8Unorm";
    case 71: return "RGBA8Unorm_sRGB";
    case 73: return "RGBA8Uint";
    case 80: return "BGRA8Unorm";
    case 81: return "BGRA8Unorm_sRGB";
    case 90: return "RGB10A2Unorm";
    case 92: return "RG11B10Float";
    case 94: return "BGR10A2Unorm";
    case 93: return "RGB9E5Float";
    case 103: return "RG32Uint";
    case 105: return "RG32Float";
    case 110: return "RGBA16Unorm";
    case 113: return "RGBA16Uint";
    case 115: return "RGBA16Float";
    case 123: return "RGBA32Uint";
    case 125: return "RGBA32Float";
    case 250: return "Depth16Unorm";
    case 252: return "Depth32Float";
    case 253: return "Stencil8";
    case 260: return "Depth32Float_Stencil8";
    case 261: return "X32_Stencil8";
    default: return nullptr;
    }
}

// --- pipeline names ----------------------------------------------------------------------------------------------
struct Pipe {
    char kind = 'c'; // c compute, r render, m mesh, t tile
    std::string name;
    std::string label;
    std::string lib; // fingerprints of the shader libraries the functions came from (see LibraryOf)
    std::string bindings; // JSON array of [type, index, name, access]; compute only
};

std::shared_mutex s_pipesMutex;
std::unordered_map<const void*, Pipe> s_pipes;
std::atomic<uint64_t> s_pipesNamed{0};
bool s_reflection = true;

// Shader libraries: each library the game creates from data is fingerprinted (size and FNV-1a 64 of its first
// 4 KiB), and each function made from a library is mapped to it. scripts/shader_index.py computes the same
// fingerprint for every library in the game's shader caches, which names the static shaders (NRD, ray tracing, ...).
std::shared_mutex s_libMutex;
std::unordered_map<const void*, std::string> s_libFp; // library -> fingerprint
std::unordered_map<const void*, std::string> s_fnLib; // function -> fingerprint
std::atomic<uint64_t> s_libCount{0};

std::string Fingerprint(dispatch_data_t data)
{
    const size_t size = dispatch_data_get_size(data);
    __block uint64_t hash = 0xcbf29ce484222325ull;
    __block size_t left = std::min<size_t>(size, 4096);
    dispatch_data_apply(data, ^bool(dispatch_data_t, size_t, const void* buffer, size_t length) {
      const auto* bytes = static_cast<const uint8_t*>(buffer);
      for (size_t i = 0; i < length && left; ++i, --left) {
          hash = (hash ^ bytes[i]) * 0x100000001b3ull;
      }
      return left > 0;
    });
    char buf[48];
    std::snprintf(buf, sizeof(buf), "%zu:%016llx", size, static_cast<unsigned long long>(hash));
    return buf;
}

std::string LibraryOf(id fn)
{
    if (!fn) {
        return {};
    }
    std::shared_lock<std::shared_mutex> lock(s_libMutex);
    auto it = s_fnLib.find((__bridge const void*)fn);
    return it == s_fnLib.end() ? std::string() : it->second;
}

void NoteFunction(id fn, id library)
{
    if (!fn) {
        return;
    }
    std::unique_lock<std::shared_mutex> lock(s_libMutex);
    auto it = s_libFp.find((__bridge const void*)library);
    if (it != s_libFp.end()) {
        s_fnLib[(__bridge const void*)fn] = it->second;
    }
}

std::string BindingsJson(MTLComputePipelineReflection* refl)
{
    if (!refl) {
        return {};
    }
    std::string out = "[";
    for (id<MTLBinding> b in refl.bindings) {
        const char* type = "other";
        switch (b.type) {
        case MTLBindingTypeBuffer: type = "buf"; break;
        case MTLBindingTypeTexture: type = "tex"; break;
        case MTLBindingTypeSampler: type = "smp"; break;
        case MTLBindingTypeThreadgroupMemory: type = "tgm"; break;
        case MTLBindingTypeInstanceAccelerationStructure: type = "ias"; break;
        case MTLBindingTypePrimitiveAccelerationStructure: type = "pas"; break;
        case MTLBindingTypeIntersectionFunctionTable: type = "ift"; break;
        case MTLBindingTypeVisibleFunctionTable: type = "vft"; break;
        default: break;
        }
        const char* access = b.access == MTLBindingAccessReadOnly ? "r" : b.access == MTLBindingAccessWriteOnly ? "w" : "rw";
        if (out.size() > 1) {
            out += ',';
        }
        out += "[\"" + std::string(type) + "\"," + std::to_string(b.index) + "," + Q(b.name) + ",\"" + access + "\"," +
               (b.used ? "1" : "0") + "]";
    }
    return out + "]";
}

void RecordPipe(id pso, char kind, std::string name, NSString* label, MTLComputePipelineReflection* refl,
                std::string lib = {})
{
    if (!pso) {
        return;
    }
    Pipe p;
    p.kind = kind;
    p.name = std::move(name);
    p.lib = std::move(lib);
    p.label = label ? label.UTF8String : "";
    p.bindings = BindingsJson(refl);
    std::unique_lock<std::shared_mutex> lock(s_pipesMutex);
    auto& slot = s_pipes[(__bridge const void*)pso];
    // A nested creation call (one variant implemented through another) reports the same pipeline again; keep the
    // entry that has bindings.
    if (slot.name.empty() || slot.bindings.empty()) {
        if (slot.name.empty()) {
            s_pipesNamed.fetch_add(1, std::memory_order_relaxed);
        }
        slot = std::move(p);
    }
}

std::string FunctionName(id<MTLFunction> f)
{
    return f ? std::string(f.name.UTF8String) : std::string();
}

std::string RenderLibs(id desc)
{
    std::string out;
    for (const char* selName : {"objectFunction", "meshFunction", "vertexFunction", "fragmentFunction", "tileFunction"}) {
        SEL sel = sel_registerName(selName);
        if ([desc respondsToSelector:sel]) {
            std::string lib = LibraryOf(((id(*)(id, SEL))objc_msgSend)(desc, sel));
            if (!lib.empty()) {
                out += (out.empty() ? "" : "|") + lib;
            }
        }
    }
    return out;
}

std::string RenderName(id desc)
{
    std::string out;
    for (const char* selName : {"objectFunction", "meshFunction", "vertexFunction", "fragmentFunction", "tileFunction"}) {
        SEL sel = sel_registerName(selName);
        if ([desc respondsToSelector:sel]) {
            id<MTLFunction> f = ((id(*)(id, SEL))objc_msgSend)(desc, sel);
            if (f) {
                if (!out.empty()) {
                    out += '|';
                }
                out += FunctionName(f);
            }
        }
    }
    return out;
}

// --- capture state -----------------------------------------------------------------------------------------------
struct Enc {
    const void* cb = nullptr;
    char kind = '?';
    const void* pso = nullptr;
    std::unordered_map<uint32_t, const void*> tex;
    std::vector<std::string> groups;
    bool as = false;
    bool ift = false;
    uint32_t psoSets = 0;
    id cbObject = nil;               // dump frames only
    std::vector<id> renderTargets;   // dump frames only
    std::vector<std::pair<id, NSUInteger>> uses;          // dump frames: textures declared since the last dispatch
    std::vector<std::pair<id, std::string>> dispatchTex;  // dump frames: textures of dumped dispatches, written at end
};

std::atomic<bool> s_capture{false};
// Dump: during a traced frame, the targets of render passes with two or more color targets and the MetalFX scaler's
// inputs are copied to buffers on the game's command buffer and written as PNGs (<name>-<n>-<what>-<w>x<h>-<format>.png;
// a second "-alpha" PNG for formats with alpha). Request "dump <name>". A target is written after every pass that
// renders to it (the first pass to use the G-buffer targets only clears them), up to kMaxDumps textures per frame.
std::atomic<bool> s_dump{false};
bool s_dumpRequested = false;
int s_dumpCount = 0;
constexpr int kMaxDumps = 256;
// "dump <name> <a,b,...>" (or the list in <plugin dir>/dump-pipes.txt): also the textures each dispatch of these
// pipelines declares (useResource), by pipeline label or function name, written when its encoder ends (inputs as they were unless the same encoder overwrites them later;
// outputs as the encoder left them). Named <label>-r|w|rw.
std::unordered_set<std::string> s_dumpPipes;
std::mutex s_capMutex;
std::vector<std::string> s_lines;
std::unordered_map<const void*, Enc> s_enc;
std::unordered_map<const void*, std::vector<std::string>> s_cbGroups;
std::unordered_set<const void*> s_capTex;
std::unordered_set<const void*> s_capPipes;
uint64_t s_seq = 0;

std::string TexJson(id<MTLTexture> t)
{
    std::string out = "{\"e\":\"tex\",\"id\":" + P((__bridge const void*)t) + ",\"w\":" + std::to_string(t.width) +
                      ",\"h\":" + std::to_string(t.height) + ",\"d\":" + std::to_string(t.depth);
    const char* fmt = FormatName(t.pixelFormat);
    out += ",\"fmt\":" + (fmt ? Q(fmt) : std::to_string(t.pixelFormat));
    out += ",\"type\":" + std::to_string(t.textureType) + ",\"mips\":" + std::to_string(t.mipmapLevelCount) +
           ",\"arr\":" + std::to_string(t.arrayLength) + ",\"usage\":" + std::to_string(t.usage) +
           ",\"storage\":" + std::to_string(t.storageMode);
    if (t.parentTexture) {
        out += ",\"parent\":" + P((__bridge const void*)t.parentTexture);
    }
    if (t.label) {
        out += ",\"label\":" + Q(t.label);
    }
    return out + "}";
}

// Caller holds s_capMutex.
void NoteTexture(id<MTLTexture> t)
{
    if (t && s_capTex.insert((__bridge const void*)t).second) {
        if (t.parentTexture) {
            NoteTexture(t.parentTexture);
        }
        s_lines.push_back(TexJson(t));
    }
}

// Caller holds s_capMutex.
Enc& EncOf(id enc)
{
    return s_enc[(__bridge const void*)enc];
}

void Emit(std::string line)
{
    s_lines.push_back(std::move(line));
}

std::string SeqField()
{
    char buf[64];
    std::snprintf(buf, sizeof(buf), "\"seq\":%llu,\"th\":%llu", static_cast<unsigned long long>(++s_seq),
                  static_cast<unsigned long long>(pthread_mach_thread_np(pthread_self())));
    return buf;
}

std::string Groups(const std::vector<std::string>& g)
{
    std::string out;
    for (const auto& s : g) {
        if (!out.empty()) {
            out += '/';
        }
        out += s;
    }
    return out;
}

// --- requests and output -----------------------------------------------------------------------------------------
std::string s_dir;
enum class TraceState { Idle, Armed, Capturing, GpuArmed, GpuCapturing };
std::atomic<TraceState> s_traceState{TraceState::Idle};
std::string s_traceName;
std::string s_dumpName;
std::atomic<uint64_t> s_frame{0};
std::atomic<bool> s_sawCbPresent{false};

struct Perf {
    std::string name;
    uint64_t skippedAtStart = 0;
    uint64_t start = 0;
    uint64_t frames = 0;
    std::vector<double> present; // CPU time of each present in the window
    std::vector<std::vector<std::pair<double, double>>> gpu; // per frame: command buffer GPU intervals
};
std::atomic<bool> s_perfActive{false};
// The window being recorded. Each window has its own buffer: command buffers of its last frames complete after the
// window ends, while the next window may already be recording.
std::shared_ptr<struct Perf> s_perfCur;

// Skip test state: the pipelines to drop, and per thread the encoder and whether its bound pipeline is dropped.
std::atomic<bool> s_skip{false};        // listed pipelines
std::atomic<bool> s_skipRefit{false};
std::atomic<bool> s_skipMetalFX{false};
std::shared_mutex s_skipMutex;
std::unordered_set<const void*> s_skipPipes;
std::atomic<uint64_t> s_skipped{0};
thread_local const void* t_enc = nullptr;
thread_local bool t_drop = false;
std::mutex s_perfMutex;

double Now()
{
    return CACurrentMediaTime();
}

void WriteFile(const std::string& path, const std::string& body)
{
    std::ofstream f(path, std::ios::out | std::ios::trunc);
    f << body;
}

double Percentile(std::vector<double> v, double p)
{
    if (v.empty()) {
        return 0;
    }
    std::sort(v.begin(), v.end());
    const size_t i = std::min(v.size() - 1, static_cast<size_t>(p * static_cast<double>(v.size() - 1) + 0.5));
    return v[i];
}

std::string Stats(const std::vector<double>& v)
{
    double sum = 0;
    for (double x : v) {
        sum += x;
    }
    char buf[160];
    std::snprintf(buf, sizeof(buf), "{\"median\":%.3f,\"p99\":%.3f,\"mean\":%.3f,\"n\":%zu}", Percentile(v, 0.5),
                  Percentile(v, 0.99), v.empty() ? 0.0 : sum / static_cast<double>(v.size()), v.size());
    return buf;
}

std::string List(const std::vector<double>& v)
{
    std::string out = "[";
    char buf[32];
    for (size_t i = 0; i < v.size(); ++i) {
        std::snprintf(buf, sizeof(buf), i ? ",%.3f" : "%.3f", v[i]);
        out += buf;
    }
    return out + "]";
}

void WritePerf(std::shared_ptr<Perf> window)
{
    Perf p;
    {
        std::lock_guard<std::mutex> lock(s_perfMutex);
        p = std::move(*window);
    }
    std::vector<double> cpu, busy, span, count;
    for (size_t i = 1; i < p.present.size(); ++i) {
        cpu.push_back((p.present[i] - p.present[i - 1]) * 1000.0);
    }
    for (auto& iv : p.gpu) {
        if (iv.empty()) {
            continue;
        }
        std::sort(iv.begin(), iv.end());
        double total = 0, curS = iv[0].first, curE = iv[0].second;
        for (size_t i = 1; i < iv.size(); ++i) {
            if (iv[i].first > curE) {
                total += curE - curS;
                curS = iv[i].first;
                curE = iv[i].second;
            } else {
                curE = std::max(curE, iv[i].second);
            }
        }
        total += curE - curS;
        double maxE = 0;
        for (auto& x : iv) {
            maxE = std::max(maxE, x.second);
        }
        busy.push_back(total * 1000.0);
        span.push_back((maxE - iv[0].first) * 1000.0);
        count.push_back(static_cast<double>(iv.size()));
    }
    const double skipped = static_cast<double>(s_skipped.load() - p.skippedAtStart) / std::max<double>(1, p.frames);
    char skipBuf[64];
    std::snprintf(skipBuf, sizeof(skipBuf), ",\"skipped_per_frame\":%.1f", skipped);
    std::string body = "{\"name\":" + Q(p.name.c_str()) + ",\"frames\":" + std::to_string(p.frames) + skipBuf +
                       ",\"gpu_ms\":" + Stats(busy) + ",\"gpu_span_ms\":" + Stats(span) + ",\"cpu_frame_ms\":" +
                       Stats(cpu) + ",\"cmdbufs_per_frame\":" + Stats(count) + ",\"gpu_ms_list\":" + List(busy) +
                       ",\"cpu_frame_ms_list\":" + List(cpu) + "}\n";
    WriteFile(s_dir + "/" + p.name + ".perf.json", body);
    Logger::Info("Metal trace: wrote " + p.name + ".perf.json (" + std::to_string(busy.size()) + " frames)");
}

// Skips the listed fingerprints, or with raygen the ray generation kernels.
void SetSkip(bool on, bool raygen = false)
{
    if (!on) {
        s_skip.store(false);
        Logger::Info("Metal trace: skip off");
        return;
    }
    std::unordered_set<std::string> fps;
    std::ifstream list(s_dir.substr(0, s_dir.find_last_of('/')) + "/skip-fingerprints.txt");
    for (std::string line; std::getline(list, line);) {
        if (!line.empty()) {
            fps.insert(line);
        }
    }
    std::unordered_set<const void*> pipes;
    {
        std::shared_lock<std::shared_mutex> lock(s_pipesMutex);
        for (const auto& [pso, pipe] : s_pipes) {
            const auto last = pipe.lib.substr(pipe.lib.find_last_of('|') + 1);
            if (pipe.kind == 'c' && (raygen ? pipe.name.rfind("rgs_", 0) == 0 : fps.count(last) != 0)) {
                pipes.insert(pso);
            }
        }
    }
    {
        std::unique_lock<std::shared_mutex> lock(s_skipMutex);
        s_skipPipes.swap(pipes);
    }
    s_skip.store(true);
    Logger::Info("Metal trace: skip on, " + std::to_string(s_skipPipes.size()) + " pipelines from " +
                 std::to_string(fps.size()) + " fingerprints");
}

void StartPerf(const std::string& name, uint64_t frames, uint64_t frame)
{
    auto window = std::make_shared<Perf>();
    window->name = name;
    window->frames = frames;
    window->start = frame + 1;
    window->skippedAtStart = s_skipped.load();
    window->gpu.resize(frames);
    std::lock_guard<std::mutex> lock(s_perfMutex);
    s_perfCur = window;
    s_perfActive.store(true);
}

// --- config variable batch -----------------------------------------------------------------------------------------
// "cvarbatch": runs the experiments in <plugin dir>/cvar-experiments.txt ("<group>/<name>=<value>" per line, # comments;
// a trailing " trace" also records frame traces "cvar<i>-exp" and "cvar<i>-base")
// at the current spot. Per experiment: set, settle, screenshot, timing ("cvar<i>-exp"), restore the value read before,
// settle, screenshot, timing ("cvar<i>-base"); one timing before the first ("cvar-pre"). Screenshots and the end of
// the batch are requested from tools/cp-run by appending SHOT / CHECK / DONE events to red4ext/logs/autotest.log.
struct Batch {
    std::vector<std::string> lines;
    std::vector<bool> trace;
    size_t index = 0;
    int phase = -1;
    uint64_t waitUntil = 0;
    std::string restore;
    bool active = false;
};
Batch s_batch;
constexpr uint64_t kSettleFrames = 90, kShotFrames = 120, kBatchPerfFrames = 180;

void AutotestEvent(const std::string& json)
{
    const std::string plugin = s_dir.substr(0, s_dir.find_last_of('/'));
    const std::string logs = plugin.substr(0, plugin.find_last_of('/'));
    std::ofstream(logs.substr(0, logs.find_last_of('/')) + "/logs/autotest.log", std::ios::app) << json << '\n';
}

void StartBatch(uint64_t frame)
{
    s_batch = {};
    std::ifstream f(s_dir.substr(0, s_dir.find_last_of('/')) + "/cvar-experiments.txt");
    for (std::string line; std::getline(f, line);) {
        if (!line.empty() && line[0] != '#' && line.find('=') != std::string::npos) {
            const bool trace = line.size() > 6 && line.compare(line.size() - 6, 6, " trace") == 0;
            s_batch.lines.push_back(trace ? line.substr(0, line.size() - 6) : line);
            s_batch.trace.push_back(trace);
        }
    }
    s_batch.active = !s_batch.lines.empty();
    s_batch.waitUntil = frame;
    Logger::Info("Config var batch: " + std::to_string(s_batch.lines.size()) + " experiments");
}

std::string ValueOf(const std::string& json)
{
    const auto key = json.find("\"after\":\"");
    if (key == std::string::npos) {
        return {};
    }
    const auto start = key + 9;
    return json.substr(start, json.find('"', start) - start);
}

void StepBatch(uint64_t frame)
{
    Batch& b = s_batch;
    if (!b.active || frame < b.waitUntil || s_perfActive.load() || s_traceState.load() != TraceState::Idle) {
        return;
    }
    const std::string tag = "cvar" + std::to_string(b.index);
    const std::string path = b.index < b.lines.size() ? b.lines[b.index].substr(0, b.lines[b.index].find('=')) : "";
    auto log = [](const std::string& line) { std::ofstream(s_dir + "/cvar.jsonl", std::ios::app) << line << '\n'; };
    switch (b.phase) {
    case -1:
        StartPerf("cvar-pre", kBatchPerfFrames, frame);
        b.phase = 0;
        return;
    case 0: {
        if (b.index >= b.lines.size()) {
            AutotestEvent("{\"event\":\"CHECK\",\"name\":\"cvarbatch_done\",\"pass\":true,\"detail\":\"" +
                          std::to_string(b.lines.size()) + " experiments\"}");
            AutotestEvent("{\"event\":\"DONE\"}");
            b.active = false;
            return;
        }
        const std::string current = ConfigVars::Apply(path); // read only: the value to restore
        b.restore = ValueOf(current);
        const std::string result = ConfigVars::Apply(b.lines[b.index]);
        log(result);
        if (b.restore.empty() || result.find("\"error\"") != std::string::npos) {
            ++b.index; // refused (not verified, checks failed): nothing was changed
            return;
        }
        b.waitUntil = frame + kSettleFrames;
        b.phase = 1;
        return;
    }
    case 1:
        AutotestEvent("{\"event\":\"SHOT\",\"name\":\"" + tag + "-exp\"}");
        b.waitUntil = frame + kShotFrames;
        b.phase = 2;
        return;
    case 2:
        StartPerf(tag + "-exp", kBatchPerfFrames, frame);
        b.phase = 3;
        return;
    case 3:
        if (b.trace[b.index]) {
            s_traceName = tag + "-exp";
            s_traceState.store(TraceState::Armed);
        }
        b.phase = 7;
        return;
    case 7:
        log(ConfigVars::Apply(path + "=" + b.restore));
        b.waitUntil = frame + kSettleFrames;
        b.phase = 4;
        return;
    case 4:
        AutotestEvent("{\"event\":\"SHOT\",\"name\":\"" + tag + "-base\"}");
        b.waitUntil = frame + kShotFrames;
        b.phase = 5;
        return;
    case 5:
        StartPerf(tag + "-base", kBatchPerfFrames, frame);
        b.phase = 6;
        return;
    default:
        if (b.trace[b.index]) {
            s_traceName = tag + "-base";
            s_traceState.store(TraceState::Armed);
        }
        ++b.index;
        b.phase = 0;
        return;
    }
}

void PollRequests(uint64_t frame)
{
    DIR* d = opendir(s_dir.c_str());
    if (!d) {
        return;
    }
    std::vector<std::string> reqs;
    while (dirent* e = readdir(d)) {
        if (std::strncmp(e->d_name, "req-", 4) == 0) {
            reqs.emplace_back(e->d_name);
        }
    }
    closedir(d);
    if (reqs.empty()) {
        return;
    }
    std::sort(reqs.begin(), reqs.end());
    const std::string path = s_dir + "/" + reqs[0];
    std::ifstream f(path);
    std::string kind, name, extra;
    f >> kind >> name >> extra;
    const uint64_t frames = std::strtoull(extra.c_str(), nullptr, 10);
    unlink(path.c_str());
    if (kind == "trace" && !name.empty()) {
        s_traceName = name;
        s_traceState.store(TraceState::Armed);
    } else if (kind == "cvar" && !name.empty()) {
        std::ofstream(s_dir + "/cvar.jsonl", std::ios::app) << ConfigVars::Apply(name) << '\n';
    } else if (kind == "skip") {
        SetSkip(name == "listed" || name == "raygen", name == "raygen");
        s_skipRefit.store(name == "refit");
        s_skipMetalFX.store(name == "metalfx");
        if (name == "refit" || name == "metalfx") {
            Logger::Info("Metal trace: skip " + name);
        }
    } else if (kind == "capture" && !name.empty()) {
        s_traceName = name;
        s_traceState.store(TraceState::GpuArmed);
    } else if (kind == "perf" && !name.empty()) {
        StartPerf(name, frames ? frames : 240, frame);
    } else if (kind == "dump" && !name.empty()) {
        s_traceName = name;
        s_dumpName = name;
        s_dumpRequested = true;
        s_dumpPipes.clear();
        if (frames || extra.empty() || extra == "0") { // tools/cp-run passes a frame count: use dump-pipes.txt
            std::ifstream list(s_dir.substr(0, s_dir.find_last_of('/')) + "/dump-pipes.txt");
            std::getline(list, extra, '\0');
        }
        for (char& c : extra) {
            c = (c == '\n' || c == ' ') ? ',' : c;
        }
        for (size_t at = 0; at < extra.size();) {
            const size_t comma = std::min(extra.find(',', at), extra.size());
            if (comma > at) {
                s_dumpPipes.insert(extra.substr(at, comma - at));
            }
            at = comma + 1;
        }
        s_traceState.store(TraceState::Armed);
    } else if (kind == "denoise") {
        if (!Denoise::SetMode(name)) {
            Logger::Warn("Metal trace: unknown denoise mode " + name);
        }
    } else if (kind == "cvarbatch") {
        StartBatch(frame);
    } else {
        Logger::Warn("Metal trace: unknown request " + reqs[0]);
    }
}

void StopCapture()
{
    std::vector<std::string> lines;
    {
        std::lock_guard<std::mutex> lock(s_capMutex);
        std::shared_lock<std::shared_mutex> pipes(s_pipesMutex);
        for (const void* pso : s_capPipes) {
            auto it = s_pipes.find(pso);
            std::string line = "{\"e\":\"pipe\",\"id\":" + P(pso);
            if (it != s_pipes.end()) {
                line += ",\"kind\":\"" + std::string(1, it->second.kind) + "\",\"name\":" + Q(it->second.name.c_str());
                if (!it->second.label.empty()) {
                    line += ",\"label\":" + Q(it->second.label.c_str());
                }
                if (!it->second.lib.empty()) {
                    line += ",\"lib\":" + Q(it->second.lib.c_str());
                }
                if (!it->second.bindings.empty()) {
                    line += ",\"bindings\":" + it->second.bindings;
                }
            }
            s_lines.push_back(line + "}");
        }
        lines.swap(s_lines);
        s_enc.clear();
        s_cbGroups.clear();
        s_capTex.clear();
        s_capPipes.clear();
    }
    const std::string path = s_dir + "/" + s_traceName + ".trace.jsonl";
    std::string name = s_traceName;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
      std::ofstream f(path, std::ios::out | std::ios::trunc);
      for (const auto& l : lines) {
          f << l << '\n';
      }
      Logger::Info("Metal trace: wrote " + name + ".trace.jsonl (" + std::to_string(lines.size()) + " events)");
    });
}

void OnPresent(bool fromCommandBuffer)
{
    if (fromCommandBuffer) {
        s_sawCbPresent.store(true, std::memory_order_relaxed);
    } else if (s_sawCbPresent.load(std::memory_order_relaxed)) {
        return; // the command buffer's presentDrawable: already counted this frame
    }
    const uint64_t frame = s_frame.fetch_add(1) + 1;

    switch (s_traceState.load()) {
    case TraceState::Armed: {
        std::lock_guard<std::mutex> lock(s_capMutex);
        s_lines.clear();
        s_enc.clear();
        s_cbGroups.clear();
        s_capTex.clear();
        s_capPipes.clear();
        s_seq = 0;
        char buf[160];
        std::snprintf(buf, sizeof(buf), "{\"e\":\"begin\",\"frame\":%llu,\"pipes_named\":%llu,\"libraries\":%llu}",
                      static_cast<unsigned long long>(frame), static_cast<unsigned long long>(s_pipesNamed.load()),
                      static_cast<unsigned long long>(s_libCount.load()));
        s_lines.emplace_back(buf);
        s_dumpCount = 0;
        s_dump.store(s_dumpRequested);
        s_capture.store(true);
        s_traceState.store(TraceState::Capturing);
        break;
    }
    case TraceState::Capturing:
        s_capture.store(false);
        s_dump.store(false);
        s_dumpRequested = false;
        {
            std::lock_guard<std::mutex> lock(s_capMutex);
            s_lines.push_back("{\"e\":\"present\",\"frame\":" + std::to_string(frame) + "}");
        }
        StopCapture();
        s_traceState.store(TraceState::Idle);
        break;
    case TraceState::GpuArmed: {
        MTLCaptureDescriptor* desc = [[MTLCaptureDescriptor new] autorelease];
        desc.captureObject = MTLCreateSystemDefaultDevice();
        desc.destination = MTLCaptureDestinationGPUTraceDocument;
        const std::string path = s_dir + "/" + s_traceName + ".gputrace";
        desc.outputURL = [NSURL fileURLWithPath:@(path.c_str())];
        NSError* error = nil;
        if ([[MTLCaptureManager sharedCaptureManager] startCaptureWithDescriptor:desc error:&error]) {
            s_traceState.store(TraceState::GpuCapturing);
        } else {
            Logger::Warn(std::string("Metal trace: GPU capture failed (the game needs MTL_CAPTURE_ENABLED=1): ") +
                         (error ? error.localizedDescription.UTF8String : "unknown"));
            s_traceState.store(TraceState::Idle);
        }
        [desc.captureObject release];
        break;
    }
    case TraceState::GpuCapturing:
        [[MTLCaptureManager sharedCaptureManager] stopCapture];
        Logger::Info("Metal trace: wrote " + s_traceName + ".gputrace");
        s_traceState.store(TraceState::Idle);
        break;
    case TraceState::Idle:
        break;
    }

    if (s_perfActive.load()) {
        std::lock_guard<std::mutex> lock(s_perfMutex);
        Perf& p = *s_perfCur;
        if (frame + 1 >= p.start) {
            p.present.push_back(Now());
        }
        if (frame + 1 >= p.start + p.frames) {
            s_perfActive.store(false);
            // Let the last frames' command buffers complete.
            std::shared_ptr<Perf> window = s_perfCur;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 1500 * NSEC_PER_MSEC),
                           dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
                             WritePerf(window);
                           });
        }
    } else if (s_traceState.load() == TraceState::Idle && frame % 15 == 0) {
        PollRequests(frame);
    }
    StepBatch(frame);
    if (frame == 1) {
        std::ifstream startup(s_dir.substr(0, s_dir.find_last_of('/')) + "/cvar-startup.txt");
        for (std::string line; std::getline(startup, line);) {
            if (!line.empty() && line[0] != '#') {
                std::ofstream(s_dir + "/cvar.jsonl", std::ios::app) << ConfigVars::Apply(line) << '\n';
            }
        }
    }
}

// --- device: pipeline creation -----------------------------------------------------------------------------------
Orig o_cpsFnOptRefl, o_cpsDescOptRefl, o_cpsFn, o_cpsFnAsync, o_cpsFnOptAsync, o_cpsDescOptAsync;
using CpsFnOptRefl = id (*)(id, SEL, id, MTLPipelineOption, MTLAutoreleasedComputePipelineReflection*, NSError**);
using CpsFn = id (*)(id, SEL, id, NSError**);
using CpsFnAsync = void (*)(id, SEL, id, MTLNewComputePipelineStateCompletionHandler);
using CpsOptAsync = void (*)(id, SEL, id, MTLPipelineOption, MTLNewComputePipelineStateWithReflectionCompletionHandler);

MTLPipelineOption WithBindings(MTLPipelineOption o)
{
    return s_reflection ? (o | MTLPipelineOptionBindingInfo | MTLPipelineOptionBufferTypeInfo) : o;
}

id CpsCreate(Orig& o, id self, SEL sel, id fnOrDesc, MTLPipelineOption opt,
             MTLAutoreleasedComputePipelineReflection* refl, NSError** err, bool isDesc)
{
    MTLComputePipelineReflection* mine = nil;
    MTLAutoreleasedComputePipelineReflection* out = refl ? refl : &mine;
    id pso = ORIG(o, CpsFnOptRefl, self)(self, sel, fnOrDesc, WithBindings(opt), out, err);
    if (!pso && WithBindings(opt) != opt) {
        pso = ORIG(o, CpsFnOptRefl, self)(self, sel, fnOrDesc, opt, refl, err); // never fail where the game would not
    }
    id<MTLFunction> fn = isDesc ? [(MTLComputePipelineDescriptor*)fnOrDesc computeFunction] : (id<MTLFunction>)fnOrDesc;
    NSString* label = isDesc ? [(MTLComputePipelineDescriptor*)fnOrDesc label] : nil;
    RecordPipe(pso, 'c', FunctionName(fn), label, *out, LibraryOf(fn));
    return pso;
}

id H_cpsFnOptRefl(id self, SEL sel, id fn, MTLPipelineOption opt, MTLAutoreleasedComputePipelineReflection* refl,
                  NSError** err)
{
    return CpsCreate(o_cpsFnOptRefl, self, sel, fn, opt, refl, err, false);
}

id H_cpsDescOptRefl(id self, SEL sel, id desc, MTLPipelineOption opt, MTLAutoreleasedComputePipelineReflection* refl,
                    NSError** err)
{
    return CpsCreate(o_cpsDescOptRefl, self, sel, desc, opt, refl, err, true);
}

id H_cpsFn(id self, SEL sel, id fn, NSError** err)
{
    // Same as the options variant with no options; going through it records the bindings.
    if (o_cpsFnOptRefl.n.load()) {
        return CpsCreate(o_cpsFnOptRefl, self, @selector(newComputePipelineStateWithFunction:options:reflection:error:),
                         fn, MTLPipelineOptionNone, nullptr, err, false);
    }
    id pso = ORIG(o_cpsFn, CpsFn, self)(self, sel, fn, err);
    RecordPipe(pso, 'c', FunctionName(fn), nil, nil, LibraryOf(fn));
    return pso;
}

void CpsAsync(Orig& o, id self, SEL sel, id fnOrDesc, MTLPipelineOption opt,
              MTLNewComputePipelineStateWithReflectionCompletionHandler handler, bool isDesc)
{
    id<MTLFunction> fn = isDesc ? [(MTLComputePipelineDescriptor*)fnOrDesc computeFunction] : (id<MTLFunction>)fnOrDesc;
    std::string name = FunctionName(fn);
    std::string lib = LibraryOf(fn);
    NSString* label = isDesc ? [[(MTLComputePipelineDescriptor*)fnOrDesc label] retain] : nil;
    const MTLPipelineOption wanted = WithBindings(opt);
    MTLNewComputePipelineStateWithReflectionCompletionHandler copied = [handler copy];
    [fnOrDesc retain];
    auto fallback = ORIG(o, CpsOptAsync, self);
    ORIG(o, CpsOptAsync, self)(self, sel, fnOrDesc, wanted,
                               ^(id<MTLComputePipelineState> pso, MTLComputePipelineReflection* refl, NSError* err) {
                                 if (!pso && wanted != opt) {
                                     fallback(self, sel, fnOrDesc, opt, copied);
                                 } else {
                                     RecordPipe(pso, 'c', name, label, refl, lib);
                                     copied(pso, refl, err);
                                 }
                                 [copied release];
                                 [label release];
                                 [fnOrDesc release];
                               });
}

void H_cpsFnOptAsync(id self, SEL sel, id fn, MTLPipelineOption opt,
                     MTLNewComputePipelineStateWithReflectionCompletionHandler h)
{
    CpsAsync(o_cpsFnOptAsync, self, sel, fn, opt, h, false);
}

void H_cpsDescOptAsync(id self, SEL sel, id desc, MTLPipelineOption opt,
                       MTLNewComputePipelineStateWithReflectionCompletionHandler h)
{
    CpsAsync(o_cpsDescOptAsync, self, sel, desc, opt, h, true);
}

void H_cpsFnAsync(id self, SEL sel, id fn, MTLNewComputePipelineStateCompletionHandler h)
{
    if (o_cpsFnOptAsync.n.load()) {
        MTLNewComputePipelineStateCompletionHandler copied = [h copy];
        CpsAsync(o_cpsFnOptAsync, self, @selector(newComputePipelineStateWithFunction:options:completionHandler:), fn,
                 MTLPipelineOptionNone,
                 ^(id<MTLComputePipelineState> pso, MTLComputePipelineReflection*, NSError* err) {
                   copied(pso, err);
                   [copied release];
                 },
                 false);
        return;
    }
    std::string name = FunctionName(fn);
    std::string lib = LibraryOf(fn);
    MTLNewComputePipelineStateCompletionHandler copied = [h copy];
    ORIG(o_cpsFnAsync, CpsFnAsync, self)(self, sel, fn, ^(id<MTLComputePipelineState> pso, NSError* err) {
      RecordPipe(pso, 'c', name, nil, nil, lib);
      copied(pso, err);
      [copied release];
    });
}

// Render, mesh and tile pipelines: names only.
Orig o_rpsDesc, o_rpsDescOptRefl, o_rpsDescAsync, o_rpsDescOptAsync, o_mesh, o_meshAsync, o_tile, o_tileAsync;
using RpsDesc = id (*)(id, SEL, id, NSError**);
using RpsOptRefl = id (*)(id, SEL, id, MTLPipelineOption, void*, NSError**);
using RpsAsync = void (*)(id, SEL, id, MTLNewRenderPipelineStateCompletionHandler);
using RpsOptAsync = void (*)(id, SEL, id, MTLPipelineOption, MTLNewRenderPipelineStateWithReflectionCompletionHandler);

id H_rpsDesc(id self, SEL sel, id desc, NSError** err)
{
    id pso = ORIG(o_rpsDesc, RpsDesc, self)(self, sel, desc, err);
    RecordPipe(pso, 'r', RenderName(desc), [desc label], nil, RenderLibs(desc));
    return pso;
}

template <Orig* O, char Kind>
id H_rpsOptRefl(id self, SEL sel, id desc, MTLPipelineOption opt, void* refl, NSError** err)
{
    id pso = ORIG(*O, RpsOptRefl, self)(self, sel, desc, opt, refl, err);
    RecordPipe(pso, Kind, RenderName(desc), [desc label], nil, RenderLibs(desc));
    return pso;
}

void H_rpsDescAsync(id self, SEL sel, id desc, MTLNewRenderPipelineStateCompletionHandler h)
{
    std::string name = RenderName(desc);
    std::string lib = RenderLibs(desc);
    NSString* label = [[desc label] retain];
    MTLNewRenderPipelineStateCompletionHandler copied = [h copy];
    ORIG(o_rpsDescAsync, RpsAsync, self)(self, sel, desc, ^(id<MTLRenderPipelineState> pso, NSError* err) {
      RecordPipe(pso, 'r', name, label, nil, lib);
      copied(pso, err);
      [copied release];
      [label release];
    });
}

template <Orig* O, char Kind>
void H_rpsOptAsync(id self, SEL sel, id desc, MTLPipelineOption opt,
                   MTLNewRenderPipelineStateWithReflectionCompletionHandler h)
{
    std::string name = RenderName(desc);
    std::string lib = RenderLibs(desc);
    NSString* label = [[desc label] retain];
    MTLNewRenderPipelineStateWithReflectionCompletionHandler copied = [h copy];
    ORIG(*O, RpsOptAsync, self)(self, sel, desc, opt,
                                ^(id<MTLRenderPipelineState> pso, MTLRenderPipelineReflection* refl, NSError* err) {
                                  RecordPipe(pso, Kind, name, label, nil, lib);
                                  copied(pso, refl, err);
                                  [copied release];
                                  [label release];
                                });
}

// --- libraries and functions -------------------------------------------------------------------------------------
Orig o_libData, o_fnName, o_fnNameConst, o_fnNameConstAsync, o_fnDesc, o_fnDescAsync;
using FnHandler = void (^)(id<MTLFunction>, NSError*);

id H_libData(id self, SEL sel, dispatch_data_t data, NSError** err)
{
    id lib = ORIG(o_libData, id (*)(id, SEL, dispatch_data_t, NSError**), self)(self, sel, data, err);
    if (lib && data) {
        std::string fp = Fingerprint(data);
        std::unique_lock<std::shared_mutex> lock(s_libMutex);
        s_libFp[(__bridge const void*)lib] = std::move(fp);
        s_libCount.fetch_add(1, std::memory_order_relaxed);
    }
    return lib;
}

id H_fnName(id self, SEL sel, NSString* name)
{
    id fn = ORIG(o_fnName, id (*)(id, SEL, id), self)(self, sel, name);
    NoteFunction(fn, self);
    return fn;
}

id H_fnNameConst(id self, SEL sel, NSString* name, id constants, NSError** err)
{
    id fn = ORIG(o_fnNameConst, id (*)(id, SEL, id, id, NSError**), self)(self, sel, name, constants, err);
    NoteFunction(fn, self);
    return fn;
}

void H_fnNameConstAsync(id self, SEL sel, NSString* name, id constants, FnHandler h)
{
    FnHandler copied = [h copy];
    ORIG(o_fnNameConstAsync, void (*)(id, SEL, id, id, FnHandler), self)(
        self, sel, name, constants, ^(id<MTLFunction> fn, NSError* err) {
          NoteFunction(fn, self);
          copied(fn, err);
          [copied release];
        });
}

id H_fnDesc(id self, SEL sel, id desc, NSError** err)
{
    id fn = ORIG(o_fnDesc, id (*)(id, SEL, id, NSError**), self)(self, sel, desc, err);
    NoteFunction(fn, self);
    return fn;
}

void H_fnDescAsync(id self, SEL sel, id desc, FnHandler h)
{
    FnHandler copied = [h copy];
    ORIG(o_fnDescAsync, void (*)(id, SEL, id, FnHandler), self)(
        self, sel, desc, ^(id<MTLFunction> fn, NSError* err) {
          NoteFunction(fn, self);
          copied(fn, err);
          [copied release];
        });
}

// --- command buffer ----------------------------------------------------------------------------------------------
Orig o_cbCompute, o_cbComputeType, o_cbComputeDesc, o_cbRender, o_cbBlit, o_cbBlitDesc, o_cbAccel, o_cbAccelDesc,
    o_cbParallel, o_cbCommit, o_cbPresent, o_cbPresentAt, o_cbPresentAfter, o_push, o_pop;
using Id0 = id (*)(id, SEL);
using Id1 = id (*)(id, SEL, id);
using IdU = id (*)(id, SEL, NSUInteger);
using V0 = void (*)(id, SEL);
using V1 = void (*)(id, SEL, id);
using V1T = void (*)(id, SEL, id, CFTimeInterval);

std::string RenderTargets(MTLRenderPassDescriptor* rp)
{
    std::string out = ",\"rt\":[";
    bool first = true;
    for (NSUInteger i = 0; i < 8; ++i) {
        id<MTLTexture> t = rp.colorAttachments[i].texture;
        if (t) {
            NoteTexture(t);
            out += (first ? "" : ",") + P((__bridge const void*)t);
            first = false;
        }
    }
    out += "]";
    if (id<MTLTexture> t = rp.depthAttachment.texture) {
        NoteTexture(t);
        out += ",\"depth\":" + P((__bridge const void*)t);
    }
    if (id<MTLTexture> t = rp.stencilAttachment.texture) {
        NoteTexture(t);
        out += ",\"stencil\":" + P((__bridge const void*)t);
    }
    return out;
}

size_t BytesPerPixel(NSUInteger f)
{
    switch (f) {
    case 10: case 13: return 1;
    case 20: case 23: case 25: case 30: return 2;
    case 53: case 55: case 60: case 62: case 63: case 65: case 70: case 71: case 73: case 80: case 81: case 90:
    case 92: case 94: return 4;
    case 103: case 105: case 110: case 113: case 115: return 8;
    case 123: case 125: return 16;
    default: return 0;
    }
}

float Half(uint16_t h)
{
    __fp16 v;
    std::memcpy(&v, &h, 2);
    return static_cast<float>(v);
}

float SmallFloat(uint32_t bits, int mantissa) // unsigned 11/10-bit float (RG11B10)
{
    const uint32_t e = bits >> mantissa, m = bits & ((1u << mantissa) - 1);
    if (e == 0) {
        return std::ldexp(static_cast<float>(m), -14 - mantissa);
    }
    return std::ldexp(1.0f + static_cast<float>(m) / (1u << mantissa), static_cast<int>(e) - 15);
}

uint8_t ToByte(float v, bool tonemap)
{
    if (tonemap) {
        v = v / (1.0f + std::max(v, 0.0f));
        v = std::sqrt(std::max(v, 0.0f));
    }
    return static_cast<uint8_t>(std::clamp(v, 0.0f, 1.0f) * 255.0f + 0.5f);
}

void WritePng(const std::string& path, const std::vector<uint8_t>& rgba, size_t w, size_t h)
{
    CGColorSpaceRef cs = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGDataProviderRef provider = CGDataProviderCreateWithData(nullptr, rgba.data(), rgba.size(), nullptr);
    CGImageRef image = CGImageCreate(w, h, 8, 32, w * 4, cs, kCGImageAlphaNoneSkipLast, provider, nullptr, false,
                                     kCGRenderingIntentDefault);
    CFURLRef url = CFURLCreateFromFileSystemRepresentation(nullptr, reinterpret_cast<const UInt8*>(path.c_str()),
                                                           static_cast<CFIndex>(path.size()), false);
    if (CGImageDestinationRef dest = CGImageDestinationCreateWithURL(url, CFSTR("public.png"), 1, nullptr)) {
        CGImageDestinationAddImage(dest, image, nullptr);
        CGImageDestinationFinalize(dest);
        CFRelease(dest);
    }
    CFRelease(url);
    CGImageRelease(image);
    CGDataProviderRelease(provider);
    CGColorSpaceRelease(cs);
}

// Converts one texture's bytes to RGBA8 (and its alpha channel to a second image, when it has one).
void ConvertAndWrite(const uint8_t* src, size_t w, size_t h, NSUInteger f, const std::string& base)
{
    std::vector<uint8_t> rgb(w * h * 4, 255), alpha;
    const size_t bpp = BytesPerPixel(f);
    const bool hasAlpha = f == 70 || f == 71 || f == 80 || f == 81 || f == 90 || f == 94 || f == 110 || f == 115 ||
                          f == 125;
    if (hasAlpha) {
        alpha.assign(w * h * 4, 255);
    }
    for (size_t i = 0; i < w * h; ++i) {
        const uint8_t* p = src + i * bpp;
        float c[4] = {0, 0, 0, 1};
        bool tonemap = false;
        uint32_t u = 0;
        std::memcpy(&u, p, std::min<size_t>(bpp, 4));
        switch (f) {
        case 10: case 13: c[0] = c[1] = c[2] = p[0] / 255.0f; break;
        case 20: case 23: c[0] = c[1] = c[2] = (u & 0xFFFF) / 65535.0f; break;
        case 25: c[0] = c[1] = c[2] = Half(u & 0xFFFF); tonemap = true; break;
        case 30: c[0] = p[0] / 255.0f; c[1] = p[1] / 255.0f; break;
        case 53: c[0] = c[1] = c[2] = (u & 0xFF) / 255.0f; break;
        case 55: { float v; std::memcpy(&v, p, 4); c[0] = c[1] = c[2] = v; tonemap = true; break; }
        case 60: c[0] = (u & 0xFFFF) / 65535.0f; c[1] = (u >> 16) / 65535.0f; break;
        case 62: c[0] = 0.5f + 0.5f * std::max(-1.0f, static_cast<int16_t>(u & 0xFFFF) / 32767.0f);
                 c[1] = 0.5f + 0.5f * std::max(-1.0f, static_cast<int16_t>(u >> 16) / 32767.0f); break;
        case 63: c[0] = (u & 0xFFFF) / 65535.0f; c[1] = (u >> 16) / 65535.0f; break;
        case 65: c[0] = 0.5f + 0.5f * Half(u & 0xFFFF); c[1] = 0.5f + 0.5f * Half(u >> 16); break;
        case 70: case 71: case 73: for (int k = 0; k < 4; ++k) c[k] = p[k] / 255.0f; break;
        case 80: case 81: c[0] = p[2] / 255.0f; c[1] = p[1] / 255.0f; c[2] = p[0] / 255.0f; c[3] = p[3] / 255.0f; break;
        case 90: c[0] = (u & 0x3FF) / 1023.0f; c[1] = ((u >> 10) & 0x3FF) / 1023.0f; c[2] = ((u >> 20) & 0x3FF) / 1023.0f;
                 c[3] = (u >> 30) / 3.0f; break;
        case 94: c[2] = (u & 0x3FF) / 1023.0f; c[1] = ((u >> 10) & 0x3FF) / 1023.0f; c[0] = ((u >> 20) & 0x3FF) / 1023.0f;
                 c[3] = (u >> 30) / 3.0f; break;
        case 92: c[0] = SmallFloat(u & 0x7FF, 6); c[1] = SmallFloat((u >> 11) & 0x7FF, 6);
                 c[2] = SmallFloat(u >> 22, 5); tonemap = true; break;
        case 115: for (int k = 0; k < 4; ++k) { uint16_t hv; std::memcpy(&hv, p + 2 * k, 2); c[k] = Half(hv); }
                  tonemap = true; break;
        case 125: std::memcpy(c, p, 16); tonemap = true; break;
        default: break;
        }
        for (int k = 0; k < 3; ++k) {
            rgb[i * 4 + k] = ToByte(c[k], tonemap);
        }
        if (hasAlpha) {
            alpha[i * 4] = alpha[i * 4 + 1] = alpha[i * 4 + 2] = ToByte(c[3], false);
        }
    }
    WritePng(base + ".png", rgb, w, h);
    if (hasAlpha) {
        WritePng(base + "-alpha.png", alpha, w, h);
    }
}

// Caller holds s_capMutex. Encodes a copy of t (slice 0: the game's render targets are 2D arrays) into a shared buffer
// on cb; the PNG is written when cb completes.
void DumpTexture(id cbObject, id<MTLTexture> t, const std::string& what)
{
    id<MTLCommandBuffer> cb = cbObject;
    if (!cb || !t || s_dumpCount >= kMaxDumps) {
        return;
    }
    const NSUInteger f = t.pixelFormat;
    const size_t bpp = BytesPerPixel(f);
    if (!bpp || (t.textureType != MTLTextureType2D && t.textureType != MTLTextureType2DArray) || t.sampleCount > 1 || t.isFramebufferOnly ||
        t.storageMode == MTLStorageModeMemoryless) {
        char why[200];
        std::snprintf(why, sizeof(why), "Metal trace: dump skips %s (format %lu, type %lu, samples %lu, framebufferOnly %d, "
                      "storage %lu)", what.c_str(), (unsigned long)f, (unsigned long)t.textureType,
                      (unsigned long)t.sampleCount, t.isFramebufferOnly ? 1 : 0, (unsigned long)t.storageMode);
        Logger::Info(why);
        return;
    }
    const NSUInteger w = t.width, h = t.height, row = w * bpp;
    id<MTLBuffer> buffer = [t.device newBufferWithLength:row * h options:MTLResourceStorageModeShared];
    if (!buffer) {
        return;
    }
    const bool wasCapturing = s_capture.exchange(false); // keep our own blit out of the trace
    id<MTLBlitCommandEncoder> blit = [cb blitCommandEncoder];
    [blit copyFromTexture:t sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0, 0, 0)
               sourceSize:MTLSizeMake(w, h, 1) toBuffer:buffer destinationOffset:0 destinationBytesPerRow:row
                 destinationBytesPerImage:row * h];
    [blit endEncoding];
    s_capture.store(wasCapturing);
    const char* fmt = FormatName(f);
    char name[256];
    std::snprintf(name, sizeof(name), "%s-%02d-%s-%lux%lu-%s", s_dumpName.c_str(), s_dumpCount++, what.c_str(),
                  (unsigned long)w, (unsigned long)h, fmt ? fmt : std::to_string(f).c_str());
    const std::string base = s_dir + "/" + name;
    [cb addCompletedHandler:^(id<MTLCommandBuffer>) {
      ConvertAndWrite(static_cast<const uint8_t*>(buffer.contents), w, h, f, base);
      [buffer release];
    }];
}

void BeginEncoder(id cb, id enc, char kind, int dispatchType, MTLRenderPassDescriptor* rp)
{
    if (!enc || !s_capture.load(std::memory_order_relaxed)) {
        return;
    }
    std::lock_guard<std::mutex> lock(s_capMutex);
    Enc& e = EncOf(enc);
    e = {};
    e.cb = (__bridge const void*)cb;
    e.kind = kind;
    std::string line = "{\"e\":\"eb\"," + SeqField() + ",\"enc\":" + P((__bridge const void*)enc) +
                       ",\"cb\":" + P((__bridge const void*)cb) + ",\"kind\":\"" + std::string(1, kind) + "\"";
    if (dispatchType >= 0) {
        line += ",\"concurrent\":" + std::to_string(dispatchType);
    }
    auto g = s_cbGroups.find((__bridge const void*)cb);
    if (g != s_cbGroups.end() && !g->second.empty()) {
        line += ",\"grp\":" + Q(Groups(g->second).c_str());
    }
    if (rp) {
        line += RenderTargets(rp);
        if (s_dump.load()) {
            e.cbObject = cb;
            for (NSUInteger i = 0; i < 8; ++i) {
                if (id<MTLTexture> t = rp.colorAttachments[i].texture) {
                    e.renderTargets.push_back(t);
                }
            }
        }
    }
    Emit(line + "}");
}

id H_cbCompute(id self, SEL sel)
{
    id enc = ORIG(o_cbCompute, Id0, self)(self, sel);
    BeginEncoder(self, enc, 'c', 0, nil);
    return enc;
}

id H_cbComputeType(id self, SEL sel, NSUInteger type)
{
    id enc = ORIG(o_cbComputeType, IdU, self)(self, sel, type);
    BeginEncoder(self, enc, 'c', type == MTLDispatchTypeConcurrent ? 1 : 0, nil);
    return enc;
}

id H_cbComputeDesc(id self, SEL sel, id desc)
{
    id enc = ORIG(o_cbComputeDesc, Id1, self)(self, sel, desc);
    BeginEncoder(self, enc, 'c', [(MTLComputePassDescriptor*)desc dispatchType] == MTLDispatchTypeConcurrent ? 1 : 0,
                 nil);
    return enc;
}

id H_cbRender(id self, SEL sel, id desc)
{
    id enc = ORIG(o_cbRender, Id1, self)(self, sel, desc);
    if (Denoise::Active()) {
        Denoise::RenderPass(desc);
    }
    BeginEncoder(self, enc, 'r', -1, desc);
    return enc;
}

id H_cbParallel(id self, SEL sel, id desc)
{
    id enc = ORIG(o_cbParallel, Id1, self)(self, sel, desc);
    if (Denoise::Active()) {
        Denoise::RenderPass(desc);
    }
    BeginEncoder(self, enc, 'p', -1, desc);
    return enc;
}

// Sub-encoders of a parallel render encoder (one per encoding thread).
Orig o_parSub;
id H_parSub(id self, SEL sel)
{
    id enc = ORIG(o_parSub, Id0, self)(self, sel);
    if (enc && s_capture.load(std::memory_order_relaxed)) {
        std::lock_guard<std::mutex> lock(s_capMutex);
        Enc& e = EncOf(enc);
        e = {};
        e.kind = 'r';
        Emit("{\"e\":\"eb\"," + SeqField() + ",\"enc\":" + P((__bridge const void*)enc) + ",\"parent\":" +
             P((__bridge const void*)self) + ",\"kind\":\"r\"}");
    }
    return enc;
}

id H_cbBlit(id self, SEL sel)
{
    id enc = ORIG(o_cbBlit, Id0, self)(self, sel);
    BeginEncoder(self, enc, 'b', -1, nil);
    return enc;
}

id H_cbBlitDesc(id self, SEL sel, id desc)
{
    id enc = ORIG(o_cbBlitDesc, Id1, self)(self, sel, desc);
    BeginEncoder(self, enc, 'b', -1, nil);
    return enc;
}

id H_cbAccel(id self, SEL sel)
{
    id enc = ORIG(o_cbAccel, Id0, self)(self, sel);
    BeginEncoder(self, enc, 'a', -1, nil);
    return enc;
}

id H_cbAccelDesc(id self, SEL sel, id desc)
{
    id enc = ORIG(o_cbAccelDesc, Id1, self)(self, sel, desc);
    BeginEncoder(self, enc, 'a', -1, nil);
    return enc;
}

void H_cbCommit(id self, SEL sel)
{
    if (s_capture.load(std::memory_order_relaxed)) {
        std::lock_guard<std::mutex> lock(s_capMutex);
        std::string line = "{\"e\":\"commit\"," + SeqField() + ",\"cb\":" + P((__bridge const void*)self);
        if (NSString* label = [(id<MTLCommandBuffer>)self label]) {
            line += ",\"label\":" + Q(label);
        }
        Emit(line + "}");
        s_cbGroups.erase((__bridge const void*)self);
    }
    if (s_perfActive.load(std::memory_order_relaxed)) {
        const uint64_t frame = s_frame.load() + 1; // the frame being encoded
        std::shared_ptr<Perf> window;
        {
            std::lock_guard<std::mutex> lock(s_perfMutex);
            window = s_perfCur;
        }
        if (window && frame >= window->start && frame < window->start + window->frames) {
            const size_t index = frame - window->start;
            [(id<MTLCommandBuffer>)self addCompletedHandler:^(id<MTLCommandBuffer> cb) {
              const double s = cb.GPUStartTime, e = cb.GPUEndTime;
              if (e > s) {
                  std::lock_guard<std::mutex> l(s_perfMutex);
                  if (index < window->gpu.size()) {
                      window->gpu[index].emplace_back(s, e);
                  }
              }
            }];
        }
    }
    ORIG(o_cbCommit, V0, self)(self, sel);
}

void H_cbPresent(id self, SEL sel, id drawable)
{
    OnPresent(true);
    ORIG(o_cbPresent, V1, self)(self, sel, drawable);
}

void H_cbPresentAt(id self, SEL sel, id drawable, CFTimeInterval t)
{
    OnPresent(true);
    ORIG(o_cbPresentAt, V1T, self)(self, sel, drawable, t);
}

void H_cbPresentAfter(id self, SEL sel, id drawable, CFTimeInterval t)
{
    OnPresent(true);
    ORIG(o_cbPresentAfter, V1T, self)(self, sel, drawable, t);
}

// pushDebugGroup:/popDebugGroup on command buffers and encoders.
void H_push(id self, SEL sel, NSString* name)
{
    if (s_capture.load(std::memory_order_relaxed)) {
        std::lock_guard<std::mutex> lock(s_capMutex);
        const void* key = (__bridge const void*)self;
        auto e = s_enc.find(key);
        (e != s_enc.end() ? e->second.groups : s_cbGroups[key]).push_back(name ? name.UTF8String : "");
    }
    ORIG(o_push, V1, self)(self, sel, name);
}

void H_pop(id self, SEL sel)
{
    if (s_capture.load(std::memory_order_relaxed)) {
        std::lock_guard<std::mutex> lock(s_capMutex);
        const void* key = (__bridge const void*)self;
        auto e = s_enc.find(key);
        auto& g = e != s_enc.end() ? e->second.groups : s_cbGroups[key];
        if (!g.empty()) {
            g.pop_back();
        }
    }
    ORIG(o_pop, V0, self)(self, sel);
}

// --- drawable ----------------------------------------------------------------------------------------------------
Orig o_drPresent, o_drPresentAt, o_drPresentAfter;
using VT = void (*)(id, SEL, CFTimeInterval);

void H_drPresent(id self, SEL sel)
{
    OnPresent(false);
    ORIG(o_drPresent, V0, self)(self, sel);
}

void H_drPresentAt(id self, SEL sel, CFTimeInterval t)
{
    OnPresent(false);
    ORIG(o_drPresentAt, VT, self)(self, sel, t);
}

void H_drPresentAfter(id self, SEL sel, CFTimeInterval t)
{
    OnPresent(false);
    ORIG(o_drPresentAfter, VT, self)(self, sel, t);
}

// --- encoders ----------------------------------------------------------------------------------------------------
Orig o_setCps, o_setTex, o_setTexs, o_setAS, o_setIFT, o_dispTG, o_dispTh, o_dispInd, o_endEnc, o_setRps, o_exec;
Orig o_asBuild, o_asRefit, o_asRefitOpt, o_asCompact;
using SetTex = void (*)(id, SEL, id, NSUInteger);
using SetTexs = void (*)(id, SEL, const id*, NSRange);
using Disp = void (*)(id, SEL, MTLSize, MTLSize);
using DispInd = void (*)(id, SEL, id, NSUInteger, MTLSize);
using Exec = void (*)(id, SEL, id, NSRange);

void H_setCps(id self, SEL sel, id pso)
{
    if (s_skip.load(std::memory_order_relaxed)) {
        std::shared_lock<std::shared_mutex> lock(s_skipMutex);
        t_enc = (__bridge const void*)self;
        t_drop = s_skipPipes.count((__bridge const void*)pso) != 0;
    }
    if (Denoise::Active()) {
        std::string label;
        {
            std::shared_lock<std::shared_mutex> pipes(s_pipesMutex);
            auto it = s_pipes.find((__bridge const void*)pso);
            if (it != s_pipes.end()) {
                label = it->second.label;
            }
        }
        Denoise::BindPipeline(self, label);
    }
    if (s_capture.load(std::memory_order_relaxed)) {
        std::lock_guard<std::mutex> lock(s_capMutex);
        Enc& e = EncOf(self);
        e.pso = (__bridge const void*)pso;
        ++e.psoSets;
        s_capPipes.insert(e.pso);
    }
    ORIG(o_setCps, V1, self)(self, sel, pso);
}

void H_setRps(id self, SEL sel, id pso)
{
    if (s_capture.load(std::memory_order_relaxed)) {
        std::lock_guard<std::mutex> lock(s_capMutex);
        Enc& e = EncOf(self);
        if (e.pso != (__bridge const void*)pso) {
            e.pso = (__bridge const void*)pso;
            s_capPipes.insert(e.pso);
            Emit("{\"e\":\"rps\"," + SeqField() + ",\"enc\":" + P((__bridge const void*)self) + ",\"pso\":" + P(e.pso) +
                 "}");
        }
    }
    ORIG(o_setRps, V1, self)(self, sel, pso);
}

void H_setTex(id self, SEL sel, id tex, NSUInteger index)
{
    if (s_capture.load(std::memory_order_relaxed)) {
        std::lock_guard<std::mutex> lock(s_capMutex);
        NoteTexture(tex);
        EncOf(self).tex[static_cast<uint32_t>(index)] = (__bridge const void*)tex;
    }
    ORIG(o_setTex, SetTex, self)(self, sel, tex, index);
}

void H_setTexs(id self, SEL sel, const id* texs, NSRange range)
{
    if (s_capture.load(std::memory_order_relaxed)) {
        std::lock_guard<std::mutex> lock(s_capMutex);
        Enc& e = EncOf(self);
        for (NSUInteger i = 0; i < range.length; ++i) {
            NoteTexture(texs[i]);
            e.tex[static_cast<uint32_t>(range.location + i)] = (__bridge const void*)texs[i];
        }
    }
    ORIG(o_setTexs, SetTexs, self)(self, sel, texs, range);
}

void H_setAS(id self, SEL sel, id as, NSUInteger index)
{
    if (s_capture.load(std::memory_order_relaxed)) {
        std::lock_guard<std::mutex> lock(s_capMutex);
        EncOf(self).as = true;
    }
    ORIG(o_setAS, SetTex, self)(self, sel, as, index);
}

void H_setIFT(id self, SEL sel, id table, NSUInteger index)
{
    if (s_capture.load(std::memory_order_relaxed)) {
        std::lock_guard<std::mutex> lock(s_capMutex);
        EncOf(self).ift = true;
    }
    ORIG(o_setIFT, SetTex, self)(self, sel, table, index);
}

// Residency declarations: with descriptor heaps (Metal Shader Converter), these name the resources an encoder's
// dispatches read and write. usage: 1 read, 2 write.
Orig o_useRes, o_useResStages, o_useRess, o_useRessStages, o_useHeap, o_useHeapStages, o_useHeaps, o_useHeapsStages;

void NoteUse(id self, id const* res, NSUInteger count, NSUInteger usage)
{
    std::lock_guard<std::mutex> lock(s_capMutex);
    std::string line = "{\"e\":\"use\"," + SeqField() + ",\"enc\":" + P((__bridge const void*)self) +
                       ",\"usage\":" + std::to_string(usage) + ",\"res\":[";
    for (NSUInteger i = 0; i < count; ++i) {
        id r = res[i];
        if ([r respondsToSelector:@selector(pixelFormat)]) {
            NoteTexture(r);
            if (s_dump.load() && !s_dumpPipes.empty()) {
                EncOf(self).uses.emplace_back(r, usage);
            }
        }
        line += (i ? "," : "") + P((__bridge const void*)r);
    }
    Emit(line + "]}");
}

void H_useRes(id self, SEL sel, id res, NSUInteger usage)
{
    if (Denoise::Active()) {
        Denoise::Use(self, reinterpret_cast<const void* const*>(&res), 1, usage);
    }
    if (s_capture.load(std::memory_order_relaxed)) {
        NoteUse(self, &res, 1, usage);
    }
    ORIG(o_useRes, void (*)(id, SEL, id, NSUInteger), self)(self, sel, res, usage);
}

void H_useResStages(id self, SEL sel, id res, NSUInteger usage, NSUInteger stages)
{
    if (s_capture.load(std::memory_order_relaxed)) {
        NoteUse(self, &res, 1, usage);
    }
    ORIG(o_useResStages, void (*)(id, SEL, id, NSUInteger, NSUInteger), self)(self, sel, res, usage, stages);
}

void H_useRess(id self, SEL sel, const id* res, NSUInteger count, NSUInteger usage)
{
    if (Denoise::Active()) {
        Denoise::Use(self, reinterpret_cast<const void* const*>(res), count, usage);
    }
    if (s_capture.load(std::memory_order_relaxed)) {
        NoteUse(self, res, count, usage);
    }
    ORIG(o_useRess, void (*)(id, SEL, const id*, NSUInteger, NSUInteger), self)(self, sel, res, count, usage);
}

void H_useRessStages(id self, SEL sel, const id* res, NSUInteger count, NSUInteger usage, NSUInteger stages)
{
    if (s_capture.load(std::memory_order_relaxed)) {
        NoteUse(self, res, count, usage);
    }
    ORIG(o_useRessStages, void (*)(id, SEL, const id*, NSUInteger, NSUInteger, NSUInteger), self)(self, sel, res, count,
                                                                                                  usage, stages);
}

void NoteHeaps(id self, id const* heaps, NSUInteger count)
{
    std::lock_guard<std::mutex> lock(s_capMutex);
    std::string line = "{\"e\":\"heap\"," + SeqField() + ",\"enc\":" + P((__bridge const void*)self) + ",\"heaps\":[";
    for (NSUInteger i = 0; i < count; ++i) {
        line += (i ? "," : "") + P((__bridge const void*)heaps[i]);
    }
    Emit(line + "]}");
}

void H_useHeap(id self, SEL sel, id heap)
{
    if (s_capture.load(std::memory_order_relaxed)) {
        NoteHeaps(self, &heap, 1);
    }
    ORIG(o_useHeap, V1, self)(self, sel, heap);
}

void H_useHeapStages(id self, SEL sel, id heap, NSUInteger stages)
{
    if (s_capture.load(std::memory_order_relaxed)) {
        NoteHeaps(self, &heap, 1);
    }
    ORIG(o_useHeapStages, void (*)(id, SEL, id, NSUInteger), self)(self, sel, heap, stages);
}

void H_useHeaps(id self, SEL sel, const id* heaps, NSUInteger count)
{
    if (s_capture.load(std::memory_order_relaxed)) {
        NoteHeaps(self, heaps, count);
    }
    ORIG(o_useHeaps, void (*)(id, SEL, const id*, NSUInteger), self)(self, sel, heaps, count);
}

void H_useHeapsStages(id self, SEL sel, const id* heaps, NSUInteger count, NSUInteger stages)
{
    if (s_capture.load(std::memory_order_relaxed)) {
        NoteHeaps(self, heaps, count);
    }
    ORIG(o_useHeapsStages, void (*)(id, SEL, const id*, NSUInteger, NSUInteger), self)(self, sel, heaps, count, stages);
}

void EmitDispatch(id self, const char* mode, MTLSize a, MTLSize b)
{
    std::lock_guard<std::mutex> lock(s_capMutex);
    Enc& e = EncOf(self);
    char sizes[160];
    std::snprintf(sizes, sizeof(sizes), ",\"g\":[%lu,%lu,%lu],\"t\":[%lu,%lu,%lu]", (unsigned long)a.width,
                  (unsigned long)a.height, (unsigned long)a.depth, (unsigned long)b.width, (unsigned long)b.height,
                  (unsigned long)b.depth);
    std::string line = "{\"e\":\"d\"," + SeqField() + ",\"enc\":" + P((__bridge const void*)self) + ",\"pso\":" +
                       P(e.pso) + ",\"mode\":\"" + mode + "\"" + sizes + ",\"tex\":[";
    bool first = true;
    for (const auto& [slot, tex] : e.tex) {
        if (tex) {
            line += (first ? "[" : ",[") + std::to_string(slot) + "," + P(tex) + "]";
            first = false;
        }
    }
    line += "]";
    if (e.as) {
        line += ",\"as\":1";
    }
    if (e.ift) {
        line += ",\"ift\":1";
    }
    if (!e.groups.empty()) {
        line += ",\"grp\":" + Q(Groups(e.groups).c_str());
    }
    Emit(line + "}");
    if (!e.uses.empty()) {
        std::shared_lock<std::shared_mutex> pipes(s_pipesMutex);
        auto it = s_pipes.find(e.pso);
        if (it != s_pipes.end()) {
            const std::string& key = s_dumpPipes.count(it->second.label) ? it->second.label : it->second.name;
            if (s_dumpPipes.count(key)) {
                for (const auto& [t, usage] : e.uses) {
                    e.dispatchTex.emplace_back(t, key + (usage == 1 ? "-r" : usage == 2 ? "-w" : "-rw"));
                }
            }
        }
        e.uses.clear();
    }
}

// Skip test: true when this encoder's bound pipeline is one to drop.
bool Dropped(id self)
{
    if (s_skip.load(std::memory_order_relaxed) && t_drop && t_enc == (__bridge const void*)self) {
        s_skipped.fetch_add(1, std::memory_order_relaxed);
        return true;
    }
    return false;
}

void H_dispTG(id self, SEL sel, MTLSize groups, MTLSize threads)
{
    if (s_capture.load(std::memory_order_relaxed)) {
        EmitDispatch(self, "tg", groups, threads);
    }
    if (Dropped(self) || (Denoise::Active() && Denoise::Dispatch(self))) {
        return;
    }
    ORIG(o_dispTG, Disp, self)(self, sel, groups, threads);
}

void H_dispTh(id self, SEL sel, MTLSize grid, MTLSize threads)
{
    if (s_capture.load(std::memory_order_relaxed)) {
        EmitDispatch(self, "th", grid, threads);
    }
    if (Dropped(self) || (Denoise::Active() && Denoise::Dispatch(self))) {
        return;
    }
    ORIG(o_dispTh, Disp, self)(self, sel, grid, threads);
}

void H_dispInd(id self, SEL sel, id buffer, NSUInteger offset, MTLSize threads)
{
    if (s_capture.load(std::memory_order_relaxed)) {
        EmitDispatch(self, "ind", MTLSizeMake(0, 0, 0), threads);
    }
    if (Dropped(self) || (Denoise::Active() && Denoise::Dispatch(self))) {
        return;
    }
    ORIG(o_dispInd, DispInd, self)(self, sel, buffer, offset, threads);
}

void H_exec(id self, SEL sel, id icb, NSRange range)
{
    if (s_capture.load(std::memory_order_relaxed)) {
        std::lock_guard<std::mutex> lock(s_capMutex);
        Emit("{\"e\":\"icb\"," + SeqField() + ",\"enc\":" + P((__bridge const void*)self) +
             ",\"n\":" + std::to_string(range.length) + "}");
    }
    ORIG(o_exec, Exec, self)(self, sel, icb, range);
}

void H_endEnc(id self, SEL sel)
{
    if (Denoise::Active()) {
        Denoise::EndEncoding(self);
    }
    id dumpCb = nil;
    std::vector<id> dumpTargets;
    std::vector<std::pair<id, std::string>> dumpDispatchTex;
    if (s_capture.load(std::memory_order_relaxed)) {
        std::lock_guard<std::mutex> lock(s_capMutex);
        std::string line = "{\"e\":\"ee\"," + SeqField() + ",\"enc\":" + P((__bridge const void*)self);
        if (NSString* label = [(id<MTLCommandEncoder>)self label]) {
            line += ",\"label\":" + Q(label);
        }
        Emit(line + "}");
        auto it = s_enc.find((__bridge const void*)self);
        if (it != s_enc.end()) {
            if (it->second.renderTargets.size() >= 2) {
                dumpCb = it->second.cbObject;
                dumpTargets = it->second.renderTargets;
            }
            if (!it->second.dispatchTex.empty()) {
                dumpCb = (__bridge id)it->second.cb;
                dumpDispatchTex = std::move(it->second.dispatchTex);
            }
            s_enc.erase(it);
        }
    }
    ORIG(o_endEnc, V0, self)(self, sel);
    if (dumpCb) {
        Logger::Info("Metal trace: dump encoder with " + std::to_string(dumpTargets.size()) + " render targets, " +
                     std::to_string(dumpDispatchTex.size()) + " dispatch textures");
        std::lock_guard<std::mutex> lock(s_capMutex);
        for (size_t i = 0; i < dumpTargets.size(); ++i) {
            DumpTexture(dumpCb, dumpTargets[i], "rt" + std::to_string(i));
        }
        for (const auto& [t, what] : dumpDispatchTex) {
            DumpTexture(dumpCb, t, what);
        }
    }
}

std::string AsDesc(id desc)
{
    std::string out = ",\"desc\":" + Q(class_getName(object_getClass(desc)));
    if ([desc isKindOfClass:[MTLPrimitiveAccelerationStructureDescriptor class]]) {
        out += ",\"geoms\":" +
               std::to_string([[(MTLPrimitiveAccelerationStructureDescriptor*)desc geometryDescriptors] count]);
    } else if ([desc isKindOfClass:[MTLInstanceAccelerationStructureDescriptor class]]) {
        out += ",\"instances\":" + std::to_string([(MTLInstanceAccelerationStructureDescriptor*)desc instanceCount]);
    }
    if ([desc respondsToSelector:@selector(usage)]) {
        out += ",\"usage\":" + std::to_string([(MTLAccelerationStructureDescriptor*)desc usage]);
    }
    return out;
}

void EmitAs(id self, const char* op, id desc)
{
    std::lock_guard<std::mutex> lock(s_capMutex);
    Emit("{\"e\":\"as\"," + SeqField() + ",\"enc\":" + P((__bridge const void*)self) + ",\"op\":\"" + op + "\"" +
         (desc ? AsDesc(desc) : std::string()) + "}");
}

void H_asBuild(id self, SEL sel, id as, id desc, id scratch, NSUInteger off)
{
    if (s_capture.load(std::memory_order_relaxed)) {
        EmitAs(self, "build", desc);
    }
    ORIG(o_asBuild, void (*)(id, SEL, id, id, id, NSUInteger), self)(self, sel, as, desc, scratch, off);
}

void H_asRefit(id self, SEL sel, id src, id desc, id dst, id scratch, NSUInteger off)
{
    if (s_skipRefit.load(std::memory_order_relaxed)) {
        s_skipped.fetch_add(1, std::memory_order_relaxed);
        return;
    }
    if (s_capture.load(std::memory_order_relaxed)) {
        EmitAs(self, "refit", desc);
    }
    ORIG(o_asRefit, void (*)(id, SEL, id, id, id, id, NSUInteger), self)(self, sel, src, desc, dst, scratch, off);
}

void H_asRefitOpt(id self, SEL sel, id src, id desc, id dst, id scratch, NSUInteger off, NSUInteger opts)
{
    if (s_skipRefit.load(std::memory_order_relaxed)) {
        s_skipped.fetch_add(1, std::memory_order_relaxed);
        return;
    }
    if (s_capture.load(std::memory_order_relaxed)) {
        EmitAs(self, "refit", desc);
    }
    ORIG(o_asRefitOpt, void (*)(id, SEL, id, id, id, id, NSUInteger, NSUInteger), self)(self, sel, src, desc, dst,
                                                                                         scratch, off, opts);
}

void H_asCompact(id self, SEL sel, id src, id dst)
{
    if (s_capture.load(std::memory_order_relaxed)) {
        EmitAs(self, "compact", nil);
    }
    ORIG(o_asCompact, void (*)(id, SEL, id, id), self)(self, sel, src, dst);
}

// --- MetalFX -----------------------------------------------------------------------------------------------------
Orig o_fxTemporalNew, o_fxSpatialNew, o_fxTemporalEncode, o_fxSpatialEncode;
std::atomic<int> s_fxLogged{0};

std::string FxTex(const char* key, id<MTLTexture> t)
{
    if (!t) {
        return {};
    }
    NoteTexture(t);
    return ",\"" + std::string(key) + "\":" + P((__bridge const void*)t);
}

void H_fxTemporalEncode(id self, SEL sel, id cb)
{
    if (s_skipMetalFX.load(std::memory_order_relaxed)) {
        s_skipped.fetch_add(1, std::memory_order_relaxed);
        return;
    }
    if (s_capture.load(std::memory_order_relaxed) || s_fxLogged.load() < 1) {
        id<MTLFXTemporalScaler> s = self;
        std::lock_guard<std::mutex> lock(s_capMutex);
        char nums[400];
        std::snprintf(nums, sizeof(nums),
                      ",\"in\":[%lu,%lu],\"content\":[%lu,%lu],\"out\":[%lu,%lu],\"jitter\":[%.4f,%.4f],"
                      "\"mvscale\":[%.4f,%.4f],\"depthReversed\":%d,\"reset\":%d,\"preExposure\":%.4f",
                      (unsigned long)s.inputWidth, (unsigned long)s.inputHeight, (unsigned long)s.inputContentWidth,
                      (unsigned long)s.inputContentHeight, (unsigned long)s.outputWidth, (unsigned long)s.outputHeight,
                      s.jitterOffsetX, s.jitterOffsetY, s.motionVectorScaleX, s.motionVectorScaleY,
                      s.isDepthReversed ? 1 : 0, s.reset ? 1 : 0, s.preExposure);
        std::string line = "{\"e\":\"fx\"," + SeqField() + ",\"type\":\"temporal\",\"cb\":" +
                           P((__bridge const void*)cb) + nums + FxTex("color", s.colorTexture) +
                           FxTex("depth", s.depthTexture) + FxTex("motion", s.motionTexture) +
                           FxTex("output", s.outputTexture) + FxTex("exposure", s.exposureTexture) +
                           FxTex("reactive", s.reactiveMaskTexture) + "}";
        if (s_capture.load()) {
            Emit(line);
        }
        if (s_fxLogged.fetch_add(1) == 0) {
            Logger::Info("Metal trace: first MetalFX temporal scaler call " + line);
        }
    }
    if (!(Denoise::Active() && Denoise::EncodeScaler(self, cb))) {
        ORIG(o_fxTemporalEncode, V1, self)(self, sel, cb);
    }
    if (s_dump.load()) {
        id<MTLFXTemporalScaler> sc = self;
        std::lock_guard<std::mutex> lock(s_capMutex);
        DumpTexture(cb, sc.colorTexture, "fx-color");
        DumpTexture(cb, sc.motionTexture, "fx-motion");
        DumpTexture(cb, sc.outputTexture, "fx-output");
    }
}

void H_fxSpatialEncode(id self, SEL sel, id cb)
{
    if (s_capture.load(std::memory_order_relaxed)) {
        id<MTLFXSpatialScaler> s = self;
        std::lock_guard<std::mutex> lock(s_capMutex);
        char nums[160];
        std::snprintf(nums, sizeof(nums), ",\"in\":[%lu,%lu],\"out\":[%lu,%lu]", (unsigned long)s.inputWidth,
                      (unsigned long)s.inputHeight, (unsigned long)s.outputWidth, (unsigned long)s.outputHeight);
        Emit("{\"e\":\"fx\"," + SeqField() + ",\"type\":\"spatial\",\"cb\":" + P((__bridge const void*)cb) + nums +
             FxTex("color", s.colorTexture) + FxTex("output", s.outputTexture) + "}");
    }
    ORIG(o_fxSpatialEncode, V1, self)(self, sel, cb);
}

id H_fxTemporalNew(id self, SEL sel, id device)
{
    id scaler = ORIG(o_fxTemporalNew, Id1, self)(self, sel, device);
    MTLFXTemporalScalerDescriptor* d = self;
    char buf[320];
    std::snprintf(buf, sizeof(buf),
                  "Metal trace: game created MTLFXTemporalScaler %lux%lu -> %lux%lu color=%lu depth=%lu motion=%lu "
                  "output=%lu autoExposure=%d inputContentProperties=%d class=%s",
                  (unsigned long)d.inputWidth, (unsigned long)d.inputHeight, (unsigned long)d.outputWidth,
                  (unsigned long)d.outputHeight, (unsigned long)d.colorTextureFormat, (unsigned long)d.depthTextureFormat,
                  (unsigned long)d.motionTextureFormat, (unsigned long)d.outputTextureFormat,
                  d.isAutoExposureEnabled ? 1 : 0, d.isInputContentPropertiesEnabled ? 1 : 0,
                  scaler ? class_getName(object_getClass(scaler)) : "nil");
    Logger::Info(buf);
    if (scaler) {
        Hook(object_getClass(scaler), @selector(encodeToCommandBuffer:), (IMP)H_fxTemporalEncode, o_fxTemporalEncode);
    }
    return scaler;
}

id H_fxSpatialNew(id self, SEL sel, id device)
{
    id scaler = ORIG(o_fxSpatialNew, Id1, self)(self, sel, device);
    MTLFXSpatialScalerDescriptor* d = self;
    char buf[200];
    std::snprintf(buf, sizeof(buf), "Metal trace: game created MTLFXSpatialScaler %lux%lu -> %lux%lu",
                  (unsigned long)d.inputWidth, (unsigned long)d.inputHeight, (unsigned long)d.outputWidth,
                  (unsigned long)d.outputHeight);
    Logger::Info(buf);
    if (scaler) {
        Hook(object_getClass(scaler), @selector(encodeToCommandBuffer:), (IMP)H_fxSpatialEncode, o_fxSpatialEncode);
    }
    return scaler;
}

// --- install -----------------------------------------------------------------------------------------------------
std::string PluginDir()
{
    Dl_info info{};
    if (dladdr(reinterpret_cast<const void*>(&PluginDir), &info) && info.dli_fname) {
        std::string path = info.dli_fname;
        return path.substr(0, path.find_last_of('/'));
    }
    return "red4ext/plugins/MetalFXDenoiser";
}

bool s_installedAll = false;

} // namespace

namespace MetalTrace {

bool Install()
{
    if (s_installedAll) {
        return true;
    }
    s_dir = PluginDir() + "/trace";
    mkdir(s_dir.c_str(), 0755);
    if (const char* r = std::getenv("METALFX_TRACE_REFLECTION")) {
        s_reflection = r[0] != '0';
    }
    if (const char* m = std::getenv("METALFX_DENOISE")) {
        Denoise::SetMode(m);
    }

    // The driver's classes are private (AGX...), so find them by making one object of each kind.
    Class device = nil, queueCb = nil, compute = nil, computeConc = nil, render = nil, blit = nil, accel = nil,
          library = nil, parallel = nil;
    @autoreleasepool {
        id<MTLDevice> dev = MTLCreateSystemDefaultDevice();
        if (!dev) {
            Logger::Warn("Metal trace: no Metal device");
            return false;
        }
        device = object_getClass(dev);
        id<MTLLibrary> lib = [dev newLibraryWithSource:@"kernel void probe() {}" options:nil error:nil];
        library = object_getClass(lib);
        [lib release];
        id<MTLCommandQueue> queue = [dev newCommandQueue];
        id<MTLCommandBuffer> cb = [queue commandBuffer];
        queueCb = object_getClass(cb);
        id<MTLComputeCommandEncoder> c = [cb computeCommandEncoder];
        compute = object_getClass(c);
        [c endEncoding];
        c = [cb computeCommandEncoderWithDispatchType:MTLDispatchTypeConcurrent];
        computeConc = object_getClass(c);
        [c endEncoding];
        MTLTextureDescriptor* td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
                                                                                      width:4
                                                                                     height:4
                                                                                  mipmapped:NO];
        td.usage = MTLTextureUsageRenderTarget;
        id<MTLTexture> rt = [dev newTextureWithDescriptor:td];
        MTLRenderPassDescriptor* rp = [MTLRenderPassDescriptor renderPassDescriptor];
        rp.colorAttachments[0].texture = rt;
        id<MTLRenderCommandEncoder> r = [cb renderCommandEncoderWithDescriptor:rp];
        render = object_getClass(r);
        [r endEncoding];
        id<MTLParallelRenderCommandEncoder> pr = [cb parallelRenderCommandEncoderWithDescriptor:rp];
        parallel = object_getClass(pr);
        id<MTLRenderCommandEncoder> sub = [pr renderCommandEncoder];
        if (object_getClass(sub) != render) {
            Logger::Info(std::string("Metal trace: parallel sub-encoder class ") + class_getName(object_getClass(sub)));
        }
        [sub endEncoding];
        [pr endEncoding];
        id<MTLBlitCommandEncoder> b = [cb blitCommandEncoder];
        blit = object_getClass(b);
        [b endEncoding];
        if (dev.supportsRaytracing) {
            id<MTLAccelerationStructureCommandEncoder> a = [cb accelerationStructureCommandEncoder];
            accel = object_getClass(a);
            [a endEncoding];
        }
        [rt release];
        [queue release];
    }

    int ok = 0, total = 0;
    auto H = [&](Class cls, SEL sel, IMP imp, Orig& o) {
        ++total;
        ok += Hook(cls, sel, imp, o) ? 1 : 0;
    };

    // Pipeline creation.
    H(device, @selector(newComputePipelineStateWithFunction:options:reflection:error:), (IMP)H_cpsFnOptRefl,
      o_cpsFnOptRefl);
    H(device, @selector(newComputePipelineStateWithDescriptor:options:reflection:error:), (IMP)H_cpsDescOptRefl,
      o_cpsDescOptRefl);
    H(device, @selector(newComputePipelineStateWithFunction:error:), (IMP)H_cpsFn, o_cpsFn);
    H(device, @selector(newComputePipelineStateWithFunction:options:completionHandler:), (IMP)H_cpsFnOptAsync,
      o_cpsFnOptAsync);
    H(device, @selector(newComputePipelineStateWithDescriptor:options:completionHandler:), (IMP)H_cpsDescOptAsync,
      o_cpsDescOptAsync);
    H(device, @selector(newComputePipelineStateWithFunction:completionHandler:), (IMP)H_cpsFnAsync, o_cpsFnAsync);
    H(device, @selector(newRenderPipelineStateWithDescriptor:error:), (IMP)H_rpsDesc, o_rpsDesc);
    H(device, @selector(newRenderPipelineStateWithDescriptor:options:reflection:error:),
      (IMP)H_rpsOptRefl<&o_rpsDescOptRefl, 'r'>, o_rpsDescOptRefl);
    H(device, @selector(newRenderPipelineStateWithDescriptor:completionHandler:), (IMP)H_rpsDescAsync, o_rpsDescAsync);
    H(device, @selector(newRenderPipelineStateWithDescriptor:options:completionHandler:),
      (IMP)H_rpsOptAsync<&o_rpsDescOptAsync, 'r'>, o_rpsDescOptAsync);
    H(device, @selector(newRenderPipelineStateWithMeshDescriptor:options:reflection:error:),
      (IMP)H_rpsOptRefl<&o_mesh, 'm'>, o_mesh);
    H(device, @selector(newRenderPipelineStateWithMeshDescriptor:options:completionHandler:),
      (IMP)H_rpsOptAsync<&o_meshAsync, 'm'>, o_meshAsync);
    H(device, @selector(newRenderPipelineStateWithTileDescriptor:options:reflection:error:),
      (IMP)H_rpsOptRefl<&o_tile, 't'>, o_tile);
    H(device, @selector(newRenderPipelineStateWithTileDescriptor:options:completionHandler:),
      (IMP)H_rpsOptAsync<&o_tileAsync, 't'>, o_tileAsync);

    // Libraries and functions (pipeline -> function -> library fingerprint).
    H(device, @selector(newLibraryWithData:error:), (IMP)H_libData, o_libData);
    H(library, @selector(newFunctionWithName:), (IMP)H_fnName, o_fnName);
    H(library, @selector(newFunctionWithName:constantValues:error:), (IMP)H_fnNameConst, o_fnNameConst);
    H(library, @selector(newFunctionWithName:constantValues:completionHandler:), (IMP)H_fnNameConstAsync,
      o_fnNameConstAsync);
    H(library, @selector(newFunctionWithDescriptor:error:), (IMP)H_fnDesc, o_fnDesc);
    H(library, @selector(newFunctionWithDescriptor:completionHandler:), (IMP)H_fnDescAsync, o_fnDescAsync);

    // Command buffers.
    H(queueCb, @selector(computeCommandEncoder), (IMP)H_cbCompute, o_cbCompute);
    H(queueCb, @selector(computeCommandEncoderWithDispatchType:), (IMP)H_cbComputeType, o_cbComputeType);
    H(queueCb, @selector(computeCommandEncoderWithDescriptor:), (IMP)H_cbComputeDesc, o_cbComputeDesc);
    H(queueCb, @selector(renderCommandEncoderWithDescriptor:), (IMP)H_cbRender, o_cbRender);
    H(queueCb, @selector(parallelRenderCommandEncoderWithDescriptor:), (IMP)H_cbParallel, o_cbParallel);
    H(queueCb, @selector(blitCommandEncoder), (IMP)H_cbBlit, o_cbBlit);
    H(queueCb, @selector(blitCommandEncoderWithDescriptor:), (IMP)H_cbBlitDesc, o_cbBlitDesc);
    H(queueCb, @selector(accelerationStructureCommandEncoder), (IMP)H_cbAccel, o_cbAccel);
    H(queueCb, @selector(accelerationStructureCommandEncoderWithDescriptor:), (IMP)H_cbAccelDesc, o_cbAccelDesc);
    H(queueCb, @selector(commit), (IMP)H_cbCommit, o_cbCommit);
    H(queueCb, @selector(presentDrawable:), (IMP)H_cbPresent, o_cbPresent);
    H(queueCb, @selector(presentDrawable:atTime:), (IMP)H_cbPresentAt, o_cbPresentAt);
    H(queueCb, @selector(presentDrawable:afterMinimumDuration:), (IMP)H_cbPresentAfter, o_cbPresentAfter);

    // Drawables (games that call -[CAMetalDrawable present] themselves).
    Class drawable = objc_getClass("CAMetalDrawable");
    H(drawable, @selector(present), (IMP)H_drPresent, o_drPresent);
    H(drawable, @selector(presentAtTime:), (IMP)H_drPresentAt, o_drPresentAt);
    H(drawable, @selector(presentAfterMinimumDuration:), (IMP)H_drPresentAfter, o_drPresentAfter);

    // Encoders.
    for (Class cls : {compute, computeConc}) {
        H(cls, @selector(setComputePipelineState:), (IMP)H_setCps, o_setCps);
        H(cls, @selector(setTexture:atIndex:), (IMP)H_setTex, o_setTex);
        H(cls, @selector(setTextures:withRange:), (IMP)H_setTexs, o_setTexs);
        H(cls, @selector(setAccelerationStructure:atBufferIndex:), (IMP)H_setAS, o_setAS);
        H(cls, @selector(setIntersectionFunctionTable:atBufferIndex:), (IMP)H_setIFT, o_setIFT);
        H(cls, @selector(dispatchThreadgroups:threadsPerThreadgroup:), (IMP)H_dispTG, o_dispTG);
        H(cls, @selector(dispatchThreads:threadsPerThreadgroup:), (IMP)H_dispTh, o_dispTh);
        H(cls, @selector(dispatchThreadgroupsWithIndirectBuffer:indirectBufferOffset:threadsPerThreadgroup:),
          (IMP)H_dispInd, o_dispInd);
        H(cls, @selector(executeCommandsInBuffer:withRange:), (IMP)H_exec, o_exec);
        H(cls, @selector(useResource:usage:), (IMP)H_useRes, o_useRes);
        H(cls, @selector(useResources:count:usage:), (IMP)H_useRess, o_useRess);
        H(cls, @selector(useHeap:), (IMP)H_useHeap, o_useHeap);
        H(cls, @selector(useHeaps:count:), (IMP)H_useHeaps, o_useHeaps);
    }
    H(render, @selector(useResource:usage:stages:), (IMP)H_useResStages, o_useResStages);
    H(render, @selector(useResources:count:usage:stages:), (IMP)H_useRessStages, o_useRessStages);
    H(render, @selector(useHeap:stages:), (IMP)H_useHeapStages, o_useHeapStages);
    H(render, @selector(useHeaps:count:stages:), (IMP)H_useHeapsStages, o_useHeapsStages);
    H(render, @selector(setRenderPipelineState:), (IMP)H_setRps, o_setRps);
    H(parallel, @selector(renderCommandEncoder), (IMP)H_parSub, o_parSub);
    H(parallel, @selector(endEncoding), (IMP)H_endEnc, o_endEnc);
    if (accel) {
        H(accel, @selector(buildAccelerationStructure:descriptor:scratchBuffer:scratchBufferOffset:), (IMP)H_asBuild,
          o_asBuild);
        H(accel, @selector(refitAccelerationStructure:descriptor:destination:scratchBuffer:scratchBufferOffset:),
          (IMP)H_asRefit, o_asRefit);
        H(accel,
          @selector(refitAccelerationStructure:descriptor:destination:scratchBuffer:scratchBufferOffset:options:),
          (IMP)H_asRefitOpt, o_asRefitOpt);
        H(accel, @selector(copyAndCompactAccelerationStructure:toAccelerationStructure:), (IMP)H_asCompact,
          o_asCompact);
    }
    for (Class cls : {compute, computeConc, render, blit, accel}) {
        if (cls) {
            H(cls, @selector(endEncoding), (IMP)H_endEnc, o_endEnc);
        }
    }
    for (Class cls : {queueCb, compute, computeConc, render, blit, accel}) {
        if (cls) {
            H(cls, @selector(pushDebugGroup:), (IMP)H_push, o_push);
            H(cls, @selector(popDebugGroup), (IMP)H_pop, o_pop);
        }
    }

    // MetalFX: scaler creation is logged; each new scaler's class gets its encode hooked.
    H([MTLFXTemporalScalerDescriptor class], @selector(newTemporalScalerWithDevice:), (IMP)H_fxTemporalNew,
      o_fxTemporalNew);
    H([MTLFXSpatialScalerDescriptor class], @selector(newSpatialScalerWithDevice:), (IMP)H_fxSpatialNew,
      o_fxSpatialNew);

    char buf[400];
    std::snprintf(buf, sizeof(buf),
                  "Metal trace: %d/%d hooks (device %s, command buffer %s, compute %s/%s, render %s); requests in %s",
                  ok, total, class_getName(device), class_getName(queueCb), class_getName(compute),
                  class_getName(computeConc), class_getName(render), s_dir.c_str());
    Logger::Info(buf);
    s_installedAll = true;
    return true;
}

void Uninstall()
{
    std::lock_guard<std::mutex> lock(s_hookMutex);
    for (auto it = s_installed.rbegin(); it != s_installed.rend(); ++it) {
        method_setImplementation(it->first, it->second);
    }
    s_installed.clear();
    s_installedAll = false;
}

} // namespace MetalTrace
